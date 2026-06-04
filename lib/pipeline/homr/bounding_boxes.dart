import 'dart:math' as math;
import 'dart:typed_data';

import 'geometry.dart';

/// Port of homr's RotatedBoundingBox (homr/bounding_boxes.py).
///
/// Holds the canonical [RotRect] plus the source pixel coordinates so that
/// merging (which re-fits minAreaRect over concatenated contours) works. Edge
/// accessors `topLeftX`/`bottomRightX`/… replicate homr's
/// calculate_edges_of_rotated_rectangle, which — note — computes corners
/// axis-aligned (cx±w/2, cy±h/2) and ignores the angle. Only [polygon] uses the
/// true rotated corners (cv2.boxPoints), matching homr's is_overlapping path.
class HRotBox {
  final RotRect rect;
  final List<int> xs;
  final List<int> ys;
  final int debugId;

  HRotBox(this.rect, this.xs, this.ys, {this.debugId = 0});

  double get cx => rect.cx;
  double get cy => rect.cy;
  double get w => rect.width;
  double get h => rect.height;
  double get angle => rect.angleDeg;

  // homr axis-aligned edge approximation.
  double get topLeftX => cx - w / 2;
  double get topLeftY => cy - h / 2;
  double get bottomLeftX => cx - w / 2;
  double get bottomLeftY => cy + h / 2;
  double get topRightX => cx + w / 2;
  double get topRightY => cy - h / 2;
  double get bottomRightX => cx + w / 2;
  double get bottomRightY => cy + h / 2;

  double get minXEdge => cx - w / 2;
  double get maxXEdge => cx + w / 2;
  double get minYEdge => cy - h / 2;
  double get maxYEdge => cy + h / 2;

  /// True rotated corners (cv2.boxPoints), used for polygon overlap.
  List<List<double>> get polygon {
    final t = angle * math.pi / 180.0;
    final ux = math.cos(t), uy = math.sin(t);
    final nx = -math.sin(t), ny = math.cos(t);
    final hw = w / 2, hh = h / 2;
    return [
      [cx - hw * ux - hh * nx, cy - hw * uy - hh * ny],
      [cx + hw * ux - hh * nx, cy + hw * uy - hh * ny],
      [cx + hw * ux + hh * nx, cy + hw * uy + hh * ny],
      [cx - hw * ux + hh * nx, cy - hw * uy + hh * ny],
    ];
  }

  /// homr get_center_extrapolated.
  double centerExtrapolated(double x) => rect.centerExtrapolated(x);

  HRotBox moveToXHorizontalBy(int dx) =>
      HRotBox(RotRect(cx + dx, cy, w, h, angle), xs, ys, debugId: debugId);

  HRotBox makeBoxTaller(int thickness) =>
      HRotBox(RotRect(cx, cy, w, h + thickness, angle), xs, ys, debugId: debugId);

  HRotBox makeBoxThicker(int thickness) {
    if (thickness <= 0) return this;
    return HRotBox(
        RotRect(cx, cy, w + thickness, h + thickness, angle), xs, ys,
        debugId: debugId);
  }

  bool _canPossiblyTouch(HRotBox other) {
    final major1 = math.max(w, h);
    final major2 = math.max(other.w, other.h);
    final d = math.sqrt(math.pow(cx - other.cx, 2) + math.pow(cy - other.cy, 2));
    return d <= major1 + major2;
  }

  bool isOverlapping(HRotBox other) {
    if (!_canPossiblyTouch(other)) return false;
    return _polygonsOverlap(polygon, other.polygon);
  }

  bool isOverlappingWithAny(Iterable<HRotBox> others) {
    for (final o in others) {
      if (isOverlapping(o)) return true;
    }
    return false;
  }

  /// homr is_intersecting (cv2.rotatedRectangleIntersection): true rectangle
  /// intersection, which — unlike the vertex-in-polygon [isOverlapping] — also
  /// detects two rectangles crossing like a `+` without either's corners being
  /// inside the other. Implemented via the separating-axis theorem.
  bool isIntersecting(HRotBox other) {
    if (!_canPossiblyTouch(other)) return false;
    return _satIntersect(polygon, other.polygon);
  }

