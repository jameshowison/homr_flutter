import 'dart:math' as math;
import 'dart:typed_data';

import 'bounding_boxes.dart';
import 'staff_detection.dart';

/// Bridges the SegNet class map to homr's staff detection, mirroring the
/// preprocessing in homr/main.py load_and_preprocess_predictions +
/// predict_symbols: per-class mask extraction, noise filtering
/// (noise_filtering.filter_predictions), make_lines_stronger on the staff mask,
/// and create_rotated_bounding_boxes for fragments and clefs.

const int _imageNoiseLimit = 50; // constants.image_noise_limit

/// homr make_lines_stronger(staff, (1,2)): dilate with an elliptical (1,2)
/// kernel then re-threshold. A (1,2) ellipse is a 2px vertical element, i.e. a
/// 1px vertical thickening — implemented directly to avoid the 3px spread a
/// symmetric kernel would give.
Uint8List makeLinesStronger12(Uint8List mask, int width, int height) {
  final out = Uint8List(width * height);
  for (int y = 0; y < height; y++) {
    final row = y * width;
    for (int x = 0; x < width; x++) {
      if (mask[row + x] != 0) {
        out[row + x] = 1;
        if (y + 1 < height) out[(y + 1) * width + x] = 1;
      }
    }
  }
  return out;
}

/// 3×3 Laplacian noise estimate over a tile (noise_filtering.estimate_noise),
/// using BORDER_REFLECT_101 like cv2.filter2D.
double _estimateNoise(Uint8List g, int w, int h) {
  if (w == 0 || h == 0) return 0;
  int refl(int i, int n) {
    if (n == 1) return 0;
    while (i < 0 || i >= n) {
      if (i < 0) i = -i;
      if (i >= n) i = 2 * (n - 1) - i;
    }
    return i;
  }

  const k = [
    [1, -2, 1],
    [-2, 4, -2],
    [1, -2, 1]
  ];
  double total = 0;
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      double acc = 0;
      for (int dy = -1; dy <= 1; dy++) {
        final yy = refl(y + dy, h);
        for (int dx = -1; dx <= 1; dx++) {
          final xx = refl(x + dx, w);
          acc += k[dy + 1][dx + 1] * g[yy * w + xx];
        }
      }
      total += acc.abs();
    }
  }
  return total / (w * h);
}

/// homr noise_filtering.filter_predictions: builds a 20×20-grid noise mask from
/// the staff prediction and blanks cells that are noisy and border a noisy cell.
/// Returns null when nothing should be filtered (clean scans), matching homr's
/// None path. The returned mask is 0/1 over the full image.
Uint8List? noiseMask(Uint8List staff, int width, int height) {
  final m = height ~/ 20;
  final n = width ~/ 20;
  if (m <= 0 || n <= 0) return null;
  final rows = (height / m).ceil();
  final cols = (width / n).ceil();
  // Per-cell noise on 255*staff.
  final grid = List<double>.generate(rows * cols, (_) => 0.0);
  final tile = Uint8List(m * n);
  for (int i = 0, y1 = 0; y1 < height; y1 += m, i++) {
    for (int j = 0, x1 = 0; x1 < width; x1 += n, j++) {
      final y2 = math.min(y1 + m, height);
      final x2 = math.min(x1 + n, width);
      final tw = x2 - x1, th = y2 - y1;
      for (int ty = 0; ty < th; ty++) {
        final src = (y1 + ty) * width + x1;
        for (int tx = 0; tx < tw; tx++) {
          tile[ty * tw + tx] = staff[src + tx] != 0 ? 255 : 0;
        }
      }
      grid[i * cols + j] = _estimateNoise(
          Uint8List.sublistView(tile, 0, tw * th), tw, th);
    }
  }

  double neighborMax(int i, int j) {
    double mx = -1;
    if (i > 0) mx = math.max(mx, grid[(i - 1) * cols + j]);
    if (j > 0) mx = math.max(mx, grid[i * cols + (j - 1)]);
    if (i < rows - 1) mx = math.max(mx, grid[(i + 1) * cols + j]);
    if (j < cols - 1) mx = math.max(mx, grid[i * cols + (j + 1)]);
    return mx;
  }

  final mask = Uint8List(width * height);
  int filtered = 0, totalCells = 0;
  for (int i = 0, y1 = 0; y1 < height; y1 += m, i++) {
    for (int j = 0, x1 = 0; x1 < width; x1 += n, j++) {
      totalCells++;
      final noisy = grid[i * cols + j] > _imageNoiseLimit;
      final neighborNoisy = neighborMax(i, j) > _imageNoiseLimit;
      if (noisy && neighborNoisy) {
        filtered++;
      } else {
        final y2 = math.min(y1 + m, height);
        final x2 = math.min(x1 + n, width);
        for (int y = y1; y < y2; y++) {
          mask.fillRange(y * width + x1, y * width + x2, 1);
        }
      }
    }
  }
  if (filtered / totalCells > 0.5) return null; // would filter too much → skip
  if (filtered == 0) return null;
  return mask;
}

