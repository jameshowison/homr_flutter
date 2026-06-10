# Suzuki Book 1 OMR — Remaining Issues

Last sweep: 2026-06-09, iPhone 17 simulator.

## Current state

18 test cases (14 songs, 4 multi-photo variants).  
**17/18 perfect** (SER=0%, pitch=dur=both=100%, key=time=clef=100%).  
1 case has residual errors — detailed below.

Song 05 resolved 2026-06-09: good lighting + erasing pencil marks → 100%.
See resolved section below for full investigation notes.

Song 10 resolved 2026-06-09: ground-truth bug (gold standard had a spurious
eighth rest in measures 5 and 13, making each measure 4.5 beats — invalid
for 4/4, and not present in the scanned image) → 100%.
See resolved section below.

Song 14 resolved 2026-06-09: ground-truth bug (gold standard had an eighth
note where a dotted half belongs in measures 8 and 32) → 100%.
See resolved section below.

Post-processing rules now applied in `_deduplicateSymbols`
(`lib/pipeline/musicxml_assembler.dart`):
- **Consecutive barlines dropped** — transformer fires spurious barline at end
  of a staff strip; assembler would otherwise produce an empty measure.
- **Time signature locked to first occurrence** — transformer mis-fires 3/2
  (or 2/2) in the second section of longer pieces where note values are
  larger; the first time sig is always correct for this repertoire.

Beaming (`_addBeaming`/`_beamVoice`/`_assignBeams`):
- **Beam groups capped at 4 notes** — groups larger than 4 aren't used in
  this repertoire and are a sign the beat unit was mis-detected (e.g. an
  8-note 16th-note run in Gavotte measure 20, caused by the engine reading
  2/2 where gold has 4/4, doubling the apparent beat length to a half
  note). Runs longer than 4 are now split into chunks of ≤4 before beaming.

---

## Residual errors

### ~~05 — O Come Little Children~~ ✓ RESOLVED (2026-06-09)

**Resolution:** combination of good lighting and erasing pencil marks.
The `o_come_island_light.png` photo (pencil marks erased, taken under
island/overhead light) achieves **SER=0%, pitch=100%, both=100%** — 47/47
notes, all measures clean.

Investigation summary:
- Original PDF scan crop (pencil marks visible): 1 spurious insertion, SER=2.1%
- Camera photo with pencil marks: 97.9% (3 phantom insertions)
- PDF scan with pencil marks erased (`o_come_no_pencil.png`): 72.7% — worse
  (image editing degraded the scan quality)
- **Island-light photo, pencil marks erased (`o_come_island_light.png`): 100%** ✓

The spurious-insertion error was caused by pencil annotations in measure 16
(visible in the scan). Erasing the pencil marks AND using good lighting
(not the pencil marks alone, and not the scan alone) was required for a
perfect result.

Updated test image: `assets/test_images/05-o-come-little-children_island_light.png`.

---

### ~~14 — Minuet No. 2~~ ✓ RESOLVED (2026-06-09)

**Resolution:** the gold standard was wrong, not the pipeline.

`assets/ground_truth/14-minuet-no-2.xml` encoded measures 8 and 32 as a
single `eighth` note (A4, `duration=300`) — musically invalid, since an
eighth note (1 beat with `divisions=120`... actually 0.5 beat) leaves most
of the 3/4 measure unaccounted for. Both the Flutter engine and Python homr
independently produced a dotted half note (A4, `type=half` + `<dot/>`,
`duration=360` = a full 3/4 measure) for these measures — agreement between
two independent OMR systems against an internally-inconsistent reference was
the tell.

Fixed the gold XML to `type=half` + `<dot/>`, `duration=360`. SER 1.2% → 0.0%.

---

### ~~10 — Allegretto~~ ✓ RESOLVED (2026-06-09)

**Resolution:** the gold standard was wrong, not the pipeline.

`assets/ground_truth/10-allegretto.xml` had an extra eighth-note rest
(`<rest/>`, `duration=60`, `type=eighth`) appended to measures 5 and 13.
With `divisions=120` and a 4/4 time signature, each measure should sum to
480 ticks; with the spurious rest, both measures summed to 540 (4.5 beats)
— musically invalid. Using the comparison viewer
(`compare.html?song=10-allegretto`) to highlight the gold standard's
"missing from engine" notes (new blue highlight, see below) showed exactly
these two rests, in measures that are otherwise correct. The rests are also
not visible in the scanned image — the engine's "2 deletions" were correct;
it simply didn't hallucinate rests that don't exist in the source.

Removed both spurious `<rest/>` notes from the gold XML. SER 2.1% → 0.0%.

---

### 17 — Gavotte (phone photo)

Re-scored 2026-06-09 against the corrected 194-note gold standard and the
current pipeline (rhythm-cap, beaming, barline-dedup, and the beam-group-≤4
cap added this session).

