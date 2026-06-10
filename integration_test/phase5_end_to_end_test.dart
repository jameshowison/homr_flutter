// End-to-end pipeline test: assets/test_images/happy_farmer_bw_50.png →
// OmrOrchestrator → MusicXML.
//
// The test image is a 2674×1574 1-bit PNG, pre-binarized at 50% threshold.
// It bypasses Phase 2 (capture) and Phase 3 (preprocessing) so the test
// runs on any simulator or device without a camera.
//
// Python reference output (liebharc/homr, same image):
//   Parts:    1
//   Measures: 21
//   Notes:    112
//
// Run on a connected device or simulator:
//   flutter test integration_test/phase5_end_to_end_test.dart
//
// First run will be slower because ONNX sessions are cold. Subsequent runs
// reuse cached sessions within the same process.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xml/xml.dart';

import 'package:homr_omr/homr_omr.dart';

// Python reference counts — used for diagnostic output only, not hard assertions.
const int _refMeasures = 21;
const int _refNotes = 112;

// Hard lower bounds calibrated from actual pipeline output (23 measures, 102 notes
// on iPhone 17 simulator). Set to ~80% of observed to allow hardware variance while
// catching regressions. Accuracy comparison (note-by-note) belongs in Phase 7.
const int _minMeasures = 18;  // 80% of 23 observed
const int _minNotes = 82;     // 80% of 102 observed

// Wall-clock budget for the full pipeline on a cold session (model loading
// included). Target from the plan is <15 s steady-state; first run on a
// mid-range phone may take longer.
const int _timeLimitSeconds = 120;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('end-to-end pipeline produces valid MusicXML from happy_farmer_bw_50',
      (tester) async {
    // ── Load test image from bundled assets ───────────────────────────────────
    final data = await rootBundle.load('assets/test_images/happy_farmer_bw_50.png');
    final pngBytes = data.buffer.asUint8List();

    // ── Run the full pipeline ─────────────────────────────────────────────────
    final stages = <String>[];
    final stopwatch = Stopwatch()..start();

    final musicXml = await OmrOrchestrator().recognise(
      pngBytes,
      onProgress: (stage) {
        final label = stage.name;
        stages.add(label);
        // ignore: avoid_print
        print('  [${stopwatch.elapsedMilliseconds} ms] $label');
      },
    );

    stopwatch.stop();
    final elapsedMs = stopwatch.elapsedMilliseconds;

    // ── Parse output XML ──────────────────────────────────────────────────────
    late XmlDocument doc;
    try {
      doc = XmlDocument.parse(musicXml);
    } catch (e) {
      fail('Output is not valid XML: $e\n\nFirst 500 chars:\n${musicXml.substring(0, musicXml.length.clamp(0, 500))}');
    }

    final measures = doc.findAllElements('measure').length;
    final notes    = doc.findAllElements('note').length;
    final parts    = doc.findAllElements('part').length;

    // ── Diagnostic output ─────────────────────────────────────────────────────
    // ignore: avoid_print
    print('\n=== Phase 5 End-to-End Pipeline ===');
    // ignore: avoid_print
    print('Elapsed: $elapsedMs ms  (limit: ${_timeLimitSeconds * 1000} ms)');
    // ignore: avoid_print
    print('Stages:  ${stages.join(' → ')}');
    // ignore: avoid_print
    print('');
    // ignore: avoid_print
    print('${'Metric'.padRight(12)} ${'Ours'.padLeft(8)} ${'Python ref'.padLeft(10)}');
    // ignore: avoid_print
    print('-' * 32);
    // ignore: avoid_print
    print('${'Parts'.padRight(12)} ${parts.toString().padLeft(8)} ${'1'.padLeft(10)}');
    // ignore: avoid_print
    print('${'Measures'.padRight(12)} ${measures.toString().padLeft(8)} ${_refMeasures.toString().padLeft(10)}');
    // ignore: avoid_print
    print('${'Notes'.padRight(12)} ${notes.toString().padLeft(8)} ${_refNotes.toString().padLeft(10)}');
    // ignore: avoid_print
    print('');

    // ── Assertions ────────────────────────────────────────────────────────────

    expect(
      doc.rootElement.name.local,
      equals('score-partwise'),
      reason: 'Root element must be score-partwise',
    );
    expect(
      doc.rootElement.getAttribute('version'),
      equals('4.0'),
      reason: 'Must be MusicXML 4.0',
    );

    expect(parts, greaterThanOrEqualTo(1),
        reason: 'Must have at least one part');

    expect(
      measures,
      greaterThanOrEqualTo(_minMeasures),
      reason: 'Expected at least $_minMeasures measures; got $measures '
          '(Python ref: $_refMeasures). '
          'Check staff detection — fewer measures suggests missing staves.',
    );

    expect(
      notes,
      greaterThanOrEqualTo(_minNotes),
      reason: 'Expected at least $_minNotes notes; got $notes '
          '(Python ref: $_refNotes). '
          'Check transformer output — too few notes suggests decoding failure.',
    );

    expect(
      elapsedMs,
      lessThanOrEqualTo(_timeLimitSeconds * 1000),
      reason: 'Pipeline exceeded ${_timeLimitSeconds}s wall-clock budget',
    );

    // ignore: avoid_print
    print('All assertions passed.');
    // ignore: avoid_print
    print('Measures: $measures (ref $_refMeasures, ${_pct(measures, _refMeasures)}% of ref)');
    // ignore: avoid_print
    print('Notes:    $notes (ref $_refNotes, ${_pct(notes, _refNotes)}% of ref)');
  });
}

String _pct(int actual, int ref) =>
    ref == 0 ? '—' : (actual * 100 ~/ ref).toString();
