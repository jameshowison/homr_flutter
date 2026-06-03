# homr Flutter Integration — Build Plan

## Status
Phases 0–6 complete. Ready to begin Phase 7 (benchmarking).

**End-to-end result (iPhone 17 simulator, happy_farmer_bw_50.png):**
- Pipeline: segmentation → staff detection → transformer × 5 staves → MusicXML
- Wall time: ~12 s cold (within 15 s Phase 7 target)
- Output: 1 part, 23 measures, 102 notes vs Python ref 21 measures, 112 notes (91%)
- Structure matches Python reference (1 voice, newline-separated staves)

## Project goal
On-device optical music recognition for single-staff printed sheet music (Suzuki Book 1 level),
producing MusicXML. Zero server cost, fully open source (AGPL).

## Repo
`git_root/homr_flutter/` — standalone Flutter app, sibling to `git_root/homr/` (Python reference) and the violin practice companion. Created with:
```
flutter create homr_flutter --org dev.homr --platforms android,ios
```

## Architecture overview

```
OS document scanner (VisionKit / ML Kit) →
Binary threshold (50%) + CLAHE + resize →
SegNet ONNX inference (patch-based) →
Staff detection + bounding boxes →
Transformer ONNX inference (encoder + autoregressive decoder) →
MusicXML output
```

Pipeline stages:
1. **Capture** — OS-native document scanner handles deskew, perspective, crop
2. **Preprocessing** — binary threshold + CLAHE + resize in Dart (homr-specific, not replaceable by OS)
3. **Segmentation** — SegNet UNet detects 6 semantic classes in 320×320 patches
4. **Staff detection** — builds staff geometry from segmentation masks
5. **Recognition** — encoder+decoder transformer converts staff strip to note tokens
6. **Assembly** — note tokens → MusicXML

---

## Phase 0 — Model audit (COMPLETE)

### Models

All models are hosted at **GitHub releases of `liebharc/homr`**:
`https://github.com/liebharc/homr/releases/download/onnx_checkpoints/{name}.zip`

| File | Stage | Notes |
|------|-------|-------|
| `segnet_308-3296ccd40960f90ca6ab9c035cca945675d30a0f.onnx` | Segmentation | FP32; `_fp16` variant available |
| `encoder_pytorch_model_367-575b4737bca815d3a7b37169269fc548d7e945b9.onnx` | Transformer encoder | FP32; `_fp16` variant available |
| `decoder_pytorch_model_367-575b4737bca815d3a7b37169269fc548d7e945b9.onnx` | Transformer decoder | FP32; `_fp16` variant available |

**Bundle strategy:** Use FP16 variants (~67 MB total estimated). Bundle in `assets/models/` — not a hard
platform limit (Google Play AAB supports >150 MB assets; iOS App Store accepts large bundles with a
Wi-Fi-required flag above 200 MB). Bundling preferred over on-demand download to support offline use
without first-launch friction.

### Tensor specs

**SegNet:**
- Input `"input"`: `[batch, 3, 320, 320]` float16
- Output `"output"`: `[batch, 6, 320, 320]` — 6-class logits; argmax → class mask
  - 0=background, 1=stems/rests, 2=noteheads, 3=clefs/keys, 4=staff lines, 5=other symbols

**Transformer encoder:**
- Input `"input"`: `[1, 1, 256, 1280]` float16 (1-channel grayscale staff strip)
- Output `"output"`: `[1, seq_len, 512]`

**Transformer decoder (autoregressive, per step):**
- Inputs: `rhythms`, `pitchs`, `lifts`, `articulations` each `[batch, 1]`; `context`; `cache_len [1]`; 32 cache tensors `cache_in0`–`cache_in31`
- Outputs: logits for each head; 32 cache outputs; `attention`
- Stop at EOS (token id=2) on rhythm stream; max 608 tokens

### Vocabularies

| Stream | Size | Key tokens |
|--------|------|------------|
| Rhythm | ~200 | PAD=0, BOS=1, EOS=2; note/rest durations in Humdrum \*\*kern (e.g. `note_4.` = dotted quarter) |
| Pitch | 71 | nonote=0; C0–B9 |
| Lift (accidentals) | 7 | nonote, ♯, ♯♯, ♮, ♭, ♭♭ |
| Position | 3 | nonote, upper, lower (grand staff) |
| Articulation | ~250 | combinations; `_` = none |

