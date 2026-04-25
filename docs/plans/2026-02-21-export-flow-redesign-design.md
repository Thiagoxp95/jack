# Export Flow Redesign

## Problem

1. Export progress bar shows in ContentView (main settings window) instead of the editor
2. No export settings UI — codec, quality, resolution are hardcoded to H.264/High/Original
3. No file picker — output always goes to `~/Documents/Jack Recordings/`
4. Progress gets stuck at 14% (likely the main window state conflict)

## Design

### User Flow

1. Click **Export** in editor toolbar
2. Sheet slides down inside editor window showing codec/quality/resolution pickers
3. Click **Export** in sheet → NSSavePanel opens, defaulting to `~/Documents/Jack Recordings/Recording-<timestamp>.mp4`
4. User confirms file location → sheet transitions to progress view (bar + percentage + cancel)
5. Export completes → sheet dismisses, Finder reveals file
6. Export fails → error message in sheet with Retry/Cancel

### Changes

**ExportDialogView** (enhance existing):
- Add `outputURL` state populated by NSSavePanel
- Add `ExportPhase` enum: `.settings`, `.exporting`, `.done`, `.error(String)`
- When phase is `.settings`: show codec/quality/resolution pickers + Export/Cancel buttons
- When Export clicked: open NSSavePanel, on success set outputURL and call `onExport(codec, quality, resolution, outputURL)`
- When phase is `.exporting`: replace settings with progress bar + percentage + Cancel button
- Add `progress` binding so parent can drive the progress value
- Add `onCancelExport` closure for cancellation

**VideoEditorView**:
- Remove `onExport: () -> Void` closure
- Add `@State private var showExportSheet = false`
- Export button sets `showExportSheet = true`
- Add `.sheet(isPresented: $showExportSheet)` presenting ExportDialogView
- Pass `editor.session` so ExportDialogView can run export self-contained
- Pass editor reference for export

**EditorWindowController**:
- Remove `onExport` parameter from `show()`
- Pass `RecordingSession` through to VideoEditorView (already available via editor.session)

**RecordingSessionController**:
- Remove `startExport(editor:)` method
- Remove `exportProgress` property
- Remove `.exporting` state transition from export flow
- Keep `ensureExportDirectory()` as a static utility (used by NSSavePanel default directory)

**RecordingTypes**:
- Remove `.exporting` case from `RecordingState` enum

**ContentView**:
- Remove `case .exporting:` block from screenRecordingSection

### What stays the same

- `ExportService.exportWithEffects()` — rendering pipeline untouched
- `ExportConfiguration` struct — same shape but outputURL now comes from NSSavePanel
- Metal rendering, audio mixing, zoom/cursor effects — unchanged
