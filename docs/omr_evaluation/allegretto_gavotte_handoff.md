# Handoff: investigating 10-allegretto & 17-gavotte

**Created:** 2026-06-06
**Branch:** `main` (post-unification — commits `ad68826` staff_parsing canvas crop,
`565cfc7` save-for-testing UI; pushed to origin)

---

## Context

The Suzuki Book 1 sweep was re-run after unifying homr's `staff_parsing`
canvas crop (`lib/pipeline/homr/staff_parsing.dart` → `prepareStaffImage`) into
`main`. That fix resolved the octave/spurious-rest failures:

| Song | before | after |
|------|--------|-------|
| 09-perpetual-motion | 45.3% | **100%** |
| 15-minuet-no-3 | 29.1% | **100%** |
| 06-may-song | 14/44 notes | **44/44 · 100%** |

Two songs remain low and are the subject of this handoff:

| Song | notes_out / ref | pitch | dur | both | wall |
|------|-----------------|-------|-----|------|------|
| 10-allegretto | 92 / 94 | 40.2% | 51.1% | 29.3% | 7.0 s |
| 17-gavotte (phone) | 193 / 192 | 26.6% | 74.5% | 20.8% | 15.4 s |

Latest full numbers: `docs/omr_evaluation/suzuki_book1/unified_results.tsv`.

---

## Scoring is now alignment-based — use the drill-down

The old positional metric (`ref[i]` vs `engine[i]`, no alignment) let one
dropped/extra note cascade into a wrongly-low score. It has been **replaced** by
hierarchical measure-then-note alignment in `lib/eval/musicxml_scoring.dart`
(design: `scoring_approach.md`), already wired into the sweep. The sweep now
prints **SER, ins/del, key%**, and a per-measure divergence list
(`formatReport`) — so for either song you get "ref#X→eng#Y: sub=… ins=… del=…"
pointing straight at the bad bar. Trust the **ins/del counts and the per-measure
list**, not a single percentage. Honest count signal: allegretto −2, gavotte +1.

`scoreMeasures(refMeasures, engMeasures)` / `scoreDocuments(refDoc, engDoc)` are
also callable from any `dart run` script or unit test for offline drill-down.

---

## Issue A — 17-gavotte: this is a ground-truth / harness problem, not a pipeline bug

Strong evidence the pipeline is **correct** and the abc2xml ground truth is the
outlier:

- Pipeline output on `gavotte_notes.png` = **193 notes**.
- Python-homr reference `assets/ground_truth/gossec_gavotte_bw.musicxml` = **193
  notes** (same image, run through the Python `homr` oracle).
- The existing **benchmark** (`integration_test/benchmark_omr_test.dart`) scores
  the pipeline at **97.9% pitch against that Python-homr reference**.
- The sweep scores the *same pipeline output* at **20.8% against
  `assets/ground_truth/17-gavotte.xml`** (abc2xml, **192 notes, 5 `<repeat>`
  elements**).

So pipeline ≈ Python homr (193, 97.9%); abc2xml ground truth disagrees (192, +
repeat structure). The most likely culprits, in order:

1. **Repeat handling / edition mismatch.** `17-gavotte.xml` notates repeats
   *once* with `<repeat>` barlines (192 written notes); the photographed sheet
   (`gavotte_notes.png`) and homr may expand or order the repeated/volta material
   differently, shifting the positional stream. `dur=74.5%` surviving while
   `pitch=26.6%` collapses is the classic signature of a *positional shift* on a
   piece with repetitive rhythm (durations keep lining up; pitches don't).
2. **Different source edition.** `17-gavotte.xml` comes from
   `../abc-music/suzuki-violin-book-1/`; `gavotte_notes.png` is the photographed
   Suzuki/Gossec edition used by the benchmark. They may simply be different
   transcriptions (octave register, ornaments-as-notes, pickup).

### Suggested resolution for A

This is an **eval-harness/ground-truth** task, not a pipeline change:
- Score pipeline-output against *both* references (`gossec_gavotte_bw.musicxml`
  and `17-gavotte.xml`) with the new aligner and read the per-measure divergence
  list to localize the exact split (almost certainly a repeat/volta boundary —
  it will surface as a block of measure ins/del). Note the aligner *localizes*
  but does not *resolve* a repeat-expansion mismatch — see "What this does NOT
  do" in `scoring_approach.md`.
- Decide the policy: either (a) treat `gossec_gavotte_bw.musicxml` as the
  reference for this image (it already gives 97.9%), or (b) regenerate/repair the
  abc2xml ground truth so its repeat expansion matches the printed sheet.
- Document the conclusion; do **not** "fix" the pipeline to chase this number —
  doing so would regress the benchmark.

**Definition of done:** a written explanation of the 193-vs-192 / repeat
divergence and a corrected reference (or a documented decision to use the
Python-homr reference for this image).

---

## Issue B — 10-allegretto: likely a genuine pipeline misread

Unlike Gavotte, this one looks real:

- **No repeats/voltas** (`grep <repeat>/<ending>` = 0), 17 measures, 94 notes, 4
  rests — so no structural-alignment trap.
- **2 notes missing** (92 vs 94) **and** both pitch (40.2%) *and* duration
  (51.1%) low. Octave errors don't hurt duration, so this is **not** the
  octave class that the canvas crop fixed — it's something else (dropped/merged
  notes, a poorly-read staff strip, or a rhythm misread cascading positionally).
