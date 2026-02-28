# Screen Recording Subtitles Design

## Overview

Add word-level karaoke-style subtitles to screen recordings. Subtitles are generated from the recording's audio using on-device CoreML transcription (ParakeetTranscriptionService / FluidAudio). Words appear grey and transition to white as they are spoken. Users can customize font, size, color, background, and position, and edit the transcribed text in the video editor.

## Requirements

- Transcription runs **after recording stops**, during editor load
- **Word-by-word** karaoke highlighting (grey -> white at each word's timestamp)
- **1-2 lines** of subtitle text visible at a time, auto-chunked at natural phrase boundaries
- User chooses **audio source**: microphone, system audio, or both
- Subtitles are **editable** in the editor (fix typos, delete words, adjust timing)
- **Position options**: top, middle, bottom (default: bottom center)
- **Styling**: font family, font size, active color, inactive color, background box toggle
- Subtitles **burned into** the exported video via the Metal rendering pipeline

## Data Model

### SubtitleWord

```swift
struct SubtitleWord: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var startTime: TimeInterval  // source time in seconds
    var endTime: TimeInterval    // source time in seconds
    var confidence: Float        // 0.0-1.0 from transcription engine
}
```

### SubtitleLine

Groups words into display chunks (1-2 lines, ~8-12 words, broken at pauses > 300ms).

```swift
struct SubtitleLine: Identifiable, Codable, Equatable {
    let id: UUID
    var words: [SubtitleWord]
    var sourceStart: TimeInterval  // first word's startTime
    var sourceEnd: TimeInterval    // last word's endTime
}
```

### SubtitleConfiguration

```swift
enum SubtitlePosition: String, Codable, CaseIterable {
    case top, middle, bottom
}

enum SubtitleAudioSource: String, Codable, CaseIterable {
    case microphone, systemAudio, both
}

struct SubtitleConfiguration: Codable, Equatable {
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

## Architecture

### Transcription Pipeline

1. User enables subtitles in the editor and clicks "Transcribe"
2. `VideoEditorController` calls `ParakeetTranscriptionService` with the chosen audio file (mic, system, or mixed)
3. The service returns word-level `TokenTiming` data (text, startTime, endTime, confidence) from FluidAudio's `AsrManager`
4. Controller converts `TokenTiming` array into `SubtitleLine` chunks using a chunking algorithm
5. Subtitle data is stored on `VideoEditorController` and saved alongside session data

### Chunking Algorithm

Words are grouped into lines by:
1. Accumulate words until reaching ~8-12 words or exceeding a max character width
2. Prefer breaking at pauses > 300ms between consecutive words
3. Never break mid-word
4. Each line's `sourceStart`/`sourceEnd` spans its contained words

### ParakeetTranscriptionService Changes

The current wrapper discards `TokenTiming` data from `ASRResult`. Extend the service to expose word-level timestamps:

```swift
struct TranscriptionResult: Sendable {
    let text: String
    let backend: String
    let wordTimings: [WordTiming]  // NEW
}

struct WordTiming: Sendable {
    let word: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Float
}
```

### Audio Source Handling

- **Microphone**: Use `session.micAudioURL` directly
- **System audio**: Use `session.systemAudioURL` directly
- **Both**: Mix mic + system audio into a temporary file before transcription (use AVMutableComposition to merge tracks)

## Editor Integration

### VideoEditorController Additions

```swift
// New state
var subtitleLines: [SubtitleLine] = []
var subtitleConfig: SubtitleConfiguration = .init()
var isTranscribing: Bool = false
var transcriptionProgress: Double = 0  // 0.0-1.0

// New methods
func transcribeAudio() async
func rechunkSubtitles()
func updateSubtitleWord(_ wordId: UUID, text: String)
func deleteSubtitleWord(_ wordId: UUID)
func subtitleLineAt(time: TimeInterval) -> SubtitleLine?
```

Subtitle state is included in the undo/redo snapshot system.

### Editor UI - Subtitles Sidebar Panel

New panel in the right sidebar (alongside Cursor Effects, Audio Tracks, Webcam):

```
┌─ Subtitles ─────────────────────────┐
│ [✓] Enable Subtitles                │
│                                     │
│ Audio Source: [Microphone ▾]        │
│ [Transcribe] / [Re-transcribe]      │
│ (progress bar when transcribing)    │
│                                     │
│ ─── Style ───────────────────────── │
│ Position: [Bottom ▾]               │
│ Font: [System ▾]  Size: [24 ▾]    │
│ Active Color: [■ #FFF]             │
│ Inactive Color: [■ #888]           │
│ [✓] Background box                  │
│                                     │
│ ─── Transcript ──────────────────── │
│ 0:02 "Hello everyone, welcome to"   │
│ 0:05 "this demo of our new..."      │
│ (click any line to edit inline)     │
└─────────────────────────────────────┘
```

### Preview Rendering

During editor playback, the Metal preview renderer displays subtitles:
1. Each frame, determine the current `SubtitleLine` based on `smoothTime`
2. For each word in the line, compare `smoothTime` to the word's `startTime`:
   - `smoothTime >= word.startTime` -> active color (white)
   - `smoothTime < word.startTime` -> inactive color (grey)
3. Render text using Core Text into an `MTLTexture`
4. Composite the text texture onto the video frame in the Metal shader

## Export Pipeline

### Metal Shader Integration

The export pipeline already processes frames through a Metal compute shader (zoom + cursor + click highlight). Subtitles add one more compositing layer:

1. For each output frame, determine the timestamp and find the active `SubtitleLine`
2. Render the subtitle text (with per-word active/inactive coloring) into a text texture using Core Text
3. The Metal shader composites the text texture at the configured position (top/middle/bottom)
4. Background box (if enabled) is rendered as a semi-transparent rectangle behind the text

### Subtitle Rendering Uniforms (additions to CompositorUniforms)

```swift
var subtitleEnabled: Float           // 0.0 or 1.0
var subtitlePosition: Float          // 0.0=top, 0.5=middle, 1.0=bottom
var subtitleBackgroundEnabled: Float // 0.0 or 1.0
var subtitleBackgroundColor: SIMD4<Float>
```

The actual text content is passed as a pre-rendered texture (not as uniforms), since Metal shaders cannot rasterize text.

### Text Texture Strategy

Rather than rasterizing text every frame:
1. Pre-render each `SubtitleLine` into two textures: one all-inactive, one all-active
2. Per frame, render the current line's text with correct per-word coloring into a cached texture
3. Cache invalidation only when the active line changes or a word transitions
4. Alternative: pre-render each line into a texture atlas with word boundaries marked, then use the shader to blend between active/inactive colors per-word using UV coordinates

## Segment-Aware Timing

Subtitles respect the timeline's segment editing:
- Disabled segments are skipped (subtitles use `sourceTime(forEditedTime:)` conversion)
- Word timestamps are in source time, matching the existing cursor and zoom keyframe model
- The `editedTime <-> sourceTime` conversion already exists in `VideoEditorController`

## Persistence

Subtitle data is saved to the session directory:
- `subtitles.json` — serialized `[SubtitleLine]` array
- `subtitle_config.json` — serialized `SubtitleConfiguration`
- Loaded when the editor opens, saved on editor close/save

## Component Changes Summary

| Component | Change |
|-----------|--------|
| `RecordingTypes.swift` | Add `SubtitleWord`, `SubtitleLine`, `SubtitleConfiguration`, `SubtitlePosition`, `SubtitleAudioSource` |
| `ParakeetTranscriptionService.swift` | Expose `TokenTiming` word-level data in `TranscriptionResult` |
| `VideoEditorController.swift` | Add subtitle state, transcription trigger, chunking, editing methods, undo/redo |
| `VideoEditorView.swift` | Add Subtitles sidebar panel with styling controls and editable transcript |
| `MetalVideoRenderer.swift` | Text texture rendering, subtitle compositing in preview |
| `ExportService.swift` | Pass subtitle data, render text textures per frame, composite in Metal shader |
| `ZoomCursorCompositor.metal` | Add subtitle texture sampling and blending |

## Out of Scope

- Live transcription during recording (future enhancement)
- Speaker diarization / multi-speaker labels
- SRT/VTT file export (just burned-in subtitles for now)
- Translation or multi-language subtitles
- Animated text transitions beyond the grey->white karaoke effect
