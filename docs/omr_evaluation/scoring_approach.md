# OMR agreement scoring

**Created:** 2026-06-06
**Implementation:** `lib/eval/musicxml_scoring.dart`
**Tests:** `test/musicxml_scoring_test.dart`
**Used by:** `integration_test/suzuki_book1_sweep_test.dart`

---

## Why not positional comparison

The old metric walked `ref[i]` vs `engine[i]` index-by-index. A single dropped
or extra note shifts every downstream note by one, so one real error reads as
dozens of mismatches. The reported percentages then say nothing about *how
wrong* the output is or *where* it went wrong. (This is exactly what made
17-gavotte look like 20.8% when the pipeline output actually matches Python
homr at 97.9% — the divergence is one structural shift, not 150 wrong notes.)

The fix is **sequence alignment**: model the output as a sequence with
insertions, deletions, and substitutions relative to the reference, and score
the aligned pairs. This is the standard OMR/ASR/OCR approach (Symbol/Word/Char
Error Rate).

## Core principle: score each thing in the scope it lives in

Music notation is layered. A note is a local event; a key or time signature is a
span-level context that applies across many measures. So they are scored as
**separate streams**:

| Scope | Attributes | How scored |
|-------|-----------|------------|
| Per note (inside a measure) | step, octave, **effective alteration**, duration (type + dots) | note-level alignment within each matched measure |
| Per note (glyph) | drawn accidental (♯/♭/♮) | tracked separately as a sub-metric |
| Span-level context | key signature, time signature, clef | compared per matched measure (in-effect value) |
| Structure | measure count, barlines/repeats | measure-level insertions / deletions |

## Hierarchical alignment (measures, then notes)

1. **Align measures first** with Needleman–Wunsch, where the cost between two
   measures is the normalized note-level edit distance between them. A dropped
   barline (two reference measures read as one) becomes a single measure-level
   edit instead of a cascade, and you get "measure 14 is where it broke" for
   free.
2. **Align notes within each matched measure pair**, again Needleman–Wunsch,
   with a cost dominated by pitch (`0.7·pitchWrong + 0.3·durWrong`) so notes are
   matched on identity, not position. Substitution is cheaper than a
   delete+insert for 1-to-1 regions, so genuine insertions/deletions only appear
   where the note counts actually differ.

Reference is always the first argument; an unmatched reference note is a
**deletion** (missing), an unmatched engine note is an **insertion** (extra).

## Effective alteration (why accidentals ride with the measure)

A note's sounding pitch depends on its measure context: an accidental persists
to the end of its measure and is cancelled by the barline, and the key signature
supplies a default. So each note's **effective alteration** is resolved as:

```
explicit <alter> on the note   (overrides, and persists in the measure)
  else a prior accidental on the same step+octave in this measure
  else the key-signature default for that step
```

Pitch agreement is then compared on `(step, octave, effectiveAlter)` — i.e.
sounding pitch — which is robust to whether a source writes the accidental as a
glyph or leaves it implied by the key signature.

**Empirical note for this repo:** abc2xml ground truth, the Python-homr
references, and the Dart engine all use the *explicit* convention (every
key-affected note carries an explicit `<alter>`, verified: zero bare F's in a
1-sharp key). The effective-alter rule above is correct for that convention and
also for a key-implied source, so the comparison is convention-independent.

The **drawn accidental** is scored separately (`accidental%`): among aligned
pitched pairs where either side drew an accidental, did both draw the same one?
This separates "right sounding note" (musical correctness) from "detected the
accidental glyph" (OMR symbol recognition), and absorbs courtesy/cautionary
accidental disagreements that don't change the pitch.

## Context errors propagate (by design)

Key/time/clef are scored on their own streams, but they are *not* netted out of
pitch. If you computed effective pitch and the key signature is wrong, the notes
it affects will also count as pitch errors — which is correct, because the
output really does specify the wrong notes. The separate `key%` tells you the
root cause; the per-measure drill-down shows the correlation.

## Reported metrics

Per piece (and per measure for drill-down):

- **SER** — `(substitutions_with_error + insertions + deletions) / refNotes`.
  One headline number; lower is better.
- **pitch% / dur% / both%** — over matched (aligned, non-gap) note pairs.
  `pitch` = effective sounding pitch; `both` = pitch and duration.
- **step% / octave% / alter%** — over matched *pitched* pairs (rests excluded),
  so you can see whether errors are octave (the historical failure mode) vs
  spelling vs duration.
- **accidental%** — drawn-glyph agreement (see above).
- **ins / del** — extra / missing notes (the honest count signal, unlike a
  cascaded percentage).
- **key% / time% / clef%** — context agreement over matched measures.
- **measure ins / del** — structural (barline/measure) edits.
- **diverging measures** — `formatReport` lists every non-clean measure as
  `ref#→eng#: sub=… ins=… del=… ctx[…]` so you jump straight to the problem bar.

## What this does NOT do (and the gavotte caveat)

Alignment **localizes** a structural mismatch; it does not **resolve** one. If
one side unfolds repeats and the other writes them once, that is a real
representational difference — it will show up as a clean block of measure
insertions/deletions, but you must normalize repeats consistently (unfold both,
or neither) *before* comparing for the numbers to mean "recognition accuracy".
For 17-gavotte specifically the right move is to reconcile the abc2xml ground
truth (192 notes, repeats written once) with the photographed edition / the
Python-homr reference (193) — not to change the pipeline. See
`allegretto_gavotte_handoff.md`.

Monophonic Suzuki violin is effectively a 1-D note sequence, so sequence
alignment is sufficient here. Polyphonic / multi-voice scores would call for
tree-edit-distance (TEDn) or MV2H-style metrics instead.
