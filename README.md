# KinshasaApp

SwiftPM-based macOS app with global voice-to-text dictation powered by local Parakeet.

## What It Does

- Configurable global invocation key (capture any physical key, including side-specific modifiers like Left Command vs Right Command).
- Shortcut modes: `Toggle`, `Hold`, `Double Tap`.
- Floating bubble while listening/transcribing.
- Optional Rive `.riv` listening indicator overlay.
- Records from default microphone.
- Optional output ducking (lower speaker volume while recording).
- Optional background model keep-warm (with plug-in-only mode).
- Installs local Parakeet runtime/model automatically on first run.
- Pastes transcript into the focused input field.

## Prerequisites

- macOS 14+
- Xcode 16+ with Swift 6.2
- Command Line Tools installed (`xcode-select --install`)
- Internet access on first run (to install runtime and download model)

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

- The app auto-installs local `parakeet-mlx` and model files in user data directories.
- `PARAKEET_MODEL` can be used for development overrides.
- Packaged builds use a workspace-unique bundle identifier (`com.actionfy.app.v2.ws...`) to avoid macOS permission/relaunch collisions across multiple clones.

## Project Layout

- `Sources/KinshasaApp/KinshasaApp.swift`: App entry point.
- `Sources/KinshasaApp/ContentView.swift`: Main UI.
- `Sources/KinshasaApp/DictationController.swift`: Orchestration logic.
- `Sources/KinshasaApp/LocalParakeetBootstrapper.swift`: Automatic runtime/model bootstrap.
- `Sources/KinshasaApp/GlobalFnShortcutMonitor.swift`: Global `Fn` shortcut monitor.
- `Sources/KinshasaApp/AudioCaptureService.swift`: Microphone recording.
- `Sources/KinshasaApp/ParakeetTranscriptionService.swift`: Local Parakeet runner.
- `Sources/KinshasaApp/PasteService.swift`: Focused-field paste helper.
- `Sources/KinshasaApp/FloatingBubbleController.swift`: Bubble overlay.

## Packaging

Build release app bundle:

```bash
./Scripts/package_app.sh release
```

Build universal release app bundle:

```bash
ARCHES="arm64 x86_64" ./Scripts/package_app.sh release
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