- **No Python-homr reference exists** for this image yet (it's one of the new
  `_crop.png` photos). You'll need to generate one.

### Investigation steps for B

1. **Get the oracle.** Run the local Python `homr` on the same image to see what
   homr itself produces (the pipeline is a port of homr, so homr is ground truth
   for "is this a port bug or an inherent model limit?"):
   ```bash
   uv tool run --from homr homr assets/test_images/10-allegretto_crop.png
   ```
   Compare its note count / pitches to both the pipeline and `10-allegretto.xml`.
   - If homr also misses those 2 notes → inherent model/image limit, lower
     priority.
   - If homr gets them but the Dart port doesn't → a port bug in detection or
     staff_parsing; keep digging.

2. **Dump the pipeline's intermediate artifacts.** `OmrOrchestrator.recognise`
   takes an `artifactDir` that writes `clahe.png`, `mask_class4.png`,
   `teaser.png`, and per-staff `staff_N_input.png` (the exact 256×1280 canvas fed
   to the transformer). `integration_test/pdf_artifact_dump_test.dart` is the
   existing pattern — adapt it for `10-allegretto_crop.png`. Inspect:
   - `teaser.png` — did staff detection find all systems with correct grids? A
     missed/merged staff would drop notes.
   - each `staff_N_input.png` — is any strip clipped, skewed, or scaled wrong by
     `prepareStaffImage` (`_calculateRegion` neighbour-clamping at
     `lib/pipeline/homr/staff_parsing.dart`)?

3. **Dump the output MusicXML + token stream.** The orchestrator currently dumps
   only PNGs to `artifactDir`, **not** the output XML. Add a one-off: write the
   `recognise()` return value to disk, and (to see *which* symbols are wrong) log
   the `EncodedSymbol` list per staff from `TransformerRunner.runTransformer`
   (`lib/inference/transformer_runner.dart:276`). Then align that against
   `10-allegretto.xml` measure-by-measure to find the 2 missing notes and the
   first real pitch/dur divergence.

4. **Localize.** Once you know which measure/strip breaks, decide whether it's:
   detection (`staff_detection.dart`), region crop (`staff_parsing.dart`), or the
   transformer reading a correct strip wrong (model limit).

### Definition of done for B

Either a fix (with the sweep re-run showing allegretto improved and **no
regression** on the currently-100% songs — especially watch 05-o-come, which is
already at 95.7%), or a documented finding that homr itself can't read this image
and the gap is inherent.

---

## Shared tooling reference

- **Re-run the sweep** (iPhone 17 sim, booted as
  `<simulator-udid>`):
  ```bash
  flutter test integration_test/suzuki_book1_sweep_test.dart \
    --device-id <simulator-udid> \
    2>&1 | tee docs/omr_evaluation/suzuki_book1/<name>_results.tsv
  ```
  Full build + 18 cases ≈ 2.5–3 min wall on the sim.
- **Python homr oracle:** `uv tool run --from homr homr <image.png>` (`uv` at
  `/opt/homebrew/bin/uv`). This is the same oracle used to validate the detection
  port — see `tool/validate_{fragments,detection,glue}.dart` for the
  layer-by-layer JSON/PNG diff pattern (`dart run`, no simulator).
- **Key files:**
  - comparison logic & cases: `integration_test/suzuki_book1_sweep_test.dart`
  - artifact dump pattern: `integration_test/pdf_artifact_dump_test.dart`
  - pipeline entry: `lib/omr_orchestrator.dart` (`artifactDir` param)
  - region crop: `lib/pipeline/homr/staff_parsing.dart` (`prepareStaffImage`,
    `_calculateRegion`)
  - transformer decode: `lib/inference/transformer_runner.dart`
  - assembler: `lib/pipeline/musicxml_assembler.dart`
- **Background:** `docs/pipeline_investigation.md`,
  `docs/homr_flutter_integration.md`, and the original
  `docs/omr_evaluation/suzuki_book1_eval_plan.md` (its "Known issues" §4/§5 are
  the pre-unification write-ups of these same songs — note they predate the
  staff_parsing fix, so the octave hypotheses there are now resolved).

---

## TL;DR for whoever picks this up

- **Gavotte = harness/ground-truth bug.** Pipeline matches Python homr (193,
  97.9%); abc2xml `17-gavotte.xml` (192 + repeats) is the outlier. Fix the
  comparison (add alignment) and reconcile/replace the reference. Do not touch
  the pipeline.
- **Allegretto = probably a real pipeline misread.** No repeats, 2 notes
  dropped, pitch+dur both low (not octave). Run the homr oracle on the image,
  dump `artifactDir` + the output XML/token stream, and localize. Re-run the
  sweep after any change and guard against regressing the 100% songs.
- **Above all: stop trusting the positional percentage — align first.**
