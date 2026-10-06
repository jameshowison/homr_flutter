/// On-device OMR (optical music recognition) pipeline: a preprocessed PNG of
/// printed sheet music in, a MusicXML 4.0 string out.
library;

export 'src/omr_orchestrator.dart' show OmrOrchestrator, OmrStage, OmrException;
export 'src/capture/image_preprocessor.dart' show preprocessImage, PreprocessResult, thresholdImage, ThresholdResult, otsuThreshold;
