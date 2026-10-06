// Which binarization should the app apply before recognition, if any?
//
// Compares, per image: raw colour (what benchmark_omr_test feeds since Phase 7)
// and Otsu's per-image threshold (thresholdImage), each as given and resized to
// 1920 px wide as Python homr's resize.py does. (A fixed 128 was dropped after
// it found no staves at all on the Mountains page.) Prompted by "I Love the Mountains" (Oct 2026): a photo
// whose print comes out grey, where the fixed 128 erased every staff line.
//
// Extra images outside the asset bundle are read from absolute paths via
// DEV_OMR_EXTRA, a ';'-separated list of `label=path[=refAssetPath]` — the
// simulator can read the Mac's filesystem. Without a ref, only note and
// measure counts are reported.
//
//   flutter test integration_test/threshold_strategy_test.dart -d dev-ipad \
//     --dart-define=DEV_OMR_EXTRA='Mountains=/abs/crop.png'

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:xml/xml.dart';

import 'package:homr_flutter/homr_flutter.dart';
import 'package:homr_flutter/preprocessing.dart';
import 'package:homr_flutter_demo/eval/musicxml_scoring.dart';
import 'package:homr_flutter_demo/omr_models.dart';

const _bundled = [
  ('Happy Farmer', 'assets/test_images/happy_farmer_notes.png',
      'assets/ground_truth/happy_farmer_bw_50.musicxml'),
  ('Lightly Row 2', 'assets/test_images/lightly_row2_notes.png',
      'assets/ground_truth/lightly_row_no_title.musicxml'),
  ('Lightly Row', 'assets/test_images/lightly_row_notes.png',
      'assets/ground_truth/lightly_row_no_title.musicxml'),
  ('Gavotte', 'assets/test_images/gavotte_notes.png',
      'assets/ground_truth/gossec_gavotte_bw.musicxml'),
];

/// What Python homr's resize.py does before anything else: exactly 1920 px
/// wide, up or down, aspect preserved.
Uint8List _to1920(Uint8List png) {
  final im = img.decodeImage(png)!;
  if (im.width == 1920) return png;
  return img.encodePng(img.copyResize(im, width: 1920));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('threshold strategy comparison', (tester) async {
    final cases = <(String, Uint8List, String?)>[];
    for (final (label, path, ref) in _bundled) {
      cases.add((label, (await rootBundle.load(path)).buffer.asUint8List(),
          await rootBundle.loadString(ref)));
    }
    const extra = String.fromEnvironment('DEV_OMR_EXTRA');
    for (final spec in extra.split(';').where((s) => s.isNotEmpty)) {
      final parts = spec.split('=');
      cases.add((
        parts[0],
        File(parts[1]).readAsBytesSync(),
        parts.length > 2 ? await rootBundle.loadString(parts[2]) : null,
      ));
    }

    final orchestrator = OmrOrchestrator(models: demoModels);
    final rows = <String>[];
    for (final (label, raw, refXml) in cases) {
      final raw1920 = _to1920(raw);
      final otsu = await thresholdImage(raw);
      final otsu1920 = await thresholdImage(raw1920);
      final width = img.decodeImage(raw)!.width;
      final variants = {
        'raw @$width': raw,
        'raw @1920': raw1920,
        'otsu @$width': otsu.png,
        'otsu @1920': otsu1920.png,
      };
      for (final MapEntry(key: name, value: input) in variants.entries) {
        String cell;
        try {
          final xml = await orchestrator.recognise(input);
          final eng = parseMeasures(XmlDocument.parse(xml));
          final notes = eng.fold<int>(0, (n, m) => n + m.notes.length);
          if (refXml != null) {
            final s = scoreMeasures(
                parseMeasures(XmlDocument.parse(refXml)), eng);
            cell = '${s.engNotes} notes, ${(s.bothPct * 100).toStringAsFixed(1)}%';
          } else {
            cell = '${eng.length} measures, $notes notes';
          }
        } catch (e) {
          cell = 'FAILED: ${'$e'.split('\n').first}';
        }
        final row = '${label.padRight(18)} ${name.padRight(12)} $cell';
        rows.add(row);
        // ignore: avoid_print
        print('[STRATEGY] $row');
      }
    }
    // ignore: avoid_print
    print('\n=== THRESHOLD STRATEGY SUMMARY ===\n${rows.join('\n')}');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
