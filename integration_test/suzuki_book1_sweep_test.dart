// Suzuki Violin Book 1 cross-branch sweep — data collection only, no pass/fail.
//
// Ground truth: abc2xml MusicXML from abc-music/suzuki-violin-book-1/ (treble clef).
// Photos: _crop.png exports from violin_practice_companion/docs/photos_no_share/.
//   Photos include song titles (not cropped away).
//   Songs 02/16/17 also have existing no-title phone photos as comparison rows.
// Excluded: 12-etude (a/b variation is ambiguous as a single ground truth).
//
// Scoring uses hierarchical measure-then-note alignment (lib/eval/musicxml_scoring.dart,
// see docs/omr_evaluation/scoring_approach.md), NOT positional comparison — so a
// single dropped/extra note no longer cascades into a wrongly-low score, and each
// case prints exactly which measures diverged.
//
// Each result is printed as a TSV row prefixed with RESULT; grep for '^RESULT' to
// extract data.
//
// Run on a connected device:
//   flutter test integration_test/suzuki_book1_sweep_test.dart
//
// Per-case budget: 600 s.  Timeouts are captured (timed_out=true) without failing.
// Wall time > 180 s is flagged with ⚠ in console but does not cause failure.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:integration_test/integration_test.dart';

import 'package:homr_flutter/omr_orchestrator.dart';
import 'package:homr_flutter/eval/musicxml_scoring.dart';

// ── Song cases ────────────────────────────────────────────────────────────────
//
// Sources:
//   Crop PNGs → assets/test_images/{nn}-{slug}_crop.png  (include title)
//   Existing phone photos → happy_farmer_notes.png, lightly_row*_notes.png, gavotte_notes.png
//
// 02-lightly-row, 16-happy-farmer, 17-gavotte each have both a crop-PNG row and
// an existing phone-photo row so we can compare photo quality effects.

class _Case {
  final String label;
  final String imagePath;
  final String refPath;

  const _Case(this.label, this.imagePath, this.refPath);
}

const _cases = [
  _Case('01-twinkle',
      'assets/test_images/01-twinkle-twinkle-little-star_crop.png',
      'assets/ground_truth/01-twinkle-twinkle-little-star.xml'),
  _Case('02-lightly-row (crop)',
      'assets/test_images/02-lightly-row_crop.png',
      'assets/ground_truth/02-lightly-row.xml'),
  // Existing phone photos of Lightly Row (no-title crops, better quality baseline).
  _Case('02-lightly-row (phone2)',
      'assets/test_images/lightly_row2_notes.png',
      'assets/ground_truth/02-lightly-row.xml'),
  _Case('02-lightly-row (phone-orig)',
      'assets/test_images/lightly_row_notes.png',
      'assets/ground_truth/02-lightly-row.xml'),
  _Case('03-song-of-the-wind',
      'assets/test_images/03-song-of-the-wind_crop.png',
      'assets/ground_truth/03-song-of-the-wind.xml'),
  _Case('04-go-tell-aunt-rhody',
      'assets/test_images/04-go-tell-aunt-rhody_crop.png',
      'assets/ground_truth/04-go-tell-aunt-rhody.xml'),
  _Case('05-o-come-little-children',
      'assets/test_images/05-o-come-little-children_crop.png',
      'assets/ground_truth/05-o-come-little-children.xml'),
  _Case('06-may-song',
      'assets/test_images/06-may-song_crop.png',
      'assets/ground_truth/06-may-song.xml'),
  _Case('07-long-long-ago',
      'assets/test_images/07-long-long-ago_crop.png',
      'assets/ground_truth/07-long-long-ago.xml'),
  _Case('08-allegro',
      'assets/test_images/08-allegro_crop.png',
      'assets/ground_truth/08-allegro.xml'),
  _Case('09-perpetual-motion',
      'assets/test_images/09-perpetual-motion_crop.png',
      'assets/ground_truth/09-perpetual-motion.xml'),
  _Case('10-allegretto',
      'assets/test_images/10-allegretto_crop.png',
      'assets/ground_truth/10-allegretto.xml'),
  _Case('11-andantino',
      'assets/test_images/11-andantino_crop.png',
      'assets/ground_truth/11-andantino.xml'),
  // 12-etude held out (a/b variation — ambiguous single ground truth).
  _Case('13-minuet-no-1',
      'assets/test_images/13-minuet-no-1_crop.png',
      'assets/ground_truth/13-minuet-no-1.xml'),
  _Case('14-minuet-no-2',
      'assets/test_images/14-minuet-no-2_crop.png',
      'assets/ground_truth/14-minuet-no-2.xml'),
  _Case('15-minuet-no-3',
      'assets/test_images/15-minuet-no-3_crop.png',
      'assets/ground_truth/15-minuet-no-3.xml'),
  // 16 and 17: existing phone photos (no-title crops).
  _Case('16-happy-farmer (phone)',
      'assets/test_images/happy_farmer_notes.png',
      'assets/ground_truth/16-the-happy-farmer.xml'),
  _Case('17-gavotte (phone)',
      'assets/test_images/gavotte_notes.png',
      'assets/ground_truth/17-gavotte.xml'),
];

