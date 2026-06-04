import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Corrects book-spine curvature in a cropped staff strip.
///
/// Implements the same 1-D column-wise vertical displacement that Python homr's
/// `calculate_span_and_optimal_points` + piecewise-affine warp produces, minus
/// the Delaunay triangulation overhead.  For book-spine warps the distortion is
/// purely vertical (pages bow up/down near the binding), so the 2-D triangulated
/// warp reduces exactly to: for each x-column, shift all pixels by
///   delta(x) = actual_middle_line_y(x) − average_middle_line_y
///
/// [strip]   — 3-channel CLAHE staff image (output of copyCrop on the full image)
/// [profile] — (x, y) pairs giving the middle staff line's detected y-position at
///             each sampled x, in full-image coordinates.  From
///             SegmentationPostprocessor.extractMiddleLineProfile.
///
/// Returns a new img.Image with the same dimensions as [strip].
img.Image dewarpStaffStrip(
  img.Image strip,
  List<(int, int)> profile,
) {
  if (profile.length < 2) return strip;

  final w = strip.width;
  final h = strip.height;


  // Sort profile by x ascending (should already be sorted, but be safe).
  final sorted = List.of(profile)..sort((a, b) => a.$1.compareTo(b.$1));

  // Median-smooth over a 3-sample window to suppress single-column mask noise.
  final smoothed = <(int, int)>[];
  for (int i = 0; i < sorted.length; i++) {
    final i0 = (i - 1).clamp(0, sorted.length - 1);
    final i1 = i;
    final i2 = (i + 1).clamp(0, sorted.length - 1);
    final ys = [sorted[i0].$2, sorted[i1].$2, sorted[i2].$2]..sort();
    smoothed.add((sorted[i].$1, ys[1]));
  }

  // Compute average over smoothed profile — the "ideal" flat target position.
  final avgY = smoothed.fold(0.0, (s, p) => s + p.$2) / smoothed.length;

  // Build per-column delta array via linear interpolation of the smoothed profile.
  //
  // delta[x] = interpolated_actual_y(x) − avgY
  //
  // Inverse warp: to fill output pixel (x, yOut), sample input at (x, yOut + delta[x]).
  // Positive delta means the line bows downward at this x → shift sample upward.
  final deltas = Float64List(w);
  int pi = 0;
  for (int x = 0; x < w; x++) {
    while (pi < smoothed.length - 2 && smoothed[pi + 1].$1 <= x) {
      pi++;
    }

    final double actualY;
    final x0 = smoothed[pi].$1.toDouble();
    final y0 = smoothed[pi].$2.toDouble();
    if (pi >= smoothed.length - 1 || smoothed[pi + 1].$1 == smoothed[pi].$1) {
      actualY = y0;
    } else {
      final x1 = smoothed[pi + 1].$1.toDouble();
      final y1 = smoothed[pi + 1].$2.toDouble();
      final t = (x - x0) / (x1 - x0);
      actualY = y0 + t * (y1 - y0);
    }
    deltas[x] = actualY - avgY;
  }

  // Apply warp: for each output pixel (x, yOut), bilinearly sample input at
  // (x, yOut + delta[x]).  Fill background with white (matching Python's fill_color=1).
  final out = img.Image(
      width: w, height: h, numChannels: strip.numChannels, format: strip.format);
  img.fill(out, color: img.ColorUint8.rgb(255, 255, 255));

  for (int x = 0; x < w; x++) {
    final delta = deltas[x];
    for (int yOut = 0; yOut < h; yOut++) {
      final ySrcRaw = yOut + delta;
      final y0 = ySrcRaw.floor().clamp(0, h - 1);
      final y1 = (y0 + 1).clamp(0, h - 1);
      final fy = (ySrcRaw - ySrcRaw.floor()).clamp(0.0, 1.0);

      final p0 = strip.getPixel(x, y0);
      final p1 = strip.getPixel(x, y1);

      final r = (p0.r * (1 - fy) + p1.r * fy).round().clamp(0, 255);
      final g = (p0.g * (1 - fy) + p1.g * fy).round().clamp(0, 255);
      final b = (p0.b * (1 - fy) + p1.b * fy).round().clamp(0, 255);
      out.setPixelRgb(x, yOut, r, g, b);
    }
  }

  return out;
}
