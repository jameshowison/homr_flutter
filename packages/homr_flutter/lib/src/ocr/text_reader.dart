import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../inference/omr_models.dart' show openModelSession;
import 'latin_dict.dart';
import 'ocr_models.dart';
import 'ocr_postprocess.dart';

/// One line of text [TextReader] read.
class OcrLine {
  final String text;

  /// Mean probability of the line's characters, 0–1.
  final double confidence;

  /// Where the line is, normalised to the whole upright image (0–1, top-left
  /// origin), whatever region was searched.
  final ui.Rect box;

  const OcrLine(this.text, this.confidence, this.box);

  @override
  String toString() =>
      'OcrLine("$text", ${confidence.toStringAsFixed(3)}, $box)';
}

/// Reads printed horizontal text on device: PaddleOCR's PP-OCRv5 mobile
/// detector finds the lines, its Latin recogniser reads each one. It is the
/// same pipeline as RapidOCR, which homr's title detection uses, with
/// axis-aligned boxes and no angle classifier.
///
/// The two sessions open on first use and stay open until [dispose]. Unlike
/// the music models they are not cached for the process, so an app can free
/// them before something memory-hungry, such as recognising a score.
class TextReader {
  TextReader(this.models);

  final OcrModels models;

  Future<OrtSession>? _det, _rec;

  /// Longest side the detector sees; larger regions are scaled down.
  static const maxDetSide = 960;

  /// The recogniser's input height, and the narrowest input it is given.
  static const _recHeight = 48, _recMinWidth = 320;

  /// The widest a line is read: 40 × its height, longer than any title.
  static const _recMaxWidth = 48 * 40;

  static const _detMean = [0.485, 0.456, 0.406],
      _detStd = [0.229, 0.224, 0.225];
  static const _recMean = [0.5, 0.5, 0.5], _recStd = [0.5, 0.5, 0.5];

  /// Every line of text in [region] of [image] (PNG or JPEG bytes), in
  /// reading order, the words of a line joined ([groupLines]). [region] is
  /// normalised to the upright image, top-left origin; null means the whole
  /// image. The image is decoded as Flutter decodes it, EXIF orientation
  /// applied.
  ///
  /// With [accept], only enough is read to find the line in the largest type
  /// that [accept] takes, which is much faster on a busy page: lines are
  /// read tallest first, and reading stops before the first line more than
  /// [sameSizeTolerance] shorter than the tallest accepted one. The lines
  /// read are returned, accepted or not, in reading order. Every line within
  /// [sameSizeTolerance] of the tallest accepted one is among them, so "the
  /// topmost acceptable line within that tolerance of the tallest" picks the
  /// same line from them as from a full read. With nothing accepted, every
  /// line is read.
  Future<List<OcrLine>> readText(
    Uint8List image, {
    ui.Rect? region,
    bool Function(OcrLine line)? accept,
    double sameSizeTolerance = 0.05,
  }) async {
    _t.clear();
    final total = Stopwatch()..start();
    try {
      return await _readText(image, region, accept, sameSizeTolerance);
    } finally {
      _t['total'] = total.elapsedMicroseconds;
      if (_logTimings) {
        // Milliseconds per stage, and counts (n_*): never any text read.
        String show(MapEntry<String, int> e) => e.key.startsWith('n_')
            ? '${e.key}=${e.value}'
            : '${e.key}=${(e.value / 1000).round()}';
        // ignore: avoid_print
        print('[TextReader] ${_t.entries.map(show).join(' ')}');
      }
    }
  }

  /// `--dart-define=HOMR_OCR_TIMINGS=true` prints [_t] after each read.
  static const _logTimings = bool.fromEnvironment('HOMR_OCR_TIMINGS');

  /// Microseconds spent per stage of the current read, and counts (n_*).
  final _t = <String, int>{};
  T _time<T>(String k, T Function() f) {
    final sw = Stopwatch()..start();
    try {
      return f();
    } finally {
      _t[k] = (_t[k] ?? 0) + sw.elapsedMicroseconds;
    }
  }

  Future<T> _timeAsync<T>(String k, Future<T> Function() f) async {
    final sw = Stopwatch()..start();
    try {
      return await f();
    } finally {
      _t[k] = (_t[k] ?? 0) + sw.elapsedMicroseconds;
    }
  }

