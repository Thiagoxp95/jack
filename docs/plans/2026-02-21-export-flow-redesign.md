# Export Flow Redesign Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move export settings + progress into the editor window as a sheet, add NSSavePanel for file location, and remove the broken export state from ContentView.

**Architecture:** ExportDialogView becomes a self-contained sheet inside VideoEditorView that handles settings selection, NSSavePanel file picking, and progress display. Export orchestration moves from RecordingSessionController into the dialog. The `.exporting` state is removed from the global recording state machine.

**Tech Stack:** SwiftUI, AppKit (NSSavePanel), AVFoundation (ExportService)

---

### Task 1: Remove `.exporting` from RecordingState and clean up references

**Files:**
- Modify: `Sources/KinshasaApp/ScreenRecording/RecordingTypes.swift:21` (remove `.exporting` case)
- Modify: `Sources/KinshasaApp/ContentView.swift:432-438` (remove `.exporting` case block)
- Modify: `Sources/KinshasaApp/ScreenRecording/RecordingSessionController.swift:386-428` (remove `startExport`, `exportProgress`)

**Step 1: Remove `.exporting` from RecordingState enum**

In `RecordingTypes.swift`, delete the `.exporting` case from the enum:

```swift
enum RecordingState: String, Equatable {
    case idle
    case setup
    case countdown
    case recording
    case paused
    case stopped
    case editing
    // .exporting removed
}
```

**Step 2: Remove `.exporting` case from ContentView**

In `ContentView.swift`, delete lines 432-438 (the `case .exporting:` block with the progress bar).

**Step 3: Remove `startExport` and `exportProgress` from RecordingSessionController**

In `RecordingSessionController.swift`:
- Delete the entire `startExport(editor:)` method (lines 386-426)
- Delete the `exportProgress` property (line 428)

**Step 4: Remove `onExport` from EditorWindowController**

In `EditorWindowController.swift`:
- Remove the `onExport` parameter from `show()`
- Remove the `onExport` closure from the `VideoEditorView` init
- The signature becomes: `func show(session:onDone:)`

```swift
func show(
    session: RecordingSession,
    onDone: @escaping @MainActor () -> Void
) {
    if window != nil { return }

    let editor = VideoEditorController(session: session)
    self.editorController = editor

    let editorView = VideoEditorView(
        editor: editor,
        onDone: { [weak self] in
            self?.hide()
            onDone()
        }
    )
    // ... rest unchanged
}
```

**Step 5: Update the `editorWindow.show()` call site in RecordingSessionController**

Find the call around line 348 and remove the `onExport:` argument:

```swift
editorWindow.show(
    session: session,
    onDone: { [weak self] in
        self?.finishEditing()
    }
)
```

**Step 6: Build and verify**

Run: `swift build`
Expected: Build succeeds (VideoEditorView will need its `onExport` removed too — next task)

**Step 7: Commit**

```bash
git add Sources/KinshasaApp/ScreenRecording/RecordingTypes.swift \
       Sources/KinshasaApp/ContentView.swift \
       Sources/KinshasaApp/ScreenRecording/RecordingSessionController.swift \
       Sources/KinshasaApp/ScreenRecording/EditorWindowController.swift
git commit -m "refactor: remove .exporting state and export logic from RecordingSessionController"
```

---

### Task 2: Rewrite ExportDialogView with phases, NSSavePanel, and progress

**Files:**
- Modify: `Sources/KinshasaApp/ScreenRecording/ExportDialogView.swift` (full rewrite)

**Step 1: Rewrite ExportDialogView**

Replace the entire file with a phased export dialog that handles settings, file picking, exporting, and error states:

