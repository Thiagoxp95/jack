# Todo Mode — Design Document

**Date:** 2026-02-27
**Status:** Approved

## Overview

Add a **Todo mode** to Jack alongside the existing Paste and Voice Note modes. Users dictate a todo, an LLM (via OpenRouter + Vercel AI SDK) structures it, and the structured todo is saved to Convex. Includes lists, tags, priorities, reminders, and both list and Kanban UI views.

## Decisions

| Decision | Choice |
|----------|--------|
| Invocation | Separate key (e.g., T) during recording |
| AI Backend | Convex action calling OpenRouter via Vercel AI SDK |
| V1 Features | Core (title, description, due date, priority, completion) + Lists/tags + Reminders |
| Reminders | Floating bubble + macOS notification |
| UI | List view + Kanban board |
| Save flow | Auto-save, edit later |

## 1. Data Model

### `todos` table

```typescript
todos: defineTable({
  spaceId: v.optional(v.id("spaces")),
  userId: v.id("users"),
  title: v.string(),
  description: v.optional(v.string()),
  status: v.union(v.literal("todo"), v.literal("in_progress"), v.literal("done")),
  priority: v.union(v.literal("none"), v.literal("low"), v.literal("medium"), v.literal("high")),
  listId: v.optional(v.id("todoLists")),
  tags: v.optional(v.array(v.string())),
  dueDate: v.optional(v.string()),        // "yyyy-MM-dd"
  dueTime: v.optional(v.string()),        // "HH:mm"
  reminders: v.optional(v.array(v.object({
    at: v.number(),                        // Unix timestamp ms
    scheduledFunctionId: v.optional(v.string()),
  }))),
  completedAt: v.optional(v.number()),
  rawTranscription: v.optional(v.string()),
  createdAt: v.number(),
})
  .index("by_space", ["spaceId"])
  .index("by_space_user", ["spaceId", "userId"])
  .index("by_list", ["listId"])
  .index("by_status", ["status"])
```

### `todoLists` table

```typescript
todoLists: defineTable({
  spaceId: v.optional(v.id("spaces")),
  userId: v.id("users"),
  name: v.string(),
  color: v.optional(v.string()),
  sortOrder: v.optional(v.number()),
  createdAt: v.number(),
})
  .index("by_space", ["spaceId"])
  .index("by_space_user", ["spaceId", "userId"])
```

## 2. LLM Processing Pipeline

### Flow

```
Speech → Local Parakeet transcription → raw text
  → Convex action (todos:processAndCreate)
    → Calls OpenRouter via Vercel AI SDK
    → LLM returns structured JSON
    → Insert into todos table
    → Schedule reminder functions if reminders present
    → Return created todo ID
```

### LLM Structured Output Schema

```typescript
{
  title: string,
  description?: string,
  dueDate?: string,           // "yyyy-MM-dd"
  dueTime?: string,           // "HH:mm"
  priority: "none" | "low" | "medium" | "high",
  tags?: string[],
  listName?: string,
  reminders?: Array<{
    offsetMinutes?: number,   // e.g. -30 = "30 min before due"
    absoluteTime?: string,    // "yyyy-MM-ddTHH:mm"
  }>
}
```

### Dependencies

- `ai` (Vercel AI SDK)
- `@openrouter/ai-sdk-provider` (OpenRouter provider)

Uses `generateObject()` from Vercel AI SDK with a Zod schema for typed, validated output.

## 3. Swift Client Changes

### 3a. RecordingOutputMode

Add `.todo` case to existing enum in `ShortcutTypes.swift`.

### 3b. Todo Switch Key

Mirror the voice note switch key pattern in `GlobalFnShortcutMonitor`:

- `todoSwitchKeyCode`, `todoSwitchArmed`, `consumeTodoSwitchKeyUp`
- `onTodoSwitchKeyPressed` callback
- In `handleKeyEvent`: fire callback when todo key pressed during recording
- In `handleFlagsChanged`: arm todo switch when invocation key goes down

In `DictationController`:
- `@Published var todoSwitchKeyCode: Int64` (default: keyCode 17 = T)
- `isCapturingTodoSwitchKey` for settings
- Wire `shortcutMonitor.onTodoSwitchKeyPressed` → set `recordingOutputMode = .todo`

### 3c. Floating Bubble

Extend `PillIndicatorView.update()` to handle todo mode with a `"checklist"` icon. Change `isNoteMode: Bool` to a mode enum or add `isTodoMode: Bool` parameter.

### 3d. handleTranscriptionResult

Add third case:

```swift
case .todo:
    statusText = "Creating todo..."
    Task { await syncTodoToConvex(text: cleaned) }
    bubble.hide()
```

### 3e. syncTodoToConvex

New method calling Convex action:

```swift
private func syncTodoToConvex(text: String) async {
    do {
        let token = try await ConvexHTTPClient.getToken()
        var args: [String: Any] = ["rawText": text]
        if let spaceId = spaceController?.currentSpaceId {
            args["spaceId"] = spaceId
        }
        _ = try await ConvexHTTPClient.action(
            function: "todos:processAndCreate",
            args: args,
            token: token
        )
        lastTodoSavedAt = Date()
        statusText = "Todo created."
    } catch {
        handleError("Could not create todo. \(error.localizedDescription)")
    }
}
```

Requires new `ConvexHTTPClient.action()` method (same as `mutation()` but hits `/api/action`).

### 3f. Settings UI

- New `SettingsSection.todos` case in sidebar
- Key capture row for todo switch key in Shortcuts settings

## 4. Reminder System

### 4a. Scheduling (Convex)

After inserting a todo with reminders in `todos:processAndCreate`:

```typescript
const scheduledId = await ctx.scheduler.runAt(
  reminder.timestamp,
  internal.todos.fireReminder,
  { todoId, userId }
);
```

Store `scheduledId` on the reminder for cancellation.

### 4b. fireReminder (internal mutation)

- Reads todo from DB
- If completed or deleted → no-op
- Otherwise sets `pendingReminder` flag on the todo

### 4c. Client-side polling

`TodoListController` polls `todos:pendingReminders` every ~30s. When found:

1. macOS notification via `UNUserNotificationCenter` (title, due date)
2. Floating bubble with bell icon and todo title
3. Mark reminder as delivered in Convex

### 4d. Cancellation

When todo is deleted or reminder changed: `ctx.scheduler.cancel(scheduledFunctionId)`.

## 5. Todo UI

### 5a. Sidebar

New `SettingsSection.todos` with `"checklist"` icon.

### 5b. List View (default)

- Grouped by todoList (with "Unassigned" section)
- Each row: checkbox, priority dots (red/orange/blue/none), title, due date
- Click to expand inline editing (title, description, priority, date, tags, list)
- Filter by tag, priority, due date range
- Sort by due date, priority, creation date

### 5c. Kanban View

Three columns: To Do, In Progress, Done.

- Cards show title, priority indicator, due date
- Drag-and-drop between columns updates status
- Cards sorted by priority (high first), then due date

### 5d. Manual Creation

"+" button for inline form (title, list, priority, due date, tags) → calls `todos:create` mutation directly (no LLM).

### 5e. TodoListController (Swift)

New `@Observable` class mirroring `NoteListController`:

- `fetchTodos(spaceId:)` — queries `todos:list`
- `updateTodo(id:, fields:)` — mutation for inline edits
- `deleteTodo(id:)` — deletes + cancels scheduled reminders
- `moveTodo(id:, status:)` — Kanban drag-and-drop
- `fetchLists(spaceId:)` — queries `todoLists:list`
- `createList(name:, color:)` — mutation
- Pending reminder polling (~30s interval)
