import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

import 'capture/image_preprocessor.dart' show applyClahe, claheGrayToRgb, eraseLightPixels;
import 'inference/encoded_symbol.dart';
import 'inference/segmentation_runner.dart';
import 'inference/transformer_runner.dart';
import 'pipeline/homr/predictions.dart';
import 'pipeline/homr/staff_detection.dart' as homr;
import 'pipeline/homr/staff_parsing.dart';
import 'pipeline/musicxml_assembler.dart';

/// Discrete pipeline stages reported via [OmrOrchestrator.recognise] progress
/// callback.
enum OmrStage {
  segmenting,
  detecting,
  recognising,
  assembling,
}

/// Thrown when the pipeline cannot recover enough information to produce output.
class OmrException implements Exception {
  final String message;
  const OmrException(this.message);
  @override
  String toString() => 'OmrException: $message';
}

/// End-to-end OMR pipeline: preprocessed PNG → MusicXML string.
///
/// Input is the binary-thresholded, 1920 px-wide PNG produced by
/// [ImagePreprocessor] (Phase 3), optionally cropped to the music region by
/// the user in [CropScreen].
///
/// Pipeline:
///   1. SegNet segmentation (Phase 4) → class mask
///   2. homr anchor+fragment staff detection (Phase 7) → Staff grid per staff
///   3. Staff strip crop + transformer (Phase 4/5 bridge) → EncodedSymbol list per staff
///   4. MusicXML assembly (Phase 5) → MusicXML string
class OmrOrchestrator {
  final SegmentationRunner _segRunner;
  final TransformerRunner _transformerRunner;

  OmrOrchestrator({
    SegmentationRunner? segRunner,
    TransformerRunner? transformerRunner,
  })  : _segRunner = segRunner ?? SegmentationRunner(),
        _transformerRunner = transformerRunner ?? TransformerRunner();

  /// Recognises [preprocessedPng] and returns a MusicXML 4.0 string.
  ///
  /// [onProgress] is called with each [OmrStage] as the pipeline advances.
  /// [title] is embedded in the MusicXML work-title element.
  ///
  /// Throws [OmrException] if no staves are found or no symbols are decoded.
  /// When [artifactDir] is set, the pipeline writes intermediate PNGs there:
  ///   clahe.png            — full CLAHE image (input to SegNet)
  ///   mask_class4.png      — class-4 (staff-line) pixels only, white-on-black
  ///   staff_N_raw.png      — crop before dewarping
  ///   staff_N_dewarped.png — crop after dewarping (input to transformer)
  Future<String> recognise(
    Uint8List preprocessedPng, {
    void Function(OmrStage)? onProgress,
    String title = '',
    bool skipClahe = false,
    String? artifactDir,
    int? pencilGateThreshold,
  }) async {
    // Decode once; used for CLAHE, dimensions, and transformer crops.
    final fullImage = img.decodeImage(preprocessedPng);
    if (fullImage == null) throw const OmrException('Failed to decode preprocessed PNG');

    // Optional pencil gate: whiten pixels above threshold before CLAHE so that
    // pencil annotations (typically 160–220 gray) are treated as background.
    // Ink (0–60) is unaffected. A pencil_gate.png artifact is saved when
    // artifactDir is set so the effect can be inspected visually.
    final img.Image claheInput;
    if (pencilGateThreshold != null) {
      final gated = eraseLightPixels(fullImage, threshold: pencilGateThreshold);
      if (artifactDir != null) {
        Directory(artifactDir).createSync(recursive: true);
        File('$artifactDir/pencil_gate.png')
            .writeAsBytesSync(img.encodePng(claheGrayToRgb(gated)));
      }
      claheInput = gated;
    } else {
      claheInput = fullImage;
    }

    // Apply CLAHE preprocessing — mirrors Python homr's color_adjust.apply_clahe:
    //   cv2.cvtColor(BGR→GRAY) + cv2.createCLAHE(clipLimit=1.0, tileGridSize=(8,8))
    //
    // applyClahe() returns a 1-channel uint8 grayscale image.
    // claheGrayToRgb() expands it to 3-channel (R=G=B) so that img.grayscale()
    // inside the inference runners computes identity (0.299*r + 0.587*r + 0.114*r = r)
    // rather than 0.886*r (which it applies to 1-channel images where .b returns 0).
    //
    // Both SegNet and transformer receive the same 3-channel CLAHE image.
    //
    // skipClahe=true is for diagnostic tests with pre-CLAHEd Python assets.
    final img.Image claheGray = skipClahe
        ? (claheInput.numChannels == 1
            ? claheInput
            : applyClahe(claheInput))
        : applyClahe(claheInput);
    final claheImage = claheGrayToRgb(claheGray);
    final clahePng = img.encodePng(claheImage);

    if (artifactDir != null) {
      Directory(artifactDir).createSync(recursive: true);
      File('$artifactDir/clahe.png').writeAsBytesSync(clahePng);
    }

    // ── 1. Segmentation (CLAHE grayscale input) ───────────────────────────────
    onProgress?.call(OmrStage.segmenting);
    final classMask = await _segRunner.runSegmentation(clahePng);

    final imgW = fullImage.width;
    final imgH = fullImage.height;

    // ── 2. Staff detection (homr anchor + fragment port) ──────────────────────
    onProgress?.call(OmrStage.detecting);
    final staves = detectStavesFromClassMap(classMask, imgW, imgH);
    if (staves.isEmpty) {
      throw const OmrException('No staves detected in segmentation mask');
    }
    final crops = staffCropRegions(staves, imgW, imgH);

    if (artifactDir != null) {
      // Render class-4 (staff-line) pixels as white on black for inspection.
      final maskBytes = Uint8List(imgW * imgH);
      for (int i = 0; i < classMask.length; i++) {
        if (classMask[i] == 4) maskBytes[i] = 255;
      }
      final maskImg = img.Image.fromBytes(
        width: imgW,
        height: imgH,
        bytes: maskBytes.buffer,
        format: img.Format.uint8,
        numChannels: 1,
        order: img.ChannelOrder.red,
      );
      File('$artifactDir/mask_class4.png')
          .writeAsBytesSync(img.encodePng(maskImg));

      // Teaser: CLAHE image with each detected staff's grid lines and crop
      // region overlaid in a distinct colour — mirrors Python homr's _teaser.png.
      File('$artifactDir/teaser.png').writeAsBytesSync(
          _generateTeaser(claheImage, staves, crops));
    }

    // ── 3. Transformer per staff ──────────────────────────────────────────────
    onProgress?.call(OmrStage.recognising);

    // Concatenate all staves into one voice, separated by 'newline' tokens.
    // This matches the Python reference (parse_staffs appends EncodedSymbol("newline")
    // between staves and passes one flat list per voice to generate_xml).
    final newline = const EncodedSymbol(
      rhythm: 'newline', pitch: '.', lift: '.', articulation: '.', position: '.',
    );
    final List<EncodedSymbol> voice = [];
    for (int si = 0; si < staves.length; si++) {
      // homr staff_parsing: tight region crop (±2u x, ±4u y, neighbour-clamped),
      // 1-D middle-line dewarp, then resize+centre onto a 256×1280 canvas — the
      // exact transformer input format. The transformer's own letterbox is then
      // an identity no-op.
      final canvas = prepareStaffImage(claheImage, staves[si], staves);
      final stripPng = img.encodePng(canvas);

      if (artifactDir != null) {
        File('$artifactDir/staff_${si}_input.png').writeAsBytesSync(stripPng);
      }

      final liftDebug = artifactDir != null ? <String>[] : null;
      final rhythmDebug = artifactDir != null ? <String>[] : null;
      final symbols = await _transformerRunner.runTransformer(stripPng,
          liftDebug: liftDebug, rhythmDebug: rhythmDebug);
      if (symbols.isNotEmpty) {
        voice.addAll(symbols);
        voice.add(newline);
      }

      if (artifactDir != null && liftDebug != null) {
        final lines = [
          for (int i = 0; i < symbols.length; i++)
            '${symbols[i].rhythm}|${symbols[i].pitch}|${symbols[i].lift}\t${liftDebug[i]}',
        ];
        File('$artifactDir/staff_${si}_lift_debug.txt')
            .writeAsStringSync(lines.join('\n'));
      }

      if (artifactDir != null && rhythmDebug != null) {
        final lines = [
          for (int i = 0; i < symbols.length; i++)
            '${symbols[i].rhythm}|${symbols[i].pitch}|${symbols[i].lift}\t${rhythmDebug[i]}',
        ];
        File('$artifactDir/staff_${si}_rhythm_debug.txt')
            .writeAsStringSync(lines.join('\n'));
      }
    }  // end for staves

    if (voice.isEmpty) {
      throw const OmrException('Transformer produced no symbols for any staff');
    }

    if (artifactDir != null) {
      // One token per line: rhythm|pitch|lift — lets you grep for barline runs.
      final tokens = voice.map((s) => '${s.rhythm}|${s.pitch}|${s.lift}').join('\n');
      File('$artifactDir/tokens.txt').writeAsStringSync(tokens);
    }

    // ── 4. MusicXML assembly ──────────────────────────────────────────────────
    onProgress?.call(OmrStage.assembling);
    return MusicXmlAssembler.assemble([voice], title: title);
  }