  Future<List<OcrLine>> _readText(
    Uint8List image,
    ui.Rect? region,
    bool Function(OcrLine)? accept,
    double sameSizeTolerance,
  ) async {
    // Open both sessions while the page decodes: the three overlap.
    final det = _det ??= _open(models.detector);
    final rec = _rec ??= _open(models.recognizer);
    final page = await _timeAsync('decode', () => _decode(image));
    final r = (region ?? const ui.Rect.fromLTWH(0, 0, 1, 1)).intersect(
      const ui.Rect.fromLTWH(0, 0, 1, 1),
    );
    final x0 = (r.left * page.width).round(),
        y0 = (r.top * page.height).round();
    final x1 = (r.right * page.width).round(),
        y1 = (r.bottom * page.height).round();
    if (r.isEmpty || x1 - x0 < 8 || y1 - y0 < 8) return const [];
    final crop = page.crop(x0, y0, x1 - x0, y1 - y0);

    final lines = groupLines(
      await _detect(await _timeAsync('detOpen', () => det), crop),
    );
    _t['n_lines'] = lines.length;
    final recSession = await _timeAsync('recOpen', () => rec);

    final read = List<OcrLine?>.filled(lines.length, null);
    Future<OcrLine?> readLine(int i) async {
      final words = <CtcResult>[];
      for (final w in lines[i].words) {
        _t['n_rec'] = (_t['n_rec'] ?? 0) + 1;
        words.add(await _recognize(recSession, crop, w));
      }
      final joined = joinWords(words);
      if (joined.text.isEmpty) return null;
      final b = lines[i].box;
      return read[i] = OcrLine(
        joined.text,
        joined.confidence,
        ui.Rect.fromLTRB(
          (x0 + b.left) / page.width,
          (y0 + b.top) / page.height,
          (x0 + b.right) / page.width,
          (y0 + b.bottom) / page.height,
        ),
      );
    }

    if (accept == null) {
      for (var i = 0; i < lines.length; i++) {
        await readLine(i);
      }
    } else {
      await readLargestFirst([for (final l in lines) l.box], (i) async {
        final line = await readLine(i);
        return line != null && accept(line);
      }, sameSizeTolerance: sameSizeTolerance);
    }
    return [for (final l in read) ?l];
  }

  /// Text boxes in [img]'s pixels, rounded and clipped to it.
  Future<List<PixelBox>> _detect(OrtSession session, _Rgba img) async {
    final scale = math.min(1.0, maxDetSide / math.max(img.width, img.height));
    int to32(int n) => math.max(32, (n * scale / 32).round() * 32);
    final dw = to32(img.width), dh = to32(img.height);

    final input = _time(
      'detPrep',
      () => img.toTensor(dw, dh, dw, _detMean, _detStd),
    );
    final x = await _timeAsync(
      'detIn',
      () => OrtValue.fromList(input, [1, 3, dh, dw]),
    );
    final List<double> flat;
    try {
      final out = await _timeAsync('detRun', () => session.run({'x': x}));
      final value = out.values.first;
      try {
        final raw = await _timeAsync('detOut', () => value.asFlattenedList());
        flat = _time('detConv', () => _asDoubles(raw));
      } finally {
        await value.dispose();
      }
    } finally {
      await x.dispose();
    }

    final sx = img.width / dw, sy = img.height / dh;
    final found = _time(
      'detPost',
      () => dbBoxes(Float32List.fromList(flat), dw, dh),
    );
    return [
      for (final b in found)
        PixelBox(
          math.max(0, (b.left * sx).roundToDouble()),
          math.max(0, (b.top * sy).roundToDouble()),
          math.min(img.width.toDouble(), (b.right * sx).roundToDouble()),
          math.min(img.height.toDouble(), (b.bottom * sy).roundToDouble()),
          b.score,
        ),
    ];
  }

  Future<CtcResult> _recognize(
    OrtSession session,
    _Rgba img,
    PixelBox b,
  ) async {
    final line = img.crop(
      b.left.toInt(),
      b.top.toInt(),
      (b.right - b.left).toInt(),
      (b.bottom - b.top).toInt(),
    );
    if (line.width < 1 || line.height < 1) return (text: '', confidence: 0.0);
    final rw = (_recHeight * line.width / line.height).ceil().clamp(
      1,
      _recMaxWidth,
    );
    final pw = math.max(rw, _recMinWidth);
    final input = _time(
      'recPrep',
      () => line.toTensor(rw, _recHeight, pw, _recMean, _recStd),
    );
    final x = await _timeAsync(
      'recIn',
      () => OrtValue.fromList(input, [1, 3, _recHeight, pw]),
    );
    try {
      final out = await _timeAsync('recRun', () => session.run({'x': x}));
      final value = out.values.first;
      try {
        final shape = value.shape; // [1, T, classes]
        final raw = await _timeAsync('recOut', () => value.asFlattenedList());
        final probs = _time('recConv', () => _asDoubles(raw));
        return _time(
          'recCtc',
          () => ctcDecode(probs, shape[1], shape[2], latinCharacters),
        );
      } finally {
        await value.dispose();
      }
    } finally {
      await x.dispose();
    }
  }

