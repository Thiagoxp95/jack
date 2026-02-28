# Screen Recording Subtitles Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add word-level karaoke-style subtitles to screen recordings, with customizable styling and editable transcripts in the video editor.

**Architecture:** Transcription runs after recording stops using FluidAudio's CoreML engine (already a dependency). Word-level timestamps are chunked into display lines, rendered via Core Text during editor preview and export, and composited onto video frames in the existing Metal pipeline. A new Subtitles sidebar panel in the editor lets users control styling, position, and edit transcribed text.

**Tech Stack:** Swift, SwiftUI, FluidAudio (AsrManager/TokenTiming), Core Text, Metal, AVFoundation

**Design doc:** `docs/plans/2026-02-28-screen-recording-subtitles-design.md`

---

### Task 1: Add Subtitle Data Models to RecordingTypes

**Files:**
- Modify: `Sources/KinshasaApp/ScreenRecording/RecordingTypes.swift` (after line 406)
- Test: `Tests/KinshasaAppTests/KinshasaAppTests.swift`

**Step 1: Write tests for subtitle data models**

Add a new test class at the end of the test file:

```swift
final class SubtitleModelTests: XCTestCase {
    func testSubtitleWordCodableRoundTrip() {
        let word = SubtitleWord(
            id: UUID(),
            text: "hello",
            startTime: 1.5,
            endTime: 2.0,
            confidence: 0.95
        )
        let data = try! JSONEncoder().encode(word)
        let decoded = try! JSONDecoder().decode(SubtitleWord.self, from: data)
        XCTAssertEqual(word, decoded)
    }

    func testSubtitleLineSourceTimeSpan() {
        let words = [
            SubtitleWord(id: UUID(), text: "hello", startTime: 1.0, endTime: 1.5, confidence: 0.9),
            SubtitleWord(id: UUID(), text: "world", startTime: 1.6, endTime: 2.1, confidence: 0.85),
        ]
        let line = SubtitleLine(id: UUID(), words: words)
        XCTAssertEqual(line.sourceStart, 1.0)
        XCTAssertEqual(line.sourceEnd, 2.1)
    }

    func testSubtitleLineEmptyWordsReturnsZeroTimes() {
        let line = SubtitleLine(id: UUID(), words: [])
        XCTAssertEqual(line.sourceStart, 0)
        XCTAssertEqual(line.sourceEnd, 0)
    }

    func testSubtitleConfigurationDefaults() {
        let config = SubtitleConfiguration()
        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.position, .bottom)
        XCTAssertEqual(config.audioSource, .microphone)
        XCTAssertEqual(config.fontSize, 24)
        XCTAssertTrue(config.backgroundEnabled)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `cd /Users/txp/Pessoal/actionfy-v2 && swift test --filter SubtitleModelTests 2>&1 | tail -5`
Expected: Compilation error — types not defined yet.

**Step 3: Implement the data models**

Add after line 406 in RecordingTypes.swift:

```swift
// MARK: - Subtitle Types

enum SubtitlePosition: String, Codable, CaseIterable, Sendable {
    case top, middle, bottom
}

enum SubtitleAudioSource: String, Codable, CaseIterable, Sendable {
    case microphone, systemAudio, both
}

struct SubtitleWord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var text: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var confidence: Float

    init(id: UUID = UUID(), text: String, startTime: TimeInterval, endTime: TimeInterval, confidence: Float) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

struct SubtitleLine: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var words: [SubtitleWord]

    var sourceStart: TimeInterval {
        words.first?.startTime ?? 0
    }

    var sourceEnd: TimeInterval {
        words.last?.endTime ?? 0
    }

    init(id: UUID = UUID(), words: [SubtitleWord]) {
        self.id = id
        self.words = words
    }
}

struct SubtitleConfiguration: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var fontFamily: String = ".AppleSystemUIFont"
    var fontSize: CGFloat = 24
    var activeColor: String = "#FFFFFF"
    var inactiveColor: String = "#888888"
    var backgroundColor: String = "#00000080"
    var backgroundEnabled: Bool = true
    var position: SubtitlePosition = .bottom
    var audioSource: SubtitleAudioSource = .microphone
}
```

**Step 4: Run tests to verify they pass**

Run: `cd /Users/txp/Pessoal/actionfy-v2 && swift test --filter SubtitleModelTests 2>&1 | tail -10`
Expected: All 4 tests pass.

**Step 5: Commit**

```bash
git add Sources/KinshasaApp/ScreenRecording/RecordingTypes.swift Tests/KinshasaAppTests/KinshasaAppTests.swift
git commit -m "feat(subtitles): add subtitle data models"
```

---

### Task 2: Extend ParakeetTranscriptionService to Expose Word Timings

**Files:**
- Modify: `Sources/KinshasaApp/ParakeetTranscriptionService.swift`
- Test: `Tests/KinshasaAppTests/KinshasaAppTests.swift`

**Step 1: Write test for extended TranscriptionResult**

```swift
final class TranscriptionResultTests: XCTestCase {
    func testWordTimingStruct() {
        let timing = WordTiming(word: "hello", startTime: 0.5, endTime: 1.0, confidence: 0.9)
        XCTAssertEqual(timing.word, "hello")
        XCTAssertEqual(timing.startTime, 0.5)
        XCTAssertEqual(timing.endTime, 1.0)
        XCTAssertEqual(timing.confidence, 0.9, accuracy: 0.001)
    }

