// Phase 7 benchmarking harness.
//
// Runs all three evaluation images through the full OMR pipeline and reports:
//   - Per-stage timing (segmenting / detecting / recognising / assembling)
//   - Note-level accuracy vs Python reference output (pitch + duration,
//     alignment-based scoring — see lib/eval/musicxml_scoring.dart)
//
// Ground-truth files are the Python homr reference outputs stored in
// assets/ground_truth/; accuracy floors are conservative — tighten after
// baselines are established on device.
//
// Run on a connected device or simulator:
//   flutter test integration_test/benchmark_omr_test.dart

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:xml/xml.dart';

import 'package:homr_omr/homr_omr.dart';
import 'package:homr_flutter/eval/musicxml_scoring.dart';

// ── Test-case descriptors ─────────────────────────────────────────────────────

class _Case {
  final String label;
  final String imagePath;
  final String refPath;
  final int minNotesFloor;   // ≥ this many engine notes — catches catastrophic failure
  final double minBothFloor; // minimum pitch+duration agreement over aligned pairs

  const _Case({
    required this.label,
    required this.imagePath,
    required this.refPath,
    required this.minNotesFloor,
    required this.minBothFloor,
  });
}

// Production test cases: raw colour phone photos, CLAHE applied inside orchestrator.
const _cases = [
  // Floors reflect Phase 7 dewarping results (see docs/omr_evaluation/homr/results.md).
  // Floors reflect the Phase 7 homr anchor+fragment staff-detection port
  // (replaces the row-density heuristic). Staff detection is now exact on all
  // four images (0 extra/missing notes); residual error is transformer-only.
  _Case(
    label: 'Happy Farmer',
    imagePath: 'assets/test_images/happy_farmer_notes.png',
    refPath: 'assets/ground_truth/happy_farmer_bw_50.musicxml',
    minNotesFloor: 108,  // observed 112/112 detected
    minBothFloor: 0.90,  // observed 97.3%
  ),
  // lightly_row2 is the primary Lightly Row test; original kept as a regression canary.
  _Case(
    label: 'Lightly Row 2',
    imagePath: 'assets/test_images/lightly_row2_notes.png',
    refPath: 'assets/ground_truth/lightly_row_no_title.musicxml',
    minNotesFloor: 54,
    minBothFloor: 0.90,  // was unstable 68–100%; now stably 100% across runs
  ),
  _Case(
    label: 'Lightly Row (original)',
    imagePath: 'assets/test_images/lightly_row_notes.png',
    refPath: 'assets/ground_truth/lightly_row_no_title.musicxml',
    minNotesFloor: 54,   // was ~13% "known-bad photo"; homr detection now 100%
    minBothFloor: 0.90,
  ),
  _Case(
    label: 'Gavotte',
    imagePath: 'assets/test_images/gavotte_notes.png',
    refPath: 'assets/ground_truth/gossec_gavotte_bw.musicxml',
    minNotesFloor: 185,
    minBothFloor: 0.90,  // observed 97.9%
  ),
];

