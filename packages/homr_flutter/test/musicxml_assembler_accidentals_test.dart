// ignore_for_file: implementation_imports
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'package:homr_flutter/src/inference/encoded_symbol.dart';
import 'package:homr_flutter/src/pipeline/musicxml_assembler.dart';

EncodedSymbol _sym(String rhythm) => EncodedSymbol(
    rhythm: rhythm, pitch: '.', lift: '.', articulation: '.', position: 'upper');

/// A quarter note; [lift] is the transformer's SOUNDING alteration.
EncodedSymbol _q(String pitch, [String lift = '_', String artic = '_']) =>
    EncodedSymbol(
        rhythm: 'note_4',
        pitch: pitch,
        lift: lift,
        articulation: artic,
        position: 'upper');

/// Each note as `step+alter+octave` followed by its drawn sign, if any.
List<String> _notes(String xml) => [
      for (final n in XmlDocument.parse(xml).findAllElements('note'))
        if (n.findElements('pitch').isNotEmpty)
          () {
            final p = n.findElements('pitch').first;
            final alter = p.findElements('alter').firstOrNull?.innerText ?? '';
            final acc = n.findElements('accidental').firstOrNull?.innerText;
            return '${p.findElements('step').first.innerText}$alter'
                '${p.findElements('octave').first.innerText}'
                '${acc == null ? '' : ' $acc'}';
          }(),
    ];

void main() {
  // G major: the signature's F♯ is sounding but undrawn, so it gets no sign.
  List<EncodedSymbol> gMajor(List<EncodedSymbol> bars) => [
        _sym('clef_G2'),
        _sym('keySignature_1'),
        _sym('timeSignature/4'),
        ...bars,
      ];

  test('a note off the key signature gets its sign drawn; F♯ does not', () {
    final xml = MusicXmlAssembler.assemble([
      gMajor([
        _q('F5', '#'), _q('A4', '#'), _q('B4'), _q('A4', '#'),
        _sym('barline'),
        _q('A4'), _q('A4', '#'), _q('A4'), _q('B4', 'b'),
        _sym('barline'),
      ]),
    ]);
    expect(_notes(xml), [
      // The second A♯ is carried by the first.
      'F15', 'A14 sharp', 'B4', 'A14',
      // A new bar resets it; going back to A♮ needs a natural.
      'A4', 'A14 sharp', 'A4 natural', 'B-14 flat',
    ]);
  });

  test('<alter> sits between <step> and <octave>, as MusicXML requires', () {
    final xml = MusicXmlAssembler.assemble([
      gMajor([_q('A4', '#'), _sym('barline')]),
    ]);
    final pitch = XmlDocument.parse(xml).findAllElements('pitch').first;
    expect([for (final c in pitch.childElements) c.name.local],
        ['step', 'alter', 'octave']);
  });

  test('<accidental> comes after <type> and before <staff>/<notations>', () {
    final xml = MusicXmlAssembler.assemble([
      gMajor([_q('A4', '#'), _sym('barline')]),
    ]);
    final note = XmlDocument.parse(xml).findAllElements('note').first;
    final names = [for (final c in note.childElements) c.name.local];
    expect(names.indexOf('accidental'), greaterThan(names.indexOf('type')));
    for (final later in ['staff', 'notations', 'beam']) {
      if (names.contains(later)) {
        expect(names.indexOf('accidental'), lessThan(names.indexOf(later)));
      }
    }
  });

  test('a note tied over the barline is not re-marked', () {
    final xml = MusicXmlAssembler.assemble([
      gMajor([
        _q('B4'), _q('B4'), _q('B4'), _q('A4', '#', 'tieStart'),
        _sym('barline'),
        _q('A4', '#', 'tieStop'), _q('B4'), _q('B4'), _q('B4'),
        _sym('barline'),
      ]),
    ]);
    expect(_notes(xml).sublist(3, 5), ['A14 sharp', 'A14']);
  });
}
