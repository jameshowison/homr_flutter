import 'dart:typed_data';

import 'artifact_writer.dart';

ArtifactWriter createArtifactWriter(String dir) => _NoopArtifactWriter();

class _NoopArtifactWriter implements ArtifactWriter {
  @override
  void writeBytes(String name, Uint8List bytes) {}

  @override
  void writeString(String name, String content) {}
}
