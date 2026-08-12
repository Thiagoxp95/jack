# Changelog

What changed in each release, written for the person about to install it.
`Scripts/changelog-to-html.sh` turns the section for a version into the
release notes Sparkle shows in the update dialog, so the wording here is
what users actually read — keep it plain, and say what they have to do.

## 1.4.4 — 2026-08-12

### Fixed

- **The AI chat works again.** Pressing A on the pill after a dictation opened
  the chat panel but never sent your question — it sat there saying "No chats
  yet". Chat was still talking to a backend that stopped accepting requests
  when accounts were removed, and every failure along the way was silent. Chats
  now live on this Mac and stream straight from OpenRouter with your own key,
  the same way todos moved local. Existing conversations were never reachable,
  so there is nothing to migrate.
- **Failures in chat now say so.** A missing or rejected key, or a model that
  will not answer, shows up in the panel instead of leaving you with an empty
  window.
- **The voice meter tracks your voice for the whole dictation.** The bars used
  to flatten out partway through — the animation was being starved rather than
  the audio being misread.
- **The pill no longer shows a dead button.** It split into three droplets when
  there were only ever two things to press: AI and Todo. The third was blank
  and swallowed clicks. There are two now, and they match the pill's own height
  as it comes apart.

## 1.4.3 — 2026-08-11

### Added

- **Smart routing can be turned off.** Settings → Smart Routing → "Enable smart
  routing". With it off, every dictation pastes where your cursor is and the
  pill afterwards still offers Todo and AI, so the same two destinations are one
  keypress away — you decide instead of a model. Nothing is sent to a routing
  model, and the paste lands as soon as the transcript does, without waiting on
  a round trip.

## 1.4.2 — 2026-08-11

### Fixed

- **Jack now checks for updates on its own.** It looks when you launch it and
  every five minutes after that, so a new version turns up without you opening
  the menu bar and asking. Sparkle refuses to schedule anything more often than
  hourly and quietly rounds a shorter interval up, so Jack keeps its own timer.
- **Reopening Jack checks for an update.** It used to resume a countdown from
  the last check instead, so quitting and relaunching to pick up a new version
  told you nothing.

This is the last release you have to fetch by hand. Everything in 1.4.1 below
is included.

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
