# homr_flutter

On-device OMR Flutter app. Phases 0–6 complete; Phase 7 (faithful port of
homr's anchor+fragment staff detection) complete — see
`docs/pipeline_investigation.md`. The detection port lives in
`lib/pipeline/homr/` and is validated against the Python `homr` install as an
oracle via `tool/validate_*.dart`. See `docs/homr_flutter_integration.md` for
the full build plan.

## Dev notes

- **Wireless debugging requires the phone to be unlocked** for a full reload to take effect. If the screen doesn't update after a hot restart, unlock the device.
- Debug mode over WiFi shows a blank white screen until the Dart VM Service handshake completes — if it hangs, the Mac firewall is likely blocking the return port. See the wireless debug section in the integration doc.
- Release mode is the practical way to test on-device performance; the 15 s pipeline budget is measured in release.

## Running integration tests

```bash
flutter test integration_test/phase5_end_to_end_test.dart
flutter test integration_test/benchmark_omr_test.dart
```

## Saving test images from the app

The Review Scan screen has a **"Save for testing"** button in debug and profile builds (`!kReleaseMode`). Use **profile mode** to get it on a physical device without needing the Mac attached — iOS 14+ blocks debug builds from launching off the home screen.

```bash
flutter run --profile -d <iphone-udid>
```

The button writes:
- `{name}.png` — resized colour original (1920 px wide, before thresholding)
- `{name}_bw.png` — binarized version (what the pipeline actually sees)

`UIFileSharingEnabled` is set in Info.plist, so saved files appear in Finder:

1. Plug in iPhone (UDID `<iphone-udid>`)
2. Open Finder → sidebar → the iPhone → **Files** tab → **Homr Flutter**
3. Drag the PNGs out to `assets/test_images/`