  /// Closes both sessions; the next [readText] opens them again.
  Future<void> dispose() async {
    final sessions = [_det, _rec];
    _det = _rec = null;
    for (final s in sessions) {
      if (s == null) continue;
      try {
        await (await s).close();
      } catch (_) {
        // Never opened (the error went to readText): nothing to close.
      }
    }
  }

  /// Starts opening [asset]'s session. Marked handled at once, since
  /// readText may return before awaiting it; awaiting it still throws.
  Future<OrtSession> _open(String asset) =>
      openModelSession(asset, models.resolvePath)..ignore();

  static List<double> _asDoubles(List<dynamic> list) => list is List<double>
      ? list
      : [for (final v in list) (v as num).toDouble()];

  static Future<_Rgba> _decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (data == null) throw StateError('could not read decoded pixels');
        return _Rgba(data.buffer.asUint8List(), image.width, image.height);
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }
}

/// RGBA pixels, row-major, with a view onto a sub-rectangle.
class _Rgba {
  _Rgba(
    this.pixels,
    this.width,
    this.height, {
    this.offsetX = 0,
    this.offsetY = 0,
    int? stride,
  }) : stride = stride ?? width;

  final Uint8List pixels;
  final int width, height, offsetX, offsetY, stride;

  _Rgba crop(int x, int y, int w, int h) {
    final cx = x.clamp(0, width), cy = y.clamp(0, height);
    return _Rgba(
      pixels,
      math.min(w, width - cx),
      math.min(h, height - cy),
      offsetX: offsetX + cx,
      offsetY: offsetY + cy,
      stride: stride,
    );
  }

  /// A `[3, dh, padWidth]` tensor, BGR (as PaddleOCR reads images through
  /// OpenCV): this image resized bilinearly to [dw] × [dh] with OpenCV's
  /// half-pixel convention, then (v/255 − mean)/std per channel. Columns
  /// from [dw] to [padWidth] are left 0.
  Float32List toTensor(
    int dw,
    int dh,
    int padWidth,
    List<double> mean,
    List<double> std,
  ) {
    final out = Float32List(3 * dh * padWidth);
    final plane = dh * padWidth;
    final sx = width / dw, sy = height / dh;

    final xi0 = Int32List(dw), xi1 = Int32List(dw);
    final xf = Float64List(dw);
    for (var x = 0; x < dw; x++) {
      final fx = ((x + 0.5) * sx - 0.5).clamp(0.0, width - 1.0);
      xi0[x] = fx.floor();
      xi1[x] = math.min(xi0[x] + 1, width - 1);
      xf[x] = fx - xi0[x];
    }
    // Per output channel c (B, G, R), its RGBA byte offset.
    const rgbaOffset = [2, 1, 0];
    final scale = [for (var c = 0; c < 3; c++) 1 / (255 * std[c])];
    final shift = [for (var c = 0; c < 3; c++) mean[c] / std[c]];

    for (var y = 0; y < dh; y++) {
      final fy = ((y + 0.5) * sy - 0.5).clamp(0.0, height - 1.0);
      final y0 = fy.floor(), y1 = math.min(y0 + 1, height - 1);
      final wy = fy - y0;
      final row0 = ((offsetY + y0) * stride + offsetX) * 4;
      final row1 = ((offsetY + y1) * stride + offsetX) * 4;
      for (var x = 0; x < dw; x++) {
        final a = xi0[x] * 4, b = xi1[x] * 4, wx = xf[x];
        for (var c = 0; c < 3; c++) {
          final o = rgbaOffset[c];
          final top =
              pixels[row0 + a + o] * (1 - wx) + pixels[row0 + b + o] * wx;
          final bottom =
              pixels[row1 + a + o] * (1 - wx) + pixels[row1 + b + o] * wx;
          final v = top * (1 - wy) + bottom * wy;
          out[c * plane + y * padWidth + x] = v * scale[c] - shift[c];
        }
      }
    }
    return out;
  }
}
