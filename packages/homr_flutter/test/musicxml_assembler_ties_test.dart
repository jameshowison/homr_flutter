// ignore_for_file: implementation_imports
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'package:homr_flutter/src/inference/encoded_symbol.dart';
import 'package:homr_flutter/src/pipeline/musicxml_assembler.dart';

EncodedSymbol _sym(String rhythm) => EncodedSymbol(
    rhythm: rhythm, pitch: '.', lift: '.', articulation: '.', position: 'upper');

EncodedSymbol _q(String pitch, {String lift = '_', String artic = '_'}) =>
    EncodedSymbol(
        rhythm: 'note_4',
        pitch: pitch,
        lift: lift,
        articulation: artic,
        position: 'upper');

EncodedSymbol _rest() => EncodedSymbol(
    rhythm: 'rest_4', pitch: '_', lift: '_', articulation: '_', position: 'upper');

String _assemble(List<EncodedSymbol> bars, {String key = 'keySignature_0'}) =>
    MusicXmlAssembler.assemble([
      [_sym('clef_G2'), _sym(key), _sym('timeSignature/4'), ...bars],
    ]);

/// Each pitched note as `tie:<types>` / `slur:<types>`, empty when neither.
List<String> _marks(String xml) => [
      for (final n in XmlDocument.parse(xml).findAllElements('note'))
        if (n.findElements('pitch').isNotEmpty)
          [
            if (n.findElements('tie').isNotEmpty)
              'tie:${n.findElements('tie').map((t) => t.getAttribute('type')).join(',')}',
            if (n.findAllElements('tied').isNotEmpty)
              'tied:${n.findAllElements('tied').map((t) => t.getAttribute('type')).join(',')}',
            if (n.findAllElements('slur').isNotEmpty)
              'slur:${n.findAllElements('slur').map((t) => t.getAttribute('type')).join(',')}',
          ].join(' '),
    ];

void main() {
  test('a slur to the same pitch across a barline is a tie', () {
    final xml = _assemble([
      _q('C4'), _q('D4'), _q('E4'), _q('G4', artic: 'slurStart'),
      _sym('barline'),
      _q('G4', artic: 'slurStop'), _q('A4'), _q('B4'), _q('C5'),
      _sym('barline'),
    ]);
    expect(_marks(xml), [
      '', '', '', 'tie:start tied:start',
      'tie:stop tied:stop', '', '', '',
    ]);
  });

  test('a chain of three: the middle note is stopped, then started', () {
    final xml = _assemble([
      _q('G4'), _q('G4'), _q('G4'), _q('G4', artic: 'slurStart'),
      _sym('barline'),
      _q('G4', artic: 'slurStart_slurStop'), _q('G4', artic: 'slurStop'),
      _q('B4'), _q('C5'),
      _sym('barline'),
    ]);
    // The token says start before stop; the stop is matched first, so the
    // sounding <tie>s read stop, then start.
    expect(_marks(xml).sublist(3, 6), [
      'tie:start tied:start',
      'tie:stop,start tied:start,stop',
      'tie:stop tied:stop',
    ]);
  });

  test('portato, a new pitch, a rest between and a longer slur stay slurs', () {
    final xml = _assemble([
      _q('D4', artic: 'slurStart_tenuto'), _q('D4', artic: 'slurStop_tenuto'),
      _q('D4', artic: 'slurStart'), _q('E4', artic: 'slurStop'),
      _sym('barline'),
      _q('D4', artic: 'slurStart'), _rest(), _q('D4', artic: 'slurStop'),
      _q('F4', lift: '#', artic: 'slurStart'),
      _sym('barline'),
      _q('F4', artic: 'slurStop'), _q('D4', artic: 'slurStart'), _q('E4'),
      _q('D4', artic: 'slurStop'),
      _sym('barline'),
    ]);
    expect(_marks(xml).where((m) => m.contains('tie')), isEmpty);
  });

  test('a sharp tied over the barline is drawn once', () {
    final xml = _assemble([
      _q('C5'), _q('C5'), _q('C5'), _q('A4', lift: '#', artic: 'slurStart'),
      _sym('barline'),
      _q('A4', lift: '#', artic: 'slurStop'), _q('B4'), _q('C5'), _q('C5'),
      _sym('barline'),
    ]);
    expect(XmlDocument.parse(xml).findAllElements('accidental').length, 1);
  });
}