  /// homr is_overlapping_extrapolated: two near-collinear fragments connect if
  /// their horizontal gap is within max_line_gap_size and their extrapolated
  /// y-values at the shared midpoint agree within tolerance.
  bool isOverlappingExtrapolated(HRotBox other, double unitSize) {
    final HRotBox left, right;
    if (cx > other.cx) {
      left = other;
      right = this;
    } else {
      left = this;
      right = other;
    }
    final centerX = (left.cx + right.cx) * 0.5;
    final tolerance = unitSize / 3; // tolerance_for_staff_line_detection
    final maxGap = 5 * unitSize; // max_line_gap_size
    if (centerX - left.cx - (left.w ~/ 2) > maxGap ||
        right.cx - centerX - (right.w ~/ 2) > maxGap) {
      return false;
    }
    final leftAngle = math.tan(left.angle * math.pi / 180.0);
    final rightAngle = math.tan(right.angle * math.pi / 180.0);
    final leftY = (centerX - left.cx) * leftAngle + left.cy;
    final rightY = (centerX - right.cx) * rightAngle + right.cy;
    return (leftY - rightY).abs() <= tolerance;
  }
}

bool _pointInConvex(List<List<double>> poly, double px, double py) {
  // True if (px,py) is inside/on the convex polygon (consistent winding).
  bool? positive;
  final n = poly.length;
  for (int i = 0; i < n; i++) {
    final a = poly[i];
    final b = poly[(i + 1) % n];
    final cross = (b[0] - a[0]) * (py - a[1]) - (b[1] - a[1]) * (px - a[0]);
    if (cross.abs() < 1e-9) continue;
    final pos = cross > 0;
    positive ??= pos;
    if (pos != positive) return false;
  }
  return true;
}

bool _satIntersect(List<List<double>> a, List<List<double>> b) {
  for (final poly in [a, b]) {
    final n = poly.length;
    for (int i = 0; i < n; i++) {
      final p1 = poly[i];
      final p2 = poly[(i + 1) % n];
      // Edge normal as separating axis.
      final axX = -(p2[1] - p1[1]);
      final axY = p2[0] - p1[0];
      double minA = double.infinity, maxA = -double.infinity;
      for (final p in a) {
        final proj = p[0] * axX + p[1] * axY;
        if (proj < minA) minA = proj;
        if (proj > maxA) maxA = proj;
      }
      double minB = double.infinity, maxB = -double.infinity;
      for (final p in b) {
        final proj = p[0] * axX + p[1] * axY;
        if (proj < minB) minB = proj;
        if (proj > maxB) maxB = proj;
      }
      if (maxA < minB || maxB < minA) return false; // separating axis found
    }
  }
  return true;
}

bool _polygonsOverlap(List<List<double>> p1, List<List<double>> p2) {
  for (final pt in p1) {
    if (_pointInConvex(p2, pt[0], pt[1])) return true;
  }
  for (final pt in p2) {
    if (_pointInConvex(p1, pt[0], pt[1])) return true;
  }
  return false;
}

/// Port of homr create_rotated_bounding_boxes.
///
/// [mask] is a 0/non-zero binary image. Connected components → minAreaRect →
/// size filter → optional thicken → optional merge. Size filters compare the
/// canonical (width, height) exactly as homr does.
List<HRotBox> createRotatedBoundingBoxes(
  Uint8List mask,
  int width,
  int height, {
  bool skipMerging = false,
  (int, int)? minSize,
  (int, int)? maxSize,
  int? thickenBoxes,
}) {
  final comps = connectedComponents(mask, width, height);
  final boxes = <HRotBox>[];
  for (int i = 0; i < comps.length; i++) {
    final c = comps[i];
    final rect = minAreaRect(c.xs, c.ys);
    if (rect.width.isNaN || rect.height.isNaN || rect.width <= 0 || rect.height <= 0) {
      continue;
    }
    if (minSize != null && (rect.width < minSize.$1 || rect.height < minSize.$2)) {
      continue;
    }
    if (maxSize != null) {
      if (maxSize.$1 > 0 && rect.width > maxSize.$1) continue;
      if (maxSize.$2 > 0 && rect.height > maxSize.$2) continue;
    }
    boxes.add(HRotBox(rect, c.xs, c.ys, debugId: i));
  }
  if (skipMerging) return boxes;
  var result = boxes;
  if (thickenBoxes != null) {
    result = [for (final b in result) b.makeBoxThicker(thickenBoxes)];
  }
  return _boxForWholeGroup(_mergeOverlaying(result));
}

