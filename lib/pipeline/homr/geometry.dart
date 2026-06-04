import 'dart:math' as math;
import 'dart:typed_data';

/// Geometry primitives ported to replace the OpenCV calls homr relies on:
///   - cv2.findContours      → [connectedComponents] (8-connectivity)
///   - cv2.minAreaRect       → [minAreaRect] (convex hull + rotating calipers)
///   - cv2.dilate / cv2.erode→ [dilate] / [erode]
///
/// homr wraps cv2.minAreaRect output in AngledBoundingBox, which normalises the
/// raw (w, h, angle∈(-90,0]) cv2 convention into a canonical form with
/// angle∈(-45,45]. We skip that two-step dance and emit the canonical form
/// directly from the rectangle geometry: of the rectangle's two perpendicular
/// edge directions, the one whose angle lies in (-45,45] becomes `width` (the
/// near-horizontal axis) and the perpendicular becomes `height`. This was
/// verified to match cv2 4.13 + homr normalisation on axis-aligned and rotated
/// probe rectangles.

/// A rotated rectangle in homr's canonical convention.
///
/// [angleDeg] is the orientation of the width-axis, in (-45, 45]. For a
/// near-horizontal staff fragment, [width] is the long (horizontal) extent and
/// [angleDeg] is its slope; for a vertical bar line, [width] is the short
/// (horizontal) extent and [height] the long (vertical) one — matching how
/// homr's AngledBoundingBox assigns width=x-extent, height=y-extent near angle 0.
class RotRect {
  final double cx, cy;
  final double width, height;
  final double angleDeg;

  const RotRect(this.cx, this.cy, this.width, this.height, this.angleDeg);

  /// Slope of the width-axis as a y-shift per unit x — homr's
  /// get_center_extrapolated uses tan(angle).
  double get tanAngle => math.tan(angleDeg * math.pi / 180.0);

  /// y of the width-axis centre line at column [x] (homr get_center_extrapolated).
  double centerExtrapolated(double x) => (x - cx) * tanAngle + cy;
}

/// One 8-connected foreground component: its pixel coordinates and bbox.
class Component {
  final List<int> xs;
  final List<int> ys;
  final int minX, minY, maxX, maxY;
  const Component(this.xs, this.ys, this.minX, this.minY, this.maxX, this.maxY);
  int get area => xs.length;
}

/// Labels 8-connected foreground (mask[i] != 0) components via union-find.
///
/// Mirrors cv2.findContours' connectivity for the purpose of feeding
/// minAreaRect: one component → one outer boundary → one minAreaRect. Holes
/// (which findContours would return as extra contours) are not emitted; for the
/// thin staff/symbol shapes homr processes they are negligible and would be
/// size-filtered anyway.
List<Component> connectedComponents(Uint8List mask, int width, int height) {
  final n = width * height;
  // labels[i] = parent index for union-find, or -1 if background.
  final parent = Int32List(n);
  for (int i = 0; i < n; i++) {
    parent[i] = mask[i] != 0 ? i : -1;
  }

  int find(int x) {
    int root = x;
    while (parent[root] != root) {
      root = parent[root];
    }
    // Path compression.
    while (parent[x] != root) {
      final next = parent[x];
      parent[x] = root;
      x = next;
    }
    return root;
  }

  void union(int a, int b) {
    final ra = find(a), rb = find(b);
    if (ra != rb) parent[ra] = rb;
  }

  // Union with already-visited neighbours: W, NW, N, NE (8-connectivity).
  for (int y = 0; y < height; y++) {
    final row = y * width;
    for (int x = 0; x < width; x++) {
      final i = row + x;
      if (parent[i] == -1) continue;
      if (x > 0 && parent[i - 1] != -1) union(i, i - 1);
      if (y > 0) {
        final up = i - width;
        if (parent[up] != -1) union(i, up);
        if (x > 0 && parent[up - 1] != -1) union(i, up - 1);
        if (x < width - 1 && parent[up + 1] != -1) union(i, up + 1);
      }
    }
  }

  // Gather pixels per root.
  final roots = <int, List<int>>{};
  for (int y = 0; y < height; y++) {
    final row = y * width;
    for (int x = 0; x < width; x++) {
      final i = row + x;
      if (parent[i] == -1) continue;
      (roots[find(i)] ??= <int>[]).add(i);
    }
  }

  final result = <Component>[];
  roots.forEach((_, pixels) {
    int minX = 1 << 30, minY = 1 << 30, maxX = -1, maxY = -1;
    final fxs = <int>[];
    final fys = <int>[];
    for (final p in pixels) {
      final px = p % width;
      final py = p ~/ width;
      fxs.add(px);
      fys.add(py);
      if (px < minX) minX = px;
      if (px > maxX) maxX = px;
      if (py < minY) minY = py;
      if (py > maxY) maxY = py;
    }
    result.add(Component(fxs, fys, minX, minY, maxX, maxY));
  });
  return result;
}

