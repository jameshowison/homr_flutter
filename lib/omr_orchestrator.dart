import 'dart:typed_data';
import 'package:image/image.dart' as img;

import 'inference/encoded_symbol.dart';
import 'inference/segmentation_runner.dart';
import 'inference/transformer_runner.dart';
import 'pipeline/musicxml_assembler.dart';
import 'pipeline/segmentation_postprocessor.dart';

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
///   2. Row-scan staff detection (Phase 5) → StaffBounds per staff
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
  Future<String> recognise(
    Uint8List preprocessedPng, {
    void Function(OmrStage)? onProgress,
    String title = '',
  }) async {
    // ── 1. Segmentation ───────────────────────────────────────────────────────
    onProgress?.call(OmrStage.segmenting);
    final classMask = await _segRunner.runSegmentation(preprocessedPng);

    // Decode image dimensions — needed by the postprocessor and crop step.
    final fullImage = img.decodeImage(preprocessedPng);
    if (fullImage == null) throw const OmrException('Failed to decode preprocessed PNG');
    final imgW = fullImage.width;
    final imgH = fullImage.height;

    // ── 2. Staff detection ────────────────────────────────────────────────────
    onProgress?.call(OmrStage.detecting);
    final staves = SegmentationPostprocessor.detectStaves(classMask, imgW, imgH);
    if (staves.isEmpty) {
      throw const OmrException('No staves detected in segmentation mask');
    }

    // ── 3. Transformer per staff ──────────────────────────────────────────────
    onProgress?.call(OmrStage.recognising);

    // Convert full image to uint8 grayscale once; reuse for all staff crops.
    final gray = fullImage.format == img.Format.uint1
        ? fullImage.convert(format: img.Format.uint8, numChannels: 1)
        : img.grayscale(fullImage).convert(format: img.Format.uint8, numChannels: 1);

    final List<List<EncodedSymbol>> allSymbols = [];
    for (final staff in staves) {
      final stripPng = _cropStaffStrip(gray, staff);
      final symbols = await _transformerRunner.runTransformer(stripPng);
      if (symbols.isNotEmpty) allSymbols.add(symbols);
    }

    if (allSymbols.isEmpty) {
      throw const OmrException('Transformer produced no symbols for any staff');
    }

    // ── 4. MusicXML assembly ──────────────────────────────────────────────────
    onProgress?.call(OmrStage.assembling);
    return MusicXmlAssembler.assemble(allSymbols, title: title);
  }

  /// Crops [gray] to the bounding box defined by [staff] and encodes as PNG.
  static Uint8List _cropStaffStrip(img.Image gray, StaffBounds staff) {
    final cropped = img.copyCrop(
      gray,
      x: staff.xLeft,
      y: staff.yTop,
      width: staff.cropWidth,
      height: staff.cropHeight,
    );
    return img.encodePng(cropped);
  }
}