```swift
import SwiftUI
import AppKit
import os

// MARK: - ExportPhase

enum ExportPhase: Equatable {
    case settings
    case exporting
    case done(URL)
    case error(String)
}

// MARK: - ExportDialogView

struct ExportDialogView: View {
    @Bindable var editor: VideoEditorController

    // MARK: - State

    @State private var codec: VideoCodec = .h264
    @State private var quality: ExportQuality = .high
    @State private var resolution: ExportResolution = .original
    @State private var phase: ExportPhase = .settings
    @State private var progress: Double = 0
    @State private var exportTask: Task<Void, Never>?

    // MARK: - Closures

    var onDismiss: () -> Void

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch phase {
            case .settings:
                settingsContent
            case .exporting:
                exportingContent
            case .done(let url):
                doneContent(url: url)
            case .error(let message):
                errorContent(message: message)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    // MARK: - Settings Phase

    @ViewBuilder
    private var settingsContent: some View {
        Text("Export Recording")
            .font(.title2)
            .fontWeight(.semibold)

        Divider()

        // Codec picker
        VStack(alignment: .leading, spacing: 6) {
            Text("Codec")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Picker("Codec", selection: $codec) {
                ForEach(VideoCodec.allCases) { c in
                    Text(c.label).tag(c)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        // Quality picker
        VStack(alignment: .leading, spacing: 6) {
            Text("Quality")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Picker("Quality", selection: $quality) {
                ForEach(ExportQuality.allCases) { q in
                    Text(q.label).tag(q)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        // Resolution picker
        VStack(alignment: .leading, spacing: 6) {
            Text("Resolution")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Picker("Resolution", selection: $resolution) {
                ForEach(ExportResolution.allCases) { r in
                    Text(r.label).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        Divider()

        // Action bar
        HStack {
            Spacer()

            Button("Cancel", action: onDismiss)
                .keyboardShortcut(.cancelAction)

            Button("Export...") {
                presentSavePanel()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Exporting Phase

    @ViewBuilder
    private var exportingContent: some View {
        Text("Exporting...")
            .font(.title2)
            .fontWeight(.semibold)

        Divider()

        VStack(spacing: 8) {
            ProgressView(value: progress, total: 1.0)
                .progressViewStyle(.linear)
            Text("\(Int(progress * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }

        Divider()

        HStack {
            Spacer()
            Button("Cancel") {
                exportTask?.cancel()
                phase = .settings
            }
        }
    }

    // MARK: - Done Phase

    @ViewBuilder
    private func doneContent(url: URL) -> some View {
        Text("Export Complete")
            .font(.title2)
            .fontWeight(.semibold)

        Divider()

        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.title3)
            Text(url.lastPathComponent)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }

        Divider()

        HStack {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Spacer()
            Button("Done", action: onDismiss)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Error Phase

    @ViewBuilder
    private func errorContent(message: String) -> some View {
        Text("Export Failed")
            .font(.title2)
            .fontWeight(.semibold)

        Divider()

        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.title3)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
        }

        Divider()

        HStack {
            Spacer()
            Button("Back") {
                phase = .settings
            }
            Button("Close", action: onDismiss)
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - NSSavePanel

    private func presentSavePanel() {
        let panel = NSSavePanel()
        panel.title = "Export Recording"
        panel.nameFieldStringValue = defaultFilename()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true

        // Default to Actionfy Recordings directory
        let exportDir = RecordingSessionController.exportDirectory
        let fm = FileManager.default
        if !fm.fileExists(atPath: exportDir.path) {
            try? fm.createDirectory(at: exportDir, withIntermediateDirectories: true)
        }
        panel.directoryURL = exportDir

        guard panel.runModal() == .OK, let url = panel.url else { return }

        startExport(outputURL: url)
    }

    private func defaultFilename() -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "Recording-\(timestamp).mp4"
    }

    // MARK: - Export Execution

    private func startExport(outputURL: URL) {
        phase = .exporting
        progress = 0

        let config = ExportConfiguration(
            codec: codec,
            quality: quality,
            resolution: resolution,
            outputURL: outputURL
        )

        let session = editor.session
        let editorRef = editor

        exportTask = Task {
            do {
                let exportService = ExportService()
                try await exportService.exportWithEffects(
                    session: session,
                    editor: editorRef,
                    config: config,
                    progress: { [self] value in
                        Task { @MainActor in
                            self.progress = value
                        }
                    }
                )

                await MainActor.run {
                    phase = .done(outputURL)
                }
            } catch is CancellationError {
                await MainActor.run {
                    phase = .settings
                }
            } catch {
                await MainActor.run {
                    phase = .error(error.localizedDescription)
                }
            }
        }
    }
}
```

**Step 2: Build and verify**

Run: `swift build`
Expected: May still fail until VideoEditorView is updated (next task)

**Step 3: Commit**

```bash
git add Sources/KinshasaApp/ScreenRecording/ExportDialogView.swift
git commit -m "feat: rewrite ExportDialogView with phases, NSSavePanel, and progress"
```

---

### Task 3: Wire ExportDialogView into VideoEditorView as a sheet

**Files:**
- Modify: `Sources/KinshasaApp/ScreenRecording/VideoEditorView.swift`

**Step 1: Update VideoEditorView**

Replace the `onExport: () -> Void` property with sheet state, and add the `.sheet` modifier:

1. Remove the `var onExport: () -> Void` property (line 8)
2. Add `@State private var showExportSheet = false`
3. Change the Export button from `Button("Export", action: onExport)` to `Button("Export") { showExportSheet = true }`
4. Add `.sheet(isPresented: $showExportSheet)` to the outermost container

The top of the struct becomes:

```swift
struct VideoEditorView: View {
    @Bindable var editor: VideoEditorController
    var onDone: () -> Void
    @State private var showExportSheet = false
    @State private var lastScrubTime: Date = .distantPast
    @State private var zoomDragStart: CGFloat?
    @State private var zoomDragEnd: CGFloat?
```

The Export button in `editorToolbar` becomes:

```swift
Button("Export") { showExportSheet = true }
    .buttonStyle(.borderedProminent)
```

Add the sheet modifier to the outermost `VStack` (after `.keyboardShortcut(shortcuts: editorShortcuts)`):

```swift
.sheet(isPresented: $showExportSheet) {
    ExportDialogView(
        editor: editor,
        onDismiss: { showExportSheet = false }
    )
}
```

**Step 2: Build and verify**

Run: `swift build`
Expected: Clean build — all compilation errors resolved

**Step 3: Commit**

```bash
git add Sources/KinshasaApp/ScreenRecording/VideoEditorView.swift
git commit -m "feat: wire export sheet into editor window"
```

---

### Task 4: Manual test and verify

**Step 1: Build and run the app**

Run: `swift build && swift run` (or the project's build script)

**Step 2: Test the export flow**

1. Start a screen recording, stop it, enter the editor
2. Click Export — verify sheet slides down with codec/quality/resolution pickers
3. Click Export... in sheet — verify NSSavePanel opens with default directory
4. Pick a location, confirm — verify progress bar appears and advances
5. Wait for completion — verify "Export Complete" with Show in Finder button
6. Verify the main settings window does NOT show export progress
7. Test cancel during export — verify it returns to settings phase
8. Test closing the sheet with Cancel button

**Step 3: Commit any fixes if needed**
