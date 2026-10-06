# Flutter OMR Pipeline — Investigation Guide & Agent Handoff

**Last updated:** 2026-06-03  
**Status:** ✅ RESOLVED — staff detection rewritten as a faithful port of homr's
anchor+fragment algorithm. All four benchmark images are stable: Lightly Row 2
100% (was 68–100% unstable), Lightly Row original 100% (was ~13%), Happy Farmer
97.3%, Gavotte 97.9%. **Extra/missing notes = 0 on every image** — detection is
exact; residual error is transformer-only.

---

## ✅ Resolution (2026-06-03): ported homr's actual staff detection

The root cause was confirmed: the Dart pipeline had **reinvented** staff
detection as a whole-image 1-D row-density heuristic, whereas homr uses
anchor-based, fragment-based 2-D detection and consumes the clef/symbol SegNet
classes the Dart code discarded. Tuning `_heightThresholdFraction` /
`_spacingTolerance` was overfitting to 3 images and could never be robust.

The fix ports homr's algorithm faithfully into `lib/pipeline/homr/`:

| File | Ports |
|------|-------|
| `geometry.dart` | cv2 `findContours`→connected components, `minAreaRect`→convex hull + rotating calipers, `dilate`/`erode` |
| `bounding_boxes.dart` | homr `RotatedBoundingBox`, `create_rotated_bounding_boxes`, `break_wide_fragments`, polygon/SAT overlap |
| `staff_detection.dart` | `find_staff_anchors` (clef path), `connect_staff_lines`, `find_peaks`/`filter_line_peaks`/`find_horizontal_lines`, raw-staff connecting, dedup, resampling to per-column grid |
| `predictions.dart` | per-class masks (homr `==class` semantics), `filter_predictions` noise filter, `make_lines_stronger`, glue → `List<Staff>` |

**Validation method (avoids re-overfitting):** the local Python `homr` install is
used as an oracle. `tool/validate_fragments.dart`, `validate_detection.dart`,
`validate_glue.dart` diff each Dart layer against homr's own output on the
benchmark masks (dumped by `tool/homr_oracle.py`, recreated Oct 2026 after the
original `/tmp` copy was lost):
- fragment extraction (pre-break): **bit-exact, 109/109, Δ=0.00**
- full staff grids: median |Δy| **0.05–0.10 px**, max < 4.3 px, staff counts 4/5/8 = homr exactly.

Remaining homr pieces not yet ported (not needed for current benchmarks, would
add robustness on harder pages): bar-line/rest anchors (`are_clefs=False`, needs
notehead+stem detection), and homr's `staff_parsing.py` dewarp+canvas-centering
(the 1280×256 transformer-input issue noted below is still open). The runner's
reconstruction was also aligned to homr's exact `==class` overlap semantics.

The 1-D row-density detector (`segmentation_postprocessor.dart`) is retained only
for its existing unit/diagnostic tests; the live pipeline no longer uses it.

---

## Historical investigation notes (pre-resolution)

The sections below documented the original instability and the (rejected)
constant-tuning / comb-fit directions. Kept for context.

---

## What we're building