/// Andrew's monotone-chain convex hull. Points are integer (x,y) pairs given as
/// parallel lists. Returns hull vertices CCW as (x,y) doubles, no duplicate
/// endpoint. cv2.minAreaRect's enclosing rectangle depends only on the hull.
List<List<double>> convexHull(List<int> xs, List<int> ys) {
  final n = xs.length;
  if (n == 1) return [[xs[0].toDouble(), ys[0].toDouble()]];
  final idx = List<int>.generate(n, (i) => i);
  idx.sort((a, b) => xs[a] != xs[b] ? xs[a] - xs[b] : ys[a] - ys[b]);

  // Deduplicate sorted points.
  final px = <int>[];
  final py = <int>[];
  for (final i in idx) {
    if (px.isNotEmpty && px.last == xs[i] && py.last == ys[i]) continue;
    px.add(xs[i]);
    py.add(ys[i]);
  }
  final m = px.length;
  if (m <= 2) return [for (int i = 0; i < m; i++) [px[i].toDouble(), py[i].toDouble()]];

  double cross(int oX, int oY, int aX, int aY, int bX, int bY) =>
      ((aX - oX) * (bY - oY) - (aY - oY) * (bX - oX)).toDouble();

  final hull = List<int>.filled(2 * m, 0);
  int k = 0;
  // Lower hull.
  for (int i = 0; i < m; i++) {
    while (k >= 2 &&
        cross(px[hull[k - 2]], py[hull[k - 2]], px[hull[k - 1]], py[hull[k - 1]],
                px[i], py[i]) <=
            0) {
      k--;
    }
    hull[k++] = i;
  }
  // Upper hull.
  final lower = k + 1;
  for (int i = m - 2; i >= 0; i--) {
    while (k >= lower &&
        cross(px[hull[k - 2]], py[hull[k - 2]], px[hull[k - 1]], py[hull[k - 1]],
                px[i], py[i]) <=
            0) {
      k--;
    }
    hull[k++] = i;
  }
  // hull[0..k-1], last == first, drop it.
  return [for (int i = 0; i < k - 1; i++) [px[hull[i]].toDouble(), py[hull[i]].toDouble()]];
}

