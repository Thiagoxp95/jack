# Dictation Cleanup Design

**Date:** 2026-02-28

## Overview

Add LLM-powered transcription cleanup that runs after Parakeet transcription and word replacements, before output (paste/note/todo). Users can toggle it on/off, customize the cleanup prompt, and choose the LLM model.

## Data Flow

```
Transcribe (Parakeet)
  → Word Replacements (local)
  → LLM Cleanup (Convex action via OpenRouter) [if enabled]
  → Output Mode Switch (Paste / Note / Todo)
```

In `DictationController.handleTranscriptionResult`:
1. Trim whitespace, apply word replacements (existing)
2. If `transcriptionCleanupEnabled`, call `ConvexHTTPClient.action("transcription:cleanup", { text, prompt, model })`
3. Replace the transcribed text with the cleaned version
4. Continue to the output mode switch as before

## Settings & Storage

New `UserDefaults` keys in `DictationController`:
- `transcription_cleanup_enabled` (Bool, default `false`) — master toggle
- `transcription_cleanup_prompt` (String) — the user's cleanup prompt
- `transcription_cleanup_model` (String) — selected OpenRouter model ID, default `google/gemini-2.0-flash-001`

Curated model list (hardcoded):
- `google/gemini-2.0-flash-001` (default)
- `openai/gpt-4o-mini`
- `anthropic/claude-3.5-haiku`
- `google/gemini-2.0-flash-thinking`

## Settings UI

In the **Overview** tab, below the transcription model picker:

1. **Toggle** — "Transcription Cleanup" with subtitle "Clean up transcribed text with an LLM"
2. **Model picker** — Dropdown showing the curated model list (visible when cleanup enabled)
3. **Prompt editor** — Multi-line TextEditor for the cleanup prompt (visible when cleanup enabled)

## Backend

New Convex action `transcription:cleanup` in `convex/transcription.ts`:
- Receives `{ text, prompt, model }`
- Calls OpenRouter `/chat/completions` (non-streaming)
- System message = the user's cleanup prompt
- User message = the transcribed text
- Returns the cleaned text string

## Decisions

- **LLM runs on Convex backend** (not client-side) — centralizes LLM logic
- **Non-streaming** — cleanup is fast on short text, no need for SSE
- **Silent wait** — no visible indicator while cleanup runs
- **Applies to all modes** (paste, note, todo) — single integration point in the pipeline
- **Curated model list** — 4 proven models, not the full OpenRouter catalog
- **Simple text area** for prompt editing — no presets