  /// Produces a teaser PNG: CLAHE image with each staff's resampled grid lines
  /// drawn as curved polylines (following the detected curvature) and the crop
  /// boundaries marked — mirrors Python homr's _teaser.png.
  ///
  /// Colour cycle (RGB): red, green, blue, yellow, magenta, cyan — one per staff.
  static Uint8List _generateTeaser(
      img.Image claheRgb, List<homr.Staff> staves, List<StaffCrop> crops) {
    final out = claheRgb.clone();
    final W = out.width;
    final H = out.height;

    const colours = [
      (255, 80, 80),   // red
      (80, 220, 80),   // green
      (80, 140, 255),  // blue
      (255, 220, 60),  // yellow
      (220, 80, 220),  // magenta
      (60, 220, 220),  // cyan
    ];

    for (int si = 0; si < staves.length; si++) {
      final staff = staves[si];
      final (cr, cg, cb) = colours[si % colours.length];
      final colour = img.ColorRgb8(cr, cg, cb);

      // Draw each of the 5 lines as a polyline through the resampled grid.
      for (int line = 0; line < 5; line++) {
        for (int j = 0; j < staff.grid.length - 1; j++) {
          final p1 = staff.grid[j];
          final p2 = staff.grid[j + 1];
          img.drawLine(out,
              x1: p1.x.round().clamp(0, W - 1),
              y1: p1.y[line].round().clamp(0, H - 1),
              x2: p2.x.round().clamp(0, W - 1),
              y2: p2.y[line].round().clamp(0, H - 1),
              color: colour,
              thickness: 2);
        }
      }

      // 1-px lines at the crop boundaries.
      if (si < crops.length) {
        for (final boundary in [crops[si].yTop, crops[si].yBottom - 1]) {
          final y = boundary.clamp(0, H - 1);
          for (int x = 0; x < W; x++) {
            out.setPixelRgb(x, y, cr, cg, cb);
          }
        }
      }
    }

    return img.encodePng(out);
  }
}
