import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homr_flutter/pipeline/segmentation_postprocessor.dart';

/// Builds a synthetic H×W class mask with class-4 pixels painted as thin
/// horizontal lines at the given y-positions.
Uint8List _buildMask(int width, int height, List<int> staffLineYs) {
  final mask = Uint8List(width * height); // zeros = background
  for (final y in staffLineYs) {
    for (int x = 0; x < width; x++) {
      mask[y * width + x] = 4;
    }
  }
  return mask;
}

void main() {
  group('SegmentationPostprocessor', () {
    const width = 400;
    const height = 600;

    test('detects a single staff from an ideal mask', () {
      // Staff lines at y = 100, 120, 140, 160, 180 → unitSize = 20.
      final lineYs = [100, 120, 140, 160, 180];
      final mask = _buildMask(width, height, lineYs);

      final staves = SegmentationPostprocessor.detectStaves(mask, width, height);

      expect(staves.length, 1);
      final s = staves.first;
      expect(s.lineYs, lineYs);
      expect(s.unitSize, closeTo(20.0, 0.1));
      // yTop = max(0, 100 - 4*20) = max(0, 20) = 20
      expect(s.yTop, 20);
      // yBottom = min(600, 180 + 80) = 260
      expect(s.yBottom, 260);
      expect(s.xLeft, 0);
      expect(s.xRight, width);
    });

    test('detects two staves in the correct top-to-bottom order', () {
      // First staff: y = 50, 70, 90, 110, 130 → unitSize = 20
      // Second staff: y = 300, 320, 340, 360, 380 → unitSize = 20
      final mask = _buildMask(width, height, [50, 70, 90, 110, 130, 300, 320, 340, 360, 380]);

      final staves = SegmentationPostprocessor.detectStaves(mask, width, height);

      expect(staves.length, 2);
      expect(staves[0].lineYs.first, lessThan(staves[1].lineYs.first));
      expect(staves[0].unitSize, closeTo(20.0, 0.1));
      expect(staves[1].unitSize, closeTo(20.0, 0.1));
    });

    test('clamps crop bounds to image edges', () {
      // Staff lines near the top — yTop would go negative without clamping.
      final lineYs = [5, 25, 45, 65, 85]; // unitSize = 20, room = 80 → yTop = 5-80 = -75
      final mask = _buildMask(width, height, lineYs);

      final staves = SegmentationPostprocessor.detectStaves(mask, width, height);

      expect(staves.length, 1);
      expect(staves.first.yTop, 0); // clamped
    });

    test('rejects a noisy mask with fewer than 5 peaks', () {
      // Only 3 class-4 lines — cannot form a staff.
      final mask = _buildMask(width, height, [100, 120, 140]);

      final staves = SegmentationPostprocessor.detectStaves(mask, width, height);

      expect(staves, isEmpty);
    });

    test('tolerates slightly uneven spacing within ±30 %', () {
      // Gaps: 19, 21, 20, 20 — all within 30 % of mean (20).
      final lineYs = [100, 119, 140, 160, 180];
      final mask = _buildMask(width, height, lineYs);

      final staves = SegmentationPostprocessor.detectStaves(mask, width, height);

      expect(staves.length, 1);
    });

    test('rejects unevenly spaced peaks that exceed tolerance', () {
      // Gaps: 10, 30, 20, 20 — first gap is 50 % off, should fail.
      final lineYs = [100, 110, 140, 160, 180];
      final mask = _buildMask(width, height, lineYs);

      final staves = SegmentationPostprocessor.detectStaves(mask, width, height);

      // The first attempt (i=0) fails; starting at i=1 there are only 4 peaks
      // left so no staff is found.
      expect(staves, isEmpty);
    });

    test('skips a spurious peak between two valid staves', () {
      // Two staves separated by a noise peak at y=215.
      // Staff 1: 50, 70, 90, 110, 130 — Staff 2: 300, 320, 340, 360, 380
      final peaks = [50, 70, 90, 110, 130, 215, 300, 320, 340, 360, 380];
      final mask = _buildMask(width, height, peaks);

      final staves = SegmentationPostprocessor.detectStaves(mask, width, height);

      // The spurious peak causes the grouper to advance by 1 at position 5,
      // eventually finding the second staff.
      expect(staves.length, 2);
    });
  });
}