### Image preprocessing pipeline (Python reference, to be ported)

1. `autocrop()` — background margin removal (subsumed by OS scanner)
2. `resize_image()` — target width **1920 px**, aspect-ratio preserving
3. `color_adjust.apply_clahe()` — BGR→grayscale + CLAHE contrast normalisation

**Note:** We replace step 3 with a binary threshold at 127. Evaluation showed this outperforms CLAHE
on printed book pages. See Phase 3 for details.

---

## Phase 1 — Flutter project scaffold

### Dependencies (pubspec.yaml)

```yaml
dependencies:
  flutter_onnxruntime: ^1.5.1     # 16 KB page-size compliant for Google Play
  flutter_doc_scanner: latest     # wraps VisionKit (iOS 13+) + ML Kit (Android API 21+)
  image: latest                   # pure-Dart image processing
  path_provider: latest
  xml: latest                     # MusicXML generation
```

Model files → `assets/models/` (pubspec assets block), FP16 variants only.

### Model fetch script

Write `tools/fetch_models.py`:
- Downloads the three FP16 `.onnx.zip` files from the GitHub releases URL above
- Unzips to `assets/models/`
- Prints tensor input/output names from each model for verification

---

## Phase 2 — Document capture

### Capture screen (`lib/capture/capture_screen.dart`)

Thin wrapper around `flutter_doc_scanner`:
- Launches the OS scanner UI (VisionKit on iOS → perspective-corrected JPEG; ML Kit on Android → corrected JPEG)
- Returns a single `File` (the scanned page)
- OS handles edge detection, deskew, and perspective correction automatically

**What the OS scanner does NOT do** (handled in Phase 3):
- Binary threshold (50% — critical, specific to book bleed-through)
- CLAHE normalisation
- Resize to 1920 px

---

## Phase 3 — Image preprocessing

### Preprocessor (`lib/capture/image_preprocessor.dart`)

Pure Dart using the `image` package:

1. Decode JPEG from scanner
2. Resize to 1920 px wide (aspect-ratio preserving)
3. Convert to grayscale
4. **Binary threshold at 127** — evaluation showed this outperforms CLAHE on printed book pages
5. Return preprocessed B&W image (pixel values 0 or 255 only) ready for SegNet patch extraction

**Divergence from Python reference:** The homr Python pipeline applies CLAHE (BGR→grayscale + contrast
normalisation) and passes a continuous-tone grayscale image to both SegNet and the transformer. We
threshold early instead and carry a binary image throughout. Nothing downstream breaks: SegNet accepts
float values at the extremes, `remove_black_contours_at_edges_of_image` thresholds at 97 (no-op on
binary), and dewarping interpolation naturally softens edges anyway. All Dart pipeline code should be
written to expect a binary (0/255) image as input.

---

## Phase 4 — ONNX inference layer

Both runners: lazy-load on first use, cache sessions as singletons, run in a Flutter `Isolate`, report inference time to a debug overlay.

### Segmentation runner (`lib/inference/segmentation_runner.dart`)

```dart
Future<Uint8List> runSegmentation(Uint8List imageGray, int width, int height)
// Returns class mask [H×W], one byte per pixel (argmax class index)
```

Patch loop:
1. Extract 320×320 region; pad edges with 255 (white)
2. Replicate grayscale → 3-channel; cast to Float16List
3. Batch up to 8 patches → run SegNet session
4. Argmax along class axis → class index per pixel
5. Paste back into full-resolution class mask

### Transformer runner (`lib/inference/transformer_runner.dart`)

```dart
Future<List<EncodedSymbol>> runTransformer(Uint8List staffGray, int w, int h)
```

1. Letterbox to 256×1280; cast to Float16List
2. Encoder: `[1, 1, 256, 1280]` → `[1, seq_len, 512]`
3. Decoder loop (max 608 steps):
   - Feed previous tokens + context + cache tensors
   - Argmax each output head → token indices
   - Reverse-lookup token strings from vocabulary tables
   - Append `EncodedSymbol`; break on EOS rhythm token
4. Return `List<EncodedSymbol>`

---

## Phase 5 — Symbolic pipeline

Reference Python files (all in `../homr/homr/`):