/// Minimum-area enclosing rectangle of a component, in canonical [RotRect] form.
///
/// Rotating calipers: the min-area rectangle has one side collinear with a hull
/// edge. For each hull edge we project all hull points onto the edge direction
/// and its normal, take the extents, and keep the smallest-area box.
RotRect minAreaRect(List<int> xs, List<int> ys) {
  final hull = convexHull(xs, ys);
  final h = hull.length;
  if (h == 1) return RotRect(hull[0][0], hull[0][1], 0, 0, 0);
  if (h == 2) {
    final dx = hull[1][0] - hull[0][0];
    final dy = hull[1][1] - hull[0][1];
    final len = math.sqrt(dx * dx + dy * dy);
    final cx = (hull[0][0] + hull[1][0]) / 2;
    final cy = (hull[0][1] + hull[1][1]) / 2;
    return _canonical(cx, cy, len, 0, math.atan2(dy, dx));
  }

  double bestArea = double.infinity;
  double bCx = 0, bCy = 0, bW = 0, bH = 0, bTheta = 0;

  for (int i = 0; i < h; i++) {
    final j = (i + 1) % h;
    double ex = hull[j][0] - hull[i][0];
    double ey = hull[j][1] - hull[i][1];
    final elen = math.sqrt(ex * ex + ey * ey);
    if (elen < 1e-9) continue;
    ex /= elen;
    ey /= elen;
    // Normal = (-ey, ex).
    double minU = double.infinity, maxU = -double.infinity;
    double minV = double.infinity, maxV = -double.infinity;
    for (final p in hull) {
      final u = p[0] * ex + p[1] * ey;
      final v = -p[0] * ey + p[1] * ex;
      if (u < minU) minU = u;
      if (u > maxU) maxU = u;
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }
    final w = maxU - minU;
    final hgt = maxV - minV;
    final area = w * hgt;
    if (area < bestArea) {
      bestArea = area;
      final midU = (minU + maxU) / 2;
      final midV = (minV + maxV) / 2;
      // Centre back in image coordinates.
      bCx = midU * ex - midV * ey;
      bCy = midU * ey + midV * ex;
      bW = w;
      bH = hgt;
      bTheta = math.atan2(ey, ex);
    }
  }
  return _canonical(bCx, bCy, bW, bH, bTheta);
}

/// Builds the canonical [RotRect]: choose, of the two perpendicular axes, the one
/// whose angle lies in (-45,45] as the width-axis. [thetaRad] is the direction of
/// the side with length [w]; the perpendicular side has length [hgt].
RotRect _canonical(double cx, double cy, double w, double hgt, double thetaRad) {
  double deg = thetaRad * 180.0 / math.pi;
  // Reduce to (-90, 90].
  while (deg > 90) {
    deg -= 180;
  }
  while (deg <= -90) {
    deg += 180;
  }
  if (deg > 45) {
    // width-axis is the perpendicular one (rotate -90), swap extents.
    return RotRect(cx, cy, hgt, w, deg - 90);
  } else if (deg <= -45) {
    return RotRect(cx, cy, hgt, w, deg + 90);
  }
  return RotRect(cx, cy, w, hgt, deg);
}

// ---------------------------------------------------------------------------
// Morphology (binary, 0/non-zero masks). Rectangular structuring elements are
// what homr's small kernels approximate closely enough for these masks.
// ---------------------------------------------------------------------------

/// Binary dilation with a [kw]×[kh] rectangular kernel (cv2.dilate equivalent
/// for the small kernels homr uses). Output is 0/1.
Uint8List dilate(Uint8List mask, int width, int height, int kw, int kh) {
  final out = Uint8List(width * height);
  final rx = kw ~/ 2;
  final ry = kh ~/ 2;
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      if (mask[y * width + x] == 0) continue;
      final y0 = math.max(0, y - ry), y1 = math.min(height - 1, y + ry);
      final x0 = math.max(0, x - rx), x1 = math.min(width - 1, x + rx);
      for (int yy = y0; yy <= y1; yy++) {
        final row = yy * width;
        for (int xx = x0; xx <= x1; xx++) {
          out[row + xx] = 1;
        }
      }
    }
  }
  return out;
}

/// Binary erosion with a [kw]×[kh] rectangular kernel. Output is 0/1.
Uint8List erode(Uint8List mask, int width, int height, int kw, int kh) {
  final out = Uint8List(width * height);
  final rx = kw ~/ 2;
  final ry = kh ~/ 2;
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      bool keep = true;
      final y0 = y - ry, y1 = y + ry, x0 = x - rx, x1 = x + rx;
      for (int yy = y0; yy <= y1 && keep; yy++) {
        if (yy < 0 || yy >= height) {
          keep = false;
          break;
        }
        final row = yy * width;
        for (int xx = x0; xx <= x1; xx++) {
          if (xx < 0 || xx >= width || mask[row + xx] == 0) {
            keep = false;
            break;
          }
        }
      }
      out[y * width + x] = keep ? 1 : 0;
    }
  }
  return out;
}
