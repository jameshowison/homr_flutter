import 'dart:typed_data';
import 'package:image/image.dart' as img;

import '../staff_dewarper.dart';
import 'geometry.dart';
import 'staff_detection.dart';

/// Port of homr/staff_parsing.py prepare_staff_image: turns a detected [Staff]
/// into the exact transformer input image (a 256×1280 white canvas with the
/// dewarped, tightly-cropped staff resized to fill the width and centred
/// vertically).
///
/// This replaces the previous full-width / midpoint-to-midpoint crop, which
/// zoomed the staff differently from homr. homr's dewarp
/// (calculate_span_and_optimal_points) shifts every row by the *middle* line's
/// per-column deviation — i.e. a 1-D vertical shift — so [dewarpStaffStrip] is
/// used directly rather than porting the 2-D piecewise-affine warp (equivalent
/// for book-spine curvature, as homr's own span points are middle-line only).

const int _trOmrMaxHeight = 256; // default_config.max_height
const int _trOmrMaxWidth = 1280; // default_config.max_width

/// homr get_tr_omr_canvas_size: the (width, height) to resize a [regionH]×
/// [regionW] strip to so it fits the canvas preserving aspect ratio.
(int, int) _canvasContentSize(int regionH, int regionW) {
  const ratio = _trOmrMaxHeight / _trOmrMaxWidth; // 0.2
  if (regionH / regionW > ratio) {
    // Height is the limiting factor.
    return ((regionW / regionH * _trOmrMaxHeight).toInt(), _trOmrMaxHeight);
  }
  // Width is the limiting factor.
  return (_trOmrMaxWidth, (regionH / regionW * _trOmrMaxWidth).toInt());
}

/// homr _calculate_region + StaffRegions: crop bounds ±2 unit in x and ±4 unit
/// in y, the latter clamped to the nearest neighbouring staff above/below.
(int, int, int, int) _calculateRegion(
    Staff staff, List<Staff> allStaves, int width, int height) {
  final u = staff.averageUnitSize;
  final xMin = staff.minX - 2 * u;
  final xMax = staff.maxX + 2 * u;

  // get_start_of_closest_staff_above: max maxY of staves starting above us.
  double above = 0;
  double below = 1e12;
  for (final s in allStaves) {
    if (s.minY < staff.minY && s.maxY > above) above = s.maxY;
    if (s.maxY > staff.maxY && s.minY < below) below = s.minY;
  }
  final yMin = (staff.minY - 4 * u).clamp(above, double.infinity);
  final yMax = (staff.maxY + 4 * u).clamp(double.negativeInfinity, below);

  return (
    xMin.round().clamp(0, width - 1),
    yMin.round().clamp(0, height - 1),
    xMax.round().clamp(1, width),
    yMax.round().clamp(1, height),
  );
}

/// homr remove_black_contours_at_edges_of_image: erases large, predominantly
/// dark connected components that touch an image edge (page-edge shadows). A
/// no-op on clean scans; matters for phone photos with dark margins.
void _removeBlackContoursAtEdges(img.Image strip, double unitSize) {
  final w = strip.width, h = strip.height;
  // thresh = 255 where gray <= 97 (dark).
  final dark = Uint8List(w * h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      if (strip.getPixel(x, y).r <= 97) dark[y * w + x] = 1;
    }
  }
  final blkThresh = 2 * unitSize; // black_spot_removal_threshold
  for (final c in connectedComponents(dark, w, h)) {
    final bw = c.maxX - c.minX + 1;
    final bh = c.maxY - c.minY + 1;
    if (bw < blkThresh || bh < blkThresh) continue;
    final atEdge =
        c.minX == 0 || c.minY == 0 || c.maxX == w - 1 || c.maxY == h - 1;
    if (!atEdge) continue;
    // mean(thresh over bounding rect) < 127 ⇔ rect <50% dark ⇒ keep.
    int darkInRect = 0;
    for (int y = c.minY; y <= c.maxY; y++) {
      final row = y * w;
      for (int x = c.minX; x <= c.maxX; x++) {
        if (dark[row + x] != 0) darkInRect++;
      }
    }
    final darkFrac = darkInRect / (bw * bh);
    if (darkFrac * 255 < 127) continue; // mostly bright ⇒ keep
    // Erase the bounding box to white.
    for (int y = c.minY; y <= c.maxY; y++) {
      for (int x = c.minX; x <= c.maxX; x++) {
        strip.setPixelRgb(x, y, 255, 255, 255);
      }
    }
  }
}

/// Produces the transformer input for one staff: a [_trOmrMaxWidth]×
/// [_trOmrMaxHeight] image. [clahe] is the full-image RGB CLAHE picture.
img.Image prepareStaffImage(img.Image clahe, Staff staff, List<Staff> allStaves) {
  final w = clahe.width, h = clahe.height;
  final (xMin, yMin, xMax, yMax) = _calculateRegion(staff, allStaves, w, h);
  final rw = xMax - xMin;
  final rh = yMax - yMin;

  var strip = img.copyCrop(clahe, x: xMin, y: yMin, width: rw, height: rh);

  // 1-D dewarp using the grid's middle line, in strip-local coordinates.
  final profile = <(int, int)>[
    for (final p in staff.grid)
      if (p.x >= xMin && p.x <= xMax)
        ((p.x - xMin).round(), (p.y[2] - yMin).round())
  ];
  if (profile.length >= 2) {
    strip = dewarpStaffStrip(strip, profile);
  }

  _removeBlackContoursAtEdges(strip, staff.averageUnitSize);

  // Resize to canvas content size, then place on the white canvas: left-aligned
  // in x (homr x_offset = 0), centred vertically.
  final (cw, ch) = _canvasContentSize(rh, rw);
  final resized = img.copyResize(strip, width: cw, height: ch);

  final canvas = img.Image(
      width: _trOmrMaxWidth, height: _trOmrMaxHeight, numChannels: strip.numChannels);
  img.fill(canvas, color: img.ColorUint8.rgb(255, 255, 255));
  final yOffset = (_trOmrMaxHeight - ch) ~/ 2;
  img.compositeImage(canvas, resized, dstX: 0, dstY: yOffset);
  return canvas;
}
