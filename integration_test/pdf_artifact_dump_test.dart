// One-shot artifact dump for PDF scan investigation.
// Writes teaser.png, clahe.png, mask_class4.png, staff_N_*.png to /tmp/homr_pdf_dump_{slug}/
//
// Pencil gate thresholds: song 05 is run at three thresholds (190/170/150) so
// the pencil_gate.png artifacts can be compared visually to find the right cut.
//
// Run with:
//   flutter test integration_test/pdf_artifact_dump_test.dart --name "dump"

import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:image/image.dart' as img;
import 'package:xml/xml.dart';
import 'package:homr_flutter/homr_flutter.dart';
import 'package:homr_flutter_demo/eval/musicxml_scoring.dart';
import 'package:homr_flutter_demo/omr_models.dart';

/// Resize [pngBytes] to [targetWidth] px wide (preserving aspect ratio),
/// matching what ImagePreprocessor does before handing off to the pipeline.
Uint8List _resizeTo(Uint8List pngBytes, int targetWidth) {
  final decoded = img.decodeImage(pngBytes)!;
  if (decoded.width <= targetWidth) return pngBytes;
  final targetHeight = (decoded.height * targetWidth / decoded.width).round();
  final resized = img.copyResize(decoded, width: targetWidth, height: targetHeight);
  return img.encodePng(resized);
}

const _cases = [
  ('01-twinkle',    'assets/test_images/01-twinkle-twinkle-little-star_crop.png'),
  ('06-may-song',   'assets/test_images/06-may-song_crop.png'),
  ('09-perpetual-motion','assets/test_images/09-perpetual-motion_crop.png'),
  ('10-allegretto',     'assets/test_images/10-allegretto_crop.png'),
  ('14-minuet-no-2','assets/test_images/14-minuet-no-2_crop.png'),
  ('15-minuet-no-3',   'assets/test_images/15-minuet-no-3_crop.png'),
  ('17-gavotte',    'assets/test_images/gavotte_notes.png'),
];

