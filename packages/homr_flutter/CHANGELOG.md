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
