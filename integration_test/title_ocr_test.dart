// End-to-end check of TextReader on a title rendered here, never a scan.
//
// Needs PaddleOCR's models in assets/ocr_models (gitignored):
//   python3 packages/homr_flutter/tool/fetch_models.py assets/ocr_models --ocr
// Without them the test is skipped.
//
//   flutter test integration_test/title_ocr_test.dart -d <device>

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:homr_flutter/homr_flutter.dart';
import 'package:homr_flutter_demo/omr_models.dart';

const _w = 1600, _h = 500;

/// A page top: a big centred title, a translated subtitle, a composer
/// right-aligned, and five staff lines below. Black on off-white.
Future<Uint8List> _renderPage() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, _w * 1.0, _h * 1.0),
      Paint()..color = const Color(0xFFF7F4EE));

  void text(String s, double size, Offset at, {TextAlign align = TextAlign.left,
      FontWeight weight = FontWeight.normal}) {
    final p = TextPainter(
      text: TextSpan(
          text: s,
          style: TextStyle(
              fontSize: size, color: const Color(0xFF111111), fontWeight: weight)),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = switch (align) {
      TextAlign.center => at.dx - p.width / 2,
      TextAlign.right => at.dx - p.width,
      _ => at.dx,
    };
    p.paint(canvas, Offset(dx, at.dy));
  }

  text('Lightly Row', 72, const Offset(_w / 2, 40),
      align: TextAlign.center, weight: FontWeight.bold);
  text('Hanschen klein', 32, const Offset(_w / 2, 140), align: TextAlign.center);
  text('Folk Song', 30, const Offset(_w - 80, 220), align: TextAlign.right);
  final line = Paint()
    ..color = const Color(0xFF111111)
    ..strokeWidth = 2;
  for (var i = 0; i < 5; i++) {
    final y = 330.0 + i * 20;
    canvas.drawLine(Offset(80, y), Offset(_w - 80.0, y), line);
  }

  final image = await recorder.endRecording().toImage(_w, _h);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return png!.buffer.asUint8List();
}

Future<bool> _haveModels() async {
  try {
    await rootBundle.load(demoOcrModels.detector);
    await rootBundle.load(demoOcrModels.recognizer);
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('reads a rendered title, subtitle and composer', (tester) async {
    await tester.runAsync(() async {
      if (!await _haveModels()) {
        markTestSkipped('no OCR models in assets/ocr_models');
        return;
      }
      final page = await _renderPage();
      final reader = TextReader(demoOcrModels);
      try {
        final sw = Stopwatch()..start();
        final lines = await reader.readText(page);
        final first = sw.elapsedMilliseconds;
        sw.reset();
        // The title strip only: the composer's line is outside it.
        final top = await reader.readText(page,
            region: const Rect.fromLTWH(0.2, 0, 0.6, 0.4));
        debugPrint('[ocr] whole page ${first}ms (incl. load), '
            'strip ${sw.elapsedMilliseconds}ms');
        for (final l in lines) {
          debugPrint('[ocr] $l');
        }

        final texts = [for (final l in lines) l.text];
        expect(texts, containsAllInOrder(['Lightly Row', 'Hanschen klein', 'Folk Song']));

        final title = lines.firstWhere((l) => l.text == 'Lightly Row');
        expect(title.confidence, greaterThan(0.9));
        // Around where it was drawn: centred, in the top fifth.
        expect(title.box.center.dx, closeTo(0.5, 0.05));
        expect(title.box.top, lessThan(0.15));
        expect(title.box.bottom, lessThan(0.35));

        expect([for (final l in top) l.text], ['Lightly Row', 'Hanschen klein']);
        // Boxes stay in whole-image coordinates when a region is given.
        final again = top.first.box;
        expect(again.left, closeTo(title.box.left, 0.01));
        expect(again.top, closeTo(title.box.top, 0.01));
      } finally {
        await reader.dispose();
      }
    });
  });
}
