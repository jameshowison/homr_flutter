# Issue text for gitlab.com/chrisspen/abc-music

The three patch files named below were written for this upstream report and are not
kept in this repository.

**Title:** Suzuki Violin Book 1: several bars have invalid total durations
(dotted-half encoded as `5`, stray `z` rest)

**Body:**

While building an OMR pipeline validated against the MusicXML generated from
these `.abc` sources (via `abc2xml`), three bars in `suzuki-violin-book-1`
were found to have an invalid total duration for their stated time signature.
In each case, two independent OMR systems (a from-scratch Dart port and the
upstream Python `homr`) agree with each other but disagree with the
`abc2xml`-generated MusicXML in exactly these bars — and the engraved PDF
score does not show the extra/altered note either, confirming the `.abc`
source itself has the typo.

## 1. `10-allegretto.abc` — two bars sum to 4.5 beats in 4/4 (`M:C`)

Line 6 ends `... .D2 z .D.E |` and line 8 ends `... E2 z!mf! !0!D!>)!E |`.
Each spurious `z` (eighth rest) pushes the bar from 8 eighth-notes (4/4) to 9
(4.5 beats). The rest does not appear in the engraved score.

Patch: `abc_bug_10_allegretto.patch`

## 2. `14-minuet-no-2.abc` — two bars sum to 2.5 beats in 3/4 (`M:3/4`)

Line 8 and line 14 both end `... c2 dcBc | A5 |`. `A5` is a 5-eighth note
(2.5 beats); the bar needs 6 eighths (3 beats), i.e. a dotted half = `A6`.

Patch: `abc_bug_14_minuet_no_2.patch`

## 3. `15-minuet-no-3.abc` — one bar sums to 2.5 beats in 3/4 (`M:3/4`)

Line 8 ends `... F2 (GA)BG | {B}A5 |`. Same defect as #2: `{B}A5` should be
`{B}A6` (grace note `B` + dotted-half `A`).

Patch: `abc_bug_15_minuet_no_3.patch`

---

All three patches apply cleanly to the current `suzuki-violin-book-1/*.abc`
files (verified with `git apply --check`). After applying, the corresponding
`.xml` files should be regenerated with `abc2xml` — the regenerated XML
should then match the manually-corrected gold standards already in
[homr_flutter `assets/ground_truth/`](../../assets/ground_truth/)
(`10-allegretto.xml`, `14-minuet-no-2.xml`, `15-minuet-no-3.xml`).

Happy to open these as separate small MRs instead of one issue if preferred.
