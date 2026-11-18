import 'dart:math' as math;
import 'dart:typed_data';

/// The pure parts of the OCR: the detector's DB post-processing and the
/// recogniser's CTC decoding, kept free of ONNX so they can be unit-tested.
///
/// They follow PaddleOCR's PP-OCRv5 defaults (`DBPostProcess`,
/// `CTCLabelDecode`), but with axis-aligned boxes only: titles are printed
/// horizontally, so there is no rotated rectangle and no angle classifier.

/// An axis-aligned box in some image's pixels, edges inclusive of the text.
class PixelBox {
  final double left, top, right, bottom;

  /// The detector's mean probability over the box, before it was grown.
  final double score;

  const PixelBox(this.left, this.top, this.right, this.bottom, this.score);

  double get width => right - left;
  double get height => bottom - top;

  @override
  String toString() =>
      'PixelBox(${left.toStringAsFixed(1)}, ${top.toStringAsFixed(1)}, '
      '${right.toStringAsFixed(1)}, ${bottom.toStringAsFixed(1)}, '
      'score ${score.toStringAsFixed(3)})';
}

/// The text boxes in a DB probability map of [width] × [height] (row-major).
///
/// 1. Binarise at [threshold] and take 8-connected components.
/// 2. Drop a component whose bounding box is under 3 px on its short side,
///    or whose mean probability over that box is below [boxThreshold].
/// 3. Unclip: grow each side by area·[unclipRatio]/perimeter, as DB's
///    polygon offset does for a rectangle, and drop one still under 5 px.
///
/// Boxes are in the map's pixels, top-to-bottom then left-to-right, and not
/// clipped to the map: scale and clip them to the source image.
List<PixelBox> dbBoxes(
  Float32List prob,
  int width,
  int height, {
  double threshold = 0.3,
  double boxThreshold = 0.6,
  double unclipRatio = 1.5,
}) {
  assert(prob.length == width * height);
  final labels = Int32List(width * height); // 0 = unvisited/background
  final boxes = <PixelBox>[];
  final stack = <int>[];
  var next = 0;

  for (var start = 0; start < prob.length; start++) {
    if (labels[start] != 0 || prob[start] <= threshold) continue;
    next++;
    labels[start] = next;
    stack.add(start);
    var x0 = width, y0 = height, x1 = -1, y1 = -1;
    while (stack.isNotEmpty) {
      final i = stack.removeLast();
      final x = i % width, y = i ~/ width;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
      for (var dy = -1; dy <= 1; dy++) {
        final ny = y + dy;
        if (ny < 0 || ny >= height) continue;
        for (var dx = -1; dx <= 1; dx++) {
          final nx = x + dx;
          if (nx < 0 || nx >= width) continue;
          final j = ny * width + nx;
          if (labels[j] == 0 && prob[j] > threshold) {
            labels[j] = next;
            stack.add(j);
          }
        }
      }
    }

    // Contour points run through pixel centres, so a component spanning
    // columns x0..x1 is x1 − x0 wide, as OpenCV measures it.
    final w = (x1 - x0).toDouble(), h = (y1 - y0).toDouble();
    if (math.min(w, h) < 3) continue;

    var sum = 0.0;
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        sum += prob[y * width + x];
      }
    }
    final score = sum / ((x1 - x0 + 1) * (y1 - y0 + 1));
    if (score < boxThreshold) continue;

    final d = w * h * unclipRatio / (2 * (w + h));
    final box = PixelBox(x0 - d, y0 - d, x1 + d, y1 + d, score);
    if (math.min(box.width, box.height) < 5) continue;
    boxes.add(box);
  }
  return sortReadingOrder(boxes);
}

