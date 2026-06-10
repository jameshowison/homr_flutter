import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

import '../packages/homr_omr/lib/src/pipeline/homr/bounding_boxes.dart';

// Validates the Dart fragment-extraction port against homr's oracle dump.
// Usage: dart run tool/validate_fragments.dart <tag>
//   reads /tmp/oracle_<tag>_staff.png and /tmp/oracle_<tag>.json
void main(List<String> args) {
  final tag = args.isNotEmpty ? args[0] : 'lr2';
  final mask = _loadBinary('/tmp/oracle_${tag}_staff.png');
  final w = mask.$2, h = mask.$3;

  final pre = createRotatedBoundingBoxes(mask.$1, w, h,
      skipMerging: true, minSize: (5, 1), maxSize: (10000, 100));
  final frags = breakWideFragments(pre);

  final fr = jsonDecode(File('/tmp/oracle_${tag}_frags.json').readAsStringSync())
      as Map<String, dynamic>;
  print('[$tag] PRE-break  Dart=${pre.length}  homr=${(fr['pre'] as List).length}');
  _compare(pre, (fr['pre'] as List).cast<Map<String, dynamic>>(), 'pre');
  print('[$tag] POST-break Dart=${frags.length}  homr=${(fr['post'] as List).length}');
  _compare(frags, (fr['post'] as List).cast<Map<String, dynamic>>(), 'post');
  return;
  // ignore: dead_code
  final oracle = jsonDecode(File('/tmp/oracle_$tag.json').readAsStringSync())
      as Map<String, dynamic>;
  final oFrags = (oracle['staff_fragments'] as List).cast<Map<String, dynamic>>();

  print('[$tag] image ${w}x$h');
  print('  Dart fragments:   ${frags.length}');
  print('  homr fragments:   ${oFrags.length}');

  // Greedy nearest-center match to measure box agreement.
  final used = List<bool>.filled(oFrags.length, false);
  final dCenter = <double>[];
  final dW = <double>[];
  final dH = <double>[];
  final dAng = <double>[];
  int matched = 0;
  for (final f in frags) {
    int best = -1;
    double bestD = 1e18;
    for (int i = 0; i < oFrags.length; i++) {
      if (used[i]) continue;
      final o = oFrags[i];
      final dx = f.cx - (o['cx'] as num);
      final dy = f.cy - (o['cy'] as num);
      final d = dx * dx + dy * dy;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    if (best >= 0 && bestD < 25) {
      // within 5px center
      used[best] = true;
      matched++;
      final o = oFrags[best];
      dCenter.add(bestD == 0 ? 0 : _sqrt(bestD));
      dW.add((f.w - (o['w'] as num)).abs().toDouble());
      dH.add((f.h - (o['h'] as num)).abs().toDouble());
      dAng.add((f.angle - (o['angle'] as num)).abs().toDouble());
    }
  }
  print('  matched (≤5px center): $matched / ${oFrags.length}');
  print('  median |Δcenter|=${_med(dCenter).toStringAsFixed(2)}  '
      '|Δw|=${_med(dW).toStringAsFixed(2)}  '
      '|Δh|=${_med(dH).toStringAsFixed(2)}  '
      '|Δangle|=${_med(dAng).toStringAsFixed(2)}°');
  print('  p95 |Δw|=${_pct(dW, 0.95).toStringAsFixed(2)}  '
      '|Δangle|=${_pct(dAng, 0.95).toStringAsFixed(2)}°');
}

void _compare(List<HRotBox> frags, List<Map<String, dynamic>> oFrags, String label) {
  final used = List<bool>.filled(oFrags.length, false);
  final dW = <double>[], dH = <double>[], dAng = <double>[];
  int matched = 0;
  for (final f in frags) {
    int best = -1;
    double bestD = 1e18;
    for (int i = 0; i < oFrags.length; i++) {
      if (used[i]) continue;
      final o = oFrags[i];
      final dx = f.cx - (o['cx'] as num);
      final dy = f.cy - (o['cy'] as num);
      final d = dx * dx + dy * dy;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    if (best >= 0 && bestD < 25) {
      used[best] = true;
      matched++;
      final o = oFrags[best];
      dW.add((f.w - (o['w'] as num)).abs().toDouble());
      dH.add((f.h - (o['h'] as num)).abs().toDouble());
      dAng.add((f.angle - (o['angle'] as num)).abs().toDouble());
    }
  }
  print('  matched (≤5px): $matched / ${oFrags.length}  '
      'median |Δw|=${_med(dW).toStringAsFixed(2)} '
      '|Δh|=${_med(dH).toStringAsFixed(2)} '
      '|Δangle|=${_med(dAng).toStringAsFixed(2)}°  '
      'p95|Δw|=${_pct(dW, 0.95).toStringAsFixed(2)}');
}

(Uint8List, int, int) _loadBinary(String path) {
  final decoded = img.decodeImage(File(path).readAsBytesSync())!;
  final g = decoded.numChannels == 1 ? decoded : img.grayscale(decoded);
  final w = g.width, h = g.height;
  final out = Uint8List(w * h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      out[y * w + x] = g.getPixel(x, y).r > 0 ? 1 : 0;
    }
  }
  return (out, w, h);
}

double _sqrt(double x) => x <= 0 ? 0 : _newton(x);
double _newton(double x) {
  double g = x;
  for (int i = 0; i < 40; i++) {
    g = 0.5 * (g + x / g);
  }
  return g;
}

double _med(List<double> v) {
  if (v.isEmpty) return double.nan;
  final s = [...v]..sort();
  return s[s.length ~/ 2];
}

double _pct(List<double> v, double p) {
  if (v.isEmpty) return double.nan;
  final s = [...v]..sort();
  return s[(s.length * p).clamp(0, s.length - 1).toInt()];
}