String _pc(double v) => (v * 100).toStringAsFixed(1);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // TSV header — grep for lines starting with RESULT to extract data.
  // ignore: avoid_print
  print('RESULT\tlabel\tnotes_out\tnotes_ref\tser\tpitch_pct\tdur_pct\tboth_pct'
      '\tins\tdel\tkey_pct\ttotal_ms\ttimed_out');

  for (final tc in _cases) {
    testWidgets('sweep: ${tc.label}',
        timeout: const Timeout(Duration(seconds: 700)),
        (tester) async {
      // ignore: avoid_print
      print('  [${tc.label}] starting (${_cases.indexOf(tc) + 1}/${_cases.length})');

      // ── Load image (skip gracefully if asset missing) ───────────────────────
      Uint8List pngBytes;
      try {
        final imgData = await rootBundle.load(tc.imagePath);
        pngBytes = imgData.buffer.asUint8List();
      } catch (_) {
        // ignore: avoid_print
        print('RESULT\t${tc.label}\tSKIP\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-');
        return;
      }

      // ── Load + parse reference XML ─────────────────────────────────────────
      final refXml = await rootBundle.loadString(tc.refPath);
      final refMeasures = parseMeasures(XmlDocument.parse(refXml));
      final refNoteCount =
          refMeasures.fold<int>(0, (s, m) => s + m.notes.length);

      // ── Run pipeline with per-case timeout ─────────────────────────────────
      final sw = Stopwatch()..start();
      bool timedOut = false;
      String? musicXml;

      try {
        musicXml = await OmrOrchestrator()
            .recognise(pngBytes)
            .timeout(const Duration(seconds: 600));
      } on TimeoutException {
        timedOut = true;
      } catch (e) {
        // ignore: avoid_print
        print('  [${tc.label}] pipeline error: $e');
      } finally {
        sw.stop();
      }

      final totalMs = sw.elapsedMilliseconds;
      final slowFlag = totalMs > 180000 ? ' ⚠ slow' : '';

      if (timedOut || musicXml == null) {
        // ignore: avoid_print
        print('RESULT\t${tc.label}\t0\t$refNoteCount\t1.0\t0.0\t0.0\t0.0'
            '\t0\t$refNoteCount\t0.0\t$totalMs\ttrue');
        // ignore: avoid_print
        print('  [${tc.label}] timed out or failed after $totalMs ms');
        return;
      }

      // ── Parse and score ────────────────────────────────────────────────────
      XmlDocument outDoc;
      try {
        outDoc = XmlDocument.parse(musicXml);
      } catch (e) {
        // ignore: avoid_print
        print('RESULT\t${tc.label}\t0\t$refNoteCount\t1.0\t0.0\t0.0\t0.0'
            '\t0\t$refNoteCount\t0.0\t$totalMs\tfalse');
        // ignore: avoid_print
        print('  [${tc.label}] invalid XML output: $e');
        return;
      }

      final engMeasures = parseMeasures(outDoc);
      final score = scoreMeasures(refMeasures, engMeasures);

      // ignore: avoid_print
      print('RESULT\t${tc.label}\t${score.engNotes}\t${score.refNotes}'
          '\t${_pc(score.ser)}\t${_pc(score.pitchPct)}\t${_pc(score.durPct)}'
          '\t${_pc(score.bothPct)}\t${score.notes.insertions}'
          '\t${score.notes.deletions}\t${_pc(score.keyPct)}\t$totalMs\tfalse');
      // ignore: avoid_print
      print('  [${tc.label}] out=${score.engNotes} ref=${score.refNotes}'
          '  SER=${_pc(score.ser)}%  pitch=${_pc(score.pitchPct)}%'
          '  dur=${_pc(score.durPct)}%  both=${_pc(score.bothPct)}%'
          '  ${totalMs}ms$slowFlag');
      // Per-measure drill-down (only printed when something diverged).
      if (score.measures.any((m) => !m.clean)) {
        // ignore: avoid_print
        print(formatReport(score).trimRight());
      }
    });
  }
}