A Flutter app that photographs a music book page and produces MusicXML. The heavy
lifting is two ONNX models ported from the Python
[`liebharc/homr`](https://github.com/liebharc/homr) library:

- **SegNet** — segmentation CNN that labels every pixel as one of 6 classes (class 4 =
  staff lines)
- **TrOmr** — transformer that reads a cropped staff-strip image and outputs note tokens

The Dart pipeline (`lib/omr_orchestrator.dart`):

```
raw PNG
  → CLAHE preprocessing
  → SegNet  →  class mask (H×W uint8, each byte = class 0–5)
  → staff detection  →  StaffBounds list (5 line y-positions per staff)
  → for each staff:
       crop  →  dewarp  →  transformer
  → MusicXML assembly
```

---

## Current benchmark results

Run with:
```bash
flutter test integration_test/benchmark_omr_test.dart --name "benchmark:" \
  -d <simulator-udid>
```

| Image | Python homr ceiling | Dart result | Status |
|-------|--------------------|-----------  |--------|
| Happy Farmer | 97.3% | 97.3% | ✓ stable |
| Gavotte | ~100% | 99.5% | ✓ stable |
| Lightly Row 2 | 100% | 68–100% | ⚠ unstable |
| Lightly Row (orig) | 100% | ~13% | ✗ known-bad photo |

---

## The unstable problem: staff detection constants

`lib/pipeline/segmentation_postprocessor.dart` detects staves by:

1. Count class-4 pixels per row → `rowDensity[y]`
2. Find local maxima in that signal above a **height threshold**
3. Group consecutive peaks into 5-line staves with **consistent spacing**

Two constants control this and are currently in tension:

### `_heightThresholdFraction` (currently 0.01)

Minimum class-4 pixels per row as a fraction of image width.  
For LR2 (1727 px wide): threshold = 17 px.

The problem: LR2's SegNet output is **non-deterministic across runs** due to FP16
arithmetic. In some runs the mask is sparse (max ~35 px/row) and in others dense (max
~800 px/row). This was formerly 0.03 (→ threshold 52), which silently rejected all LR2
peaks in sparse runs.

### `_spacingTolerance` (currently 0.35–0.40, actively being tuned)

How much the 4 inter-line gaps in a 5-line staff can vary from their mean.

LR2 has **noise peaks 8–9 px from real peaks** (SegNet sub-peaks within a thick staff
line band), making gap patterns like `[9, 17, 16, 16]` (max dev 37.9%) and
`[24, 12, 17, 16]` (max dev 39.5%). These require tolerance ≥ 0.40 to pass.

At 0.40, LR2 gets 100% but Gavotte regresses to 16.6%. At 0.35, Gavotte is fine but
LR2 only finds 3 of 4 staves.

**This suggests overfitting to specific images.** The constants are toggling between
satisfying LR2 and satisfying Gavotte rather than solving the underlying structural
problem.

---

## Investigation toolkit

### 1. Dump intermediate pipeline artifacts

Tests named `dump-artifacts: <image>` are in `integration_test/benchmark_omr_test.dart`.
They write to `/tmp/` (which maps directly to Mac `/tmp/` because the iOS simulator is a
Mac process):

```bash
flutter test integration_test/benchmark_omr_test.dart \
  --name "dump-artifacts: Lightly Row 2" \
  -d <simulator-udid>
```

Files at `/tmp/homr_dart_lr2/`:

| File | Description |
|------|-------------|
| `clahe.png` | CLAHE-preprocessed input (what SegNet sees) |
| `mask_class4.png` | Class-4 pixels only (white = staff line) |
| `staff_N_raw.png` | Each detected staff strip before dewarping |
| `staff_N_dewarped.png` | After dewarping (what transformer sees) |
| `teaser.png` | Full image with staff regions tinted, line positions drawn |

Artifact dirs: `/tmp/homr_dart_lr2/`, `/tmp/homr_dart_hf/`, `/tmp/homr_dart_gavotte/`.

### 2. Python homr debug run (gold standard)

```bash
mkdir /tmp/homr_lr2_debug
cp assets/test_images/lightly_row2_notes.png /tmp/homr_lr2_debug/
cd /tmp/homr_lr2_debug
PYTHONWARNINGS=ignore homr --debug lightly_row2_notes.png
```

Key output files:

| File | Description |
|------|-------------|
| `*_teaser.png` | Staff detection overlay — curved lines follow actual curvature |
| `*_debug_1_color_adjust.png` | Python CLAHE output (compare to `clahe.png`) |
| `*_debug_3_staff.png` | Raw SegNet staff-class probability map |
| `*_staff-N_input.jpg` | Per-staff strip after dewarping (**always 1280×256**) |
| `*_staff-N_debug_span_points.png` | Dewarping control points (red=actual, blue=target) |

### 3. Analyse the Dart mask in Python

```bash
uv tool run --from homr python3 - << 'EOF'
import cv2, numpy as np

mask = cv2.imread('/tmp/homr_dart_lr2/mask_class4.png', cv2.IMREAD_GRAYSCALE)
h, w = mask.shape
row_density = np.sum(mask > 0, axis=1)
min_h = int(w * 0.01)
print(f"Dart mask: {w}x{h}, max density: {row_density.max()}, threshold: {min_h}")
for start in range(0, h, 50):
    end = min(start+50, h)
    bmax = row_density[start:end].max()
    print(f"  y={start:4d}-{end:4d}: max={bmax:3d}  {'█'*(bmax//10)}")
EOF
```

### 4. Simulate the full Dart grouping algorithm in Python

This is the fastest debugging loop — tweak constants, see result immediately, then
transfer to Dart:

```bash
uv tool run --from homr python3 - << 'EOF'
import cv2, numpy as np

mask = cv2.imread('/tmp/homr_dart_lr2/mask_class4.png', cv2.IMREAD_GRAYSCALE)
h, w = mask.shape
row_density = np.sum(mask > 0, axis=1)

MIN_HEIGHT   = int(w * 0.01)   # _heightThresholdFraction
MIN_DISTANCE = 7               # _minPeakDistance
SPACING_TOL  = 0.35            # _spacingTolerance
MIN_UNIT     = 8               # _minUnitSize

# Step 1–2: local maxima + height filter
candidates = [i for i in range(1, h-1)
              if row_density[i] > row_density[i-1]
              and row_density[i] >= row_density[i+1]
              and row_density[i] >= MIN_HEIGHT]

# Step 3: distance filter
peaks = [candidates[0]] if candidates else []
for p in candidates[1:]:
    if p - peaks[-1] > MIN_DISTANCE:
        peaks.append(p)
    elif row_density[p] > row_density[peaks[-1]]:
        peaks[-1] = p

print(f"Peaks after all filters ({len(peaks)}): {peaks}")

# Step 4: greedy 5-line grouping
groups, i = [], 0
while i <= len(peaks) - 5:
    g = peaks[i:i+5]
    gaps = [g[j+1]-g[j] for j in range(4)]
    mean_gap = sum(gaps) / 4
    consistent = all(abs(gap - mean_gap) <= mean_gap * SPACING_TOL for gap in gaps)
    if mean_gap >= MIN_UNIT and consistent:
        groups.append(g)
        print(f"  ACCEPTED staff {len(groups)-1}: {g}  gaps={gaps}  unit={mean_gap:.1f}")
        i += 5
    else:
        max_dev = max(abs(gap - mean_gap)/mean_gap for gap in gaps) if mean_gap else 999
        print(f"  rejected i={i}: {g}  gaps={gaps}  max_dev={max_dev:.0%}")
        i += 1

print(f"\nTotal staves: {len(groups)}")
EOF
```

---

## Key architectural differences: Python vs Dart

| Aspect | Python homr | Dart pipeline |
|--------|-------------|---------------|
| **Staff detection** | Fragment-based: finds class-4 blobs, connects them into lines | Row-density peaks in a 1D histogram |
| **Per-column line tracking** | `Staff.grid` — actual y-pos of all 5 lines every 10 px | `StaffBounds.lineYs` — 5 average y-positions only |
| **Dewarping** | 2D piecewise affine (Delaunay triangulation) | 1D column-wise vertical shift (equivalent for book-spine bow) |
| **Transformer input size** | Always exactly **1280×256** (landscape) | Variable height after letterbox to **256×1280** |
| **CLAHE** | Internal (`color_adjust.apply_clahe`, clipLimit=1.0, 8×8) | Dart port in `image_preprocessor.dart` (same params) |

The **transformer input size** difference is significant and under-investigated:
Python always produces a landscape 1280×256 crop; Dart's letterboxing produces a
portrait-ish 256×(short) crop. The TrOmr transformer may have been trained primarily
on wide-and-short strips, which could explain residual accuracy gaps even when staff
detection is correct.

---

## More principled directions to investigate

The current approach (tuning `_heightThresholdFraction` and `_spacingTolerance`) is
overfitting to specific benchmark images. More structural fixes:

### 1. Why is LR2's SegNet output non-deterministic?

FP16 arithmetic with batch averaging over overlapping 320×320 patches *should* be
deterministic for identical input. If it isn't, there may be a batch-ordering or
floating-point accumulation issue in `inference/segmentation_runner.dart`. Investigate
by saving the mask on two successive runs and diffing them.

### 2. Python uses fragment-based staff detection, not row-density peaks

The row-density approach is fragile because it collapses 2D structure into 1D. A
sub-peak within a single thick staff-line band appears as two separate peaks in the
histogram.

Python homr's approach:
- Finds connected horizontal blobs of class-4 pixels (line *fragments*)
- Connects fragments into complete lines using spatial proximity
- Groups 5 aligned lines into a staff using geometric constraints

This is more robust to sparse/noisy masks because it uses the *shape* of the class-4
regions, not just their row-wise density. Porting the fragment approach to Dart is
more work but would eliminate the constant-tuning problem.

### 3. Investigate the transformer input aspect ratio

Python's `center_image_on_canvas` produces exactly 1280×256 (wide, short).
Dart's `_letterbox` in `transformer_runner.dart` fits the crop to 256×1280 but the
actual staff image may be much shorter than 1280 px, leaving large white bands.

Check whether rotating the transformer's expected input format (or rotating the staff
crop before letterboxing) improves accuracy.