// Song 05 at three pencil-gate thresholds for visual comparison.
const _pencilGateCases = [
  (190, '05-o-come-little-children', 'assets/test_images/05-o-come-little-children_crop.png'),
  (170, '05-o-come-little-children', 'assets/test_images/05-o-come-little-children_crop.png'),
  (150, '05-o-come-little-children', 'assets/test_images/05-o-come-little-children_crop.png'),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Standard dump (no pencil gate).
  for (final (slug, imagePath) in _cases) {
    testWidgets('dump: $slug',
        timeout: const Timeout(Duration(seconds: 300)),
        (tester) async {
      final artifactDir = '/tmp/homr_pdf_dump_$slug';
      Directory(artifactDir).createSync(recursive: true);

      final imgData = await rootBundle.load(imagePath);
      try {
        final musicXml = await OmrOrchestrator(models: demoModels).recognise(
          imgData.buffer.asUint8List(),
          artifactDir: artifactDir,
        );
        if (musicXml != null) {
          File('$artifactDir/output.xml').writeAsStringSync(musicXml);
        }
      } catch (e, st) {
        // ignore: avoid_print
        print('[$slug] pipeline error: $e\n$st');
      }

      final files = Directory(artifactDir).listSync()
        ..sort((a, b) => a.path.compareTo(b.path));
      // ignore: avoid_print
      print('\n[$slug] artifacts → $artifactDir');
      for (final f in files) {
        // ignore: avoid_print
        print('  ${f.uri.pathSegments.last}');
      }
    });
  }

  // Direct camera photo of O Come — runs outside rootBundle using dart:io.
  testWidgets('dump: 05-o-come-camera-photo',
      timeout: const Timeout(Duration(seconds: 300)),
      (tester) async {
    const slug = '05-o-come-camera-photo';
    const photoPath =
        '/path/to/violin_practice_companion'
        '/docs/photos_no_share/o_come_photo.png';
    const refAsset = 'assets/ground_truth/05-o-come-little-children.xml';
    final artifactDir = '/tmp/homr_pdf_dump_$slug';
    Directory(artifactDir).createSync(recursive: true);

    final pngBytes = File(photoPath).readAsBytesSync();
    final refXml = await rootBundle.loadString(refAsset);
    final refMeasures = parseMeasures(XmlDocument.parse(refXml));

    String? musicXml;
    try {
      musicXml = await OmrOrchestrator(models: demoModels).recognise(
        pngBytes,
        artifactDir: artifactDir,
      );
      if (musicXml != null) {
        File('$artifactDir/output.xml').writeAsStringSync(musicXml);
      }
    } catch (e, st) {
      // ignore: avoid_print
      print('[$slug] pipeline error: $e\n$st');
    }

    if (musicXml != null) {
      final outDoc = XmlDocument.parse(musicXml);
      final engMeasures = parseMeasures(outDoc);
      final score = scoreMeasures(refMeasures, engMeasures);
      // ignore: avoid_print
      print('\n[$slug] notes=${score.engNotes}/${score.refNotes} '
          'pitch=${(score.pitchPct * 100).toStringAsFixed(1)}% '
          'both=${(score.bothPct * 100).toStringAsFixed(1)}% '
          'SER=${(score.ser * 100).toStringAsFixed(1)}%');
      // ignore: avoid_print
      print(formatReport(score).trimRight());
    }

    // ignore: avoid_print
    print('\n[$slug] artifacts → $artifactDir');
    final files = Directory(artifactDir).listSync()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      // ignore: avoid_print
      print('  ${f.uri.pathSegments.last}');
    }
  });

  // No-pencil version of O Come — compare note count and accuracy vs original photo.
  testWidgets('dump: 05-o-come-no-pencil',
      timeout: const Timeout(Duration(seconds: 300)),
      (tester) async {
    const slug = '05-o-come-no-pencil';
    const photoPath =
        '/path/to/violin_practice_companion'
        '/docs/photos_no_share/o_come_no_pencil.png';
    const refAsset = 'assets/ground_truth/05-o-come-little-children.xml';
    final artifactDir = '/tmp/homr_pdf_dump_$slug';
    Directory(artifactDir).createSync(recursive: true);

    final pngBytes = File(photoPath).readAsBytesSync();
    final refXml = await rootBundle.loadString(refAsset);
    final refMeasures = parseMeasures(XmlDocument.parse(refXml));

    String? musicXml;
    try {
      musicXml = await OmrOrchestrator(models: demoModels).recognise(
        pngBytes,
        artifactDir: artifactDir,
      );
      if (musicXml != null) {
        File('$artifactDir/output.xml').writeAsStringSync(musicXml);
      }
    } catch (e, st) {
      // ignore: avoid_print
      print('[$slug] pipeline error: $e\n$st');
    }

    if (musicXml != null) {
      final outDoc = XmlDocument.parse(musicXml);
      final engMeasures = parseMeasures(outDoc);
      final score = scoreMeasures(refMeasures, engMeasures);
      // ignore: avoid_print
      print('\n[$slug] notes=${score.engNotes}/${score.refNotes} '
          'pitch=${(score.pitchPct * 100).toStringAsFixed(1)}% '
          'both=${(score.bothPct * 100).toStringAsFixed(1)}% '
          'SER=${(score.ser * 100).toStringAsFixed(1)}%');
      // ignore: avoid_print
      print(formatReport(score).trimRight());
    }

    // ignore: avoid_print
    print('\n[$slug] artifacts → $artifactDir');
    final files = Directory(artifactDir).listSync()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      // ignore: avoid_print
      print('  ${f.uri.pathSegments.last}');
    }
  });

  // Island-light photo of O Come (lighter exposure than o_come_photo.png).
  testWidgets('dump: 05-o-come-island-light',
      timeout: const Timeout(Duration(seconds: 300)),
      (tester) async {
    const slug = '05-o-come-island-light';
    const photoPath =
        '/path/to/violin_practice_companion'
        '/docs/photos_no_share/o_come_island_light.png';
    const refAsset = 'assets/ground_truth/05-o-come-little-children.xml';
    final artifactDir = '/tmp/homr_pdf_dump_$slug';
    Directory(artifactDir).createSync(recursive: true);

    final pngBytes = File(photoPath).readAsBytesSync();
    final refXml = await rootBundle.loadString(refAsset);
    final refMeasures = parseMeasures(XmlDocument.parse(refXml));

    String? musicXml;
    try {
      musicXml = await OmrOrchestrator(models: demoModels).recognise(
        pngBytes,
        artifactDir: artifactDir,
      );
      if (musicXml != null) {
        File('$artifactDir/output.xml').writeAsStringSync(musicXml);
      }
    } catch (e, st) {
      // ignore: avoid_print
      print('[$slug] pipeline error: $e\n$st');
    }

    if (musicXml != null) {
      final outDoc = XmlDocument.parse(musicXml);
      final engMeasures = parseMeasures(outDoc);
      final score = scoreMeasures(refMeasures, engMeasures);
      // ignore: avoid_print
      print('\n[$slug] notes=${score.engNotes}/${score.refNotes} '
          'pitch=${(score.pitchPct * 100).toStringAsFixed(1)}% '
          'both=${(score.bothPct * 100).toStringAsFixed(1)}% '
          'SER=${(score.ser * 100).toStringAsFixed(1)}%');
      // ignore: avoid_print
      print(formatReport(score).trimRight());
    }

    // ignore: avoid_print
    print('\n[$slug] artifacts → $artifactDir');
    final files = Directory(artifactDir).listSync()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      // ignore: avoid_print
      print('  ${f.uri.pathSegments.last}');
    }
  });

  // PDF scan of O Come — pre-rendered to PNG with:
  //   qlmanage -t -s 1920 -o /tmp/ 05-o-come-little-children_crop.pdf
  // (Process.runSync is blocked in the iOS simulator sandbox so rendering is
  // done outside the test and the result read back directly.)
  testWidgets('dump: 05-o-come-pdf',
      timeout: const Timeout(Duration(seconds: 300)),
      (tester) async {
    const slug = '05-o-come-pdf';
    // Pre-rendered by running qlmanage on the Mac before the test.
    const pngPath = '/tmp/05-o-come-little-children_crop.pdf.png';
    const refAsset = 'assets/ground_truth/05-o-come-little-children.xml';
    final artifactDir = '/tmp/homr_pdf_dump_$slug';
    Directory(artifactDir).createSync(recursive: true);

    if (!File(pngPath).existsSync()) {
      // ignore: avoid_print
      print('[$slug] SKIP: pre-rendered PNG not found at $pngPath — '
          'run: qlmanage -t -s 1920 -o /tmp/ <pdf>');
      return;
    }

    final pngBytes = File(pngPath).readAsBytesSync();
    final refXml = await rootBundle.loadString(refAsset);
    final refMeasures = parseMeasures(XmlDocument.parse(refXml));

    String? musicXml;
    try {
      musicXml = await OmrOrchestrator(models: demoModels).recognise(
        pngBytes,
        artifactDir: artifactDir,
      );
      if (musicXml != null) {
        File('$artifactDir/output.xml').writeAsStringSync(musicXml);
      }
    } catch (e, st) {
      // ignore: avoid_print
      print('[$slug] pipeline error: $e\n$st');
    }

    if (musicXml != null) {
      final outDoc = XmlDocument.parse(musicXml);
      final engMeasures = parseMeasures(outDoc);
      final score = scoreMeasures(refMeasures, engMeasures);
      // ignore: avoid_print
      print('\n[$slug] notes=${score.engNotes}/${score.refNotes} '
          'pitch=${(score.pitchPct * 100).toStringAsFixed(1)}% '
          'both=${(score.bothPct * 100).toStringAsFixed(1)}% '
          'SER=${(score.ser * 100).toStringAsFixed(1)}%');
      // ignore: avoid_print
      print(formatReport(score).trimRight());
    }

    // ignore: avoid_print
    print('\n[$slug] artifacts → $artifactDir');
    final files = Directory(artifactDir).listSync()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      // ignore: avoid_print
      print('  ${f.uri.pathSegments.last}');
    }
  });

  // Island-light 1-up photo of Gavotte (compare to gavotte_notes.png phone photo, SER=4.2%).
  testWidgets('dump: 17-gavotte-island-light',
      timeout: const Timeout(Duration(seconds: 300)),
      (tester) async {
    const slug = '17-gavotte-island-light';
    const photoPath =
        '/path/to/violin_practice_companion'
        '/docs/photos_no_share/gavotte_1_up_island.png';
    const refAsset = 'assets/ground_truth/17-gavotte.xml';
    final artifactDir = '/tmp/homr_pdf_dump_$slug';
    Directory(artifactDir).createSync(recursive: true);

    // Raw scan is ~7300 px wide; pipeline expects ~1920 px (ImagePreprocessor scale).
    final pngBytes = _resizeTo(File(photoPath).readAsBytesSync(), 1920);
    final refXml = await rootBundle.loadString(refAsset);
    final refMeasures = parseMeasures(XmlDocument.parse(refXml));

    String? musicXml;
    try {
      musicXml = await OmrOrchestrator(models: demoModels).recognise(
        pngBytes,
        artifactDir: artifactDir,
      );
      if (musicXml != null) {
        File('$artifactDir/output.xml').writeAsStringSync(musicXml);
      }
    } catch (e, st) {
      // ignore: avoid_print
      print('[$slug] pipeline error: $e\n$st');
    }

    if (musicXml != null) {
      final outDoc = XmlDocument.parse(musicXml);
      final engMeasures = parseMeasures(outDoc);
      final score = scoreMeasures(refMeasures, engMeasures);
      // ignore: avoid_print
      print('\n[$slug] notes=${score.engNotes}/${score.refNotes} '
          'pitch=${(score.pitchPct * 100).toStringAsFixed(1)}% '
          'both=${(score.bothPct * 100).toStringAsFixed(1)}% '
          'SER=${(score.ser * 100).toStringAsFixed(1)}%');
      // ignore: avoid_print
      print(formatReport(score).trimRight());
    }

    // ignore: avoid_print
    print('\n[$slug] artifacts → $artifactDir');
    final files = Directory(artifactDir).listSync()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      // ignore: avoid_print
      print('  ${f.uri.pathSegments.last}');
    }
  });

  // Island-light 1-up photo of Minuet No. 2 (compare to crop PNG, SER=1.2%).
  testWidgets('dump: 14-minuet-no-2-island-light',
      timeout: const Timeout(Duration(seconds: 300)),
      (tester) async {
    const slug = '14-minuet-no-2-island-light';
    const photoPath =
        '/path/to/violin_practice_companion'
        '/docs/photos_no_share/minuet2_1_up_island.png';
    const refAsset = 'assets/ground_truth/14-minuet-no-2.xml';
    final artifactDir = '/tmp/homr_pdf_dump_$slug';
    Directory(artifactDir).createSync(recursive: true);

    // Raw scan is ~7390 px wide; pipeline expects ~1920 px (ImagePreprocessor scale).
    final pngBytes = _resizeTo(File(photoPath).readAsBytesSync(), 1920);
    final refXml = await rootBundle.loadString(refAsset);
    final refMeasures = parseMeasures(XmlDocument.parse(refXml));

    String? musicXml;
    try {
      musicXml = await OmrOrchestrator(models: demoModels).recognise(
        pngBytes,
        artifactDir: artifactDir,
      );
      if (musicXml != null) {
        File('$artifactDir/output.xml').writeAsStringSync(musicXml);
      }
    } catch (e, st) {
      // ignore: avoid_print
      print('[$slug] pipeline error: $e\n$st');
    }

    if (musicXml != null) {
      final outDoc = XmlDocument.parse(musicXml);
      final engMeasures = parseMeasures(outDoc);
      final score = scoreMeasures(refMeasures, engMeasures);
      // ignore: avoid_print
      print('\n[$slug] notes=${score.engNotes}/${score.refNotes} '
          'pitch=${(score.pitchPct * 100).toStringAsFixed(1)}% '
          'both=${(score.bothPct * 100).toStringAsFixed(1)}% '
          'SER=${(score.ser * 100).toStringAsFixed(1)}%');
      // ignore: avoid_print
      print(formatReport(score).trimRight());
    }

    // ignore: avoid_print
    print('\n[$slug] artifacts → $artifactDir');
    final files = Directory(artifactDir).listSync()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      // ignore: avoid_print
      print('  ${f.uri.pathSegments.last}');
    }
  });

  // Pencil gate sweep on song 05 — compare pencil_gate.png at each threshold.
  for (final (threshold, slug, imagePath) in _pencilGateCases) {
    testWidgets('dump: pencil-gate-$threshold $slug',
        timeout: const Timeout(Duration(seconds: 300)),
        (tester) async {
      final artifactDir = '/tmp/homr_pdf_dump_pencil${threshold}_$slug';
      Directory(artifactDir).createSync(recursive: true);

      final imgData = await rootBundle.load(imagePath);
      try {
        final musicXml = await OmrOrchestrator(models: demoModels).recognise(
          imgData.buffer.asUint8List(),
          artifactDir: artifactDir,
          pencilGateThreshold: threshold,
        );
        if (musicXml != null) {
          File('$artifactDir/output.xml').writeAsStringSync(musicXml);
        }
      } catch (e, st) {
        // ignore: avoid_print
        print('[pencil-$threshold-$slug] pipeline error: $e\n$st');
      }

      // ignore: avoid_print
      print('\n[pencil-$threshold-$slug] artifacts → $artifactDir');
      final files = Directory(artifactDir).listSync()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final f in files) {
        // ignore: avoid_print
        print('  ${f.uri.pathSegments.last}');
      }
    });
  }
}
