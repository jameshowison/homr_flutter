import 'package:flutter_test/flutter_test.dart';
import 'package:homr_omr/homr_omr.dart';
import 'package:image/image.dart' as img;

img.Image _twoTone(int ink, int paper, {int inkPixels = 100, int total = 1000}) {
  final im = img.Image(width: total, height: 1);
  for (var x = 0; x < total; x++) {
    final v = x < inkPixels ? ink : paper;
    im.setPixelRgb(x, 0, v, v, v);
  }
  return im;
}

void main() {
  test('splits dark ink from white paper', () {
    final t = otsuThreshold(_twoTone(20, 240));
    expect(t, greaterThan(20));
    expect(t, lessThanOrEqualTo(240));
  });

  test('grey print on white paper: the cut lands above the grey, so lines '
      'survive (the case a fixed 128 erased)', () {
    final t = otsuThreshold(_twoTone(170, 250));
    expect(t, greaterThan(170));
  });

  test('a uniform image does not throw', () {
    expect(() => otsuThreshold(_twoTone(255, 255)), returnsNormally);
  });
}