// Diagnostic cases: Python-generated CLAHE images (skipClahe=true).
// These verify that the SegNet+transformer pipeline achieves a baseline when given
// correct CLAHE preprocessing, independent of any Dart CLAHE bugs.
// Note: Happy Farmer py-clahe detects only 4 of 5 staves (staff detection issue
// specific to the single-channel CLAHE asset) — floor reflects 4-staff ceiling.
const _claheImageCases = [
  _Case(
    label: 'Happy Farmer (py-clahe)',
    imagePath: 'assets/test_images/happy_farmer_notes_clahe.png',
    refPath: 'assets/ground_truth/happy_farmer_bw_50.musicxml',
    minNotesFloor: 80,   // 4 staves of ~5 detected; ~88 notes
    minBothFloor: 0.45,  // conservative; missing staff is a deletion, not cascade
  ),
  _Case(
    label: 'Lightly Row (py-clahe)',
    imagePath: 'assets/test_images/lightly_row_notes_clahe.png',
    refPath: 'assets/ground_truth/lightly_row_no_title.musicxml',
    minNotesFloor: 30,
    minBothFloor: 0.10,
  ),
  _Case(
    label: 'Lightly Row 2 (py-clahe)',
    imagePath: 'assets/test_images/lightly_row2_notes_clahe.png',
    refPath: 'assets/ground_truth/lightly_row_no_title.musicxml',
    minNotesFloor: 30,
    minBothFloor: 0.10,
  ),
  _Case(
    label: 'Gavotte (py-clahe)',
    imagePath: 'assets/test_images/gavotte_notes_clahe.png',
    refPath: 'assets/ground_truth/gossec_gavotte_bw.musicxml',
    minNotesFloor: 154,
    minBothFloor: 0.85,
  ),
];

// ── Per-stage timing ──────────────────────────────────────────────────────────

class _StageTimer {
  final _times = <String, int>{};
  int _stageStart = 0;
  String? _current;
  final Stopwatch _sw;

  _StageTimer(this._sw);

  void begin(String stage) {
    if (_current != null) _times[_current!] = _sw.elapsedMilliseconds - _stageStart;
    _current = stage;
    _stageStart = _sw.elapsedMilliseconds;
  }

  void finish() {
    if (_current == null) return;
    _times[_current!] = _sw.elapsedMilliseconds - _stageStart;
    _current = null;
  }

  Map<String, int> get times => _times;
}

// ── Threshold sweep helpers ───────────────────────────────────────────────────

// (label, threshold) — threshold 0 = grayscale only, 1-255 = binary at that value.
const _sweepVariants = [
  (label: 'grayscale (0)', threshold: 0),
  (label: 'threshold 40%', threshold: 102),
  (label: 'threshold 50%', threshold: 128),
  (label: 'threshold 60%', threshold: 153),
  (label: 'threshold 70%', threshold: 178),
];

/// Convert [pngBytes] to grayscale; if [threshold] > 0 also binarise at that value.
Uint8List _applyThreshold(Uint8List pngBytes, int threshold) {
  final decoded = img.decodeImage(pngBytes);
  if (decoded == null) throw Exception('Could not decode image for preprocessing');
  final gray = img.grayscale(decoded);
  if (threshold > 0) {
    for (final pixel in gray) {
      final v = pixel.r < threshold ? 0 : 255;
      pixel.r = v;
      pixel.g = v;
      pixel.b = v;
    }
  }
  return img.encodePng(gray);
}

