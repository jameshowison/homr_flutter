// ignore_for_file: implementation_imports
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:homr_omr/src/inference/encoded_symbol.dart';
import 'package:homr_omr/src/pipeline/musicxml_assembler.dart';

// Helper: parse MusicXML string and return the document root.
XmlDocument _parse(String xml) => XmlDocument.parse(xml);

// Collect text content from all elements with [name] anywhere in [doc].
List<String> _all(XmlDocument doc, String name) => doc
    .findAllElements(name)
    .map((e) => e.innerText.trim())
    .toList();

void main() {
  group('MusicXmlAssembler', () {
    test('produces a valid score-partwise document', () {
      final voice = [
        const EncodedSymbol(rhythm: 'clef_G2', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
        const EncodedSymbol(rhythm: 'keySignature_0', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
        const EncodedSymbol(rhythm: 'timeSignature/4', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
        const EncodedSymbol(rhythm: 'note_4', pitch: 'C4', lift: '_', articulation: '_', position: 'upper'),
        const EncodedSymbol(rhythm: 'note_4', pitch: 'D4', lift: '_', articulation: '_', position: 'upper'),
        const EncodedSymbol(rhythm: 'note_4', pitch: 'E4', lift: '_', articulation: '_', position: 'upper'),
        const EncodedSymbol(rhythm: 'note_4', pitch: 'F4', lift: '_', articulation: '_', position: 'upper'),
        const EncodedSymbol(rhythm: 'barline', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
      ];

      final xml = MusicXmlAssembler.assemble([voice], title: 'Test');
      final doc = _parse(xml);

      expect(doc.rootElement.name.local, 'score-partwise');
      expect(doc.rootElement.getAttribute('version'), '4.0');
    });

    test('title appears in work-title', () {
      final voice = [
        const EncodedSymbol(rhythm: 'barline', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
      ];
      final xml = MusicXmlAssembler.assemble([voice], title: 'Twinkle');
      final doc = _parse(xml);
      expect(_all(doc, 'work-title').first, 'Twinkle');
    });

    test('note pitch elements are emitted correctly', () {
      final voice = [
        const EncodedSymbol(rhythm: 'note_4', pitch: 'G5', lift: '#', articulation: '_', position: 'upper'),
        const EncodedSymbol(rhythm: 'barline', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
      ];
      final xml = MusicXmlAssembler.assemble([voice]);
      final doc = _parse(xml);

      expect(_all(doc, 'step'), contains('G'));
      expect(_all(doc, 'octave'), contains('5'));
      expect(_all(doc, 'alter'), contains('1')); // sharp
    });

    test('flat accidental emits alter -1', () {
      final voice = [
        const EncodedSymbol(rhythm: 'note_4', pitch: 'B4', lift: 'b', articulation: '_', position: 'upper'),
        const EncodedSymbol(rhythm: 'barline', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
      ];
      final xml = MusicXmlAssembler.assemble([voice]);
      final doc = _parse(xml);
      expect(_all(doc, 'alter'), contains('-1'));
    });

    test('natural lift emits alter 0', () {
      final voice = [
        const EncodedSymbol(rhythm: 'note_4', pitch: 'E4', lift: 'N', articulation: '_', position: 'upper'),
        const EncodedSymbol(rhythm: 'barline', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
      ];
      final xml = MusicXmlAssembler.assemble([voice]);
      final doc = _parse(xml);
      expect(_all(doc, 'alter'), contains('0'));
    });

    test('rest is emitted for pitch . or _', () {
      final voice = [
        const EncodedSymbol(rhythm: 'rest_4', pitch: '_', lift: '.', articulation: '_', position: 'upper'),
        const EncodedSymbol(rhythm: 'barline', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
      ];
      final xml = MusicXmlAssembler.assemble([voice]);
      final doc = _parse(xml);
      expect(doc.findAllElements('rest'), isNotEmpty);
    });

    test('dotted quarter produces a dot element', () {
      final voice = [
        const EncodedSymbol(rhythm: 'note_4.', pitch: 'A4', lift: '_', articulation: '_', position: 'upper'),
        const EncodedSymbol(rhythm: 'rest_8', pitch: '_', lift: '.', articulation: '_', position: 'upper'),
        const EncodedSymbol(rhythm: 'barline', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
      ];
      final xml = MusicXmlAssembler.assemble([voice]);
      final doc = _parse(xml);
      expect(doc.findAllElements('dot'), isNotEmpty);
    });

    test('grace note emits grace element', () {
      final voice = [
        const EncodedSymbol(rhythm: 'note_8G', pitch: 'D5', lift: '_', articulation: '_', position: 'upper'),
        const EncodedSymbol(rhythm: 'note_4', pitch: 'C5', lift: '_', articulation: '_', position: 'upper'),
        const EncodedSymbol(rhythm: 'barline', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
      ];
      final xml = MusicXmlAssembler.assemble([voice]);
      final doc = _parse(xml);
      expect(doc.findAllElements('grace'), isNotEmpty);
    });

    test('barline creates separate measures', () {
      // Two measures of 4/4 with one quarter note each (incomplete, but valid for structure test)
      final voice = [
        const EncodedSymbol(rhythm: 'note_4', pitch: 'C4', lift: '_', articulation: '_', position: 'upper'),
        const EncodedSymbol(rhythm: 'barline', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
        const EncodedSymbol(rhythm: 'note_4', pitch: 'D4', lift: '_', articulation: '_', position: 'upper'),
        const EncodedSymbol(rhythm: 'barline', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
      ];
      final xml = MusicXmlAssembler.assemble([voice]);
      final doc = _parse(xml);
      expect(doc.findAllElements('measure').length, 2);
    });

    test('key signature emits fifths element', () {
      final voice = [
        const EncodedSymbol(rhythm: 'keySignature_2', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
        const EncodedSymbol(rhythm: 'barline', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
      ];
      final xml = MusicXmlAssembler.assemble([voice]);
      final doc = _parse(xml);
      expect(_all(doc, 'fifths'), contains('2'));
    });

    test('clef emits sign and line', () {
      final voice = [
        const EncodedSymbol(rhythm: 'clef_G2', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
        const EncodedSymbol(rhythm: 'barline', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
      ];
      final xml = MusicXmlAssembler.assemble([voice]);
      final doc = _parse(xml);
      expect(_all(doc, 'sign'), contains('G'));
      expect(_all(doc, 'line'), contains('2'));
    });

    test('two staves produce two part elements', () {
      final staff1 = [
        const EncodedSymbol(rhythm: 'note_4', pitch: 'C5', lift: '_', articulation: '_', position: 'upper'),
        const EncodedSymbol(rhythm: 'barline', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
      ];
      final staff2 = [
        const EncodedSymbol(rhythm: 'note_4', pitch: 'G3', lift: '_', articulation: '_', position: 'upper'),
        const EncodedSymbol(rhythm: 'barline', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
      ];
      final xml = MusicXmlAssembler.assemble([staff1, staff2]);
      final doc = _parse(xml);
      expect(doc.findAllElements('part').length, 2);
      expect(doc.findAllElements('score-part').length, 2);
    });

    test('repeat produces repeat direction element', () {
      final voice = [
        const EncodedSymbol(rhythm: 'note_4', pitch: 'C4', lift: '_', articulation: '_', position: 'upper'),
        const EncodedSymbol(rhythm: 'repeatEnd', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
      ];
      final xml = MusicXmlAssembler.assemble([voice]);
      final doc = _parse(xml);
      expect(doc.findAllElements('repeat'), isNotEmpty);
      expect(doc.findAllElements('repeat').first.getAttribute('direction'), 'backward');
    });

    test('redundant clef tokens are deduplicated', () {
      final voice = [
        const EncodedSymbol(rhythm: 'clef_G2', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
        const EncodedSymbol(rhythm: 'note_4', pitch: 'C4', lift: '_', articulation: '_', position: 'upper'),
        const EncodedSymbol(rhythm: 'barline', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
        const EncodedSymbol(rhythm: 'clef_G2', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
        const EncodedSymbol(rhythm: 'note_4', pitch: 'D4', lift: '_', articulation: '_', position: 'upper'),
        const EncodedSymbol(rhythm: 'barline', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
      ];
      final xml = MusicXmlAssembler.assemble([voice]);
      final doc = _parse(xml);
      // Only one clef element should appear (second is duplicate)
      expect(doc.findAllElements('clef').length, 1);
    });

    test('tuplet note emits time-modification', () {
      // note_6 = triplet eighth (6 = 2/3 of a quarter, i.e., 3 in the time of 2)
      final voice = [
        const EncodedSymbol(rhythm: 'note_6', pitch: 'C4', lift: '_', articulation: '_', position: 'upper'),
        const EncodedSymbol(rhythm: 'note_6', pitch: 'D4', lift: '_', articulation: '_', position: 'upper'),
        const EncodedSymbol(rhythm: 'note_6', pitch: 'E4', lift: '_', articulation: '_', position: 'upper'),
        const EncodedSymbol(rhythm: 'barline', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
      ];
      final xml = MusicXmlAssembler.assemble([voice]);
      final doc = _parse(xml);
      expect(doc.findAllElements('time-modification'), isNotEmpty);
      expect(_all(doc, 'actual-notes'), contains('3'));
      expect(_all(doc, 'normal-notes'), contains('2'));
    });
  });
}
