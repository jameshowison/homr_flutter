import 'dart:io';
import 'dart:typed_data';

import 'artifact_writer.dart';

ArtifactWriter createArtifactWriter(String dir) => _IoArtifactWriter(dir);

class _IoArtifactWriter implements ArtifactWriter {
  final String dir;

  _IoArtifactWriter(this.dir) {
    Directory(dir).createSync(recursive: true);
  }

  @override
  void writeBytes(String name, Uint8List bytes) =>
      File('$dir/$name').writeAsBytesSync(bytes);

  @override
  void writeString(String name, String content) =>
      File('$dir/$name').writeAsStringSync(content);
}
