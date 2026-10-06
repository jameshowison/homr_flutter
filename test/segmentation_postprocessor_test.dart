import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:homr_flutter/src/pipeline/segmentation_postprocessor.dart';

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
      // Single staff → crop spans full image height (0..600).
      final lineYs = [100, 120, 140, 160, 180];
      final mask = _buildMask(width, height, lineYs);

      final staves = SegmentationPostprocessor.detectStaves(mask, width, height);

      expect(staves.length, 1);
      final s = staves.first;
      expect(s.lineYs, lineYs);
      expect(s.unitSize, closeTo(20.0, 0.1));
      // Single staff: top=0, bottom=imageHeight (no neighbouring staves)
      expect(s.yTop, 0);
      expect(s.yBottom, height);
      expect(s.xLeft, 0);
      expect(s.xRight, width);
    });

    test('detects two staves with midpoint crop bounds', () {
      // Staff 1: y = 50..130, Staff 2: y = 300..380
      // Midpoint = (130 + 300) / 2 = 215
      final mask = _buildMask(width, height, [50, 70, 90, 110, 130, 300, 320, 340, 360, 380]);

      final staves = SegmentationPostprocessor.detectStaves(mask, width, height);

      expect(staves.length, 2);
      expect(staves[0].lineYs.first, lessThan(staves[1].lineYs.first));
      expect(staves[0].unitSize, closeTo(20.0, 0.1));
      expect(staves[1].unitSize, closeTo(20.0, 0.1));
      // Staff 0: yTop=0 (first), yBottom=(130+300)/2=215
      expect(staves[0].yTop, 0);
      expect(staves[0].yBottom, (130 + 300) ~/ 2);
      // Staff 1: yTop=(130+300)/2=215, yBottom=height (last)
      expect(staves[1].yTop, (130 + 300) ~/ 2);
      expect(staves[1].yBottom, height);
    });

    test('single staff crop spans full image height', () {
      // Staff lines near the top — single staff → crop is 0..imageHeight.
      final lineYs = [5, 25, 45, 65, 85];
      final mask = _buildMask(width, height, lineYs);

      final staves = SegmentationPostprocessor.detectStaves(mask, width, height);

      expect(staves.length, 1);
      expect(staves.first.yTop, 0);
      expect(staves.first.yBottom, height);
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