/// Applies [mask] (0/1) in place to a class mask (bitwise-and with a non-zero
/// mask), returning a new masked copy.
Uint8List _applyMask(Uint8List src, Uint8List mask) {
  final out = Uint8List(src.length);
  for (int i = 0; i < src.length; i++) {
    if (mask[i] != 0) out[i] = src[i];
  }
  return out;
}

/// Result of homr-style symbol prediction needed for staff detection.
class StaffDetectionInput {
  final Uint8List staffMask; // after noise filter + make_lines_stronger
  final List<HRotBox> staffFragments;
  final List<HRotBox> clefs;
  final int width, height;
  StaffDetectionInput(
      this.staffMask, this.staffFragments, this.clefs, this.width, this.height);
}

/// From the SegNet class map (values 0–5, or 255 = ambiguous) to detected staves
/// via homr's pipeline.
List<Staff> detectStavesFromClassMap(Uint8List classMap, int width, int height) {
  var staff = classMask(classMap, 4);
  var clefsKeys = classMask(classMap, 3);

  // Noise filtering keys off the staff mask and blanks the others in tandem.
  final nm = noiseMask(staff, width, height);
  if (nm != null) {
    staff = _applyMask(staff, nm);
    clefsKeys = _applyMask(clefsKeys, nm);
  }

  staff = makeLinesStronger12(staff, width, height);

  var fragments = createRotatedBoundingBoxes(staff, width, height,
      skipMerging: true, minSize: (5, 1), maxSize: (10000, 100));
  fragments = breakWideFragments(fragments);
  final clefs = createRotatedBoundingBoxes(clefsKeys, width, height,
      minSize: (20, 40), maxSize: (1000, 1000));

  return detectStaves(staff, width, height, fragments, clefs);
}

/// Crop region and middle-line profile for one detected staff, ready for the
/// existing [dewarpStaffStrip] + transformer stage.
class StaffCrop {
  final int yTop;
  final int yBottom;

  /// (x, middleLineY) pairs in full-image coordinates, from the staff grid.
  final List<(int, int)> profile;
  StaffCrop(this.yTop, this.yBottom, this.profile);
}

/// Converts homr [Staff]s into full-width crop regions for the transformer.
///
/// Vertical bounds use inter-staff midpoints (as the previous pipeline did,
/// which the transformer expects — it was trained on strips that fill the
/// canvas height), falling back to a 4×unit ledger margin at the first/last
/// staff. The middle-line profile (grid line index 2) feeds the 1-D dewarper.
List<StaffCrop> staffCropRegions(List<Staff> staves, int width, int height) {
  final crops = <StaffCrop>[];
  for (int i = 0; i < staves.length; i++) {
    final s = staves[i];
    final unit = s.averageUnitSize;
    final yTop = i == 0
        ? math.max(0, (s.minY - 4 * unit).round())
        : ((staves[i - 1].maxY + s.minY) / 2).round();
    final yBottom = i == staves.length - 1
        ? math.min(height, (s.maxY + 4 * unit).round())
        : ((s.maxY + staves[i + 1].minY) / 2).round();
    final profile = [
      for (final p in s.grid) (p.x.round(), p.y[2].round())
    ];
    crops.add(StaffCrop(yTop, yBottom, profile));
  }
  return crops;
}
