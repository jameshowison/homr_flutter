/// On-device optical music recognition for Flutter: a photo or scan of
/// printed sheet music in, MusicXML 4.0 out. A Dart port of
/// [homr](https://github.com/liebharc/homr), running homr's own ONNX models.
///
/// ```dart
/// final omr = OmrOrchestrator(models: OmrModels.inAssetDir('assets/omr_models'));
/// final musicXml = await omr.recognise(pngOrJpegBytes, title: 'Lightly Row');
/// ```
///
/// The models are not part of this package; see [OmrModels] and the README.
library;

export 'src/inference/omr_models.dart' show OmrModels, AssetPathResolver;
export 'src/omr_orchestrator.dart' show OmrOrchestrator, OmrStage, OmrException;