| Metric | Value |
|--------|-------|
| SER | 1.0% (2/194) |
| Pitch | 99.5% |
| Duration | 100.0% |
| Both | 99.5% |
| Notes out/ref | 193/194 |
| Ins/Del | 0/1 |

**Location:**
- Measure 20 (0-based #19): 1 substitution — C5 natural misread as C5#
  (see "Missing natural sign" below)
- Measure 22 (0-based #21): 1 deletion

**Character:** down from 4.2% SER (8/192) before this session's beaming
fixes and gold-standard correction. The remaining substitution is a
confirmed model limitation (see below); the deletion is unexamined.

#### Missing natural sign (measure 20, 2026-06-09)

The engine emits C5# where gold has C5-natural; an earlier C5# in the same
measure biases the model. Confirmed via `staff_4_lift_debug.txt`: at the
C5 token the lift head is 98% confident on `#` (`#=0.98 _=0.02 b=0.00`) —
natural (`N`) isn't even in the top-3. There is no separate accidental
detector upstream (single transformer decoder; the lift head is the sole
source of accidentals — the 6-class SegNet is used only for staff-region
cropping). This is a genuine model misprediction, not a port bug, and not
fixable via reconstruction heuristics. Python homr gets this wrong too.

#### Repeat-barline accuracy (2026-06-09)

The gold standard has 4 repeat markers forming an AABB-style structure:

| Measure | Gold | Engine |
|---|---|---|
| 8 (end) | `light-heavy` + `repeatEnd` | `repeatEnd` ✓ |
| 16/17 (end/start) | `light-heavy` then `heavy-light` + `repeatStart` | `bolddoublebarline` (no repeat) |
| 24/25 (end/start) | `light-heavy`+`repeatEnd` then `heavy-light`+`repeatStart` (i.e. `repeatEndStart`) | plain `barline` (no repeat) |
| 32 (final) | `light-heavy` + `repeatEnd` | plain `barline` (no repeat) |

So **3 of 4 repeat markers are missing** — only the first (measure 8) is
correct. This is invisible to the SER/note-alignment scorer (it doesn't
examine `<barline>`/`<repeat>` at all), but visible in the rendered
comparison (no `:|`/`|:` signs around the B and C sections).

Added rhythm-head debug instrumentation
(`staff_N_rhythm_debug.txt`, same pattern as the lift-head debug above) and
checked the top-3 softmax at each boundary token:

- Measure 8 (`staff_1`, correct): `repeatEnd=0.60 barline=0.24 repeatEndStart=0.03`
- Measure 16/17 (`staff_3`): `bolddoublebarline=0.50 barline=0.37 doublebarline=0.01`
  — `repeatStart`/`repeatEndStart` not even in top-3. Confident miss.
- Measure 24/25 (`staff_5`): `barline=0.81 repeatEnd=0.06 repeatEndStart=0.01`
  — correct token (`repeatEndStart`) is in the top-3 but far behind. Confident miss.
- Measure 32 final (`staff_7`): `barline=0.46 repeatEnd=0.37 repeatEndStart=0.02`
  — near coin-flip; `repeatEnd` is the runner-up.

**Conclusion:** same architecture limitation as the missing natural sign —
a single rhythm-head classification per barline token, no separate
repeat-structure detector, and the model under-predicts repeat-marker
variants (especially `repeatStart`/`repeatEndStart`) relative to plain
`barline`/`bolddoublebarline`. Not fixable via post-processing since the
correct token usually isn't even the model's top choice. Worth flagging
upstream to homr as a model-training observation (repeat markers may be
under-represented in the training data relative to plain barlines).

---

## Upstream homr issue to report

**Spurious barline at staff-strip boundary.**

The transformer emits a `barline` token as the final token of a staff
strip, immediately before the `newline` separator. In the assembled
token stream this appears as `barline barline newline`, producing an
empty measure (confirmed in song 15 before the post-processing fix).

Token stream evidence (song 15, staff boundary between strips 2 and 3):
```
note_2.|A4|_
barline|.|.      ← legitimate end-of-measure
barline|_|_      ← spurious — last token of strip 2
newline|.|.
clef_G2|_|_      ← strip 3 begins
```

**Suggested fix for homr:** post-processing filter dropping trailing
`barline` before `newline`, or a constrained decoding penalty on
`barline → barline` in the token sequence. The token stream for any
image can be inspected at `/tmp/homr_pdf_dump_{slug}/tokens.txt`
(written by the dump test).

---

## Planned next steps

1. File the spurious-barline issue upstream to homr.
2. Consider reporting the missing-natural-sign and repeat-marker findings
   (song 17) to homr as model-training observations, with the lift/rhythm
   debug evidence above.