### 4. Model version mismatch

- SegNet: commit 308 (FP16) — matches Python homr 0.6.2 ✓
- Transformer: commit 367 (FP16) — **newer than** Python homr 0.6.2 (commit 331)

The transformer version mismatch could mean the Dart transformer was trained with
slightly different data augmentation or input preprocessing than what we're providing.

---

## File map

| File | Purpose |
|------|---------|
| `lib/omr_orchestrator.dart` | Pipeline entry point; wires all stages; `artifactDir` param for debugging |
| `lib/pipeline/segmentation_postprocessor.dart` | Row-density staff detection; four tunable constants |
| `lib/pipeline/staff_dewarper.dart` | Per-staff 1D vertical dewarping; 3-sample median smoothing |
| `lib/capture/image_preprocessor.dart` | CLAHE implementation (Dart port of cv2.createCLAHE) |
| `lib/inference/segmentation_runner.dart` | SegNet ONNX inference (FP16, 320×320 overlapping patches) |
| `lib/inference/transformer_runner.dart` | TrOmr encoder-decoder; letterbox to 256×1280 |
| `integration_test/benchmark_omr_test.dart` | Accuracy benchmarks + `dump-artifacts` tests |
| `assets/test_images/lightly_row2_notes.png` | Primary LR benchmark photo (use this, not the original) |
| `docs/omr_evaluation/homr/results.md` | Full evaluation log — all phases with accuracy numbers |
| `docs/omr_evaluation/scripts/homr_phone_sweep.py` | Python homr sweep over preprocessing variants |
| `docs/omr_evaluation/scripts/generate_clahe_assets.py` | Generates `*_clahe.png` test assets |

---

## Simulator info

Device UDID: `<iphone-udid>` (physical iPhone)  
Simulator UDID: `<simulator-udid>` (iOS 17, Apple Silicon)

The iOS simulator runs as a Mac process. Files written to `/tmp/` inside the simulator
appear at `/tmp/` on the Mac — no container-path hunting needed.
