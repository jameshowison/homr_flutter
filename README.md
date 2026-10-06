# homr_flutter

On-device OMR (Optical Music Recognition) for Flutter: a Dart port of
[homr](https://github.com/liebharc/homr).

This repo holds two things:

- **`packages/homr_flutter/`** — the package apps depend on (`homr_flutter`,
  AGPL-3.0). Its [README](packages/homr_flutter/README.md) covers setup and
  usage. Apps pin a release tag (`v0.1.0`, …) as a git dependency.
- **the root** — `homr_flutter_demo`: a demo app, the accuracy benchmarks and
  the evaluation tooling.

Before running the demo or any integration test, fetch homr's models into the
demo's assets (≈150 MB, once; gitignored):

```bash
python3 packages/homr_flutter/tool/fetch_models.py assets/omr_models
```

To release: bump `version` and `CHANGELOG.md` in the package, commit, tag
`vX.Y.Z`, push the tag; dependent apps move their `ref:` to it.

## How the port was made

This is an attempt to run [homr](https://github.com/liebharc/homr) on a phone.
homr does the hard part: its two ONNX models (a segmentation network that
labels every pixel, and a transformer that reads one staff at a time) and the
Python pipeline that connects them. We did not train or change any models. What
we did was port the Python pipeline to Dart, stage by stage, so that homr's own
models could run on-device through `flutter_onnxruntime`:

> resize to 1920 px wide → CLAHE contrast adjustment → segmentation → staff
> detection → per-staff crop and straightening → transformer → MusicXML

Most of the work, and most of the mistakes, came from places where the Dart
version quietly differed from homr's. Our general lesson was to follow homr
closely rather than simplify it, and to check against homr itself rather than
against our own sense of what looked right. The notes below record what we ran
into, in roughly the order we hit it. The code was written largely with AI
coding assistants, so it is likely there are things here we've misunderstood;
corrections are very welcome.

**No OpenCV in Dart.** homr's staff detection relies on three OpenCV
operations: finding connected shapes (`findContours`), fitting a rotated
rectangle around each one (`minAreaRect`), and growing and shrinking shapes
(`dilate`/`erode`). There is no OpenCV built into Dart. Bindings to the native
library exist, but we preferred not to add a large native dependency for three
operations, so they are written out in pure Dart in
`packages/homr_flutter/lib/src/pipeline/homr/geometry.dart` (connected
components, a convex hull with rotating calipers, and plain morphology). It
took some care to reproduce homr's conventions for rectangle angles exactly.

**Staff detection, first attempt.** Our first version did not port homr's staff
detection. It tried something simpler: counting staff-line pixels row by row in
the segmentation output and looking for five evenly spaced peaks. It worked on
a few images, but it needed its thresholds re-tuned for each new photo, and on
one photo it gave different answers from run to run. We came to think we were
fitting the method to our handful of test images, and that it had discarded
information (the clef and symbol classes) that homr relies on.

**Staff detection, ported.** We then ported homr's actual approach: find short
staff-line fragments, anchor staves on clefs, join fragments into lines and
lines into staves, and resample each staff into a grid. To avoid fitting the
port to our images all over again, we used the Python package as an *oracle*.
`tool/homr_oracle.py` runs homr itself on an image and saves each intermediate
result, and three Dart tools compare the port against it, layer by layer:

| Check | What it compares |
|---|---|
| `tool/validate_fragments.dart` | staff-line fragments, before and after splitting overly wide ones |
| `tool/validate_detection.dart` | detected staves, given homr's own masks as input |
| `tool/validate_glue.dart` | detected staves, from homr's raw segmentation output |

On the four benchmark photos (re-run in October 2026), the fragments the port
extracts are identical to homr's (109/109, 95/95, 148/148 and 288/288). It finds
the same number of staves on every image (4, 4, 5 and 8), and their line
positions agree with homr's to a median of 0.01–0.06 px (at most 5.3 px). One
known difference remains, which we have not tracked down: after the step that
splits overly wide fragments, the port produces about 7–9% more pieces than
homr does. It doesn't seem to change the staves, but it is a place where the
port is not yet faithful. Bar-line and rest anchors, which homr also uses to
find staves, are not ported, so the oracle compares clef-anchored detection on
both sides.

**Smaller things that mattered.**

- *The `image` package and 1-bit PNGs.* Converting a 1-bit PNG to grayscale
  made every pixel white, so the segmentation network saw an empty page.
- *The transformer's input format.* homr crops each staff tightly, straightens
  it along its middle line, and centres it on a 1280×256 canvas. Until we did
  exactly the same, the transformer misread octaves and dotted rhythms. Two
  Suzuki pieces went from 45% and 29% to 100% once the crop matched.
- *Resizing.* homr resizes every image to 1920 px wide before anything else.
  The port didn't, which went unnoticed because our benchmark photos were
  already about that size. A crop of half a page was then read at half the
  scale the models expect, and lost most of its notes. The orchestrator now
  resizes as homr does.
- *Thresholding.* Early on, we binarized images (pure black and white) to
  suppress bleed-through from the reverse side of the page. Once staff
  detection followed homr, that stopped being necessary, and a fixed threshold
  turned out to erase faint staff lines in some photos, so the port now passes
  colour images to the pipeline, as homr does
  (`integration_test/threshold_strategy_test.dart` has the comparison).

**Not ported, or different.** homr's automatic page crop (`autocrop`) is not
ported; the app asks the user to crop to the music instead. Title detection is
not ported. Staves are read one after another into a single part, so a system
with two staves, such as a duet, comes out as alternating lines rather than
two parts. Only iOS has been tried.

**Re-running the validation.** With a Python environment that has homr
installed (we used homr 0.6.2):

```bash
~/.local/share/uv/tools/homr/bin/python tool/homr_oracle.py   # writes /tmp/oracle_*
for t in lr2 lr hf gav; do
  dart run tool/validate_fragments.dart $t
  dart run tool/validate_detection.dart $t
  dart run tool/validate_glue.dart $t
done
```

`docs/pipeline_investigation.md` has the longer story of the staff-detection
work.

## OMR accuracy (Suzuki Book 1)

Evaluated against ground-truth MusicXML on iPhone 17 simulator (2026-06-09).
18 test cases (14 songs, 4 multi-photo variants): **17/18 perfect** (SER=0%).

Full results: `docs/omr_evaluation/current_status.md`.  
Residual issues and investigation notes: `docs/omr_evaluation/remaining_issues.md`.

### Test data

The scans and ground truth these numbers come from are not in the repository:
*Suzuki Violin School, Book 1* is a copyrighted edition, so the page images and
the MusicXML transcribed from them stay local. The integration tests expect them in
`assets/test_images/` and `assets/ground_truth/` (both gitignored), named:

- `assets/test_images/NN-slug_scan.png` — the full scanned page
- `assets/test_images/NN-slug_crop.png` — the page cropped to the staves
- `assets/ground_truth/NN-slug.xml` — the reference MusicXML

for example `02-lightly-row_scan.png` and `02-lightly-row.xml`. The test files
list the exact names they load. The tests in `pdf_artifact_dump_test.dart` that use
camera photos read them from a folder you pass with
`--dart-define=HOMR_PHOTO_DIR=/path/to/photos`, and are skipped without it.

### Scanning technique

Best results come from:
1. **Good lighting** — overhead/island light, avoid shadows and glare.
2. **Erasing pencil annotations** before scanning.
3. **Open the book flat** — spine-fold causes clef clipping; see CLAUDE.md.

These were confirmed on song 05 (O Come, Little Children): erasing pencil marks
under good lighting brought the score from 97.9% → **100%**. Using only one of
the two (erase but poor lighting, or good lighting but marks present) does not
achieve the same result.

## Running integration tests

```bash
flutter test integration_test/phase5_end_to_end_test.dart
flutter test integration_test/benchmark_omr_test.dart
flutter test integration_test/suzuki_book1_sweep_test.dart
```

## Dev notes

See `CLAUDE.md` for wireless debug setup, release-mode testing, and the
Save-for-testing button in the Review Scan screen.
