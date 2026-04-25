# Chat Side Sheet Design

## Overview

A toggleable chat side sheet (same mechanism as the Todo side sheet) that lets users chat with AI models via OpenRouter. Features per-thread model selection, streaming responses, and an always-visible thread sidebar.

## Architecture: Convex HTTP Proxy Streaming

The Swift app calls a Convex HTTP action (`POST /chat/stream`) which proxies to OpenRouter with streaming enabled, relaying SSE chunks back to the client. API key stays server-side. After stream completes, the full assistant message is persisted to Convex.

## Data Model

### `chatThreads` table

| Field | Type | Description |
|-------|------|-------------|
| spaceId | optional Id<"spaces"> | Associated space |
| userId | Id<"users"> | Thread owner |
| title | string | Auto-generated or user-set |
| model | string | OpenRouter model ID (e.g. `anthropic/claude-sonnet-4`) |
| createdAt | number | Timestamp |
| updatedAt | number | Timestamp, used for sort order |

Indexes: `by_space`, `by_space_user`

### `chatMessages` table

| Field | Type | Description |
|-------|------|-------------|
| threadId | Id<"chatThreads"> | Parent thread |
| role | "user" \| "assistant" | Message author |
| content | string | Message text |
| model | optional string | Model that generated this (assistant messages) |
| createdAt | number | Timestamp |

Indexes: `by_thread`

## Backend (Convex)

### `convex/chats.ts` - Queries & Mutations

- `listThreads(spaceId)` - List threads sorted by `updatedAt` desc
- `getThread(threadId)` - Get single thread
- `getMessages(threadId)` - Get messages sorted by `createdAt` asc
- `createThread(spaceId, title, model)` - Create new thread
- `deleteThread(threadId)` - Delete thread + all its messages
- `updateThread(threadId, { title?, model? })` - Update thread metadata
- `sendMessage(threadId, content)` - Save user message, update thread `updatedAt`
- `saveAssistantMessage(threadId, content, model)` - Save completed assistant response
- `listModels()` (action) - Fetch available models from OpenRouter `/api/v1/models`

### `convex/http.ts` - Streaming Endpoint

`POST /chat/stream`
- Body: `{ threadId, messageContent, clerkToken }`
- Authenticates user via Clerk token
- Loads thread + full message history
- Calls OpenRouter `/api/v1/chat/completions` with `stream: true`
- Relays SSE chunks to the Swift client
- After stream ends, saves assistant message via `saveAssistantMessage`

## Swift Client

### ChatSideSheetController (singleton, @MainActor)

Mirrors `TodoSideSheetController` pattern:
- `ChatSideSheetState` (Observable): `isVisible`, `selectedThreadIndex`, `threads`, `messages`, `isComposing`, `inputText`, `isStreaming`, `currentStreamedText`
- `KeyInterceptingPanel`: custom NSPanel, default ~550pt wide, resizable (min 400pt, max 800pt), drag handle on left edge
- `show()`/`hide()` toggle methods
- Anchored to right edge of screen, full height, slides in/out with animation

### ChatSideSheetView (SwiftUI)

Two-column layout:

**Left sidebar (~160pt):**
- "Chats" header + "+" new thread button
- Thread rows: truncated title, model badge, relative timestamp
- Selected thread highlighted
- Delete via right-click or Delete key (with confirmation)

**Right chat area:**
- Top bar: editable thread title + model selector dropdown
- Messages: user right-aligned (accent color), assistant left-aligned (subtle background)
- Streaming: pulsing dot + token-by-token text in assistant bubble
- Bottom: multiline text input (up to 4 lines) + send button
- Empty state: "Select or create a chat to get started"

### Model Selector

- Dropdown with fetched OpenRouter models
- Favorites section pinned at top (star toggle)
- Search/filter field within dropdown
- Shows model name + provider
- Favorites persisted in UserDefaults

### ChatSyncService

- Subscribes to Convex queries for threads and messages (real-time)
- Calls `/chat/stream` HTTP endpoint for sending messages
- Parses SSE stream using `URLSession` async bytes
- On stream complete, Convex subscription picks up saved message automatically

### Shortcut Integration

- New slot in `DictationController` + `GlobalFnShortcutMonitor`
- Default: `Control+Shift+A`
- Persisted in UserDefaults as `chat_sheet_shortcut_json`
- Same registration pattern as `todoSheetShortcut`

## Keyboard Shortcuts (within panel)

| Shortcut | Action |
|----------|--------|
| Cmd+N | New thread |
| Cmd+Delete | Delete current thread |
| Escape | Close panel / cancel action |
| Enter | Send message (input focused) |
| Shift+Enter | Newline in input |
| Up/Down | Navigate thread list (sidebar focused) |

## UI Style

- Same dark glassmorphism as Todo side sheet
- Panel default 550pt, min 400pt, max 800pt, resizable
- Anchored right edge, full screen height
- Slide in/out animation matching todos
