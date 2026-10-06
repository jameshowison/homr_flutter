// Diagnostic test — prints internal pipeline state to find what's wrong.
// Run on simulator: flutter test integration_test/phase5_diagnostic_test.dart
// ignore_for_file: implementation_imports
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:image/image.dart' as img;

import 'package:homr_flutter/src/inference/segmentation_runner.dart';
import 'package:homr_flutter/src/inference/transformer_runner.dart';
import 'package:homr_flutter/src/pipeline/segmentation_postprocessor.dart';
import 'package:homr_flutter_demo/omr_models.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('diagnostic: staves and transformer tokens', (tester) async {
    final data = await rootBundle.load('assets/test_images/happy_farmer_bw_50.png');
    final pngBytes = data.buffer.asUint8List();

    // Decode image
    final fullImage = img.decodeImage(pngBytes)!;
    // ignore: avoid_print
    print('\nImage: ${fullImage.width}×${fullImage.height}, format=${fullImage.format}');

    // Segmentation
    // ignore: avoid_print
    print('Running segmentation...');
    final sw = Stopwatch()..start();
    final mask = await SegmentationRunner(demoModels.segnet).runSegmentation(pngBytes);
    // ignore: avoid_print
    print('Segmentation: ${sw.elapsedMilliseconds} ms, mask length=${mask.length}');

    // Class counts
    final counts = List<int>.filled(6, 0);
    for (final v in mask) { if (v < 6) counts[v]++; }
    // ignore: avoid_print
    print('Class counts: bg=${counts[0]} stems=${counts[1]} notes=${counts[2]} clefs=${counts[3]} staff=${counts[4]} other=${counts[5]}');

    // Staff detection
    final staves = SegmentationPostprocessor.detectStaves(mask, fullImage.width, fullImage.height);
    // ignore: avoid_print
    print('\nDetected ${staves.length} stave(s):');
    for (int i = 0; i < staves.length; i++) {
      final s = staves[i];
      // ignore: avoid_print
      print('  Staff $i: lineYs=${s.lineYs}, unitSize=${s.unitSize.toStringAsFixed(1)}, '
            'crop y=${s.yTop}–${s.yBottom} (${s.cropHeight}px tall)');
    }

    if (staves.isEmpty) {
      fail('No staves detected — cannot proceed with transformer test');
    }

    // Convert to uint8 grayscale (same as orchestrator)
    final gray = fullImage.format == img.Format.uint1
        ? fullImage.convert(format: img.Format.uint8, numChannels: 1)
        : img.grayscale(fullImage).convert(format: img.Format.uint8, numChannels: 1);

    // Dump raw row-density peaks (replicate postprocessor logic here for visibility)
    // ignore: avoid_print
    print('\nRaw row-density peaks (class-4 pixels per row, top-30):');
    final density = List<int>.filled(fullImage.height, 0);
    for (int y = 0; y < fullImage.height; y++) {
      final base = y * fullImage.width;
      for (int x = 0; x < fullImage.width; x++) {
        if (mask[base + x] == 4) density[y]++;
      }
    }
    final minH = (fullImage.width * 0.03).round();
    // ignore: avoid_print
    print('  minHeight threshold: $minH (3% of width ${fullImage.width})');
    final allPeaks = <int>[];
    for (int i = 1; i < density.length - 1; i++) {
      if (density[i] > density[i - 1] && density[i] >= density[i + 1] && density[i] >= minH) {
        allPeaks.add(i);
      }
    }
    // ignore: avoid_print
    print('  Total peaks above threshold: ${allPeaks.length}');
    // ignore: avoid_print
    print('  First 30 peaks: ${allPeaks.take(30).toList()}');
    // Print density at y=0..200 to see top-stave region
    // ignore: avoid_print
    print('\n  Density at y=100..220 (expected top stave):');
    for (int y = 100; y <= 220; y += 5) {
      // ignore: avoid_print
      if (density[y] > 20) print('    y=$y: ${density[y]}');
    }
    // ignore: avoid_print
    print('\n  Density at y=1380..1500 (expected bottom stave):');
    for (int y = 1380; y <= 1500; y += 5) {
      // ignore: avoid_print
      if (density[y] > 20) print('    y=$y: ${density[y]}');
    }

    // Show pixel sample from first staff strip
    final s0 = staves.first;
    // ignore: avoid_print
    print('\nFirst staff strip pixel sample (every 50px across mid-height):');
    final midY = (s0.yTop + s0.yBottom) ~/ 2;
    final sampleBuf = StringBuffer();
    for (int x = 0; x < gray.width; x += 50) {
      final pxVal = gray.getPixel(x, midY).r.toInt();
      sampleBuf.write(pxVal == 0 ? 'X' : '.');
    }
    // ignore: avoid_print
    print('  y=$midY: $sampleBuf');

    // Run transformer on first staff only
    // ignore: avoid_print
    print('\nRunning transformer on staff 0...');
    final cropped = img.copyCrop(gray,
        x: s0.xLeft, y: s0.yTop, width: s0.cropWidth, height: s0.cropHeight);
    final stripPng = img.encodePng(cropped);
    // ignore: avoid_print
    print('  Strip size: ${cropped.width}×${cropped.height}');

    sw.reset();
    final symbols = await TransformerRunner(encoderAsset: demoModels.encoder, decoderAsset: demoModels.decoder).runTransformer(stripPng);
    // ignore: avoid_print
    print('  Transformer: ${sw.elapsedMilliseconds} ms, ${symbols.length} symbols');

    // Print first 40 tokens
    // ignore: avoid_print
    print('\n  First ${symbols.length.clamp(0, 40)} tokens:');
    for (int i = 0; i < symbols.length && i < 40; i++) {
      final sym = symbols[i];
      // ignore: avoid_print
      print('    [$i] rhythm="${sym.rhythm}" pitch="${sym.pitch}" lift="${sym.lift}" pos="${sym.position}"');
    }

    // Count rhythm categories
    int noteCount = 0, restCount = 0, barCount = 0, otherCount = 0;
    for (final s in symbols) {
      if (s.rhythm.startsWith('note')) noteCount++;
      else if (s.rhythm.startsWith('rest')) restCount++;
      else if (s.rhythm.contains('barline') || s.rhythm.contains('repeat')) barCount++;
      else otherCount++;
    }
    // ignore: avoid_print
    print('\n  Token breakdown: notes=$noteCount rests=$restCount barlines=$barCount other=$otherCount');

    // Pass if we got any symbols at all
    expect(symbols, isNotEmpty, reason: 'Transformer returned no symbols');
  });
}
