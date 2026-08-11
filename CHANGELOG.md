# Changelog

What changed in each release, written for the person about to install it.
`Scripts/changelog-to-html.sh` turns the section for a version into the
release notes Sparkle shows in the update dialog, so the wording here is
what users actually read — keep it plain, and say what they have to do.

## 1.4.1 — 2026-08-11

### Fixed

- **Your OpenRouter API key now lives in the macOS keychain.** It used to sit
  in Jack's preferences file, which any process running as you could read.
  Jack moves it across the first time you launch this version.
- **A dictation could overwrite your API key.** The dictation shortcut works
  everywhere, including inside Jack's own Settings window — so a capture that
  landed while the key field was focused replaced the key with the transcript,
  and every routed dictation silently became a plain paste from then on. Jack
  no longer types into its own windows; it copies to the clipboard instead and
  says so.
- **A rejected key is now visible.** Settings shows a red dot and the actual
  reason instead of looking identical to a working key, and a failed capture
  says it fell back to pasting rather than failing in silence.

### You may need to do this

If your key was corrupted by the bug above, Jack discards it on upgrade rather
than carrying a broken value forward — Settings will show "No key". Generate a
new one at <https://openrouter.ai/settings/keys> and paste it into Settings to
get routing, cleanup, and AI chat back. A key that is still intact is moved
across for you and needs nothing.

## 1.4.0 — 2026-08-11

- Dictation now routes itself three ways: a todo goes to the todo list, a
  question opens the AI chat, and anything else pastes as before.
- Todos are stored locally instead of in a hosted backend.
- Note mode removed.

## 1.3.1 — 2026-08-10

- Hardened the cleanup prompt so the model tidies your words instead of
  answering them, with a guard for the cases it still gets wrong.
- Model picker now does fuzzy matching.
