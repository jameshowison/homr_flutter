// Phase 4 verification: segmentation runner output vs Python reference.
//
// Python reference command:
//   ~/.local/share/uv/tools/homr/bin/python tools/verify_segmentation.py
//
// Reference stats (2674×1574, step_size=320, FP16):
//   class 0 background    3763400  89.42%
//   class 1 stems_rests     28919   0.69%
//   class 2 noteheads       61999   1.47%
//   class 3 clefs_keys      18106   0.43%
//   class 4 staff_lines    336452   7.99%
//   class 5 other_symbols       0   0.00%
//
// Run on a connected device/simulator:
//   flutter test integration_test/phase4_segmentation_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// ignore: implementation_imports
import 'package:homr_omr/src/inference/segmentation_runner.dart';

// Python reference class counts for happy_farmer_bw_50.png (step_size=320, FP16)
const int _refTotal = 4208876; // 2674 × 1574
const List<int> _refCounts = [3763400, 28919, 61999, 18106, 336452, 0];
const List<String> _classNames = [
  'background',
  'stems_rests',
  'noteheads',
  'clefs_keys',
  'staff_lines',
  'other_symbols',
];

// Tolerance: ±2% of total pixels per class (≈84 177 pixels).
const double _toleranceFraction = 0.02;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('segmentation runner matches Python reference', (tester) async {
    final bytes =
        await rootBundle.load('assets/test_images/happy_farmer_bw_50.png');
    final pngBytes = bytes.buffer.asUint8List();

    final stopwatch = Stopwatch()..start();
    final mask = await SegmentationRunner().runSegmentation(pngBytes);
    stopwatch.stop();

    expect(mask.length, equals(_refTotal),
        reason: 'Mask length must equal image pixel count');

    final counts = List<int>.filled(6, 0);
    for (final v in mask) {
      if (v < 6) counts[v]++;
    }

    final tolerance = (_refTotal * _toleranceFraction).round();

    // ignore: avoid_print
    print('\n=== Phase 4 Segmentation Verification ===');
    // ignore: avoid_print
    print('Elapsed: ${stopwatch.elapsedMilliseconds} ms');
    // ignore: avoid_print
    print('Total pixels: ${mask.length}');
    // ignore: avoid_print
    print('');
    // ignore: avoid_print
    print(
        '${'Class'.padRight(6)}  ${'Name'.padRight(16)}  ${'Dart'.padLeft(8)}  ${'Python'.padLeft(8)}  ${'Diff'.padLeft(8)}  Status');
    // ignore: avoid_print
    print('-' * 70);

    for (int c = 0; c < 6; c++) {
      final diff = (counts[c] - _refCounts[c]).abs();
      final ok = diff <= tolerance;
      final status = ok ? 'OK' : 'FAIL (diff=$diff > tol=$tolerance)';
      // ignore: avoid_print
      print(
          '${c.toString().padRight(6)}  ${_classNames[c].padRight(16)}  ${counts[c].toString().padLeft(8)}  ${_refCounts[c].toString().padLeft(8)}  ${diff.toString().padLeft(8)}  $status');
      expect(diff, lessThanOrEqualTo(tolerance),
          reason:
              'Class $c (${_classNames[c]}): dart=${counts[c]} python=${_refCounts[c]} diff=$diff exceeds tolerance=$tolerance');
    }

    // ignore: avoid_print
    print('\nAll classes within ${(_toleranceFraction * 100).toStringAsFixed(0)}% tolerance. Phase 4 segmentation VERIFIED.');
  });
}
