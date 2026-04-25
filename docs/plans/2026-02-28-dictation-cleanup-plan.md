# Dictation Cleanup Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add LLM-powered transcription cleanup that runs after Parakeet transcription, before output.

**Architecture:** A new Convex action `transcription:cleanup` calls OpenRouter with the user's custom prompt and selected model. On the Swift side, `DictationController.handleTranscriptionResult` calls this action after word replacements when the cleanup toggle is enabled. A new settings card in the Overview tab lets users toggle cleanup, pick a model, and edit their prompt.

**Tech Stack:** Swift/SwiftUI (client), Convex/TypeScript (backend), OpenRouter API (LLM gateway)

---

### Task 1: Create Convex `transcription.ts` with cleanup action

**Files:**
- Create: `convex/transcription.ts`

**Step 1: Create the Convex action**

```typescript
import { v } from "convex/values";
import { action } from "./_generated/server";

export const cleanup = action({
  args: {
    text: v.string(),
    prompt: v.string(),
    model: v.string(),
  },
  handler: async (_ctx, args) => {
    const apiKey = process.env.OPENROUTER_API_KEY;
    if (!apiKey) throw new Error("OPENROUTER_API_KEY not configured");

    const response = await fetch(
      "https://openrouter.ai/api/v1/chat/completions",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${apiKey}`,
        },
        body: JSON.stringify({
          model: args.model,
          messages: [
            { role: "system", content: args.prompt },
            { role: "user", content: args.text },
          ],
        }),
      },
    );

    if (!response.ok) {
      const errText = await response.text();
      throw new Error(`OpenRouter error ${response.status}: ${errText}`);
    }

    const json = await response.json();
    const content = json.choices?.[0]?.message?.content;
    if (typeof content !== "string") {
      throw new Error("No content in OpenRouter response");
    }

    return content.trim();
  },
});
```

**Step 2: Verify Convex picks up the new module**

Run: `cd /Users/txp/Pessoal/jack-v2 && npx convex dev --once`
Expected: No errors, `transcription:cleanup` action registered

**Step 3: Commit**

```bash
git add convex/transcription.ts
git commit -m "feat: add transcription cleanup Convex action"
```

---

### Task 2: Add cleanup settings to DictationController

**Files:**
- Modify: `Sources/JackApp/DictationController.swift`

**Step 1: Add the CleanupModel enum after `TranscriptionModelChoice` (after line 37)**

```swift
enum CleanupModelChoice: String, CaseIterable, Identifiable {
    case geminiFlash = "google/gemini-2.0-flash-001"
    case gpt4oMini = "openai/gpt-4o-mini"
    case claudeHaiku = "anthropic/claude-3.5-haiku"
    case geminiThinking = "google/gemini-2.0-flash-thinking"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .geminiFlash: return "Gemini 2.0 Flash"
        case .gpt4oMini: return "GPT-4o Mini"
        case .claudeHaiku: return "Claude 3.5 Haiku"
        case .geminiThinking: return "Gemini 2.0 Flash Thinking"
        }
    }
}
```

**Step 2: Add DefaultsKey entries (inside `DefaultsKey` enum, after line 364)**

```swift
static let cleanupEnabled = "transcription_cleanup_enabled"
static let cleanupPrompt = "transcription_cleanup_prompt"
static let cleanupModel = "transcription_cleanup_model"
```

**Step 3: Add published properties (after `selectedTranscriptionModel` ~line 240)**

```swift
@Published var cleanupEnabled: Bool {
    didSet {
        UserDefaults.standard.set(cleanupEnabled, forKey: DefaultsKey.cleanupEnabled)
    }
}
@Published var cleanupPrompt: String {
    didSet {
        UserDefaults.standard.set(cleanupPrompt, forKey: DefaultsKey.cleanupPrompt)
    }
}
@Published var cleanupModel: CleanupModelChoice {
    didSet {
        UserDefaults.standard.set(cleanupModel.rawValue, forKey: DefaultsKey.cleanupModel)
    }
}
```

**Step 4: Initialize from UserDefaults in `init` (after `selectedTranscriptionModel` init ~line 529)**

```swift
cleanupEnabled = defaults.object(forKey: DefaultsKey.cleanupEnabled) as? Bool ?? false
cleanupPrompt = defaults.string(forKey: DefaultsKey.cleanupPrompt) ?? ""
let storedCleanupModel = defaults.string(forKey: DefaultsKey.cleanupModel) ?? ""
cleanupModel = CleanupModelChoice(rawValue: storedCleanupModel) ?? .geminiFlash
```

**Step 5: Commit**

```bash
git add Sources/JackApp/DictationController.swift
git commit -m "feat: add cleanup settings properties to DictationController"
```

---

### Task 3: Integrate cleanup into handleTranscriptionResult

**Files:**
- Modify: `Sources/JackApp/DictationController.swift`

**Step 1: Make `handleTranscriptionResult` async and add cleanup call**

Change `handleTranscriptionResult` (line 1563) from:

```swift
private func handleTranscriptionResult(_ text: String) {
```

to:

```swift
private func handleTranscriptionResult(_ text: String) async {
```

After line 1574 (`let cleaned = ...`), before `lastTranscript = cleaned`, insert:

```swift
var finalText = cleaned
if cleanupEnabled, !cleanupPrompt.isEmpty {
    do {
        let token = try await ConvexHTTPClient.getToken()
        let result = try await ConvexHTTPClient.action(
            function: "transcription:cleanup",
            args: [
                "text": cleaned,
                "prompt": cleanupPrompt,
                "model": cleanupModel.rawValue,
            ],
            token: token
        )
        if let cleanedUp = result as? String, !cleanedUp.isEmpty {
            finalText = cleanedUp
        }
    } catch {
        // If cleanup fails, fall through with original text
        print("Transcription cleanup failed: \(error.localizedDescription)")
    }
}
lastTranscript = finalText
```

Then replace all references to `cleaned` after that point with `finalText` in the switch block (lines 1577-1619).

**Step 2: Update all call sites to use `await`**

There are 4 call sites (lines 1384, 1408, 1451, 1476). Each currently reads:

```swift
handleTranscriptionResult(someText)
```

Change each to:

```swift
await handleTranscriptionResult(someText)
```

These are already inside `Task { @MainActor in ... }` blocks, so `await` is valid.

**Step 3: Build and verify**

Run: `swift build` from the project root
Expected: Compiles without errors

**Step 4: Commit**

```bash
git add Sources/JackApp/DictationController.swift
git commit -m "feat: integrate LLM cleanup into transcription pipeline"
```

---

### Task 4: Add cleanup settings UI to ContentView

**Files:**
- Modify: `Sources/JackApp/ContentView.swift`

**Step 1: Add cleanup settings card after the "Transcription Model" card (after line 610)**

```swift
// 5b. Transcription Cleanup
settingsCard(title: "Transcription Cleanup", subtitle: "Clean up transcribed text with an LLM before output.") {
    Toggle("Enable cleanup", isOn: $controller.cleanupEnabled)

    if controller.cleanupEnabled {
        Picker("Model", selection: $controller.cleanupModel) {
            ForEach(CleanupModelChoice.allCases) { model in
                Text(model.title).tag(model)
            }
        }
        .pickerStyle(.menu)

        VStack(alignment: .leading, spacing: 4) {
            Text("Cleanup Prompt")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $controller.cleanupPrompt)
                .font(.body)
                .frame(minHeight: 80, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        }
    }
}
```

**Step 2: Build and verify**

Run: `swift build` from the project root
Expected: Compiles without errors

**Step 3: Commit**

```bash
git add Sources/JackApp/ContentView.swift
git commit -m "feat: add transcription cleanup settings UI"
```

---

### Task 5: Manual testing

**Steps:**
1. Launch the app
2. Go to Overview settings
3. Verify the "Transcription Cleanup" card appears below the Transcription Model card
4. Toggle it on — model picker and prompt editor should appear
5. Select a model, paste in a cleanup prompt
6. Toggle it off and on again — settings should persist
7. Record a dictation in Paste mode — verify text gets cleaned up before paste
8. Record in Voice Note mode — verify cleaned text is saved
9. Record in Todo mode — verify cleaned text is sent to todo processing
10. Toggle cleanup off — verify transcription works as before (no cleanup)
11. Test with an empty prompt — cleanup should be skipped (guard `!cleanupPrompt.isEmpty`)
