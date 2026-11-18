# Open title OCR: handoff for homr_flutter

**Goal.** Replace closed Google ML Kit text recognition on Android with open
code and open models. If a side-by-side comparison with Vision supports it, do
the same on iOS. The background and the decision are in `docs/plan.md`
("Android goes cleanly GPL"). The full plan is in
`~/.claude/plans/we-need-to-explore-twinkling-ripple.md`.

**Step 1 happens in the homr_flutter repo** (`../homr_flutter`, package
`packages/homr_flutter`). It needs its own session there, because an app
worktree session can't run git in that repo. That checkout also has someone
else's uncommitted `ios/Podfile.lock` and `project.pbxproj` changes; work on a
branch and leave those alone.

## Engine: PaddleOCR PP-OCRv5 mobile, ONNX (RapidOCR's conversions)

| File | Size | SHA-256 |
|---|---|---|
| `ch_PP-OCRv5_det_mobile.onnx` (detector, multilingual) | 4,819,576 B | `4d97c44a20d30a81aad087d6a396b08f786c4635742afc391f6621f5c6ae78ae` |
| `latin_PP-OCRv5_rec_mobile.onnx` (recogniser, Latin) | 7,904,513 B | `b20bd37c168a570f583afbc8cd7925603890efbcdc000a59e22c269d160b5f5a` |
| `en_PP-OCRv5_rec_mobile.onnx` (alternative: English only) | 7,872,351 B | `c3461add59bb4323ecba96a492ab75e06dda42467c9e3d0c18db5d1d21924be8` |

URL base: `https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.10.0/onnx/PP-OCRv5/{det,rec}/<file>`
(from RapidOCR's `python/rapidocr/default_models.yaml`. The hashes above were
re-verified on download on 2026-11-18.)

**Licence:** Apache-2.0 for the models (PaddleOCR repo, and the ModelScope
`RapidAI/RapidOCR` model repo states "Apache License 2.0") and for the
converter (RapidOCR). It is GPL-3.0-compatible, needs an attribution notice,
and adds no new native code: it runs on the `flutter_onnxruntime` already in
the package. (RapidOCR has no `MODEL_LICENSES.md`, whatever some summaries say.)

**Size:** about 12.7 MB added (det + Latin rec). On Android, removing ML Kit
saves roughly 4 MB per architecture. Target: no more than +15 MB per platform.
If it goes over, try an int8-quantised recogniser.

## Model I/O (inspected with `onnx`)

- **Detector** `x: float32 [N,3,H,W]` → `[N,1,H,W]` probability map.
  - Before: resize so H and W are multiples of 32 (longest side ≤ 960; a
    title strip is small anyway). Convert BGR or RGB to float, take /255,
    then mean `0.485,0.456,0.406` and std `0.229,0.224,0.225`.
  - After (DB):
    1. Binarise at 0.3 and take connected components.
    2. Drop a box when its mean probability is below 0.6.
    3. Unclip with ratio 1.5, i.e. grow each side by area·1.5/perimeter.
    4. Map back to the source pixels.
  - Use axis-aligned boxes; titles are horizontal, so no angle classifier.
- **Recogniser** `x: float32 [N,3,48,W]` → `[N,T,504]` softmax.
  - Before: crop the box, resize to height 48 keeping the aspect ratio, and
    pad W to the batch maximum (≤ 320 is typical; titles can be wider, so
    allow more). Normalise with (x/255 − 0.5)/0.5.
  - After: greedy CTC. Take the argmax per step, collapse repeats, and drop
    index 0 (blank).
  - **The character list is in the model's ONNX metadata** (key `character`,
    newline-separated, 502 entries). Index 0 is blank, entries 1..502 follow
    that list, and index 503 is a space (`use_space_char`).
    `flutter_onnxruntime` probably doesn't expose metadata. Extract it once
    to `latin_dict.txt` and ship that next to the models, or as a Dart const
    in the package (it's Apache-2.0 data from PaddleOCR's `latin_dict.txt`).
  - Confidence is the mean of the kept steps' max probabilities.

Upstream homr does the same thing in Python (`homr/title_detection.py`,
`RapidOCR()` defaults).

## Package API (proposed)

```dart
class OcrModels { // mirrors OmrModels, reuses openModelSession
  OcrModels.inAssetDir(String dir, {AssetPathResolver? resolvePath});
  static const detFile = 'ch_PP-OCRv5_det_mobile.onnx', recFile = 'latin_PP-OCRv5_rec_mobile.onnx';
  static const sha256 = {...};
}
class OcrLine { final String text; final double confidence; final Rect box; } // box 0–1, top-left origin
class TextReader {
  TextReader(OcrModels models);
  Future<List<OcrLine>> readText(Uint8List image, {Rect? region}); // honours EXIF orientation
  Future<void> dispose(); // release sessions: not static-cached like OMR's, to keep off the ~1.7 GB scan peak
}
```

The boxes match what the app's native channel returns today
(`lib/services/title_recognizer_io.dart`), so the app maps `OcrLine` →
`RecognizedLine` and keeps `titleSearchRegion` and `pickTitle` unchanged.

Tests in the package:
- CTC decode.
- Box unclip and components on synthetic maps.
- One end-to-end golden on a title rendered in the test, never a scan. It
  needs the models, so skip it when they're absent.

Update the package README ("Title detection is not ported") and its licence
notes. Then tag `v0.5.0`.

## Back in the app (steps 2–5 of the plan)

1. `scripts/fetch_omr_models.sh`: fetch det + rec (+ dict) pinned by the hashes above.
2. Add `assets/engine/licenses/paddleocr.txt` and register it in `lib/services/bundled_licenses.dart`.
3. `title_recognizer_io.dart`: `--dart-define=TITLE_OCR=onnx|native`, default `native`.
4. Comparison gate: extend `integration_test/title_recognition_test.dart` to print native vs onnx vs stored title, with timings.
   - Run it on `dev-iphone-se` and `dev-android`, and time it on `dev-android-low`.
   - Android switches if accuracy is within a couple of titles of ML Kit and it takes under ~1 s.
   - The user decides iOS from the table.
5. Remove ML Kit:
   - `TextRecognitionPlugin.kt`, its `MainActivity.kt` registration, and the Gradle line (plus `exifinterface` if unused).
   - The docs: `CLAUDE.md`, `docs/privacy.md`, `docs/plan.md`.
   - Measure the appbundle and ipa sizes before and after.
