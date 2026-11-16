// ignore_for_file: implementation_imports
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'package:homr_flutter/src/inference/encoded_symbol.dart';
import 'package:homr_flutter/src/pipeline/musicxml_assembler.dart';

EncodedSymbol _sym(String rhythm) => EncodedSymbol(
    rhythm: rhythm, pitch: '.', lift: '.', articulation: '.', position: 'upper');

EncodedSymbol _q() => EncodedSymbol(
    rhythm: 'note_4', pitch: 'A4', lift: '_', articulation: '_', position: 'upper');

/// [n] bars of [beats] quarter notes each, every one closed by a barline.
List<EncodedSymbol> _bars(int n, int beats) => [
      for (var i = 0; i < n; i++) ...[
        for (var b = 0; b < beats; b++) _q(),
        _sym('barline'),
      ],
    ];

String _assemble(List<EncodedSymbol> body) => MusicXmlAssembler.assemble([
      [_sym('clef_G2'), _sym('keySignature_0'), ...body],
    ]);

/// Each `<time>` as `measure:beats/beat-type`.
List<String> _times(String xml) => [
      for (final m in XmlDocument.parse(xml).findAllElements('measure'))
        for (final t in m.findAllElements('time'))
          '${m.getAttribute('number')}:'
              '${t.getElement('beats')!.innerText}/${t.getElement('beat-type')!.innerText}',
    ];

void main() {
  test('a printed change of meter is kept, each with its own top digit', () {
    final xml = _assemble([
      _sym('timeSignature/4'), ..._bars(4, 3),
      _sym('timeSignature/4'), ..._bars(4, 4),
    ]);
    expect(_times(xml), ['1:3/4', '5:4/4']);
  });

  test('equal halves of 3/4 and 4/4 never make 7/4', () {
    // The whole-piece median of these bars is 7/8 of a whole note.
    final xml = _assemble([_sym('timeSignature/4'), ..._bars(2, 3), ..._bars(2, 4)]);
    expect(_times(xml), ['1:7/8']);
  });

  test('a time signature over rests alone is common time, not the next one', () {
    // 4/4 rests, then 3/4: the 3/4 must stay where it was printed.
    final xml = _assemble([
      _sym('timeSignature/4'), _sym('rest_5m'), _sym('barline'),
      _sym('timeSignature/4'), ..._bars(3, 3),
    ]);
    expect(_times(xml), ['1:4/4', '6:3/4']); // after five bars of rest
  });

  test('a lone time signature over rests and music measures the music', () {
    final xml = _assemble([
      _sym('timeSignature/4'), _sym('rest_2m'), _sym('barline'), ..._bars(3, 3),
    ]);
    expect(_times(xml), ['1:3/4']);
  });

  test('a restatement with no note between is collapsed', () {
    final xml = _assemble([
      _sym('timeSignature/4'), _sym('timeSignature/4'), ..._bars(3, 4),
    ]);
    expect(_times(xml), ['1:4/4']);
  });

  test('a time signature in the middle of a bar is a mis-fire', () {
    final xml = _assemble([
      _sym('timeSignature/4'), ..._bars(2, 4),
      _q(), _q(), _sym('timeSignature/4'), _q(), _q(), _sym('barline'),
      ..._bars(2, 4),
    ]);
    expect(_times(xml), ['1:4/4']);
  });

  test('a multi-measure rest is written as that many bars of rest', () {
    final xml = _assemble([
      _sym('timeSignature/4'), _sym('rest_3m'), _sym('barline'), ..._bars(2, 3),
    ]);
    final doc = XmlDocument.parse(xml);
    expect(doc.findAllElements('multiple-rest'), isEmpty);
    final measures = doc.findAllElements('measure').toList();
    expect(measures, hasLength(5));
    final divisions = int.parse(doc.findAllElements('divisions').first.innerText);
    for (final m in measures.take(3)) {
      final notes = m.findElements('note').toList();
      expect(notes, hasLength(1));
      expect(notes.single.getElement('rest')!.getAttribute('measure'), 'yes');
      expect(int.parse(notes.single.getElement('duration')!.innerText),
          3 * divisions); // a full 3/4 bar
    }
    expect(measures[3].findElements('note'), hasLength(3));
    expect(_times(xml), ['1:3/4']);
  });
}
