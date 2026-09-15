// ignore_for_file: implementation_imports
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:xml/xml.dart';

import 'package:homr_omr/homr_omr.dart';
import 'package:homr_omr/src/inference/encoded_symbol.dart';
import 'package:homr_omr/src/inference/segmentation_runner.dart';
import 'package:homr_omr/src/inference/transformer_runner.dart';

const _width = 300;
const _height = 200;

/// A SegNet-shaped class-index map (one byte per pixel: 3 = clef, 4 = staff
/// line, 0 = other) containing exactly one clef + 5-line staff, verified via
/// a standalone probe against the real `detectStavesFromClassMap` pipeline
/// (predictions.dart/staff_detection.dart) to yield exactly one [Staff]. The
/// clef is drawn *after* the staff lines so it fully occupies its region
/// (mirrors a real scan, where the clef glyph's ink overlaps/hides the staff
/// lines behind it) — drawing them in the other order leaves the clef mask
/// with holes that `createRotatedBoundingBoxes` fails to size-filter as one
/// component.
Uint8List _syntheticClassMap() {
  final m = Uint8List(_width * _height);
  void setPx(int x, int y, int cls) {
    if (x < 0 || x >= _width || y < 0 || y >= _height) return;
    m[y * _width + x] = cls;
  }

  for (final y in [60, 80, 100, 120, 140]) {
    for (var x = 0; x < _width; x++) {
      setPx(x, y, 4);
    }
  }
  for (var y = 60; y < 140; y++) {
    for (var x = 30; x < 60; x++) {
      setPx(x, y, 3);
    }
  }
  return m;
}

/// A decodable but otherwise-irrelevant PNG standing in for a preprocessed
/// page image — its pixel content is never inspected because segmentation is
/// faked; only its dimensions (matching [_syntheticClassMap]'s) matter.
Uint8List _blankPreprocessedPng() {
  final image = img.Image(width: _width, height: _height);
  return img.encodePng(image);
}

class _FakeSegmentationRunner extends SegmentationRunner {
  final Uint8List classMap;
  _FakeSegmentationRunner(this.classMap);

  @override
  Future<Uint8List> runSegmentation(Uint8List pngBytes) async => classMap;
}

/// Returns one valid single-measure voice per call — clef/key/time, one
/// note, barline — with the note's pitch taken from [notePitches] in call
/// order, so callers can tell pages apart in the assembled output.
class _FakeTransformerRunner extends TransformerRunner {
  final List<String> notePitches;
  int calls = 0;
  _FakeTransformerRunner(this.notePitches);

  @override
  Future<List<EncodedSymbol>> runTransformer(
    Uint8List staffPng, {
    List<String>? liftDebug,
    List<String>? rhythmDebug,
  }) async {
    final pitch = notePitches[calls];
    calls++;
    return [
      const EncodedSymbol(
          rhythm: 'clef_G2', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
      const EncodedSymbol(
          rhythm: 'keySignature_0', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
      const EncodedSymbol(
          rhythm: 'timeSignature/4', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
      EncodedSymbol(
          rhythm: 'note_4', pitch: pitch, lift: '_', articulation: '_', position: 'upper'),
      const EncodedSymbol(
          rhythm: 'barline', pitch: '.', lift: '.', articulation: '.', position: 'upper'),
    ];
  }
}

void main() {
  group('OmrOrchestrator.recogniseMultiPage', () {
    test('concatenates pages in order into one continuous part', () async {
      final classMap = _syntheticClassMap();
      final page = _blankPreprocessedPng();
      final orchestrator = OmrOrchestrator(
        segRunner: _FakeSegmentationRunner(classMap),
        transformerRunner: _FakeTransformerRunner(['C4', 'D4']),
      );

      final xml = await orchestrator.recogniseMultiPage([page, page], title: 'Two Pages');
      final doc = XmlDocument.parse(xml);

      expect(doc.findAllElements('part').length, 1);
      expect(
        doc.findAllElements('note').map((n) => n.findElements('pitch').first.findElements('step').first.innerText),
        ['C', 'D'],
      );
      expect(
        doc.findAllElements('note').map((n) => n.findElements('pitch').first.findElements('octave').first.innerText),
        ['4', '4'],
      );

      // Exactly one system-break should appear (at the page boundary) — a
      // doubled 'newline' between pages would show up as a second one.
      final systemBreaks =
          doc.findAllElements('print').where((e) => e.getAttribute('new-system') == 'yes');
      expect(systemBreaks.length, 1);
    });

    test('reports (pageIndex, stage) in order across pages', () async {
      final classMap = _syntheticClassMap();
      final page = _blankPreprocessedPng();
      final orchestrator = OmrOrchestrator(
        segRunner: _FakeSegmentationRunner(classMap),
        transformerRunner: _FakeTransformerRunner(['C4', 'D4']),
      );

      final calls = <(int, OmrStage)>[];
      await orchestrator.recogniseMultiPage(
        [page, page],
        onProgress: (pageIndex, stage) => calls.add((pageIndex, stage)),
      );

      expect(calls, [
        (0, OmrStage.segmenting),
        (0, OmrStage.detecting),
        (0, OmrStage.recognising),
        (1, OmrStage.segmenting),
        (1, OmrStage.detecting),
        (1, OmrStage.recognising),
        (1, OmrStage.assembling),
      ]);
    });

    test('throws OmrException for an empty page list', () {
      final orchestrator = OmrOrchestrator(
        segRunner: _FakeSegmentationRunner(_syntheticClassMap()),
        transformerRunner: _FakeTransformerRunner(const []),
      );
      expect(orchestrator.recogniseMultiPage([]), throwsA(isA<OmrException>()));
    });
  });

  group('OmrOrchestrator.recognise (single page, post-refactor)', () {
    test('matches recogniseMultiPage([page]) for the same page', () async {
      final classMap = _syntheticClassMap();
      final page = _blankPreprocessedPng();

      final single = await OmrOrchestrator(
        segRunner: _FakeSegmentationRunner(classMap),
        transformerRunner: _FakeTransformerRunner(['E4']),
      ).recognise(page, title: 'Single');

      final multi = await OmrOrchestrator(
        segRunner: _FakeSegmentationRunner(classMap),
        transformerRunner: _FakeTransformerRunner(['E4']),
      ).recogniseMultiPage([page], title: 'Single');

      expect(single, multi);
    });
  });
}
