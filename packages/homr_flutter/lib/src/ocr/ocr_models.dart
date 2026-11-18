import '../inference/omr_models.dart';

/// Where the two text-recognition models live in the APP's asset bundle, as
/// [OmrModels] does for the music models.
///
/// They are PaddleOCR's PP-OCRv5 mobile detector and Latin recogniser in
/// RapidOCR's ONNX conversions (Apache-2.0; credit PaddleOCR in the app's
/// licence notices), about 12.7 MB together. The package ships neither:
/// `tool/fetch_models.py --ocr` fetches and verifies them at build time.
///
/// ```dart
/// final reader = TextReader(OcrModels.inAssetDir('assets/ocr_models'));
/// ```
class OcrModels {
  /// Asset key of the text detector.
  final String detector;

  /// Asset key of the Latin text recogniser.
  final String recognizer;

  /// See [OmrModels.resolvePath].
  final AssetPathResolver? resolvePath;

  const OcrModels({
    required this.detector,
    required this.recognizer,
    this.resolvePath,
  });

  /// The canonical filenames under one asset folder (no trailing slash).
  OcrModels.inAssetDir(String dir, {this.resolvePath})
    : detector = '$dir/$detFile',
      recognizer = '$dir/$recFile';

  /// RapidOCR's model repository, a pinned tag; the files are under
  /// `PP-OCRv5/det/` and `PP-OCRv5/rec/`.
  static const releaseBaseUrl =
      'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.10.0/onnx';

  static const detFile = 'ch_PP-OCRv5_det_mobile.onnx';
  static const recFile = 'latin_PP-OCRv5_rec_mobile.onnx';

  /// SHA-256 of each model, for verifying a download. This package version is
  /// tested against exactly these files.
  static const sha256 = {
    detFile: '4d97c44a20d30a81aad087d6a396b08f786c4635742afc391f6621f5c6ae78ae',
    recFile: 'b20bd37c168a570f583afbc8cd7925603890efbcdc000a59e22c269d160b5f5a',
  };
}
