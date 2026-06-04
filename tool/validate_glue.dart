import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

import '../lib/pipeline/homr/predictions.dart';
import '../lib/pipeline/homr/staff_detection.dart';

// Validates detectStavesFromClassMap (noise filter + make_lines_stronger +
// fragment/clef extraction + detection) from homr's RAW class map against the
// oracle staves. Usage: dart run tool/validate_glue.dart <tag>
void main(List<String> args) {
  final tag = args.isNotEmpty ? args[0] : 'lr2';
  final cm = _loadClassMap('/tmp/oracle_${tag}_classmap.png');
  final staves = detectStavesFromClassMap(cm.$1, cm.$2, cm.$3);

  final oracle = jsonDecode(File('/tmp/oracle_$tag.json').readAsStringSync())
      as Map<String, dynamic>;
  final oStaves = (oracle['staves'] as List).cast<Map<String, dynamic>>();
  print('[$tag] glue: Dart staves=${staves.length}  homr=${oStaves.length}');

  final allDev = <double>[];
  for (final o in oStaves) {
    final oMinY = (o['min_y'] as num).toDouble();
    Staff? best;
    double bestD = 1e18;
    for (final s in staves) {
      final d = (s.minY - oMinY).abs();
      if (d < bestD) {
        bestD = d;
        best = s;
      }
    }
    if (best == null || bestD > 40) {
      print('  homr staff @${oMinY.toStringAsFixed(0)}: NO match (Δ=${bestD.toStringAsFixed(0)})');
      continue;
    }
    for (final sp in (o['sample_grid'] as List).cast<Map<String, dynamic>>()) {
      final x = (sp['x'] as num).toDouble();
      final oy = (sp['y'] as List).cast<num>().map((e) => e.toDouble()).toList();
      StaffPoint? gp;
      double gd = 1e18;
      for (final p in best.grid) {
        final d = (p.x - x).abs();
        if (d < gd) {
          gd = d;
          gp = p;
        }
      }
      if (gp == null || gd > 15) continue;
      for (int i = 0; i < 5 && i < oy.length && i < gp.y.length; i++) {
        allDev.add((gp.y[i] - oy[i]).abs());
      }
    }
  }
  allDev.sort();
  if (allDev.isNotEmpty) {
    print('  line-position median|Δy|=${allDev[allDev.length ~/ 2].toStringAsFixed(2)}px  '
        'p95=${allDev[(allDev.length * 0.95).toInt()].toStringAsFixed(2)}px  '
        'max=${allDev.last.toStringAsFixed(2)}px');
  }
}

(Uint8List, int, int) _loadClassMap(String path) {
  final decoded = img.decodeImage(File(path).readAsBytesSync())!;
  final g = decoded.numChannels == 1 ? decoded : img.grayscale(decoded);
  final w = g.width, h = g.height;
  final out = Uint8List(w * h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      out[y * w + x] = g.getPixel(x, y).r.toInt();
    }
  }
  return (out, w, h);
}
