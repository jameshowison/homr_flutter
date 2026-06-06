import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

const int _targetWidth = 1920;
const int _thresholdValue = 128;

typedef PreprocessResult = ({Uint8List original, Uint8List thresholded});

/// Resize to [_targetWidth] px wide, then produce two PNGs:
///   original    — resized full-colour (before any thresholding)
///   thresholded — grayscale + binary threshold at [_thresholdValue]
Future<PreprocessResult> preprocessImage(Uint8List jpegBytes) {
  return Isolate.run(() => _process(jpegBytes));
}

PreprocessResult _process(Uint8List jpegBytes) {
  final decoded = img.decodeImage(jpegBytes);
  if (decoded == null) throw Exception('Could not decode image');

  final resized = img.copyResize(decoded, width: _targetWidth);
  final originalPng = img.encodePng(resized);

  final gray = img.grayscale(resized);
  for (final pixel in gray) {
    final v = pixel.r < _thresholdValue ? 0 : 255;
    pixel.r = v;
    pixel.g = v;
    pixel.b = v;
  }

  return (original: originalPng, thresholded: img.encodePng(gray));
}

/// Apply CLAHE (Contrast Limited Adaptive Histogram Equalisation) using the
/// same parameters as the Python homr pipeline:
///   cv2.createCLAHE(clipLimit=1.0, tileGridSize=(8, 8))
///
/// Converts [source] to grayscale uint8 first. The returned image is
/// single-channel uint8, ready to pass to SegNet or the transformer.
img.Image applyClahe(
  img.Image source, {
  double clipLimit = 1.0,
  int tilesX = 8,
  int tilesY = 8,
}) {
  // Ensure single-channel uint8 grayscale.
  final img.Image gray;
  if (source.numChannels == 1 && source.format == img.Format.uint8) {
    gray = source;
  } else {
    gray = img.grayscale(source)
        .convert(format: img.Format.uint8, numChannels: 1);
  }

  final W = gray.width;
  final H = gray.height;
  final int tileW = (W / tilesX).ceil();
  final int tileH = (H / tilesY).ceil();

  // ── Per-tile histograms ───────────────────────────────────────────────────
  final hists = List.generate(tilesY * tilesX, (_) => Int32List(256));
  for (int ty = 0; ty < tilesY; ty++) {
    for (int tx = 0; tx < tilesX; tx++) {
      final x0 = tx * tileW;
      final y0 = ty * tileH;
      final x1 = min(x0 + tileW, W);
      final y1 = min(y0 + tileH, H);
      final hist = hists[ty * tilesX + tx];
      for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
          hist[gray.getPixel(x, y).r.toInt()]++;
        }
      }
    }
  }

  // ── Clip, redistribute, build CDF lookup table per tile ──────────────────
  final maps = List.generate(tilesY * tilesX, (_) => Uint8List(256));
  for (int ty = 0; ty < tilesY; ty++) {
    for (int tx = 0; tx < tilesX; tx++) {
      final x0 = tx * tileW;
      final y0 = ty * tileH;
      final nPixels =
          (min(x0 + tileW, W) - x0) * (min(y0 + tileH, H) - y0);
      final int clipCount =
          max(1, (clipLimit * nPixels / 256).round());
      final hist = hists[ty * tilesX + tx];

      int excess = 0;
      for (int i = 0; i < 256; i++) {
        if (hist[i] > clipCount) {
          excess += hist[i] - clipCount;
          hist[i] = clipCount;
        }
      }
      final int evenAdd = excess ~/ 256;
      final int rem = excess % 256;
      for (int i = 0; i < 256; i++) {
        hist[i] += evenAdd;
        if (i < rem) hist[i]++;
      }

      final map = maps[ty * tilesX + tx];
      int cdf = 0;
      for (int i = 0; i < 256; i++) {
        cdf += hist[i];
        map[i] = ((cdf * 255.0) / nPixels).round().clamp(0, 255);
      }
    }
  }

  // ── Bilinear interpolation between tile centres ───────────────────────────
  // Build raw output bytes directly.
  final outBytes = Uint8List(W * H);
  for (int y = 0; y < H; y++) {
    for (int x = 0; x < W; x++) {
      final int v = gray.getPixel(x, y).r.toInt();

      // Fractional tile-centre coordinate.
      final double fx = (x + 0.5) / tileW - 0.5;
      final double fy = (y + 0.5) / tileH - 0.5;

      final int tx0 = fx.floor().clamp(0, tilesX - 1);
      final int tx1 = (tx0 + 1).clamp(0, tilesX - 1);
      final int ty0 = fy.floor().clamp(0, tilesY - 1);
      final int ty1 = (ty0 + 1).clamp(0, tilesY - 1);

      final double ax = (fx - tx0).clamp(0.0, 1.0);
      final double ay = (fy - ty0).clamp(0.0, 1.0);

      outBytes[y * W + x] = (maps[ty0 * tilesX + tx0][v] * (1 - ax) * (1 - ay) +
              maps[ty0 * tilesX + tx1][v] * ax * (1 - ay) +
              maps[ty1 * tilesX + tx0][v] * (1 - ax) * ay +
              maps[ty1 * tilesX + tx1][v] * ax * ay)
          .round()
          .clamp(0, 255);
    }
  }

  return img.Image.fromBytes(
    width: W,
    height: H,
    bytes: outBytes.buffer,
    format: img.Format.uint8,
    numChannels: 1,
    order: img.ChannelOrder.red,
  );
}

/// Expand a single-channel grayscale image to 3-channel RGB with R=G=B=v.
///
/// Passing a 3-channel image to the inference runners ensures img.grayscale()
/// inside them computes 0.299*r + 0.587*r + 0.114*r = r (identity), not the
/// 0.886*r scaling it applies to single-channel images (where .b returns 0).
img.Image claheGrayToRgb(img.Image gray1ch) {
  assert(gray1ch.numChannels == 1 && gray1ch.format == img.Format.uint8);
  final W = gray1ch.width;
  final H = gray1ch.height;
  final grayBytes = gray1ch.getBytes(order: img.ChannelOrder.red);
  final rgbBytes = Uint8List(W * H * 3);
  for (int i = 0; i < grayBytes.length; i++) {
    final v = grayBytes[i];
    rgbBytes[i * 3] = v;
    rgbBytes[i * 3 + 1] = v;
    rgbBytes[i * 3 + 2] = v;
  }
  return img.Image.fromBytes(
    width: W,
    height: H,
    bytes: rgbBytes.buffer,
    format: img.Format.uint8,
    numChannels: 3,
  );
}
