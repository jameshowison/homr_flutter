# homr_flutter

On-device optical music recognition (OMR) for Flutter. You give it a photo or scan of printed sheet music, and it gives back MusicXML 4.0, with no server and no network at runtime.

It's a Dart port of [homr](https://github.com/liebharc/homr) by Christian Liebhardt, and runs homr's own ONNX models through [`flutter_onnxruntime`](https://pub.dev/packages/flutter_onnxruntime). The pipeline follows homr's: resize to 1920 px wide, then contrast adjustment (CLAHE), segmentation, staff detection, a transformer read of each staff, and MusicXML assembly. Each stage has been checked against the Python original.

> **Status: 0.x.** The API may change between minor versions until 1.0. It has been verified on iOS (devices and simulator). Android and macOS are what `flutter_onnxruntime` supports, but haven't been tried.

## Setup

The package **does not ship the models**. They are about 140 MB, and they're homr's, published as release assets of the homr repository. Your app bundles them as its own assets. You fetch them once, at build time:

```bash
# from your app's root; downloads from homr's release and verifies SHA-256
python3 <path-to>/homr_flutter/tool/fetch_models.py assets/omr_models
# or copy from a folder you already have (offline):
python3 <path-to>/homr_flutter/tool/fetch_models.py assets/omr_models --from <dir>
```

Declare the folder in your app's `pubspec.yaml`, and gitignore the `.onnx` files:

```yaml
flutter:
  assets:
    - assets/omr_models/
```

## Usage

```dart
import 'package:homr_flutter/homr_flutter.dart';

final omr = OmrOrchestrator(models: OmrModels.inAssetDir('assets/omr_models'));

// PNG or JPEG bytes of the music, ideally cropped to the staves.
final musicXml = await omr.recognise(imageBytes, title: 'Lightly Row');

// Several pages, read as one continuous piece:
final whole = await omr.recogniseMultiPage([page1, page2], title: 'Gavotte');
```

Some notes on input:

- **Crop to the music, in colour.** Don't binarize first: the orchestrator does its own resizing and contrast adjustment, and a fixed threshold can erase faint staff lines.
- **Any size is fine.** Every input is resized to exactly 1920 px wide, as homr does. A crop with more pixels than that holds up better than one that has to be upscaled.
- `onProgress` reports each `OmrStage` as recognition moves through segmentation, staff detection, recognition and assembly.
- It throws `OmrException` if it can't find any staves, or can't read any symbols.

`package:homr_flutter/preprocessing.dart` holds image helpers for previews and experiments (resizing, Otsu thresholding). They're experimental, and recognition doesn't need them.

## Accuracy

On the four benchmark photos in this repository (`integration_test/benchmark_omr_test.dart`), pitch and duration agree with homr's Python output on 97.3–100% of notes. It reads one voice per staff. Staves are read in order and joined into a single part.

## Licence

AGPL-3.0-or-later, the same as homr, which this package ports. The models belong to the homr project and are distributed under its terms.