| Python file | Dart target |
|-------------|-------------|
| `segmentation/inference_segnet.py` | mask → bounding boxes |
| `staff_detection.py` | staff grid construction |
| `model.py` | data structures |
| `bounding_boxes.py` | RotatedBoundingBox, BoundingEllipse |
| `note_detection.py` | notehead ellipse fitting |
| `transformer/vocabulary.py` | EncodedSymbol, SymbolDuration |
| `music_xml_generator.py` | MusicXML assembly |

### Segmentation postprocessor (`lib/pipeline/segmentation_postprocessor.dart`)

Port `bounding_boxes.py` + `staff_detection.py`:
- Per-class binary mask → contour detection → `RotatedBoundingBox` objects
  (no OpenCV in Dart; use `image` package morphology + custom minAreaRect)
- Group staff-line fragments (class 4) into 5-line staves by y-distance clustering
- Compute `avgUnitSize` (median inter-line spacing in pixels)
- Build `StaffGrid` (list of `StaffPoint`: x, y[5], angle, unitSize)

Key constants from `../homr/homr/constants.py`:
- `toleranceForStaffLine` = `unitSize / 3`
- `maxLineGap` = `5 * unitSize`
- `barLineMaxWidth` = `2 * unitSize`

### Symbol classifier (`lib/pipeline/symbol_classifier.dart`)

- Parse rhythm token string → `SymbolDuration` (Humdrum kern: base duration + dots + tuplet ratio)
- Map pitch token → MIDI note number
- Map lift token → accidental
- Assign symbols to staves by bounding-box y-overlap with `StaffGrid`

### MusicXML assembler (`lib/pipeline/musicxml_assembler.dart`)

Uses the `xml` Dart package; emits MusicXML 4.0 `<score-partwise>`.

Handles: notes, rests, time signatures, key signatures, barlines, clefs.
Out of scope for Suzuki Book 1: dynamics, articulations, double sharps/flats, tuplets.

---

## Phase 6 — Integration

### OMR orchestrator (`lib/omr_orchestrator.dart`)

```dart
Future<String> recognise(File image)  // returns MusicXML string
```

Progress events (stream): `preprocessing → segmenting → detecting → recognising → assembling`

Error handling: return partial result if segmentation succeeds but transformer fails; clear `OmrError` enum otherwise.

---

## Phase 7 — Performance and optimisation

### Benchmarking harness (`test/benchmark_omr.dart`)

- 10 test images from `../violin_practice_companion/docs/omr_evaluation/` corpus
- Per-stage timing
- Note-level accuracy vs hand-corrected ground truth MusicXML

### If inference too slow

Target: <15 s end-to-end on a 3-year-old mid-range phone.

1. FP16 models (already selected above) — first gain
2. Hardware delegates: CoreML (iOS), NNAPI (Android) via `flutter_onnxruntime` execution provider options
3. INT8 quantisation via ONNX Runtime Python API if FP16 + delegates still insufficient

---

## Key risks and mitigations

| Risk | Mitigation |
|------|------------|
| No OpenCV in Dart for contour/minAreaRect | Port from scratch; test each function against Python reference outputs on the same scan |
| Transformer attention coordinates unreliable | Use sequential symbol ordering; accept minor x-position imprecision |
| Dart port of staff detection diverges subtly | Keep Python reference runnable; diff outputs on same scan |
| FP16 accuracy regression vs FP32 | Validate on evaluation corpus; fall back to FP32 if accuracy drops |

---

## Recommended sequence

```
Phase 0 (done) →
Phase 1 (scaffold + fetch script) →
Phase 2 (capture screen) →
Phase 3 (preprocessor) →
Phase 4 (inference runners — seg and transformer can be parallelised) →
Phase 5 (pipeline — sequential: postprocessor → classifier → assembler) →
Phase 6 (orchestrator) →
Phase 7 (benchmarking + optimisation if needed)
```

Do not start Phase 5 until Phase 4 produces tensor outputs verified against the Python reference on the same image.

## Discipline notes

- Each agent task = one deliverable file or small set of files
- Before writing any Dart port, read the corresponding Python source in `../homr/homr/`
- Write unit tests alongside each module using evaluation-corpus images as fixtures
- Keep the Python reference pipeline runnable throughout — use it to generate ground truth

---

