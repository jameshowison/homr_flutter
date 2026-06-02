import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

const int _targetWidth = 1920;
const int _thresholdValue = 128;

/// Resize → grayscale → binary threshold at 128.
/// Returns PNG bytes of the processed image.
Future<Uint8List> preprocessImage(Uint8List jpegBytes) {
  return Isolate.run(() => _process(jpegBytes));
}

Uint8List _process(Uint8List jpegBytes) {
  final decoded = img.decodeImage(jpegBytes);
  if (decoded == null) throw Exception('Could not decode image');

  final resized = img.copyResize(decoded, width: _targetWidth);
  final gray = img.grayscale(resized);

  for (final pixel in gray) {
    final v = pixel.r < _thresholdValue ? 0 : 255;
    pixel.r = v;
    pixel.g = v;
    pixel.b = v;
  }

  return img.encodePng(gray);
}
