// ignore_for_file: implementation_imports
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:homr_flutter/src/ocr/latin_dict.dart';
import 'package:homr_flutter/src/ocr/ocr_postprocess.dart';

/// A [w] × [h] map, 0 everywhere but [p] over each rectangle (x0, y0, x1, y1
/// inclusive).
Float32List _map(
  int w,
  int h,
  List<(int, int, int, int)> rects, {
  double p = 0.9,
}) {
  final m = Float32List(w * h);
  for (final (x0, y0, x1, y1) in rects) {
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        m[y * w + x] = p;
      }
    }
  }
  return m;
}

/// One step per entry of [classes] (null = a blank), [p] on that class.
List<double> _steps(List<int> classes, int numClasses, {double p = 0.9}) {
  final out = List<double>.filled(classes.length * numClasses, 0);
  for (var t = 0; t < classes.length; t++) {
    final rest = (1 - p) / (numClasses - 1);
    for (var c = 0; c < numClasses; c++) {
      out[t * numClasses + c] = c == classes[t] ? p : rest;
    }
  }
  return out;
}

void main() {
  group('ctcDecode', () {
    const chars = ['a', 'b', 'c'];
    const n = 5; // blank, a, b, c, space

    test('collapses repeats and drops blanks', () {
      final r = ctcDecode(_steps([1, 1, 0, 1, 2, 2, 0, 0, 3], n), 9, n, chars);
      expect(r.text, 'aabc');
      expect(r.confidence, closeTo(0.9, 1e-9));
    });

    test('the class past the list is a space', () {
      final r = ctcDecode(_steps([1, 4, 2], n), 3, n, chars);
      expect(r.text, 'a b');
    });

    test('all blank is empty with confidence 0', () {
      final r = ctcDecode(_steps([0, 0, 0], n), 3, n, chars);
      expect(r.text, '');
      expect(r.confidence, 0);
    });

    test('confidence is the mean over kept steps only', () {
      final probs = [
        ..._steps([1], n, p: 0.6),
        ..._steps([1], n, p: 0.99), // a repeat: not kept
        ..._steps([0], n, p: 0.99),
        ..._steps([2], n, p: 0.8),
      ];
      final r = ctcDecode(probs, 4, n, chars);
      expect(r.text, 'ab');
      expect(r.confidence, closeTo(0.7, 1e-9));
    });

    test('the Latin list fits the model: 502 characters, then a space', () {
      // The recogniser has 504 classes: blank + 502 + space.
      expect(latinCharacters, hasLength(502));
      expect(latinCharacters.take(3), ['!', '"', '#']);
      expect(latinCharacters, isNot(contains(' ')));
      final r = ctcDecode(
        _steps([
          latinCharacters.indexOf('A') + 1,
          503,
          latinCharacters.indexOf('é') + 1,
        ], 504),
        3,
        504,
        latinCharacters,
      );
      expect(r.text, 'A é');
    });
  });

  group('groupLines', () {
    PixelBox b(double l, double t, double r, double bo) =>
        PixelBox(l, t, r, bo, 0.8);
    List<List<double>> lefts(List<LineBoxes> lines) => [
      for (final l in lines) [for (final w in l.words) w.left],
    ];

    test('joins the words of a large title, left to right', () {
      // The detector's boxes for a 72 pt "Lightly Row": they even overlap.
      final out = groupLines([b(848, 52, 1012, 121), b(588, 50, 860, 123)]);
      expect(lefts(out), [
        [588, 848],
      ]);
      expect(out.single.box.left, 588);
      expect(out.single.box.top, 50);
      expect(out.single.box.right, 1012);
      expect(out.single.box.bottom, 123);
    });

    test('keeps apart: far gaps, other lines, much smaller type', () {
      final out = groupLines([
        b(100, 50, 300, 110), // a title
        b(700, 52, 800, 108), // 400 px away
        b(100, 130, 300, 160), // the next line down
        b(305, 70, 340, 95), // beside the title, under half its size
      ]);
      // Reading order: the "3" starts 20 px lower, so it is its own line.
      expect(lefts(out), [
        [100],
        [700],
        [305],
        [100],
      ]);
    });

    test('a word gap of under 0.8 heights joins', () {
      final out = groupLines([
        b(0, 0, 100, 40),
        b(130, 2, 200, 40),
        b(225, 0, 300, 41),
      ]);
      expect(lefts(out), [
        [0, 130, 225],
      ]);
    });
  });

  group('joinWords', () {
    test('joins with spaces, confidence weighted by length', () {
      final r = joinWords([
        (text: 'Lightly', confidence: 1.0),
        (text: 'Row', confidence: 0.994),
      ]);
      expect(r.text, 'Lightly Row');
      expect(r.confidence, closeTo((7 * 1.0 + 3 * 0.994) / 10, 1e-9));
    });

    test('skips words that read empty', () {
      final r = joinWords([
        (text: ' ', confidence: 0.2),
        (text: 'Andante', confidence: 0.9),
        (text: '', confidence: 0.0),
      ]);
      expect(r.text, 'Andante');
      expect(r.confidence, closeTo(0.9, 1e-9));
    });

    test('all empty is empty', () {
      expect(joinWords([(text: '', confidence: 0.0)]).text, '');
    });
  });

  group('readLargestFirst', () {
    /// Lines of these heights, the i-th one [i * 50] px down the page.
    List<PixelBox> lines(List<double> heights) => [
      for (var i = 0; i < heights.length; i++)
        PixelBox(0, i * 50.0, 100, i * 50.0 + heights[i], 0.8),
    ];

    Future<List<int>> run(List<double> heights, Set<int> acceptable) =>
        readLargestFirst(lines(heights), (i) async => acceptable.contains(i));

    test('tallest first; stops past the size of the first accepted', () async {
      // 0: 30, 1: 60 (accepted), 2: 58 (within 5 %), 3: 56 (> 5 % shorter).
      expect(await run([30, 60, 58, 56], {1}), [1, 2]);
    });

    test('rejected tall lines are read and passed over', () async {
      // The tallest (a page number, say) is rejected; the next is taken.
      expect(await run([20, 80, 50, 49, 30], {2, 4}), [1, 2, 3]);
    });

    test(
      'every line of the same size is read, so the topmost can be picked',
      () async {
        // Equal heights: higher on the page first, and all of them read.
        expect(await run([40, 40, 40, 10], {2}), [0, 1, 2]);
      },
    );

    test('nothing accepted: every line, tallest first', () async {
      expect(await run([10, 30, 20], {}), [1, 2, 0]);
    });

    test('the tolerance is a parameter', () async {
      final read = await readLargestFirst(
        lines([100, 85, 70]),
        (i) async => i == 0,
        sameSizeTolerance: 0.2,
      );
      expect(read, [0, 1]);
    });

    test('no lines, no reads', () async {
      expect(await run([], {}), isEmpty);
    });
  });

  group('dbBoxes', () {
    test('one component, unclipped by area·1.5/perimeter', () {
      // Columns 10..49, rows 20..29: 39 × 9 between pixel centres.
      final boxes = dbBoxes(_map(100, 50, [(10, 20, 49, 29)]), 100, 50);
      expect(boxes, hasLength(1));
      final d = 39 * 9 * 1.5 / (2 * (39 + 9));
      final b = boxes.single;
      expect(b.left, closeTo(10 - d, 1e-9));
      expect(b.top, closeTo(20 - d, 1e-9));
      expect(b.right, closeTo(49 + d, 1e-9));
      expect(b.bottom, closeTo(29 + d, 1e-9));
      expect(b.score, closeTo(0.9, 1e-6));
    });

    test('drops low-scoring and tiny components', () {
      final m = _map(100, 60, [(5, 5, 40, 15), (60, 5, 61, 30)]);
      // A faint third box: above the binarisation threshold, below 0.6.
      for (var y = 40; y <= 50; y++) {
        for (var x = 10; x <= 60; x++) {
          m[y * 100 + x] = 0.4;
        }
      }
      final boxes = dbBoxes(m, 100, 60);
      expect(boxes, hasLength(1)); // the 2-px-wide one goes too
      expect(boxes.single.left, lessThan(5));
    });

    test('touching diagonally is one component (8-connected)', () {
      final m = _map(60, 40, [(5, 5, 20, 15), (21, 16, 40, 30)]);
      // Merged, the box is half empty: score it leniently to see it at all.
      final boxes = dbBoxes(m, 60, 40, boxThreshold: 0.3);
      expect(boxes, hasLength(1));
      expect(boxes.single.right, greaterThan(40));
    });

    test('reading order: lines by top, words by left', () {
      final m = _map(200, 100, [
        (120, 12, 180, 22), // line 1, right word, 2 px lower
        (10, 10, 100, 20), // line 1, left word
        (10, 60, 100, 75), // line 2
      ]);
      final lefts = [for (final b in dbBoxes(m, 200, 100)) b.left.round()];
      expect(lefts.length, 3);
      expect(lefts[0], lessThan(lefts[1])); // same line, left first
      expect(lefts[2], lessThan(lefts[1]));
    });

    test('an empty map has no boxes', () {
      expect(dbBoxes(Float32List(64 * 32), 64, 32), isEmpty);
    });
  });
}
