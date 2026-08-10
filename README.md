# Jack

Jack is a macOS voice-to-text dictation app. Press a global shortcut, speak, and the transcript is pasted into whatever field has focus — transcription runs fully on-device using a local CoreML Parakeet model (via [FluidAudio](https://github.com/FluidInference/FluidAudio)).

On top of dictation, Jack includes:

- **LLM transcript cleanup** — optionally post-process raw transcripts through any OpenRouter model for punctuation, filler-word removal, and formatting.
- **Notes** — voice notes saved to daily markdown files (`~/Documents/Jack Notes/YYYY-MM-DD.md`), with optional cloud sync into spaces.
- **Todos** — a todo mode with kanban board, confirmation cards, and sync.
- **Auto mode** — press the auto switch key while recording and an OpenRouter model decides whether the capture is a note or a todo, using the transcript, OCR text from any screenshots you grabbed, and the frontmost app/window.
- **Chat** — an AI chat side sheet backed by a Convex + OpenRouter backend.
- **Knowledge base** — a local vector store over your dictations, searchable from an MCP server.

Core dictation works entirely offline with no account. Cloud features (chat, spaces/todos sync, cloud transcription) are optional and require a self-hosted backend — see [Bring your own keys](#bring-your-own-keys).

## Building

Requirements:

- macOS 14+
- Xcode 16+ / Swift 6 toolchain (`xcode-select --install` for Command Line Tools)
- Internet access on first run (the app downloads CoreML model files automatically)

Build and run:

```bash
swift build                      # build
swift test                       # run tests
./Scripts/compile_and_run.sh     # package the .app and launch it
```

The `FluidAudio` dependency is resolved by SwiftPM from GitHub ([FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio)).

On first launch, grant:

- Input Monitoring (global shortcut)
- Accessibility (global shortcut + auto-paste)
- Microphone (recording)

Then wait for the one-time model download to complete.

### Shortcut and dictation features

- Configurable global invocation key (any physical key, including side-specific modifiers like Left vs Right Command).
- Shortcut modes: `Toggle`, `Hold`, `Double Tap`.
- Floating bubble / Siri-style orb while listening and transcribing.
- Optional output ducking (lower speaker volume while recording).
- Optional background model keep-warm.
- `KINSHASA_COREML_MODEL` (or legacy `PARAKEET_MODEL`) environment variable can override model selection (`v2`/`v3`).

## Bring your own keys

Jack is open source, but the backend it ships pointing at is the maintainer's deployment. To use the optional features, supply your own keys:

### Transcript cleanup and auto mode (OpenRouter)

Paste an [OpenRouter](https://openrouter.ai/keys) key into **Overview → OpenRouter**. It's stored on your Mac and used for direct calls to `openrouter.ai` — no backend involved. Pick models separately for **Transcription Cleanup** and **Smart Routing (Auto Mode)**; the picker lists OpenRouter's live catalog.

### Cloud features (chat, cloud transcription, spaces/todos sync)

The app has no login — it runs local-first out of the box. Cloud features require self-hosting the Convex backend in `convex/`:

1. Run `npx convex dev` in the repo root — this provisions a Convex deployment and writes its URLs to `.env.local` (see `.env.example`).
2. In the Convex dashboard, set the environment variables `OPENROUTER_API_KEY` and `OPENAI_API_KEY` (used for chat and cloud transcription).
3. Point the app at your deployment via the `AppConfig` overrides — either environment variables or Info.plist keys:

| Environment variable | Info.plist key | Value |
| --- | --- | --- |
| `JACK_CONVEX_URL` | `JackConvexURL` | Convex cloud URL (`https://….convex.cloud`) |
| `JACK_CONVEX_SITE_URL` | `JackConvexSiteURL` | Convex site URL (`https://….convex.site`) |

Note: the bundled `convex/` functions were written against an authenticated schema; most still require an identity and will reject anonymous calls. Until the backend is reworked for anonymous/local use, cloud features degrade gracefully (they simply stay silent) and everything local — dictation, cleanup and auto mode with your own OpenRouter key, notes, the knowledge base — works without it. See `Sources/JackApp/Auth/AppConfig.swift` and `convex/README.md`.

## Auto-updates

The packaged app updates itself via [Sparkle](https://sparkle-project.org): updates download silently in the background and a **Restart to update** card appears at the bottom of the sidebar when ready (there's also "Check for Updates…" in the status-bar menu). Releases and the appcast are served from GitHub. See `docs/RELEASING.md`.

## Packaging

```bash
./Scripts/package_app.sh release                         # release app bundle
ARCHES="arm64 x86_64" ./Scripts/package_app.sh release   # universal build
```

Packaged builds use a workspace-unique bundle identifier (`com.jack.app.v2.ws...`) to avoid macOS permission/relaunch collisions across multiple clones.

## Stable dev permissions (recommended)

With ad-hoc signing, macOS privacy permissions may need re-approval after every rebuild. Use a stable development signing identity instead:

```bash
./Scripts/setup_dev_signing.sh
./Scripts/compile_and_run.sh
```

`compile_and_run.sh` and `package_app.sh` auto-detect an available code-signing identity and fall back to ad-hoc only when none is configured. Force a specific identity with:

```bash
export APP_IDENTITY="Apple Development: Your Name (TEAMID)"
```

Reset permissions for the current bundle ID if they get into a bad state:

```bash
./Scripts/reset_permissions.sh --all        # everything
./Scripts/reset_permissions.sh --microphone # just microphone
```

## Signing / notarization

```bash
./Scripts/setup_dev_signing.sh     # create dev signing cert
./Scripts/sign-and-notarize.sh     # notarized release flow
```

Required variables for notarization: `APP_STORE_CONNECT_API_KEY_P8`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_IDENTITY`.

## Project layout

- `Sources/JackApp/` — the SwiftPM macOS app (entry point `JackApp.swift`, orchestration in `DictationController.swift`).
- `convex/` — the optional Convex backend (chat, sync, cloud transcription). See `convex/README.md`.
- `Scripts/` — build, packaging, signing, and release tooling.
- `docs/plans/` — design and implementation plans for past features.

## License

MIT — see [LICENSE](LICENSE).
