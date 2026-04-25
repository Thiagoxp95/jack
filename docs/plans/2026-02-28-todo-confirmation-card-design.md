# Todo Confirmation Card — Design

## Overview

After dictation creates a todo, show a floating confirmation card at bottom-center of screen (same position as the dictation pill) displaying the full parsed todo details. The card auto-dismisses after 3 seconds, can be dismissed with Escape/OK, or expanded into an inline floating editor via an Edit button.

## Approach

Separate NSPanel + SwiftUI (Approach B). A new `TodoConfirmationController` manages its own NSPanel hosting SwiftUI views. Clean separation from the existing pill/bubble system.

## Data Flow

1. `syncTodoToConvex()` calls `todos:processAndCreate` — change return value to include full parsed todo data (title, description, dueDate, dueTime, priority, tags, reminders, listName).
2. `DictationController` receives the parsed data and passes it to `TodoConfirmationController.show(todo:)`.
3. Confirmation card appears at bottom-center (same spot as pill).
4. After 3 seconds OR pressing Escape/OK: card fades out.
5. Pressing Edit: card transitions to the floating editor view.

## Backend Change

`processAndCreate` currently returns just the todo ID string. Change it to return a JSON object:

```typescript
return JSON.stringify({
  id: todoId,
  title: parsed.title,
  description: parsed.description,
  dueDate: parsed.dueDate,
  dueTime: parsed.dueTime,
  priority: parsed.priority,
  tags: parsed.tags,
  reminders: reminders,
  listName: parsed.listName,
});
```

## Confirmation Card UI

Dark rounded-rect card (~320pt wide), bottom-center, 48pt above dock:

```
┌─────────────────────────────────────┐
│  ✓  Todo Created                    │
│                                     │
│  Take the dishes                    │  ← title (bold)
│                                     │
│  📅 Today 09:55   🔔 1 reminder    │  ← due date + reminders
│  🏷 None          ○ To Do          │  ← priority + status
│  📋 Uncategorized                   │  ← list name
│                                     │
│       [ Edit ]     [ OK ]           │
└─────────────────────────────────────┘
```

- Dark background with `.ultraThinMaterial` + vibrancy (matching existing card style)
- Fade-in animation (0.3s)
- Auto-dismiss after 3 seconds with fade-out (0.3s)
- Hovering pauses the auto-dismiss timer
- Escape key dismisses immediately
- Mouse events enabled (unlike the pill)

## Floating Editor UI

When Edit is pressed, the card transitions into an editor (~320pt wide, taller):

```
┌─────────────────────────────────────┐
│  Edit Todo                          │
│                                     │
│  Title: [Take the dishes        ]   │
│  Due:   [2026-02-28] [09:55]       │
│  Priority: [None ▾]                 │
│  Tags:  [                       ]   │
│  List:  [Uncategorized ▾]          │
│                                     │
│       [ Cancel ]    [ Save ]        │
└─────────────────────────────────────┘
```

- Same dark material style
- Editable fields for all metadata
- Save calls `todos:update` Convex mutation
- Cancel dismisses without saving
- No auto-dismiss timer while editing

## Window Management — TodoConfirmationController

- New `TodoConfirmationController` class
- Uses NSPanel: borderless, non-activating, floating, `.statusBar` level
- `ignoresMouseEvents = false` (needs clicks)
- Positioned bottom-center, same logic as pill
- Owned by `DictationController`

## Files Involved

### New Files
- `Sources/JackApp/TodoConfirmationController.swift` — NSPanel management, show/hide/position logic
- `Sources/JackApp/TodoConfirmationView.swift` — SwiftUI view for confirmation card
- `Sources/JackApp/TodoEditView.swift` — SwiftUI view for floating editor

### Modified Files
- `convex/todos.ts` — Change `processAndCreate` return value to include full parsed data
- `Sources/JackApp/DictationController.swift` — Parse returned todo data, instantiate and call `TodoConfirmationController.show(todo:)`
