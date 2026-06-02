import 'dart:math';
import 'dart:typed_data';

/// Bounding box for one staff strip, ready to crop from the preprocessed image.
class StaffBounds {
  /// Y-position (pixels) of each of the 5 staff lines, top to bottom.
  final List<int> lineYs;

  /// Median inter-line spacing in pixels (homr's `unit_size`).
  final double unitSize;

  /// Top of the crop region — includes ledger-line and symbol room above line 1.
  final int yTop;

  /// Bottom of the crop region — includes ledger-line and symbol room below line 5.
  final int yBottom;

  final int xLeft;
  final int xRight;

  const StaffBounds({
    required this.lineYs,
    required this.unitSize,
    required this.yTop,
    required this.yBottom,
    required this.xLeft,
    required this.xRight,
  });

  int get cropWidth => xRight - xLeft;
  int get cropHeight => yBottom - yTop;
}

/// Detects staff positions from a SegNet class mask.
///
/// Works from the class-4 (staff-line) pixels in the segmentation mask rather
/// than raw image pixels, so morphological preprocessing and contour detection
/// (as used by the Python reference) are not needed. See the Phase 5 design
/// note in docs/homr_flutter_integration.md for the full rationale.
class SegmentationPostprocessor {
  static const int _staffLineClass = 4;

  // Minimum fraction of image width that a real staff line row must cover.
  // At 1920 px wide this is ~58 px — well below a full staff line but well
  // above scattered noise pixels.
  static const double _heightThresholdFraction = 0.03;

  // Suppress duplicate detections from a staff line that spans 2–3 pixel rows.
  static const int _minPeakDistance = 3;

  // A valid staff has 4 inter-line gaps all within this fraction of their mean.
  // 0.30 (±30 %) is tight enough to reject random coincidences while tolerating
  // minor SegNet prediction jitter.
  static const double _spacingTolerance = 0.30;

  // Reject candidate staves whose unit_size is implausibly small (e.g. two
  // adjacent noise peaks). 8 px corresponds to roughly a 40 px staff height,
  // which would only occur in extremely low-resolution captures.
  static const int _minUnitSize = 8;

  // Extra padding above/below the outermost staff lines when computing the crop
  // region. 4 × unitSize provides room for ledger lines (max 4 per side in
  // homr's constants.py) plus the symbols attached to them.
  static const double _ledgerLineRoom = 4.0;

  /// Returns staves sorted top-to-bottom.
  ///
  /// [mask] is the flat H×W class-index array produced by [SegmentationRunner].
  static List<StaffBounds> detectStaves(Uint8List mask, int width, int height) {
    final rowDensity = _computeRowDensity(mask, width, height);
    final minHeight = (width * _heightThresholdFraction).round();
    final peaks = _findPeaks(rowDensity, minHeight: minHeight, minDistance: _minPeakDistance);
    if (peaks.length < 5) return [];
    return _groupIntoStaves(peaks, height, width);
  }

  // ---------------------------------------------------------------------------
  // Row density
  // ---------------------------------------------------------------------------

  static List<int> _computeRowDensity(Uint8List mask, int width, int height) {
    final density = List<int>.filled(height, 0);
    for (int y = 0; y < height; y++) {
      final base = y * width;
      int count = 0;
      for (int x = 0; x < width; x++) {
        if (mask[base + x] == _staffLineClass) count++;
      }
      density[y] = count;
    }
    return density;
  }

  // ---------------------------------------------------------------------------
  // Peak finding
  // ---------------------------------------------------------------------------

  /// Finds local maxima in [signal] subject to height and distance constraints.
  ///
  /// Uses a simple strict local-maximum test (value > both immediate neighbours)
  /// which is sufficient because staff-line peaks in the row-density signal are
  /// sharp — typically 1–3 rows wide.
  static List<int> _findPeaks(
    List<int> signal, {
    required int minHeight,
    required int minDistance,
  }) {
    final n = signal.length;
    if (n < 3) return [];

    // Collect strict local maxima.
    final candidates = <int>[];
    for (int i = 1; i < n - 1; i++) {
      // >= on the right edge handles flat-topped peaks: take the left edge.
      if (signal[i] > signal[i - 1] && signal[i] >= signal[i + 1]) {
        candidates.add(i);
      }
    }

    // Height filter.
    final heightFiltered = candidates.where((p) => signal[p] >= minHeight).toList();
    if (heightFiltered.length <= 1) return heightFiltered;

    // Distance filter: when two peaks are within minDistance, keep the taller.
    // Candidates are already in ascending y-order.
    final result = <int>[heightFiltered[0]];
    for (int k = 1; k < heightFiltered.length; k++) {
      final peak = heightFiltered[k];
      if (peak - result.last >= minDistance) {
        result.add(peak);
      } else if (signal[peak] > signal[result.last]) {
        result[result.length - 1] = peak;
      }
    }

    return result;
  }

  // ---------------------------------------------------------------------------
  // Stave grouping
  // ---------------------------------------------------------------------------

  /// Greedily scans [peaks] for consecutive groups of 5 with consistent spacing.
  ///
  /// Advances by 5 when a valid staff is found, by 1 when not — so a single
  /// spurious peak between two staves does not corrupt the rest of the page.
  static List<StaffBounds> _groupIntoStaves(List<int> peaks, int imageHeight, int imageWidth) {
    final staves = <StaffBounds>[];
    int i = 0;

    while (i <= peaks.length - 5) {
      final y0 = peaks[i];
      final y1 = peaks[i + 1];
      final y2 = peaks[i + 2];
      final y3 = peaks[i + 3];
      final y4 = peaks[i + 4];

      final gaps = [y1 - y0, y2 - y1, y3 - y2, y4 - y3];
      final meanGap = gaps.reduce((a, b) => a + b) / 4.0;

      if (meanGap >= _minUnitSize) {
        final allConsistent =
            gaps.every((g) => (g - meanGap).abs() <= meanGap * _spacingTolerance);

        if (allConsistent) {
          final unitSize = meanGap;
          final room = (unitSize * _ledgerLineRoom).round();
          staves.add(StaffBounds(
            lineYs: [y0, y1, y2, y3, y4],
            unitSize: unitSize,
            yTop: max(0, y0 - room),
            yBottom: min(imageHeight, y4 + room),
            xLeft: 0,
            xRight: imageWidth,
          ));
          i += 5;
          continue;
        }
      }

      i++;
    }

    return staves;
  }
}
