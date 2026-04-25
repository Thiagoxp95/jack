# JackApp

SwiftPM-based macOS app with global voice-to-text dictation powered by local CoreML Parakeet.

## What It Does

- Configurable global invocation key (capture any physical key, including side-specific modifiers like Left Command vs Right Command).
- Shortcut modes: `Toggle`, `Hold`, `Double Tap`.
- Floating bubble while listening/transcribing.
- Optional Rive `.riv` listening indicator overlay.
- Records from default microphone.
- Optional output ducking (lower speaker volume while recording).
- Optional background model keep-warm (with plug-in-only mode).
- Downloads local CoreML Parakeet models automatically on first run.
- Pastes transcript into the focused input field.
- Optional in-session Voice Note mode: while recording, press the configured key to save transcription to daily markdown notes at `~/Documents/Jack Notes/YYYY-MM-DD.md`.

## Prerequisites

- macOS 14+
- Xcode 16+ with Swift 6.2
- Command Line Tools installed (`xcode-select --install`)
- Internet access on first run (to download CoreML model files)

## Quick Start

1. Build:

```bash
swift build
```

2. Run tests:

```bash
swift test
```

3. Package + launch:

```bash
./Scripts/compile_and_run.sh
```

4. On first launch, grant:

- Input Monitoring permission (global `Fn`/`Globe` shortcut)
- Accessibility permission (global shortcut + auto-paste)
- Microphone permission (recording)

5. Wait for initial model setup to complete (one-time).

## Notes

- The app uses `FluidAudio` CoreML models (`parakeet-tdt-0.6b-v2-coreml` by default).
- `KINSHASA_COREML_MODEL` (or legacy `PARAKEET_MODEL`) can override model selection (`v2`/`v3`).
- Packaged builds use a workspace-unique bundle identifier (`com.jack.app.v2.ws...`) to avoid macOS permission/relaunch collisions across multiple clones.

## Project Layout

- `Sources/JackApp/JackApp.swift`: App entry point.
- `Sources/JackApp/ContentView.swift`: Main UI.
- `Sources/JackApp/DictationController.swift`: Orchestration logic.
- `Sources/JackApp/LocalParakeetBootstrapper.swift`: CoreML model bootstrap/config.
- `Sources/JackApp/GlobalFnShortcutMonitor.swift`: Global `Fn` shortcut monitor.
- `Sources/JackApp/AudioCaptureService.swift`: Microphone recording.
- `Sources/JackApp/ParakeetTranscriptionService.swift`: CoreML streaming transcription service.
- `Sources/JackApp/PasteService.swift`: Focused-field paste helper.
- `Sources/JackApp/FloatingBubbleController.swift`: Bubble overlay.

## Packaging

Build release app bundle:

```bash
./Scripts/package_app.sh release
```

Build universal release app bundle:

```bash
ARCHES="arm64 x86_64" ./Scripts/package_app.sh release
```

## Stable Dev Permissions (Recommended)

If you use ad-hoc signing, macOS privacy permissions (Input Monitoring / Accessibility / Microphone) may need to be re-approved after rebuilds.

Use a stable development signing identity instead:

```bash
./Scripts/setup_dev_signing.sh
./Scripts/compile_and_run.sh
```

`Scripts/compile_and_run.sh` and `Scripts/package_app.sh` now auto-detect an available code-signing identity and only fall back to ad-hoc when none is configured.  
You can still force a specific identity with:

```bash
export APP_IDENTITY="Apple Development: Your Name (TEAMID)"
```

If permissions get into a bad state during development, reset them for the currently built bundle ID:

```bash
./Scripts/reset_permissions.sh --all
```

Or only microphone:

```bash
./Scripts/reset_permissions.sh --microphone
```

## Optional Signing / Notarization

Create dev signing cert:

```bash
./Scripts/setup_dev_signing.sh
```

Notarized release flow:

```bash
./Scripts/sign-and-notarize.sh
```

Required vars for notarization:

- `APP_STORE_CONNECT_API_KEY_P8`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_IDENTITY`
