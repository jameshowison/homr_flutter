## 0.3.2

- A time signature over nothing but rests gets the commonest top digit for
  its denominator (4/4, 2/2, 6/8) instead of the next one's. Borrowing made
  the next time signature a restatement, so a 4/4 rest then a 3/4 rest came
  out as 3/4 throughout, the printed 3/4 lost.

## 0.3.1

- Write a multi-measure rest of n bars as n bars of whole-bar rest
  (`<rest measure="yes"/>`), not one bar with `<multiple-rest>n`. The model
  gives the rest one bar, so the renderer folded the n−1 bars after it — the
  music — into the rest: a tune's first bars disappeared behind a "5". Real
  bars also give playback the silence.

## 0.3.0

- Keep the time signatures the model reads, not just the first, so a piece
  that changes meter (3/4 → 4/4 → 2/4 …) keeps its changes. A time-signature
  token in the middle of a bar, or one restating the last with no note
  between, is still dropped as a mis-fire.
- The model reads only the denominator; the top digit is now the median bar
  length of the stretch each time signature governs, not of the whole piece.
  A piece half in 3/4 and half in 4/4 used to come out "7/4". Multi-measure
  rests no longer count as bars (a time signature over rests takes the next
  stretch's meter), and a length that isn't a whole number of beats is
  written in smaller ones (7/8, never 7/4).

## 0.2.0

- Require `xml` ^7.0.1 (was ^6.0.0), so apps can use `pdf` 3.13 and
  `printing` 5.15, which need it. No change to the MusicXML written.

## 0.1.2

- Write ties. The model has no tie token (homr's training data maps MusicXML
  `<tied>` and kern ties to `slurStart`/`slurStop`), so every tie came out as
  a `<slur>`: drawn right, but played as two struck notes. A slur from one
  note to the very next in its staff and voice, at the same pitch, is now
  written as `<tie>` + `<tied>`, unless either note has an articulation
  (portato with tenuto marks stays a slur). A note tied over a barline is not
  given its accidental again.

## 0.1.1

- Draw accidentals. Each note's `<alter>` (the sounding pitch the model
  predicts) is now accompanied by an `<accidental>` wherever a sign is printed:
  where the alteration differs from the key signature and the earlier notes in
  the bar. Before, no `<accidental>` was written at all, so renderers that take
  MusicXML literally (Verovio) drew an A♯ in G major as a plain A.
- `<alter>` is written between `<step>` and `<octave>`, as MusicXML requires
  (it came after `<octave>`).

## 0.1.0

First versioned release, as a dependency for violin_practice_companion; not yet
published to pub.dev.

- `OmrOrchestrator(models: …)` recognises a page (`recognise`) or several as one
  piece (`recogniseMultiPage`), returning MusicXML 4.0.
- Models are supplied by the app (`OmrModels`); the package ships none.
  `tool/fetch_models.py` downloads and verifies homr's release.
- Input is resized to exactly 1920 px wide before CLAHE, as Python homr does.
- Experimental image helpers in `package:homr_flutter/preprocessing.dart`.
