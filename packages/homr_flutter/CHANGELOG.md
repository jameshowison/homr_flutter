## 0.1.0

First versioned release, as a dependency for violin_practice_companion; not yet
published to pub.dev.

- `OmrOrchestrator(models: …)` recognises a page (`recognise`) or several as one
  piece (`recogniseMultiPage`), returning MusicXML 4.0.
- Models are supplied by the app (`OmrModels`); the package ships none.
  `tool/fetch_models.py` downloads and verifies homr's release.
- Input is resized to exactly 1920 px wide before CLAHE, as Python homr does.
- Experimental image helpers in `package:homr_flutter/preprocessing.dart`.
