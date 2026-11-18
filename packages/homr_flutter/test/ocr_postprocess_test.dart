// ignore_for_file: implementation_imports
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:homr_flutter/src/ocr/latin_dict.dart';
import 'package:homr_flutter/src/ocr/ocr_postprocess.dart';

/// A [w] × [h] map, 0 everywhere but [p] over each rectangle (x0, y0, x1, y1
/// inclusive).
Float32List _map(int w, int h, List<(int, int, int, int)> rects,
    {double p = 0.9}) {
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
          _steps([latinCharacters.indexOf('A') + 1, 503,
              latinCharacters.indexOf('é') + 1], 504),
          3, 504, latinCharacters);
      expect(r.text, 'A é');
    });
  });

  group('mergeLines', () {
    ReadBox r(double l, double t, double rt, double b, String s, double c) =>
        (box: PixelBox(l, t, rt, b, 0.8), text: s, confidence: c);

    test('joins the words of a large title, in order', () {
      // The detector's boxes for a 72 pt "Lightly Row": they even overlap.
      final out = mergeLines([
        r(848, 52, 1012, 121, 'Row', 0.994),
        r(588, 50, 860, 123, 'Lightly', 1.0),
      ]);
      expect(out, hasLength(1));
      expect(out.single.text, 'Lightly Row');
      expect(out.single.box.left, 588);
      expect(out.single.box.right, 1012);
      expect(out.single.confidence, closeTo((7 * 1.0 + 3 * 0.994) / 10, 1e-9));
    });

    test('keeps apart: far gaps, other lines, much smaller type', () {
      final out = mergeLines([
        r(100, 50, 300, 110, 'Allegro', 0.9),
        r(700, 52, 800, 108, 'Suzuki', 0.9), // 400 px away
        r(100, 130, 300, 160, 'Moderato', 0.9), // the next line down
        r(305, 70, 340, 95, '3', 0.9), // beside the title, under half its size
      ]);
      expect([for (final l in out) l.text], ['Allegro', 'Suzuki', '3', 'Moderato']);
    });

    test('a word gap of under 0.8 heights joins', () {
      final out = mergeLines([
        r(0, 0, 100, 40, 'Song', 0.9),
        r(130, 2, 200, 40, 'of', 0.9),
        r(225, 0, 300, 41, 'Wind', 0.9),
      ]);
      expect([for (final l in out) l.text], ['Song of Wind']);
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
