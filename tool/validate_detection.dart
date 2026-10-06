import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

import '../packages/homr_flutter/lib/src/pipeline/homr/bounding_boxes.dart';
import '../packages/homr_flutter/lib/src/pipeline/homr/staff_detection.dart';

// Validates the Dart staff detection port end-to-end against homr's oracle.
// Uses homr's own staff/clefs masks as input so any divergence is purely in the
// Dart detection port. Usage: dart run tool/validate_detection.dart <tag>
void main(List<String> args) {
  final tag = args.isNotEmpty ? args[0] : 'lr2';
  final staff = _loadBinary('/tmp/oracle_${tag}_staff.png');
  final clefsMask = _loadBinary('/tmp/oracle_${tag}_clefs.png');
  final w = staff.$2, h = staff.$3;

  var frags = createRotatedBoundingBoxes(staff.$1, w, h,
      skipMerging: true, minSize: (5, 1), maxSize: (10000, 100));
  frags = breakWideFragments(frags);
  final clefs = createRotatedBoundingBoxes(clefsMask.$1, w, h,
      minSize: (20, 40), maxSize: (1000, 1000));

  final staves = detectStaves(staff.$1, w, h, frags, clefs);

  final oracle = jsonDecode(File('/tmp/oracle_$tag.json').readAsStringSync())
      as Map<String, dynamic>;
  final oStaves = (oracle['staves'] as List).cast<Map<String, dynamic>>();

  print('[$tag] ${w}x$h  clefs: ${clefs.length} (homr ${oracle['clefs'].length})  '
      'staves: Dart=${staves.length}  homr=${oStaves.length}');

  // Match staves by min_y, compare grid y at shared x positions.
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
      print('  homr staff @minY=${oMinY.toStringAsFixed(0)}: NO Dart match (closest Δ=${bestD.toStringAsFixed(0)})');
      continue;
    }
    final samples = (o['sample_grid'] as List).cast<Map<String, dynamic>>();
    final devs = <double>[];
    for (final sp in samples) {
      final x = (sp['x'] as num).toDouble();
      final oy = (sp['y'] as List).cast<num>().map((e) => e.toDouble()).toList();
      // nearest Dart grid point by x
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
        devs.add((gp.y[i] - oy[i]).abs());
      }
    }
    devs.sort();
    allDev.addAll(devs);
    final med = devs.isEmpty ? double.nan : devs[devs.length ~/ 2];
    final mx = devs.isEmpty ? double.nan : devs.last;
    print('  homr staff @minY=${oMinY.toStringAsFixed(0)} ↔ Dart @minY=${best.minY.toStringAsFixed(0)}: '
        'lines median|Δy|=${med.toStringAsFixed(2)} max|Δy|=${mx.toStringAsFixed(2)} (${devs.length} samples)');
  }
  allDev.sort();
  if (allDev.isNotEmpty) {
    print('  OVERALL line-position median|Δy|=${allDev[allDev.length ~/ 2].toStringAsFixed(2)}px  '
        'p95=${allDev[(allDev.length * 0.95).toInt()].toStringAsFixed(2)}px  max=${allDev.last.toStringAsFixed(2)}px');
  }
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
