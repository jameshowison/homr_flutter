import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:homr_flutter/eval/musicxml_scoring.dart';

// ── Minimal MusicXML builders ────────────────────────────────────────────────

String _note(String step, int octave, {int? alter, String type = 'quarter', int dots = 0}) {
  final alterEl = alter != null ? '<alter>$alter</alter>' : '';
  final dotEls = '<dot/>' * dots;
  return '<note><pitch><step>$step</step>$alterEl<octave>$octave</octave></pitch>'
      '<type>$type</type>$dotEls</note>';
}

String _rest({String type = 'quarter'}) =>
    '<note><rest/><type>$type</type></note>';

String _attrs({int fifths = 0, String time = '4/4', String clef = 'G2'}) {
  final beats = time.split('/');
  return '<attributes>'
      '<key><fifths>$fifths</fifths></key>'
      '<time><beats>${beats[0]}</beats><beat-type>${beats[1]}</beat-type></time>'
      '<clef><sign>${clef[0]}</sign><line>${clef.substring(1)}</line></clef>'
      '</attributes>';
}

/// Builds a one-part document from a list of measures, each a list of note
/// XML fragments. [attrsPerMeasure] supplies the `<attributes>` for each measure
/// (null = none).
XmlDocument _doc(List<List<String>> measures, {List<String?>? attrsPerMeasure}) {
  final buf = StringBuffer('<score-partwise><part id="P1">');
  for (int i = 0; i < measures.length; i++) {
    buf.write('<measure number="${i + 1}">');
    final a = attrsPerMeasure != null && i < attrsPerMeasure.length
        ? attrsPerMeasure[i]
        : (i == 0 ? _attrs() : null);
    if (a != null) buf.write(a);
    for (final n in measures[i]) {
      buf.write(n);
    }
    buf.write('</measure>');
  }
  buf.write('</part></score-partwise>');
  return XmlDocument.parse(buf.toString());
}

void main() {
  group('parsing & effective alter', () {
    test('key signature applies to bare notes (key-implied fallback)', () {
      // 1 sharp: a bare F should resolve to effective alter +1.
      final m = parseMeasures(_doc([
        [_note('F', 4), _note('C', 4)]
      ], attrsPerMeasure: [_attrs(fifths: 1)]));
      expect(m.single.notes[0].effectiveAlter, 1); // F -> F#
      expect(m.single.notes[1].effectiveAlter, 0); // C unaffected by 1 sharp
    });

    test('explicit accidental overrides and persists within the measure', () {
      // C#4 explicit, then bare C4 same measure -> persists; new measure resets.
      final m = parseMeasures(_doc([
        [_note('C', 4, alter: 1), _note('C', 4)],
        [_note('C', 4)],
      ], attrsPerMeasure: [_attrs(fifths: 0), null]));
      expect(m[0].notes[0].effectiveAlter, 1);
      expect(m[0].notes[1].effectiveAlter, 1); // persisted in measure 1
      expect(m[1].notes[0].effectiveAlter, 0); // reset after barline
    });
  });

  group('alignment localizes errors (no cascade)', () {
    test('one inserted note in measure 2 stays in measure 2', () {
      final ref = _doc([
        [_note('C', 4), _note('D', 4)],
        [_note('E', 4), _note('F', 4)],
        [_note('G', 4), _note('A', 4)],
      ]);
      // engine: extra note inserted in measure 2; measures 1 and 3 identical.
      final eng = _doc([
        [_note('C', 4), _note('D', 4)],
        [_note('E', 4), _note('B', 4), _note('F', 4)],
        [_note('G', 4), _note('A', 4)],
      ]);
      final s = scoreDocuments(ref, eng);

      expect(s.notes.insertions, 1);
      expect(s.notes.deletions, 0);
      // Positional comparison would tank measure 3; alignment keeps it clean.
      final byRef = {for (final d in s.measures) d.refIndex: d};
      expect(byRef[0]!.clean, isTrue);
      expect(byRef[2]!.clean, isTrue);
      expect(byRef[1]!.noteInsertions, 1);
      // All real notes still matched at 100% pitch.
      expect(s.pitchPct, 1.0);
    });

    test('a dropped barline is one measure-level edit', () {
      final ref = _doc([
        [_note('C', 4), _note('D', 4)],
        [_note('E', 4), _note('F', 4)],
      ]);
      // engine merged the two measures into one (missing barline).
      final eng = _doc([
        [_note('C', 4), _note('D', 4), _note('E', 4), _note('F', 4)],
      ]);
      final s = scoreDocuments(ref, eng);
      expect(s.refMeasures, 2);
      expect(s.engMeasures, 1);
      // One measure is unmatched; its notes are accounted, not cascaded.
      expect(s.measureDeletions + s.measureInsertions, greaterThanOrEqualTo(1));
    });
  });

  group('context scored separately from notes', () {
    test('key-sig mismatch shows in key% but notes still match', () {
      // Same sounding notes (explicit F#), different fifths.
      final ref = _doc([
        [_note('F', 4, alter: 1), _note('G', 4)]
      ], attrsPerMeasure: [_attrs(fifths: 1)]);
      final eng = _doc([
        [_note('F', 4, alter: 1), _note('G', 4)]
      ], attrsPerMeasure: [_attrs(fifths: 0)]);
      final s = scoreDocuments(ref, eng);
      expect(s.pitchPct, 1.0); // effective pitch identical
      expect(s.keyPct, 0.0); // but key signature disagrees
      expect(s.measures.single.keyOk, isFalse);
    });

    test('accidental glyph tracked even when effective pitch matches', () {
      // ref draws the sharp; engine relies on the key signature (no glyph).
      final ref = _doc([
        [_note('F', 4, alter: 1)]
      ], attrsPerMeasure: [_attrs(fifths: 1)]);
      final eng = _doc([
        [_note('F', 4)]
      ], attrsPerMeasure: [_attrs(fifths: 1)]);
      final s = scoreDocuments(ref, eng);
      expect(s.pitchPct, 1.0); // both resolve to F#
      expect(s.notes.accidentalConsidered, 1);
      expect(s.notes.accidentalOk, 0); // glyph drawn on one side only
    });
  });

  group('identical documents', () {
    test('perfect score, clean measures, SER 0', () {
      final d = _doc([
        [_note('C', 4), _note('D', 4, type: 'eighth')],
        [_rest(), _note('E', 4, alter: -1, dots: 1, type: 'half')],
      ]);
      // Parse twice to two independent docs.
      final s = scoreDocuments(d, XmlDocument.parse(d.toXmlString()));
      expect(s.ser, 0.0);
      expect(s.pitchPct, 1.0);
      expect(s.durPct, 1.0);
      expect(s.bothPct, 1.0);
      expect(s.measures.every((m) => m.clean), isTrue);
    });
  });

  group('duration distinguishes dots', () {
    test('dotted half vs plain half is a duration error, pitch still ok', () {
      final ref = _doc([
        [_note('A', 4, type: 'half', dots: 1)]
      ]);
      final eng = _doc([
        [_note('A', 4, type: 'half', dots: 0)]
      ]);
      final s = scoreDocuments(ref, eng);
      expect(s.pitchPct, 1.0);
      expect(s.durPct, 0.0);
      expect(s.bothPct, 0.0);
    });
  });
}
