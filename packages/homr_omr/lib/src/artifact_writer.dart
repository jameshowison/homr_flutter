import 'dart:typed_data';

import 'artifact_writer_stub.dart'
    if (dart.library.io) 'artifact_writer_io.dart' as impl;

/// Sink for the optional debug artifacts [OmrOrchestrator.recognise] writes
/// when `artifactDir` is set.
///
/// Conditionally backed by `dart:io` File/Directory on platforms that support
/// it, and a no-op on web — keeps the package core free of `dart:io` so it
/// stays compilable for a web build (inference itself still requires native
/// ONNX and won't run there).
abstract class ArtifactWriter {
  /// Returns null if [dir] is null; otherwise an [ArtifactWriter] rooted at
  /// [dir] (created recursively if needed, on platforms that support it).
  static ArtifactWriter? maybeCreate(String? dir) =>
      dir == null ? null : impl.createArtifactWriter(dir);

  void writeBytes(String name, Uint8List bytes);

  void writeString(String name, String content);
}
