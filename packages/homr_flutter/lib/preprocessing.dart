/// Image helpers around recognition: resize-and-binarize previews and Otsu
/// thresholding.
///
/// **Experimental**, and not needed for recognition: `OmrOrchestrator`
/// resizes and contrast-adjusts its input itself, and recognises colour
/// crops best. These exist for previews and for comparing preprocessing
/// strategies, and may change or move between 0.x versions.
library;

export 'src/capture/image_preprocessor.dart'
    show preprocessImage, PreprocessResult, thresholdImage, ThresholdResult, otsuThreshold;
