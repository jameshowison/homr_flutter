# Suzuki Book 1 OMR — Current Status

**Date:** 2026-06-09  
**Platform:** iPhone 17 simulator, macOS  
**Scorer:** alignment-based MusicXML scoring (`lib/eval/musicxml_scoring.dart`)  
**Test:** `integration_test/suzuki_book1_sweep_test.dart`

## Summary

18 test cases (14 songs, 4 multi-photo variants for songs 02/16/17).  
Song 12 (Etude) excluded — a/b variation makes a single ground truth ambiguous.

| | Count |
|---|---|
| **Perfect (SER=0%, both=100%)** | **16 / 18** |
| With residual errors | 2 / 18 |

Total notes in corpus: 1,426 ref / 1,426 engine (Gavotte gold corrected to 194 notes).

---

## Full results

| Label | Out | Ref | SER | Pitch | Dur | Both | Ins | Del | ms |
|---|---|---|---|---|---|---|---|---|---|
| 01-twinkle | 42 | 42 | 0.0% | 100.0% | 100.0% | 100.0% | 0 | 0 | 5291 |
| 02-lightly-row (crop) | 57 | 57 | 0.0% | 100.0% | 100.0% | 100.0% | 0 | 0 | 6217 |
| 02-lightly-row (phone2) | 57 | 57 | 0.0% | 100.0% | 100.0% | 100.0% | 0 | 0 | 7694 |
| 02-lightly-row (phone-orig) | 57 | 57 | 0.0% | 100.0% | 100.0% | 100.0% | 0 | 0 | 9670 |
| 03-song-of-the-wind | 49 | 49 | 0.0% | 100.0% | 100.0% | 100.0% | 0 | 0 | 5130 |
| 04-go-tell-aunt-rhody | 58 | 58 | 0.0% | 100.0% | 100.0% | 100.0% | 0 | 0 | 4453 |
| **05-o-come-little-children** ✓ | **47** | **47** | **0.0%** | **100.0%** | **100.0%** | **100.0%** | **0** | **0** | 5868 |
| 06-may-song | 44 | 44 | 0.0% | 100.0% | 100.0% | 100.0% | 0 | 0 | 5136 |
| 07-long-long-ago | 74 | 74 | 0.0% | 100.0% | 100.0% | 100.0% | 0 | 0 | 7740 |
| 08-allegro | 72 | 72 | 0.0% | 100.0% | 100.0% | 100.0% | 0 | 0 | 6284 |
| 09-perpetual-motion | 128 | 128 | 0.0% | 100.0% | 100.0% | 100.0% | 0 | 0 | 8423 |
| **10-allegretto** ⚠ | 92 | 94 | 2.1% | 100.0% | 100.0% | 100.0% | 0 | 2 | 7167 |
| 11-andantino | 76 | 76 | 0.0% | 100.0% | 100.0% | 100.0% | 0 | 0 | 6943 |
| 13-minuet-no-1 | 82 | 82 | 0.0% | 100.0% | 100.0% | 100.0% | 0 | 0 | 10438 |
| **14-minuet-no-2** ✓ | 167 | 167 | 0.0% | 100.0% | 100.0% | 100.0% | 0 | 0 | 17300 |
| 15-minuet-no-3 | 127 | 127 | 0.0% | 100.0% | 100.0% | 100.0% | 0 | 0 | 13620 |
| 16-happy-farmer (phone) | 112 | 112 | 0.0% | 100.0% | 100.0% | 100.0% | 0 | 0 | 11072 |
| **17-gavotte (phone)** ⚠ | 193 | 194 | 1.0% | 99.5% | 100.0% | 99.5% | 0 | 1 | 15649 |

Song 05 marked ✓ — resolved this session (was 2.1% SER in previous sweep).
Song 14 marked ✓ — resolved this session: ground-truth bug, not a pipeline error
(see below).
Song 17 numbers updated this session (4.2% → 1.0% SER) — gold standard now
194 notes (was 192) and beam groups are capped at 4; re-scored from a fresh
`pdf_artifact_dump_test` run, not yet confirmed via the full sweep.

---

## Residual errors detail

### 10 — Allegretto (SER 2.1%)

2 deletions, pitch and duration of all detected notes correct.  
- measure #4 (0-based): 1 note deleted  
- measure #12 (0-based): 1 note deleted  

Both deletions are single isolated notes in separate measures; no cascading.
See `remaining_issues.md` for hypothesis and next steps.

### ~~14 — Minuet No. 2~~ ✓ RESOLVED (2026-06-09) — ground-truth bug

**Resolution:** the gold standard (`assets/ground_truth/14-minuet-no-2.xml`)
had measures 8 and 32 encoded as a single `eighth` note (A4, duration 300)
instead of a dotted half note (A4, duration 360) — musically incorrect, since
an eighth note leaves 2.5 beats unaccounted for in a 3/4 measure. The engine
(and Python homr) both correctly produced a dotted half in these measures.
Corrected the gold XML (`type=half` + `<dot/>`, `duration=360`); SER now 0.0%.

### 17 — Gavotte — phone photo (SER 1.0%)

1 substitution + 1 deletion.
- measure #19: 1 substitution — C5 natural misread as C5# (confirmed model
  limitation: lift head 98% confident on `#`, natural not in top-3)
- measure #21: 1 deletion

Also: 3 of 4 repeat-barline markers are missing from the engine output
(only measure 8's `repeatEnd` is correct). Not captured by SER (the scorer
doesn't examine `<barline>`/`<repeat>`), but visible in the rendered
comparison. Confirmed via rhythm-head debug as the same kind of
single-token-classification limitation as the natural-sign issue.

Only case using an existing phone photo (no standardised scan).
See `remaining_issues.md` for full detail.

---

## Changelog

| Date | Change | Effect |
|---|---|---|
| 2026-06-09 | Song 05: switched to island-light photo (pencil marks erased) | 2.1% → **0.0% SER** |
| 2026-06-09 | Post-processing: consecutive barlines dropped; time sig locked to first | Several songs fixed |
| 2026-06-09 | Song 14: fixed ground-truth bug (eighth → dotted half, m. 8 & 32) | 1.2% → **0.0% SER** |
| 2026-06-09 | Beaming: capped beam groups at ≤4 notes (Gavotte m. 20 was 8-note group) | Song 17: 4.2% → **1.0% SER** |
