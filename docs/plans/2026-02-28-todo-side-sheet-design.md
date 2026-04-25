# Todo Side Sheet — Design Document

**Date:** 2026-02-28
**Status:** Approved

## Overview

A keyboard-driven side sheet panel that slides in from the right edge of the screen, showing todos for the current space. Invoked via a configurable global combo shortcut (like screen recording). Fully keyboard-controlled: navigate, toggle done, delete, create, edit, cycle priority, switch spaces — all without mouse.

## Architecture

### New Files

- `TodoSideSheetController.swift` — NSPanel lifecycle (pre-create, show/hide, keyboard routing)
- `TodoSideSheetView.swift` — SwiftUI view rendered inside NSHostingView

### Modified Files

- `GlobalFnShortcutMonitor.swift` — Add `todoSheetShortcut: InvocationShortcut?` combo + `onTodoSheetKeyPressed` callback
- `DictationController.swift` — Wire shortcut, hold `TodoSideSheetController` reference, add UserDefaults persistence for the shortcut, expose display name / apply / clear methods
- `ContentView.swift` — Add "Todo Sheet" shortcut capture row in Recording Controls section + sheet for capture

## Shortcut System

Same pattern as `screenRecordingShortcut`:

- Stored as `InvocationShortcut?` (optional, can be cleared)
- Persisted via `UserDefaults` key `todo_sheet_shortcut_json`
- Registered in `GlobalFnShortcutMonitor` with its own matching in `flagsChanged` and `keyDown` handlers
- Works anytime (not gated behind recording state)
- Fires `onTodoSheetKeyPressed: (() -> Void)?`

## NSPanel Configuration

- Style: `.borderless`, `.nonactivatingPanel`
- `isFloatingPanel = true`, `level = .floating`
- `hidesOnDeactivate = false`
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`
- `backgroundColor = .clear`, `isOpaque = false`
- Pre-created on app init, toggled visible/hidden (zero creation delay)
- Custom `NSPanel` subclass overrides `keyDown` for keyboard routing

## Panel Dimensions & Position

- Width: 320pt
- Height: full screen height (visibleFrame)
- Anchored to right edge of main screen
- Slide-in: 0.15s ease-out from right
- Slide-out: 0.15s ease-in to right

## Keyboard Controls

| Key | Action |
|-----|--------|
| `Esc` | Close sheet |
| `↑` / `↓` | Navigate todos |
| `Enter` / `Space` | Toggle done/undone |
| `Delete` / `Backspace` | Delete selected todo |
| `Tab` | Cycle space forward |
| `Shift+Tab` | Cycle space backward |
| `N` | Create new todo (inline input at top) |
| `E` | Edit selected todo title inline |
| `P` | Cycle priority on selected todo |

## UI Layout

```
┌─────────────────────────────┐
│  ● Space Name    ← Tab →   │  Header: space icon + name + hint
│─────────────────────────────│
│  + New todo...         [N]  │  Input field (shown on N press)
│─────────────────────────────│
│  ○ Buy groceries       med  │  Todo row
│  ● Fix login bug      high  │  Selected row (highlighted)
│  ✓ Write tests         low  │  Completed (strikethrough, dimmed)
│  ○ Call dentist        none  │
│                             │
│─────────────────────────────│
│ ↑↓ Navigate  ⏎ Done  ⌫ Del │  Keyboard hints footer
│ N New  E Edit  P Priority   │
│ Tab Space  Esc Close        │
└─────────────────────────────┘
```

### Visual Details

- Dark `.ultraThinMaterial` background
- Selected row: subtle highlight using active space color at low opacity
- Completed todos: strikethrough title + 0.5 opacity
- Priority indicator: colored dot (high=red, medium=orange, low=blue, none=gray)
- Space icon + color from SpaceController
- Keyboard hints footer: small monospace text, dimmed

## Data Flow

1. On show: fetch todos for active space via `TodoListController.fetchTodos(spaceId:)`
2. TodoListController is `@Observable` — SwiftUI view updates automatically
3. Mutations (toggle, delete, create, edit, priority) go through `TodoListController` methods
4. On space cycle: update SpaceController, re-fetch todos for new space
5. Optimistic updates: modify local array immediately, then fire async mutation

## State Management

`TodoSideSheetController` holds:
- `isVisible: Bool` — panel visibility
- `selectedIndex: Int` — currently highlighted todo
- `isCreating: Bool` — whether new-todo input is shown
- `isEditing: Bool` — whether inline edit is active
- `editText: String` — current edit/create text

These are passed to the SwiftUI view as `@Observable` state.