/// Union-find merge of overlapping boxes (homr _merge_groups_optimized).
List<List<HRotBox>> _mergeOverlaying(List<HRotBox> boxes) {
  final n = boxes.length;
  final parent = List<int>.generate(n, (i) => i);
  int find(int x) {
    while (parent[x] != x) {
      parent[x] = parent[parent[x]];
      x = parent[x];
    }
    return x;
  }

  void union(int a, int b) {
    final ra = find(a), rb = find(b);
    if (ra != rb) parent[ra] = rb;
  }

  for (int i = 0; i < n; i++) {
    for (int j = i + 1; j < n; j++) {
      if (boxes[i].isOverlapping(boxes[j])) union(i, j);
    }
  }
  final groups = <int, List<HRotBox>>{};
  for (int i = 0; i < n; i++) {
    (groups[find(i)] ??= <HRotBox>[]).add(boxes[i]);
  }
  return groups.values.toList();
}

/// Re-fit one minAreaRect over each merged group's concatenated pixels
/// (homr _get_box_for_whole_group).
List<HRotBox> _boxForWholeGroup(List<List<HRotBox>> groups) {
  final result = <HRotBox>[];
  for (final group in groups) {
    final xs = <int>[];
    final ys = <int>[];
    for (final b in group) {
      xs.addAll(b.xs);
      ys.addAll(b.ys);
    }
    result.add(HRotBox(minAreaRect(xs, ys), xs, ys));
  }
  return result;
}

/// Port of homr break_wide_fragments: split fragments whose (re-fitted) width
/// exceeds [limit] into ~limit-wide pieces so curved lines are better
/// approximated by straight boxes. Replicates homr's iterative loop: each pass
/// peels off the points with x < min_x+limit (plus a bridging point — the
/// leftmost of the remainder), emits its minAreaRect, and continues on the rest
/// until the remaining box width ≤ limit. The loop condition uses the canonical
/// (along-axis) width, matching homr's `size[0]`.
///
/// Known divergence: homr splits cv2 contour *vertices* (CHAIN_APPROX_SIMPLE,
/// collinear runs compressed), so its split boundaries snap to those vertices
/// while we split exact pixels. This yields a slightly different count of split
/// pieces (~7% on long staff lines) but identical coverage; the pieces are
/// reconnected by connect_staff_lines downstream, so detection is unaffected
/// (verified end-to-end against the staff-grid oracle).
List<HRotBox> breakWideFragments(List<HRotBox> fragments, {int limit = 100}) {
  final result = <HRotBox>[];
  for (final frag in fragments) {
    var remXs = frag.xs;
    var remYs = frag.ys;
    var remRect = frag.rect;
    while (remRect.width > limit) {
      int minX = 1 << 30;
      for (final x in remXs) {
        if (x < minX) minX = x;
      }
      final bound = minX + limit;
      final lx = <int>[], ly = <int>[], rx = <int>[], ry = <int>[];
      // Track the leftmost point of the right side (the bridging point).
      int bridgeX = 1 << 30, bridgeY = 0;
      for (int k = 0; k < remXs.length; k++) {
        if (remXs[k] < bound) {
          lx.add(remXs[k]);
          ly.add(remYs[k]);
        } else {
          rx.add(remXs[k]);
          ry.add(remYs[k]);
          if (remXs[k] < bridgeX) {
            bridgeX = remXs[k];
            bridgeY = remYs[k];
          }
        }
      }
      if (lx.isEmpty || rx.isEmpty) break;
      // homr bridges the left piece to the start of the right piece.
      lx.add(bridgeX);
      ly.add(bridgeY);
      final leftRect = minAreaRect(lx, ly);
      if (leftRect.width > 0 && leftRect.height > 0) {
        result.add(HRotBox(leftRect, lx, ly, debugId: frag.debugId));
      }
      remXs = rx;
      remYs = ry;
      remRect = minAreaRect(rx, ry);
    }
    result.add(HRotBox(remRect, remXs, remYs, debugId: frag.debugId));
  }
  return result;
}

/// Extracts a binary mask (0/1) for class [cls] from a class-index image where
/// 255 means "ambiguous / no class".
Uint8List classMask(Uint8List classes, int cls) {
  final out = Uint8List(classes.length);
  for (int i = 0; i < classes.length; i++) {
    out[i] = classes[i] == cls ? 1 : 0;
  }
  return out;
}