/// Top-to-bottom, then left-to-right among boxes whose tops are within
/// [lineTolerance] px of each other (PaddleOCR's `sorted_boxes`).
List<PixelBox> sortReadingOrder(List<PixelBox> boxes,
    {double lineTolerance = 10}) {
  final byTop = [...boxes]..sort((a, b) => a.top.compareTo(b.top));
  final lines = <List<PixelBox>>[];
  for (final b in byTop) {
    if (lines.isEmpty || b.top - lines.last.last.top >= lineTolerance) {
      lines.add([b]);
    } else {
      lines.last.add(b);
    }
  }
  return [
    for (final line in lines)
      ...(line..sort((a, b) => a.left.compareTo(b.left))),
  ];
}

/// A recognised box: where, what, and how sure.
typedef ReadBox = ({PixelBox box, String text, double confidence});

/// Joins boxes that are words of one line, as Vision and ML Kit report text:
/// the detector splits large type at word gaps ("Lightly", "Row"), and a
/// title has to come back whole.
///
/// Going left to right, a box joins a line when they overlap vertically by
/// at least half the shorter one's height, their heights are within
/// [maxHeightRatio] of each other (so a title doesn't swallow a smaller
/// marking beside it), and the gap between them is at most [maxGap] × the
/// shorter height. Texts are joined with a space; confidence is their mean
/// weighted by length. The result is in reading order ([sortReadingOrder]).
List<ReadBox> mergeLines(List<ReadBox> boxes,
    {double maxGap = 0.8, double maxHeightRatio = 1.5}) {
  final byLeft = [...boxes]..sort((a, b) => a.box.left.compareTo(b.box.left));
  final lines = <ReadBox>[];
  for (final b in byLeft) {
    final i = lines.lastIndexWhere(
        (l) => _sameLine(l.box, b.box, maxGap, maxHeightRatio));
    if (i < 0) {
      lines.add(b);
      continue;
    }
    final l = lines[i];
    final n1 = l.text.length, n2 = b.text.length;
    lines[i] = (
      box: PixelBox(
        math.min(l.box.left, b.box.left),
        math.min(l.box.top, b.box.top),
        math.max(l.box.right, b.box.right),
        math.max(l.box.bottom, b.box.bottom),
        math.max(l.box.score, b.box.score),
      ),
      text: '${l.text} ${b.text}',
      confidence: (l.confidence * n1 + b.confidence * n2) / (n1 + n2),
    );
  }
  final order = sortReadingOrder([for (final l in lines) l.box]);
  return [for (final box in order) lines.firstWhere((l) => identical(l.box, box))];
}

/// Whether [b], which starts at or right of [a]'s left edge, continues [a]'s
/// line.
bool _sameLine(PixelBox a, PixelBox b, double maxGap, double maxHeightRatio) {
  final lo = math.min(a.height, b.height), hi = math.max(a.height, b.height);
  if (lo <= 0 || hi / lo > maxHeightRatio) return false;
  final overlap = math.min(a.bottom, b.bottom) - math.max(a.top, b.top);
  if (overlap < lo / 2) return false;
  return b.left - a.right <= maxGap * lo;
}

/// One recognised line: its text and the mean probability of its characters.
typedef CtcResult = ({String text, double confidence});

/// Greedy CTC over [steps] × [classes] probabilities (row-major): the argmax
/// per step, repeats collapsed, class 0 (blank) dropped. Class k ≥ 1 is
/// `characters[k - 1]`, and any class past the list is a space.
///
/// Confidence is the mean of the kept steps' probabilities, 0 when nothing
/// is kept.
CtcResult ctcDecode(
    List<double> probs, int steps, int classes, List<String> characters) {
  assert(probs.length >= steps * classes);
  final text = StringBuffer();
  var sum = 0.0, kept = 0, previous = -1;
  for (var t = 0; t < steps; t++) {
    final row = t * classes;
    var best = 0;
    var bestP = probs[row];
    for (var c = 1; c < classes; c++) {
      final p = probs[row + c];
      if (p > bestP) {
        bestP = p;
        best = c;
      }
    }
    if (best != 0 && best != previous) {
      text.write(best <= characters.length ? characters[best - 1] : ' ');
      sum += bestP;
      kept++;
    }
    previous = best;
  }
  return (text: text.toString(), confidence: kept == 0 ? 0.0 : sum / kept);
}
