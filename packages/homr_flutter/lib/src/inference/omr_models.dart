/// Where the three ONNX models live in the APP's asset bundle.
///
/// The package ships no models. They are 140+ MB, far past what belongs in a
/// package, and they are homr's, released separately at [releaseBaseUrl]. The
/// app downloads them once at build time (`tool/fetch_models.py`), declares
/// the folder as an asset, and passes its location here; recognition then
/// needs no network.
///
/// ```dart
/// final omr = OmrOrchestrator(models: OmrModels.inAssetDir('assets/omr_models'));
/// ```
class OmrModels {
  /// Asset key of the segmentation network.
  final String segnet;

  /// Asset key of the transformer encoder.
  final String encoder;

  /// Asset key of the transformer decoder.
  final String decoder;

  const OmrModels({
    required this.segnet,
    required this.encoder,
    required this.decoder,
  });

  /// The canonical filenames under one asset folder (no trailing slash).
  OmrModels.inAssetDir(String dir)
      : segnet = '$dir/$segnetFile',
        encoder = '$dir/$encoderFile',
        decoder = '$dir/$decoderFile';

  /// homr's release that publishes the models, one `<name>.zip` per file.
  static const releaseBaseUrl =
      'https://github.com/liebharc/homr/releases/download/onnx_checkpoints';

  static const segnetFile =
      'segnet_308-3296ccd40960f90ca6ab9c035cca945675d30a0f_fp16.onnx';
  static const encoderFile =
      'encoder_pytorch_model_367-575b4737bca815d3a7b37169269fc548d7e945b9_fp16.onnx';
  static const decoderFile =
      'decoder_pytorch_model_367-575b4737bca815d3a7b37169269fc548d7e945b9_fp16.onnx';

  /// SHA-256 of each unzipped model, for verifying a download. This package
  /// version is tested against exactly these files.
  static const sha256 = {
    segnetFile:
        '60f495496cb41473c0521d0811d8f44b9d5cff892d287974a8aebb3eaee2fa83',
    encoderFile:
        'aa252963c934234d30faca0a2363903f6ec02e81f85f87f12dadad7035ec6495',
    decoderFile:
        '60c037e2eb30a142d746051e5c3aa0aa23445b3563c44673f95b8b1c5102a6aa',
  };
}
