/// On-device optical music recognition for Flutter: a photo or scan of
/// printed sheet music in, MusicXML 4.0 out. A Dart port of
/// [homr](https://github.com/liebharc/homr), running homr's own ONNX models.
///
/// ```dart
/// final omr = OmrOrchestrator(models: OmrModels.inAssetDir('assets/omr_models'));
/// final musicXml = await omr.recognise(pngOrJpegBytes, title: 'Lightly Row');
/// ```
///
/// [TextReader] reads printed text, such as a piece's title, with
/// PaddleOCR's models.
///
/// The models are not part of this package; see [OmrModels], [OcrModels]
/// and the README.
library;

export 'src/inference/omr_models.dart' show OmrModels, AssetPathResolver;
export 'src/omr_orchestrator.dart' show OmrOrchestrator, OmrStage, OmrException;
export 'src/ocr/ocr_models.dart' show OcrModels;
export 'src/ocr/text_reader.dart' show TextReader, OcrLine;