## Phase 5 design note — simplified staff detection

### Why we are not porting `bounding_boxes.py` + `staff_detection.py`

The Python staff detection pipeline (`staff_detection.py`, 740 lines; `bounding_boxes.py`, 553 lines)
is complex because it works from **raw pixels**: it must separate staff lines from noteheads, stems,
barlines, and everything else using only pixel intensity. That forces a chain of:

1. **Morphological erosion/dilation** — removes small blobs (noteheads, stems) to isolate long
   horizontal lines
2. **Contour detection + `minAreaRect`** — finds connected pixel regions and fits rotated bounding
   boxes to capture angle and extent of each line fragment
3. **`StaffLineSegment` merging** — groups nearby fragments at similar y-positions
4. **`StaffAnchor` detection** — verifies candidates by requiring exactly 5 parallel segments with
   equal spacing, distinguishing staves from barlines and bracket lines
5. **Complex staff assembly** — threads anchors through fragments, handles gaps

None of this is music logic — it is all **pixel-level disambiguation work**.

### What our pipeline already gives us

We work from the **SegNet class-4 semantic mask**. Every pixel labelled class 4 has already been
declared "staff line" by a neural network trained to distinguish staff lines (class 4) from
noteheads (class 2), stems/rests (class 1), clefs/keys (class 3), barlines/other (class 5), and
background (class 0). Steps 1–4 above are a hand-engineered approximation of what SegNet does
implicitly. We have the output, not the input, of that process.

### Why we skip dewarping

`staff_dewarping.py` (461 lines) applies a piecewise-affine transformation that straightens curved
staff lines. It is designed for:

- **Book spine curvature** — pages bow toward the binding when a book is laid flat and photographed
- **Flatbed scanner barrel distortion**

Two things in our pipeline cover both:

1. **OS document scanner** (VisionKit / ML Kit) applies perspective correction and deskew before we
   ever see the image, handling the gross warp.
2. **Transformer training augmentation** — `warp_image_array_randomly` in `staff_dewarping.py`
   warps training images by ±20 px vertical displacement across 5 columns, making the transformer
   explicitly robust to residual curvature within that envelope.

For a Suzuki Book 1 page held flat under a phone camera, residual bowing after the OS scanner's
correction is well within the transformer's trained tolerance.

### The simplified approach (`segmentation_postprocessor.dart`)

```
class-4 mask (H × W)
  ↓
rowDensity[y] = count of class-4 pixels in row y      O(H × W)
  ↓
find local maxima in rowDensity with:
  height  ≥ 3% of image width   (rejects noise rows)
  distance ≥ 3 px               (collapses thick line peaks)
  ↓
group maxima: sets of 5 consecutive peaks where
  all 4 inter-line gaps are within ±30% of their mean
  AND mean gap ≥ 8 px
  → unitSize = mean of the 4 gaps
  ↓
per staff:
  yTop    = lineYs[0] − 4 × unitSize   (ledger line + symbol room)
  yBottom = lineYs[4] + 4 × unitSize
  xLeft   = 0 / xRight = imageWidth    (full width — one piece per page)
```

Output: `List<StaffBounds>` sorted top-to-bottom, consumed by the orchestrator to crop staff strips
and feed each to `TransformerRunner`.

**What we give up vs. the full port, and why it is acceptable:**

| Skipped feature | Needed for | Our situation |
|---|---|---|
| Morphological isolation | Separate staff lines from other symbols in raw pixels | SegNet class-4 mask already does this |
| Contour + `minAreaRect` | Line angle and fragment geometry | OS scanner pre-corrects angle |
| `StaffAnchor` verification | Reject non-staff horizontals | Class-4 label already means "staff line" |
| Piecewise-affine dewarp | Book spine curvature | OS scanner + transformer training data covers this |
| Grand-staff / brace detection | Piano, orchestral scores | Out of scope (Suzuki Book 1) |

### Phase 5 module order

1. `segmentation_postprocessor.dart` — class-4 mask → `List<StaffBounds>` (prerequisite for all else)
2. Wire orchestrator: crop staff strips, call `TransformerRunner` per staff
3. `musicxml_assembler.dart` — `List<List<EncodedSymbol>>` → MusicXML string
   (symbol parsing logic lives inside the assembler; no separate `symbol_classifier.dart` needed)
