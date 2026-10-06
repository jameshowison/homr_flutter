# homr_flutter

On-device OMR (Optical Music Recognition) for Flutter: a Dart port of
[homr](https://github.com/liebharc/homr). Phases 0–7 complete — see
`docs/pipeline_investigation.md` and `docs/homr_flutter_integration.md`.

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

## OMR accuracy (Suzuki Book 1)

Evaluated against ground-truth MusicXML on iPhone 17 simulator (2026-06-09).
18 test cases (14 songs, 4 multi-photo variants): **17/18 perfect** (SER=0%).

Full results: `docs/omr_evaluation/current_status.md`.  
Residual issues and investigation notes: `docs/omr_evaluation/remaining_issues.md`.

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
