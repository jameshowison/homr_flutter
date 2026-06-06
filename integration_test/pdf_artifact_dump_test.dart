// One-shot artifact dump for PDF scan investigation.
// Writes teaser.png, clahe.png, mask_class4.png, staff_N_*.png to /tmp/homr_pdf_dump_{slug}/
// Run with:
//   flutter test integration_test/pdf_artifact_dump_test.dart --name "dump"

import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:homr_flutter/omr_orchestrator.dart';

const _cases = [
  ('01-twinkle',    'assets/test_images/01-twinkle-twinkle-little-star_crop.png'),
  ('06-may-song',   'assets/test_images/06-may-song_crop.png'),
  ('14-minuet-no-2','assets/test_images/14-minuet-no-2_crop.png'),
  ('09-perpetual-motion','assets/test_images/09-perpetual-motion_crop.png'),
  ('10-allegretto',     'assets/test_images/10-allegretto_crop.png'),
  ('15-minuet-no-3',   'assets/test_images/15-minuet-no-3_crop.png'),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final (slug, imagePath) in _cases) {
    testWidgets('dump: $slug',
        timeout: const Timeout(Duration(seconds: 300)),
        (tester) async {
      final artifactDir = '/tmp/homr_pdf_dump_$slug';
      Directory(artifactDir).createSync(recursive: true);

      final imgData = await rootBundle.load(imagePath);
      try {
        final musicXml = await OmrOrchestrator().recognise(
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
}