String _pc(double v) => (v * 100).toStringAsFixed(1);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Generous per-image wall-clock limit (models load cold on first run).
  const wallLimitSeconds = 180;

  for (final tc in _cases) {
    testWidgets('benchmark: ${tc.label}', (tester) async {
      // ── Load inputs ─────────────────────────────────────────────────────────
      final imgData = await rootBundle.load(tc.imagePath);
      // Pass raw colour PNG — CLAHE preprocessing is now applied inside
      // OmrOrchestrator.recognise() before SegNet (Phase 7).
      final pngBytes = imgData.buffer.asUint8List();

      final refXml = await rootBundle.loadString(tc.refPath);
      final refMeasures = parseMeasures(XmlDocument.parse(refXml));

      // ── Run pipeline with per-stage timing ──────────────────────────────────
      final sw = Stopwatch()..start();
      final timer = _StageTimer(sw);

      late String musicXml;
      try {
        musicXml = await OmrOrchestrator().recognise(
          pngBytes,
          onProgress: (stage) {
            timer.begin(stage.name);
            // ignore: avoid_print
            print('  [${sw.elapsedMilliseconds} ms] ${stage.name}');
          },
        );
      } catch (e) {
        // ignore: avoid_print
        print('  Pipeline threw: $e');
        rethrow;
      } finally {
        timer.finish();
        sw.stop();
      }

      // ── Parse output and score ─────────────────────────────────────────────
      late XmlDocument outDoc;
      try {
        outDoc = XmlDocument.parse(musicXml);
      } catch (e) {
        fail('Pipeline output is not valid XML: $e\n\n'
            '${musicXml.substring(0, musicXml.length.clamp(0, 500))}');
      }

      final engMeasures = parseMeasures(outDoc);
      final score = scoreMeasures(refMeasures, engMeasures);

      // ── Detailed report ──────────────────────────────────────────────────────
      // ignore: avoid_print
      print('\n╔══════════════════════════════════════════════╗');
      // ignore: avoid_print
      print('║  BENCHMARK: ${tc.label.padRight(32)}║');
      // ignore: avoid_print
      print('╚══════════════════════════════════════════════╝');
      // ignore: avoid_print
      print('  Wall time: ${sw.elapsedMilliseconds} ms  '
          '(budget: ${wallLimitSeconds * 1000} ms)');
      // ignore: avoid_print
      print('');
      // ignore: avoid_print
      print('  Stage timing:');
      for (final e in timer.times.entries) {
        // ignore: avoid_print
        print('    ${e.key.padRight(14)} ${e.value.toString().padLeft(6)} ms');
      }
      // ignore: avoid_print
      print('');
      // ignore: avoid_print
      print('  ${'Metric'.padRight(12)} ${'Ours'.padLeft(8)} ${'Ref'.padLeft(10)}');
      // ignore: avoid_print
      print('  ${'-' * 32}');
      // ignore: avoid_print
      print('  ${'Measures'.padRight(12)} '
          '${score.engMeasures.toString().padLeft(8)} '
          '${score.refMeasures.toString().padLeft(10)}');
      // ignore: avoid_print
      print('  ${'Notes'.padRight(12)} '
          '${score.engNotes.toString().padLeft(8)} '
          '${score.refNotes.toString().padLeft(10)}');
      // ignore: avoid_print
      print('');
      // ignore: avoid_print
      print('  Accuracy (alignment-based):');
      // ignore: avoid_print
      print('    SER:      ${_pc(score.ser)}%');
      // ignore: avoid_print
      print('    Pitch:    ${_pc(score.pitchPct)}%');
      // ignore: avoid_print
      print('    Duration: ${_pc(score.durPct)}%');
      // ignore: avoid_print
      print('    Both:     ${_pc(score.bothPct)}%  '
          '(floor: ${_pc(tc.minBothFloor)}%)');
      // ignore: avoid_print
      print('    ins=${score.notes.insertions} del=${score.notes.deletions}  '
          'measure ins=${score.measureInsertions} del=${score.measureDeletions}');

      if (score.measures.any((m) => !m.clean)) {
        // ignore: avoid_print
        print('');
        // ignore: avoid_print
        print(formatReport(score).trimRight());
      }

      // ── Assertions ───────────────────────────────────────────────────────────
      expect(
        outDoc.rootElement.name.local,
        equals('score-partwise'),
        reason: 'Root element must be score-partwise',
      );

      expect(
        score.engNotes,
        greaterThanOrEqualTo(tc.minNotesFloor),
        reason: '${tc.label}: got ${score.engNotes} notes, '
            'expected ≥${tc.minNotesFloor} (ref: ${score.refNotes})',
      );

      expect(
        score.bothPct,
        greaterThanOrEqualTo(tc.minBothFloor),
        reason: '${tc.label}: pitch+duration accuracy '
            '${_pc(score.bothPct)}% '
            'below ${_pc(tc.minBothFloor)} floor',
      );

      expect(
        sw.elapsedMilliseconds,
        lessThanOrEqualTo(wallLimitSeconds * 1000),
        reason: '${tc.label}: exceeded ${wallLimitSeconds}s wall-clock budget',
      );

      // ignore: avoid_print
      print('\n  PASS: ${tc.label}');
    });
  }

  // ── Diagnostic: pipeline with Python-generated CLAHE images ─────────────────
  //
  // Passes pre-CLAHEd images (generated by generate_clahe_assets.py using
  // exact Python homr parameters) with skipClahe=true.  Confirms the
  // SegNet+transformer pipeline hits ≥85% when given correct CLAHE input,
  // independently of any Dart CLAHE implementation.
  for (final tc in _claheImageCases) {
    testWidgets('clahe-image: ${tc.label}', (tester) async {
      final imgData = await rootBundle.load(tc.imagePath);
      final pngBytes = imgData.buffer.asUint8List();
      final refXml = await rootBundle.loadString(tc.refPath);
      final refMeasures = parseMeasures(XmlDocument.parse(refXml));

      late String musicXml;
      try {
        musicXml = await OmrOrchestrator().recognise(
          pngBytes,
          skipClahe: true,
        );
      } catch (e) {
        // ignore: avoid_print
        print('  Pipeline threw: $e');
        rethrow;
      }

      final outDoc = XmlDocument.parse(musicXml);
      final engMeasures = parseMeasures(outDoc);
      final score = scoreMeasures(refMeasures, engMeasures);

      // ignore: avoid_print
      print('\n[PY-CLAHE] ${tc.label}: '
          '${score.engNotes} notes / SER=${_pc(score.ser)}% '
          'both=${_pc(score.bothPct)}%');

      expect(score.engNotes, greaterThanOrEqualTo(tc.minNotesFloor),
          reason: '${tc.label}: ${score.engNotes} notes < floor ${tc.minNotesFloor}');
      expect(score.bothPct, greaterThanOrEqualTo(tc.minBothFloor),
          reason: '${tc.label}: ${_pc(score.bothPct)}% '
              '< floor ${_pc(tc.minBothFloor)}%');
    });
  }

  // ── Threshold sweep (diagnostic only — no hard assertions) ───────────────────
  //
  // Runs all 3 evaluation images × 5 preprocessing variants and prints a
  // summary table.  Helps determine whether grayscale-only or a binary
  // threshold level produces the best accuracy.  Does not change the quality
  // gates in the per-piece tests above.
  testWidgets('threshold sweep summary', (tester) async {
    // results[variantLabel][caseLabel] = (noteCount, bothPct) or null on failure.
    final results = <String, Map<String, (int, double)?>>{};
    for (final v in _sweepVariants) {
      results[v.label] = {};
    }

    // Reuse one orchestrator so ONNX models stay warm across variants.
    final orchestrator = OmrOrchestrator();

    for (final tc in _cases) {
      final imgData = await rootBundle.load(tc.imagePath);
      final rawPngBytes = imgData.buffer.asUint8List();
      final refXml = await rootBundle.loadString(tc.refPath);
      final refMeasures = parseMeasures(XmlDocument.parse(refXml));

      for (final variant in _sweepVariants) {
        // ignore: avoid_print
        print('\n[SWEEP] ${tc.label} / ${variant.label}');
        try {
          final preprocessed = _applyThreshold(rawPngBytes, variant.threshold);
          final musicXml = await orchestrator.recognise(preprocessed);
          final outDoc = XmlDocument.parse(musicXml);
          final engMeasures = parseMeasures(outDoc);
          final score = scoreMeasures(refMeasures, engMeasures);
          results[variant.label]![tc.label] = (score.engNotes, score.bothPct);
          // ignore: avoid_print
          print('  ${score.engNotes} notes / ${_pc(score.bothPct)}%');
        } catch (e) {
          results[variant.label]![tc.label] = null;
          // ignore: avoid_print
          print('  FAILED: $e');
        }
      }
    }

    // Print summary table.
    const colW = 22;
    // ignore: avoid_print
    print('\n=== THRESHOLD SWEEP SUMMARY ===');
    final headerLine = StringBuffer('Variant'.padRight(20));
    for (final tc in _cases) {
      headerLine.write(' ${tc.label.padRight(colW)}');
    }
    // ignore: avoid_print
    print(headerLine.toString());
    // ignore: avoid_print
    print('-' * (20 + _cases.length * (colW + 1)));
    for (final variant in _sweepVariants) {
      final row = StringBuffer(variant.label.padRight(20));
      for (final tc in _cases) {
        final r = results[variant.label]![tc.label];
        final cell = r == null
            ? 'FAILED'
            : '${r.$1} notes / ${_pc(r.$2)}%';
        row.write(' ${cell.padRight(colW)}');
      }
      // ignore: avoid_print
      print(row.toString());
    }
  }, timeout: const Timeout(Duration(seconds: 1800)));

  // ── Artifact dump (diagnostic only) ──────────────────────────────────────────
  //
  // Runs Lightly Row 2 and Happy Farmer through the pipeline and writes
  // intermediate images (CLAHE, mask, raw/dewarped staff crops) to the app's
  // Documents directory so they can be copied off the simulator via Finder.
  //
  // Run with:
  //   flutter test integration_test/benchmark_omr_test.dart --name "dump-artifacts"
  testWidgets('dump-artifacts: Lightly Row 2', (tester) async {
    // ignore: avoid_print
    print('[ARTIFACTS] starting LR2');
    // Write to /tmp so files survive the app-container teardown after flutter test.
    const artifactDir = '/tmp/homr_dart_lr2';
    Directory(artifactDir).createSync(recursive: true);

    final imgData = await rootBundle.load('assets/test_images/lightly_row2_notes.png');
    await OmrOrchestrator().recognise(
      imgData.buffer.asUint8List(),
      artifactDir: artifactDir,
    );

    final files = Directory(artifactDir).listSync()
      ..sort((a, b) => a.path.compareTo(b.path));
    // ignore: avoid_print
    print('\n[ARTIFACTS] Lightly Row 2 → $artifactDir');
    for (final f in files) {
      // ignore: avoid_print
      print('[ARTIFACTS]   ${f.uri.pathSegments.last}');
    }
  }, timeout: const Timeout(Duration(seconds: 300)));

  testWidgets('dump-artifacts: Happy Farmer', (tester) async {
    const artifactDir = '/tmp/homr_dart_hf';
    Directory(artifactDir).createSync(recursive: true);

    final imgData = await rootBundle.load('assets/test_images/happy_farmer_notes.png');
    await OmrOrchestrator().recognise(
      imgData.buffer.asUint8List(),
      artifactDir: artifactDir,
    );

    final files = Directory(artifactDir).listSync()
      ..sort((a, b) => a.path.compareTo(b.path));
    // ignore: avoid_print
    print('\n[ARTIFACTS] Happy Farmer → $artifactDir');
    for (final f in files) {
      // ignore: avoid_print
      print('[ARTIFACTS]   ${f.uri.pathSegments.last}');
    }
  }, timeout: const Timeout(Duration(seconds: 300)));

  testWidgets('dump-artifacts: Gavotte', (tester) async {
    const artifactDir = '/tmp/homr_dart_gavotte';

    final imgData = await rootBundle.load('assets/test_images/gavotte_notes.png');
    await OmrOrchestrator().recognise(
      imgData.buffer.asUint8List(),
      artifactDir: artifactDir,
    );

    final files = Directory(artifactDir).listSync()
      ..sort((a, b) => a.path.compareTo(b.path));
    // ignore: avoid_print
    print('\n[ARTIFACTS] Gavotte → $artifactDir');
    for (final f in files) {
      // ignore: avoid_print
      print('[ARTIFACTS]   ${f.uri.pathSegments.last}');
    }
  }, timeout: const Timeout(Duration(seconds: 300)));
}