    func testTranscriptionResultContainsTimings() {
        let timings = [
            WordTiming(word: "hello", startTime: 0.5, endTime: 1.0, confidence: 0.9),
            WordTiming(word: "world", startTime: 1.1, endTime: 1.6, confidence: 0.85),
        ]
        let result = ParakeetTranscriptionService.TranscriptionResult(
            text: "hello world",
            backend: "test",
            wordTimings: timings
        )
        XCTAssertEqual(result.wordTimings.count, 2)
        XCTAssertEqual(result.wordTimings[0].word, "hello")
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `cd /Users/txp/Pessoal/actionfy-v2 && swift test --filter TranscriptionResultTests 2>&1 | tail -5`
Expected: Compilation error — `WordTiming` not defined, `wordTimings` not a member.

**Step 3: Modify ParakeetTranscriptionService**

In `ParakeetTranscriptionService.swift`:

1. Add `WordTiming` struct (around line 13):

```swift
struct WordTiming: Sendable {
    let word: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Float
}
```

2. Update `TranscriptionResult` (lines 14-17) to include word timings:

```swift
struct TranscriptionResult: Sendable {
    let text: String
    let backend: String
    let wordTimings: [WordTiming]
}
```

3. In the `CoreMLParakeetEngine.transcribe()` method (~line 125), after getting the `ASRResult`, extract token timings:

```swift
let wordTimings: [WordTiming] = (result.tokenTimings ?? []).map { timing in
    WordTiming(
        word: timing.token,
        startTime: timing.startTime,
        endTime: timing.endTime,
        confidence: timing.confidence
    )
}
```

4. Update the return statement to include `wordTimings`:

```swift
return TranscriptionResult(text: result.text, backend: "CoreML Streaming", wordTimings: wordTimings)
```

5. Update any other places that construct `TranscriptionResult` to include `wordTimings: []` as a default.

**Step 4: Run tests to verify they pass**

Run: `cd /Users/txp/Pessoal/actionfy-v2 && swift test --filter TranscriptionResultTests 2>&1 | tail -10`
Expected: All 2 tests pass.

**Step 5: Commit**

```bash
git add Sources/KinshasaApp/ParakeetTranscriptionService.swift Tests/KinshasaAppTests/KinshasaAppTests.swift
git commit -m "feat(subtitles): expose word-level timings from ParakeetTranscriptionService"
```

---

### Task 3: Implement Subtitle Chunking Algorithm

**Files:**
- Create: `Sources/KinshasaApp/ScreenRecording/SubtitleChunker.swift`
- Test: `Tests/KinshasaAppTests/KinshasaAppTests.swift`

**Step 1: Write tests for the chunking algorithm**

```swift
final class SubtitleChunkerTests: XCTestCase {
    func testChunkEmptyTimingsReturnsEmpty() {
        let lines = SubtitleChunker.chunk(wordTimings: [])
        XCTAssertTrue(lines.isEmpty)
    }

    func testChunkSingleWordReturnsOneLine() {
        let timings = [WordTiming(word: "hello", startTime: 0.5, endTime: 1.0, confidence: 0.9)]
        let lines = SubtitleChunker.chunk(wordTimings: timings)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].words.count, 1)
        XCTAssertEqual(lines[0].words[0].text, "hello")
    }

    func testChunkBreaksAtLongPause() {
        // Words with a 500ms gap between "world" and "this" (> 300ms threshold)
        let timings = [
            WordTiming(word: "hello", startTime: 0.0, endTime: 0.4, confidence: 0.9),
            WordTiming(word: "world", startTime: 0.5, endTime: 0.9, confidence: 0.9),
            WordTiming(word: "this", startTime: 1.4, endTime: 1.8, confidence: 0.9),
            WordTiming(word: "works", startTime: 1.9, endTime: 2.3, confidence: 0.9),
        ]
        let lines = SubtitleChunker.chunk(wordTimings: timings, maxWordsPerLine: 10, pauseThreshold: 0.3)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].words.count, 2) // "hello world"
        XCTAssertEqual(lines[1].words.count, 2) // "this works"
    }

    func testChunkBreaksAtMaxWords() {
        // 12 words with no pauses — should break at maxWordsPerLine
        var timings: [WordTiming] = []
        for i in 0..<12 {
            let start = Double(i) * 0.5
            timings.append(WordTiming(word: "word\(i)", startTime: start, endTime: start + 0.4, confidence: 0.9))
        }
        let lines = SubtitleChunker.chunk(wordTimings: timings, maxWordsPerLine: 8)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].words.count, 8)
        XCTAssertEqual(lines[1].words.count, 4)
    }

    func testChunkLineTimesMatchWordBoundaries() {
        let timings = [
            WordTiming(word: "hello", startTime: 1.0, endTime: 1.5, confidence: 0.9),
            WordTiming(word: "world", startTime: 1.6, endTime: 2.1, confidence: 0.85),
        ]
        let lines = SubtitleChunker.chunk(wordTimings: timings)
        XCTAssertEqual(lines[0].sourceStart, 1.0)
        XCTAssertEqual(lines[0].sourceEnd, 2.1)
    }

    func testChunkFiltersEmptyTokens() {
        let timings = [
            WordTiming(word: "", startTime: 0.0, endTime: 0.1, confidence: 0.5),
            WordTiming(word: "hello", startTime: 0.2, endTime: 0.6, confidence: 0.9),
            WordTiming(word: " ", startTime: 0.7, endTime: 0.8, confidence: 0.3),
            WordTiming(word: "world", startTime: 0.9, endTime: 1.3, confidence: 0.85),
        ]
        let lines = SubtitleChunker.chunk(wordTimings: timings)
        XCTAssertEqual(lines[0].words.count, 2)
        XCTAssertEqual(lines[0].words[0].text, "hello")
        XCTAssertEqual(lines[0].words[1].text, "world")
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `cd /Users/txp/Pessoal/actionfy-v2 && swift test --filter SubtitleChunkerTests 2>&1 | tail -5`
Expected: Compilation error — `SubtitleChunker` not defined.

**Step 3: Implement SubtitleChunker**

Create `Sources/KinshasaApp/ScreenRecording/SubtitleChunker.swift`:

```swift
import Foundation

enum SubtitleChunker {
    /// Groups word timings into display lines.
    /// Breaks at pauses > `pauseThreshold` or when word count reaches `maxWordsPerLine`.
    static func chunk(
        wordTimings: [WordTiming],
        maxWordsPerLine: Int = 10,
        pauseThreshold: TimeInterval = 0.3
    ) -> [SubtitleLine] {
        let filtered = wordTimings.filter { !$0.word.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !filtered.isEmpty else { return [] }

        var lines: [SubtitleLine] = []
        var currentWords: [SubtitleWord] = []

        for (index, timing) in filtered.enumerated() {
            let word = SubtitleWord(
                text: timing.word,
                startTime: timing.startTime,
                endTime: timing.endTime,
                confidence: timing.confidence
            )

            // Check if we should start a new line
            if !currentWords.isEmpty {
                let gap = timing.startTime - filtered[index - 1].endTime
                let atMaxWords = currentWords.count >= maxWordsPerLine
                let atPause = gap >= pauseThreshold

                if atMaxWords || atPause {
                    lines.append(SubtitleLine(words: currentWords))
                    currentWords = []
                }
            }

            currentWords.append(word)
        }

        // Flush remaining words
        if !currentWords.isEmpty {
            lines.append(SubtitleLine(words: currentWords))
        }

        return lines
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `cd /Users/txp/Pessoal/actionfy-v2 && swift test --filter SubtitleChunkerTests 2>&1 | tail -10`
Expected: All 6 tests pass.

**Step 5: Commit**

```bash
git add Sources/KinshasaApp/ScreenRecording/SubtitleChunker.swift Tests/KinshasaAppTests/KinshasaAppTests.swift
git commit -m "feat(subtitles): add subtitle chunking algorithm"
```

---

### Task 4: Add Subtitle State to VideoEditorController

**Files:**
- Modify: `Sources/KinshasaApp/ScreenRecording/VideoEditorController.swift`
- Test: `Tests/KinshasaAppTests/KinshasaAppTests.swift`

**Step 1: Write tests for editor subtitle state**

```swift
@MainActor
final class SubtitleEditorTests: XCTestCase {
    private func makeEditor() -> VideoEditorController {
        let session = RecordingSession(
            sessionDirectory: URL(fileURLWithPath: "/tmp/test-\(UUID())"),
            captureSourceType: .screen,
            fps: .thirty
        )
        return VideoEditorController(session: session)
    }

    func testSubtitleConfigDefaultsToDisabled() {
        let editor = makeEditor()
        XCTAssertFalse(editor.subtitleConfig.enabled)
    }

    func testSetSubtitleLinesUpdatesState() {
        let editor = makeEditor()
        let words = [SubtitleWord(text: "hello", startTime: 0, endTime: 0.5, confidence: 0.9)]
        let lines = [SubtitleLine(words: words)]
        editor.subtitleLines = lines
        XCTAssertEqual(editor.subtitleLines.count, 1)
    }

    func testSubtitleLineAtTimeReturnsCorrectLine() {
        let editor = makeEditor()
        let line1 = SubtitleLine(words: [
            SubtitleWord(text: "hello", startTime: 0.0, endTime: 0.5, confidence: 0.9),
            SubtitleWord(text: "world", startTime: 0.6, endTime: 1.0, confidence: 0.9),
        ])
        let line2 = SubtitleLine(words: [
            SubtitleWord(text: "foo", startTime: 2.0, endTime: 2.5, confidence: 0.9),
        ])
        editor.subtitleLines = [line1, line2]

        let found = editor.subtitleLineAt(time: 0.7)
        XCTAssertEqual(found?.words.first?.text, "hello")

        let found2 = editor.subtitleLineAt(time: 2.2)
        XCTAssertEqual(found2?.words.first?.text, "foo")

        let notFound = editor.subtitleLineAt(time: 1.5)
        XCTAssertNil(notFound)
    }

    func testDeleteSubtitleWord() {
        let editor = makeEditor()
        let word1 = SubtitleWord(text: "hello", startTime: 0, endTime: 0.5, confidence: 0.9)
        let word2 = SubtitleWord(text: "world", startTime: 0.6, endTime: 1.0, confidence: 0.9)
        editor.subtitleLines = [SubtitleLine(words: [word1, word2])]

        editor.deleteSubtitleWord(word1.id)
        XCTAssertEqual(editor.subtitleLines[0].words.count, 1)
        XCTAssertEqual(editor.subtitleLines[0].words[0].text, "world")
    }

    func testDeleteLastWordRemovesEntireLine() {
        let editor = makeEditor()
        let word = SubtitleWord(text: "hello", startTime: 0, endTime: 0.5, confidence: 0.9)
        editor.subtitleLines = [SubtitleLine(words: [word])]

        editor.deleteSubtitleWord(word.id)
        XCTAssertTrue(editor.subtitleLines.isEmpty)
    }

    func testUpdateSubtitleWordText() {
        let editor = makeEditor()
        let word = SubtitleWord(text: "helo", startTime: 0, endTime: 0.5, confidence: 0.9)
        editor.subtitleLines = [SubtitleLine(words: [word])]

        editor.updateSubtitleWord(word.id, text: "hello")
        XCTAssertEqual(editor.subtitleLines[0].words[0].text, "hello")
    }

    func testSubtitleStateIncludedInUndoRedo() {
        let editor = makeEditor()
        let word = SubtitleWord(text: "hello", startTime: 0, endTime: 0.5, confidence: 0.9)
        editor.subtitleLines = [SubtitleLine(words: [word])]
        editor.pushSnapshot()

        editor.subtitleLines = []
        editor.pushSnapshot()
        XCTAssertTrue(editor.subtitleLines.isEmpty)

        editor.undo()
        XCTAssertEqual(editor.subtitleLines.count, 1)
        XCTAssertEqual(editor.subtitleLines[0].words[0].text, "hello")
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `cd /Users/txp/Pessoal/actionfy-v2 && swift test --filter SubtitleEditorTests 2>&1 | tail -5`
Expected: Compilation error — properties and methods not defined on VideoEditorController.

**Step 3: Add subtitle state and methods to VideoEditorController**

In `VideoEditorController.swift`:

1. Add state properties (around line 100, with other state properties):

```swift
// MARK: - Subtitles
var subtitleLines: [SubtitleLine] = []
var subtitleConfig: SubtitleConfiguration = .init()
var isTranscribing: Bool = false
```

2. Add subtitle query method:

```swift
func subtitleLineAt(time: TimeInterval) -> SubtitleLine? {
    subtitleLines.first { time >= $0.sourceStart && time <= $0.sourceEnd }
}
```

3. Add word editing methods:

```swift
func updateSubtitleWord(_ wordId: UUID, text: String) {
    for lineIndex in subtitleLines.indices {
        if let wordIndex = subtitleLines[lineIndex].words.firstIndex(where: { $0.id == wordId }) {
            subtitleLines[lineIndex].words[wordIndex].text = text
            return
        }
    }
}

func deleteSubtitleWord(_ wordId: UUID) {
    for lineIndex in subtitleLines.indices.reversed() {
        if let wordIndex = subtitleLines[lineIndex].words.firstIndex(where: { $0.id == wordId }) {
            subtitleLines[lineIndex].words.remove(at: wordIndex)
            if subtitleLines[lineIndex].words.isEmpty {
                subtitleLines.remove(at: lineIndex)
            }
            return
        }
    }
}
```

4. Add `subtitleLines` and `subtitleConfig` to `EditorSnapshot` (lines 6-26) and to `makeSnapshot()`/`applySnapshot()` methods.

5. Add subtitle persistence in `load()` and save methods — load from `subtitles.json` and `subtitle_config.json` in the session directory.

**Step 4: Run tests to verify they pass**

Run: `cd /Users/txp/Pessoal/actionfy-v2 && swift test --filter SubtitleEditorTests 2>&1 | tail -10`
Expected: All 7 tests pass.

**Step 5: Commit**

```bash
git add Sources/KinshasaApp/ScreenRecording/VideoEditorController.swift Tests/KinshasaAppTests/KinshasaAppTests.swift
git commit -m "feat(subtitles): add subtitle state, editing, and undo/redo to VideoEditorController"
```

---

### Task 5: Add Transcription Trigger to VideoEditorController

**Files:**
- Modify: `Sources/KinshasaApp/ScreenRecording/VideoEditorController.swift`

**Step 1: Add the transcribe method**

This method calls `ParakeetTranscriptionService`, chunks the result, and stores it. The method needs access to the session's audio URLs.

```swift
func transcribeAudio() async {
    guard !isTranscribing else { return }
    isTranscribing = true
    defer { isTranscribing = false }

    pushSnapshot()

    do {
        let audioURL: URL
        switch subtitleConfig.audioSource {
        case .microphone:
            audioURL = session.micAudioURL
        case .systemAudio:
            audioURL = session.systemAudioURL
        case .both:
            audioURL = try await mixAudioTracks(
                mic: session.micAudioURL,
                system: session.systemAudioURL
            )
        }

        let service = ParakeetTranscriptionService()
        let config = ParakeetTranscriptionService.Configuration()
        try await service.prepare(configuration: config)
        let result = try await service.transcribe(audioFileURL: audioURL, configuration: config)
        subtitleLines = SubtitleChunker.chunk(wordTimings: result.wordTimings)
        subtitleConfig.enabled = true
        saveSubtitles()
    } catch {
        print("Transcription failed: \(error)")
    }
}
```

Note: The `mixAudioTracks` helper creates a temporary AVMutableComposition merging mic + system audio into a single file for transcription. Implement as a private helper using AVFoundation.

**Step 2: Add subtitle persistence helpers**

```swift
private func saveSubtitles() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    if let data = try? encoder.encode(subtitleLines) {
        try? data.write(to: session.sessionDirectory.appendingPathComponent("subtitles.json"))
    }
    if let data = try? encoder.encode(subtitleConfig) {
        try? data.write(to: session.sessionDirectory.appendingPathComponent("subtitle_config.json"))
    }
}

private func loadSubtitles() {
    let subtitlesURL = session.sessionDirectory.appendingPathComponent("subtitles.json")
    let configURL = session.sessionDirectory.appendingPathComponent("subtitle_config.json")
    if let data = try? Data(contentsOf: subtitlesURL) {
        subtitleLines = (try? JSONDecoder().decode([SubtitleLine].self, from: data)) ?? []
    }
    if let data = try? Data(contentsOf: configURL) {
        subtitleConfig = (try? JSONDecoder().decode(SubtitleConfiguration.self, from: data)) ?? .init()
    }
}
```

Call `loadSubtitles()` at the end of the existing `load()` method (after cursor data loading, ~line 253).
Call `saveSubtitles()` in the existing save flow (wherever session data is persisted before export).

**Step 3: Build to verify compilation**

Run: `cd /Users/txp/Pessoal/actionfy-v2 && swift build 2>&1 | tail -10`
Expected: Build succeeds.

**Step 4: Commit**

```bash
git add Sources/KinshasaApp/ScreenRecording/VideoEditorController.swift
git commit -m "feat(subtitles): add transcription trigger and subtitle persistence"
```

---

### Task 6: Add Subtitles Sidebar Panel to VideoEditorView

**Files:**
- Modify: `Sources/KinshasaApp/ScreenRecording/VideoEditorView.swift`

**Step 1: Add the subtitles panel to the sidebar**

In the right sidebar ScrollView (around line 193), add `subtitlesPanel` after `audioTracksPanel`:

```swift
ScrollView {
    VStack(spacing: 16) {
        if editor.hasWebcamRecording {
            webcamPanel
        }
        cursorEffectsPanel
        audioTracksPanel
        subtitlesPanel  // NEW
    }
}
.frame(width: 280)
```

**Step 2: Implement the subtitles panel**

Add after the audio tracks panel definition (~line 1232):

```swift
// MARK: - Subtitles Panel

@ViewBuilder
private var subtitlesPanel: some View {
    DisclosureGroup("Subtitles") {
        VStack(alignment: .leading, spacing: 12) {
            // Enable toggle
            Toggle("Enable Subtitles", isOn: $editor.subtitleConfig.enabled)
                .toggleStyle(.switch)
                .controlSize(.small)

            // Audio source picker
            HStack {
                Text("Audio Source")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $editor.subtitleConfig.audioSource) {
                    Text("Microphone").tag(SubtitleAudioSource.microphone)
                    Text("System Audio").tag(SubtitleAudioSource.systemAudio)
                    Text("Both").tag(SubtitleAudioSource.both)
                }
                .labelsHidden()
                .fixedSize()
            }

            // Transcribe button
            Button(action: {
                Task { await editor.transcribeAudio() }
            }) {
                HStack {
                    if editor.isTranscribing {
                        ProgressView()
                            .controlSize(.small)
                        Text("Transcribing...")
                    } else {
                        Image(systemName: "waveform")
                        Text(editor.subtitleLines.isEmpty ? "Transcribe" : "Re-transcribe")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(editor.isTranscribing)

            if editor.subtitleConfig.enabled && !editor.subtitleLines.isEmpty {
                Divider()

                // Position picker
                HStack {
                    Text("Position")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $editor.subtitleConfig.position) {
                        Text("Top").tag(SubtitlePosition.top)
                        Text("Middle").tag(SubtitlePosition.middle)
                        Text("Bottom").tag(SubtitlePosition.bottom)
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                // Font size
                HStack {
                    Text("Size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $editor.subtitleConfig.fontSize) {
                        Text("Small").tag(CGFloat(18))
                        Text("Medium").tag(CGFloat(24))
                        Text("Large").tag(CGFloat(32))
                        Text("Extra Large").tag(CGFloat(42))
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                // Background toggle
                Toggle("Background Box", isOn: $editor.subtitleConfig.backgroundEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Divider()

                // Scrollable transcript
                Text("Transcript")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(editor.subtitleLines) { line in
                            subtitleLineRow(line)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .padding(.vertical, 4)
    }
    .padding(8)
    .background(RoundedRectangle(cornerRadius: 10).fill(EditorColors.card))
}

@ViewBuilder
private func subtitleLineRow(_ line: SubtitleLine) -> some View {
    HStack(alignment: .top, spacing: 6) {
        Text(formatTime(line.sourceStart))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .frame(width: 36, alignment: .trailing)

        Text(line.words.map(\.text).joined(separator: " "))
            .font(.caption)
            .foregroundStyle(.primary)
            .lineLimit(2)
    }
    .padding(.vertical, 2)
}

private func formatTime(_ seconds: TimeInterval) -> String {
    let mins = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return String(format: "%d:%02d", mins, secs)
}
```

**Step 3: Build to verify compilation**

Run: `cd /Users/txp/Pessoal/actionfy-v2 && swift build 2>&1 | tail -10`
Expected: Build succeeds.

**Step 4: Commit**

```bash
git add Sources/KinshasaApp/ScreenRecording/VideoEditorView.swift
git commit -m "feat(subtitles): add subtitles sidebar panel to video editor"
```

---

### Task 7: Add Subtitle Text Renderer (Core Text)

**Files:**
- Create: `Sources/KinshasaApp/ScreenRecording/SubtitleRenderer.swift`
- Test: `Tests/KinshasaAppTests/KinshasaAppTests.swift`

This renders subtitle text into a `CGImage` that can be composited onto video frames during both preview and export.

**Step 1: Write tests**

```swift
final class SubtitleRendererTests: XCTestCase {
    func testRenderReturnsImageWithCorrectSize() {
        let words = [
            SubtitleWord(text: "hello", startTime: 0.0, endTime: 0.5, confidence: 0.9),
            SubtitleWord(text: "world", startTime: 0.6, endTime: 1.0, confidence: 0.9),
        ]
        let line = SubtitleLine(words: words)
        let config = SubtitleConfiguration(enabled: true, fontSize: 24)

        let image = SubtitleRenderer.renderLine(
            line,
            currentTime: 0.3,
            canvasSize: CGSize(width: 1920, height: 1080),
            config: config
        )
        XCTAssertNotNil(image)
        XCTAssertGreaterThan(image!.width, 0)
        XCTAssertGreaterThan(image!.height, 0)
    }

    func testRenderReturnsNilForEmptyLine() {
        let line = SubtitleLine(words: [])
        let config = SubtitleConfiguration(enabled: true)
        let image = SubtitleRenderer.renderLine(
            line,
            currentTime: 0,
            canvasSize: CGSize(width: 1920, height: 1080),
            config: config
        )
        XCTAssertNil(image)
    }

    func testVerticalPositionForBottom() {
        let y = SubtitleRenderer.verticalOffset(
            position: .bottom,
            textHeight: 40,
            canvasHeight: 1080
        )
        // Should be near the bottom with some padding
        XCTAssertGreaterThan(y, 900)
    }

    func testVerticalPositionForTop() {
        let y = SubtitleRenderer.verticalOffset(
            position: .top,
            textHeight: 40,
            canvasHeight: 1080
        )
        // Should be near the top with some padding
        XCTAssertLessThan(y, 100)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `cd /Users/txp/Pessoal/actionfy-v2 && swift test --filter SubtitleRendererTests 2>&1 | tail -5`
Expected: Compilation error.

**Step 3: Implement SubtitleRenderer**

Create `Sources/KinshasaApp/ScreenRecording/SubtitleRenderer.swift`:

```swift
import AppKit
import CoreText
import Foundation

enum SubtitleRenderer {

    /// Renders a subtitle line into a CGImage with per-word karaoke coloring.
    /// Words with startTime <= currentTime are rendered in activeColor, others in inactiveColor.
    static func renderLine(
        _ line: SubtitleLine,
        currentTime: TimeInterval,
        canvasSize: CGSize,
        config: SubtitleConfiguration
    ) -> CGImage? {
        let words = line.words
        guard !words.isEmpty else { return nil }

        let fullText = words.map(\.text).joined(separator: " ")

        // Build attributed string with per-word coloring
        let attributed = NSMutableAttributedString()
        let font = NSFont(name: config.fontFamily, size: config.fontSize)
            ?? NSFont.systemFont(ofSize: config.fontSize, weight: .semibold)

        for (index, word) in words.enumerated() {
            let isActive = currentTime >= word.startTime
            let color = isActive
                ? NSColor(hex: config.activeColor) ?? .white
                : NSColor(hex: config.inactiveColor) ?? .gray

            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]

            if index > 0 {
                attributed.append(NSAttributedString(string: " ", attributes: attrs))
            }
            attributed.append(NSAttributedString(string: word.text, attributes: attrs))
        }

        // Measure text size
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let maxWidth = canvasSize.width * 0.85
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRangeMake(0, attributed.length),
            nil,
            CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude),
            nil
        )

        let padding: CGFloat = config.backgroundEnabled ? 12 : 0
        let imgWidth = Int(ceil(textSize.width + padding * 2))
        let imgHeight = Int(ceil(textSize.height + padding * 2))
        guard imgWidth > 0, imgHeight > 0 else { return nil }

        // Create bitmap context
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: imgWidth,
            height: imgHeight,
            bitsPerComponent: 8,
            bytesPerRow: imgWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        // Draw background box
        if config.backgroundEnabled {
            let bgColor = NSColor(hex: config.backgroundColor) ?? NSColor.black.withAlphaComponent(0.5)
            ctx.setFillColor(bgColor.cgColor)
            let bgRect = CGRect(x: 0, y: 0, width: imgWidth, height: imgHeight)
            let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 8, cornerHeight: 8, transform: nil)
            ctx.addPath(bgPath)
            ctx.fillPath()
        }

        // Draw text
        let textRect = CGRect(x: padding, y: padding, width: textSize.width, height: textSize.height)
        let path = CGMutablePath()
        path.addRect(textRect)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, attributed.length), path, nil)
        CTFrameDraw(frame, ctx)

        return ctx.makeImage()
    }

    /// Returns the Y offset (from top) for subtitle placement.
    static func verticalOffset(position: SubtitlePosition, textHeight: CGFloat, canvasHeight: CGFloat) -> CGFloat {
        let margin: CGFloat = 40
        switch position {
        case .top:
            return margin
        case .middle:
            return (canvasHeight - textHeight) / 2
        case .bottom:
            return canvasHeight - textHeight - margin
        }
    }
}

// MARK: - NSColor hex helper

extension NSColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let length = hexSanitized.count
        if length == 8 {
            // RRGGBBAA
            self.init(
                red: CGFloat((rgb >> 24) & 0xFF) / 255,
                green: CGFloat((rgb >> 16) & 0xFF) / 255,
                blue: CGFloat((rgb >> 8) & 0xFF) / 255,
                alpha: CGFloat(rgb & 0xFF) / 255
            )
        } else if length == 6 {
            // RRGGBB
            self.init(
                red: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1.0
            )
        } else {
            return nil
        }
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `cd /Users/txp/Pessoal/actionfy-v2 && swift test --filter SubtitleRendererTests 2>&1 | tail -10`
Expected: All 4 tests pass.

**Step 5: Commit**

```bash
git add Sources/KinshasaApp/ScreenRecording/SubtitleRenderer.swift Tests/KinshasaAppTests/KinshasaAppTests.swift
git commit -m "feat(subtitles): add Core Text subtitle renderer with karaoke coloring"
```

---

### Task 8: Composite Subtitles in Export Pipeline

**Files:**
- Modify: `Sources/KinshasaApp/ScreenRecording/ExportService.swift`

**Step 1: Pass subtitle data to ExportService**

Add subtitle parameters to the `exportWithEffects()` method signature. The method already receives editor state for cursor, zoom, webcam, and audio effects. Add:

```swift
subtitleLines: [SubtitleLine],
subtitleConfig: SubtitleConfiguration,
```

**Step 2: Add subtitle compositing in the frame processing loop**

In the frame processing loop (after webcam compositing at ~line 694, before frame append at ~line 698):

```swift
// Composite subtitles
if subtitleConfig.enabled, !subtitleLines.isEmpty {
    let sourceTime = timeSeconds  // already computed earlier in the loop
    if let line = subtitleLines.first(where: { sourceTime >= $0.sourceStart && sourceTime <= $0.sourceEnd }) {
        if let subtitleImage = SubtitleRenderer.renderLine(
            line,
            currentTime: sourceTime,
            canvasSize: CGSize(width: outputWidth, height: outputHeight),
            config: subtitleConfig
        ) {
            // Draw subtitle image onto the output pixel buffer
            let subtitleY = SubtitleRenderer.verticalOffset(
                position: subtitleConfig.position,
                textHeight: CGFloat(subtitleImage.height),
                canvasHeight: CGFloat(outputHeight)
            )
            let subtitleX = (CGFloat(outputWidth) - CGFloat(subtitleImage.width)) / 2

            CVPixelBufferLockBaseAddress(outputPB, [])
            defer { CVPixelBufferUnlockBaseAddress(outputPB, []) }

            if let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(outputPB),
                width: outputWidth,
                height: outputHeight,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(outputPB),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                // Core Graphics Y is flipped (origin at bottom-left)
                let flippedY = CGFloat(outputHeight) - subtitleY - CGFloat(subtitleImage.height)
                ctx.draw(subtitleImage, in: CGRect(
                    x: subtitleX,
                    y: flippedY,
                    width: CGFloat(subtitleImage.width),
                    height: CGFloat(subtitleImage.height)
                ))
            }
        }
    }
}
```

This follows the same pattern as the existing webcam and cursor compositing code in ExportService.

**Step 3: Update the call site in UploadQueue/EditorWindowController**

Wherever `exportWithEffects()` is called, pass the subtitle data from the editor:

```swift
editor.subtitleLines,
editor.subtitleConfig,
```

**Step 4: Build to verify compilation**

Run: `cd /Users/txp/Pessoal/actionfy-v2 && swift build 2>&1 | tail -10`
Expected: Build succeeds.

**Step 5: Commit**

```bash
git add Sources/KinshasaApp/ScreenRecording/ExportService.swift
git commit -m "feat(subtitles): composite subtitles in export pipeline"
```

---

### Task 9: Add Subtitle Preview to Metal Renderer

**Files:**
- Modify: `Sources/KinshasaApp/ScreenRecording/MetalVideoRenderer.swift`
- Modify: `Sources/KinshasaApp/ScreenRecording/VideoEditorView.swift` (Metal preview section)

**Step 1: Add subtitle overlay to the preview renderer**

The editor's Metal preview view already renders zoom + cursor effects. Add subtitle rendering as a post-processing step. The approach: render the subtitle CGImage into an MTLTexture and composite it on top of the preview frame.

In `MetalVideoRenderer.swift`, add a method to convert a CGImage to an MTLTexture:

```swift
func makeTexture(from image: CGImage) -> MTLTexture? {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: image.width,
        height: image.height,
        mipmapped: false
    )
    descriptor.usage = [.shaderRead]
    guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }

    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

    if let data = ctx.data {
        texture.replace(
            region: MTLRegionMake2D(0, 0, image.width, image.height),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: image.width * 4
        )
    }
    return texture
}
```

**Step 2: In the VideoEditorView preview rendering path, overlay subtitles**

After the Metal preview renders the frame (zoom + cursor), draw the subtitle CGImage on top using a SwiftUI overlay or by compositing in the existing draw callback:

```swift
// In the preview rendering section of VideoEditorView
if editor.subtitleConfig.enabled, !editor.subtitleLines.isEmpty {
    let time = editor.smoothTime
    if let line = editor.subtitleLineAt(time: time) {
        if let subtitleImage = SubtitleRenderer.renderLine(
            line,
            currentTime: time,
            canvasSize: previewSize,
            config: editor.subtitleConfig
        ) {
            // Convert to NSImage and overlay
            let nsImage = NSImage(cgImage: subtitleImage, size: NSSize(width: subtitleImage.width, height: subtitleImage.height))
            // Render as SwiftUI Image overlay at the correct position
        }
    }
}
```

The exact integration depends on whether the preview uses a Metal layer directly or a SwiftUI Image. Match the existing pattern (the preview already composites cursor and zoom — follow the same approach).

**Step 3: Build and test visually**

Run: `cd /Users/txp/Pessoal/actionfy-v2 && swift build 2>&1 | tail -10`
Expected: Build succeeds. Verify visually by recording a short clip with audio and enabling subtitles in the editor.

**Step 4: Commit**

```bash
git add Sources/KinshasaApp/ScreenRecording/MetalVideoRenderer.swift Sources/KinshasaApp/ScreenRecording/VideoEditorView.swift
git commit -m "feat(subtitles): add subtitle preview overlay in video editor"
```

---

### Task 10: Final Integration and Polish

**Files:**
- Modify: `Sources/KinshasaApp/ScreenRecording/VideoEditorController.swift` (save on config changes)
- Modify: `Sources/KinshasaApp/ScreenRecording/VideoEditorView.swift` (inline text editing)

**Step 1: Auto-save subtitle config changes**

Wire up `subtitleConfig` changes to auto-persist, so users don't lose their styling preferences:

```swift
// In VideoEditorController, observe config changes
func updateSubtitleConfig(_ config: SubtitleConfiguration) {
    subtitleConfig = config
    saveSubtitles()
}
```

**Step 2: Add inline text editing for transcript lines**

In the subtitles sidebar, make transcript lines clickable to edit. Use a `TextField` that appears on click:

```swift
@ViewBuilder
private func subtitleLineRow(_ line: SubtitleLine) -> some View {
    HStack(alignment: .top, spacing: 6) {
        Text(formatTime(line.sourceStart))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .frame(width: 36, alignment: .trailing)

        // Editable text field for each line's combined words
        TextField("", text: Binding(
            get: { line.words.map(\.text).joined(separator: " ") },
            set: { newText in
                // Update words individually based on space-split
                let newWords = newText.split(separator: " ", omittingEmptySubsequences: true)
                for (index, word) in line.words.enumerated() {
                    if index < newWords.count {
                        editor.updateSubtitleWord(word.id, text: String(newWords[index]))
                    }
                }
            }
        ))
        .font(.caption)
        .textFieldStyle(.plain)
    }
    .padding(.vertical, 2)
}
```

**Step 3: Build and run full integration test**

Run: `cd /Users/txp/Pessoal/actionfy-v2 && ./Scripts/compile_and_run.sh --test`
Expected: All tests pass. App builds and runs.

**Step 4: Manual verification checklist**

- [ ] Record a short screen recording with mic audio
- [ ] Open editor, click "Transcribe" in Subtitles panel
- [ ] Verify words appear with timestamps
- [ ] Play video — confirm grey->white karaoke effect in preview
- [ ] Change position (top/middle/bottom) — confirm subtitle moves
- [ ] Change font size — confirm subtitle resizes
- [ ] Toggle background box on/off
- [ ] Edit a transcript line — confirm changes persist
- [ ] Export video — confirm subtitles are burned into the output file
- [ ] Test undo/redo after editing subtitles

**Step 5: Commit**

```bash
git add Sources/KinshasaApp/ScreenRecording/VideoEditorController.swift Sources/KinshasaApp/ScreenRecording/VideoEditorView.swift
git commit -m "feat(subtitles): add inline transcript editing and auto-save"
```

---

## Task Summary

| Task | Description | Files |
|------|------------|-------|
| 1 | Data models (SubtitleWord, SubtitleLine, SubtitleConfiguration) | RecordingTypes.swift |
| 2 | Expose word timings from ParakeetTranscriptionService | ParakeetTranscriptionService.swift |
| 3 | Subtitle chunking algorithm | SubtitleChunker.swift (new) |
| 4 | Subtitle state + editing in VideoEditorController | VideoEditorController.swift |
| 5 | Transcription trigger + persistence | VideoEditorController.swift |
| 6 | Subtitles sidebar panel UI | VideoEditorView.swift |
| 7 | Core Text subtitle renderer | SubtitleRenderer.swift (new) |
| 8 | Export pipeline compositing | ExportService.swift |
| 9 | Editor preview rendering | MetalVideoRenderer.swift, VideoEditorView.swift |
| 10 | Polish: inline editing, auto-save, integration test | VideoEditorController.swift, VideoEditorView.swift |
