# Chat Side Sheet Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a toggleable chat side sheet (mirroring the Todo side sheet) that lets users chat with AI models via OpenRouter, with per-thread model selection, streaming responses, and an always-visible thread sidebar.

**Architecture:** Convex HTTP action proxies OpenRouter streaming to the Swift client. Chat threads and messages are persisted in two new Convex tables. The Swift UI mirrors the TodoSideSheetController/View pattern with a KeyInterceptingPanel, global shortcut toggle, and Observable state.

**Tech Stack:** Swift/SwiftUI (macOS), Convex (TypeScript backend), OpenRouter API, SSE streaming, ClerkKit auth

---

### Task 1: Add Convex Schema for Chat Tables

**Files:**
- Modify: `convex/schema.ts:80-115` (add two new tables after `todoLists`)

**Step 1: Add chatThreads and chatMessages tables to the schema**

Add these two table definitions to `convex/schema.ts` before the closing `});`:

```typescript
chatThreads: defineTable({
  spaceId: v.optional(v.id("spaces")),
  userId: v.id("users"),
  title: v.string(),
  model: v.string(),
  createdAt: v.number(),
  updatedAt: v.number(),
})
  .index("by_space", ["spaceId"])
  .index("by_space_user", ["spaceId", "userId"]),

chatMessages: defineTable({
  threadId: v.id("chatThreads"),
  role: v.union(v.literal("user"), v.literal("assistant")),
  content: v.string(),
  model: v.optional(v.string()),
  createdAt: v.number(),
}).index("by_thread", ["threadId"]),
```

**Step 2: Verify schema pushes successfully**

Run: `npx convex dev --once`
Expected: Schema deploys without errors.

**Step 3: Commit**

```bash
git add convex/schema.ts
git commit -m "feat: add chatThreads and chatMessages tables to Convex schema"
```

---

### Task 2: Create Convex Chat Functions (Queries & Mutations)

**Files:**
- Create: `convex/chats.ts`

**Step 1: Create the chats module with all queries and mutations**

Create `convex/chats.ts` with:

```typescript
import { v } from "convex/values";
import { action, mutation, query } from "./_generated/server";

// Helper: resolve user from auth identity
async function getUser(ctx: any) {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) throw new Error("Unauthenticated");
  const user = await ctx.db
    .query("users")
    .withIndex("by_clerkId", (q: any) => q.eq("clerkId", identity.subject))
    .unique();
  if (!user) throw new Error("User not found");
  return user;
}

// Helper: verify space membership
async function verifySpaceMembership(ctx: any, spaceId: string, userId: string) {
  const membership = await ctx.db
    .query("space_members")
    .withIndex("by_space_user", (q: any) => q.eq("spaceId", spaceId).eq("userId", userId))
    .unique();
  if (!membership) throw new Error("Not a member of this space");
}

// ── 1. listThreads ──────────────────────────────────────────────────────────
export const listThreads = query({
  args: { spaceId: v.optional(v.id("spaces")) },
  handler: async (ctx, args) => {
    const user = await getUser(ctx);

    if (args.spaceId) {
      await verifySpaceMembership(ctx, args.spaceId, user._id);
      return await ctx.db
        .query("chatThreads")
        .withIndex("by_space", (q: any) => q.eq("spaceId", args.spaceId))
        .order("desc")
        .collect();
    }

    return await ctx.db
      .query("chatThreads")
      .withIndex("by_space_user", (q: any) =>
        q.eq("spaceId", undefined).eq("userId", user._id)
      )
      .order("desc")
      .collect();
  },
});

// ── 2. getMessages ──────────────────────────────────────────────────────────
export const getMessages = query({
  args: { threadId: v.id("chatThreads") },
  handler: async (ctx, args) => {
    const user = await getUser(ctx);
    const thread = await ctx.db.get(args.threadId);
    if (!thread) throw new Error("Thread not found");

    // Verify ownership or space membership
    if (thread.spaceId) {
      await verifySpaceMembership(ctx, thread.spaceId, user._id);
    } else if (thread.userId !== user._id) {
      throw new Error("Not authorized");
    }

    return await ctx.db
      .query("chatMessages")
      .withIndex("by_thread", (q: any) => q.eq("threadId", args.threadId))
      .order("asc")
      .collect();
  },
});

// ── 3. createThread ─────────────────────────────────────────────────────────
export const createThread = mutation({
  args: {
    spaceId: v.optional(v.id("spaces")),
    title: v.string(),
    model: v.string(),
  },
  handler: async (ctx, args) => {
    const user = await getUser(ctx);

    if (args.spaceId) {
      await verifySpaceMembership(ctx, args.spaceId, user._id);
    }

    const now = Date.now();
    return await ctx.db.insert("chatThreads", {
      spaceId: args.spaceId,
      userId: user._id,
      title: args.title,
      model: args.model,
      createdAt: now,
      updatedAt: now,
    });
  },
});

// ── 4. updateThread ─────────────────────────────────────────────────────────
export const updateThread = mutation({
  args: {
    threadId: v.id("chatThreads"),
    title: v.optional(v.string()),
    model: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const user = await getUser(ctx);
    const thread = await ctx.db.get(args.threadId);
    if (!thread) throw new Error("Thread not found");

    if (thread.spaceId) {
      await verifySpaceMembership(ctx, thread.spaceId, user._id);
    } else if (thread.userId !== user._id) {
      throw new Error("Not authorized");
    }

    const updates: any = { updatedAt: Date.now() };
    if (args.title !== undefined) updates.title = args.title;
    if (args.model !== undefined) updates.model = args.model;

    await ctx.db.patch(args.threadId, updates);
  },
});

// ── 5. deleteThread ─────────────────────────────────────────────────────────
export const deleteThread = mutation({
  args: { threadId: v.id("chatThreads") },
  handler: async (ctx, args) => {
    const user = await getUser(ctx);
    const thread = await ctx.db.get(args.threadId);
    if (!thread) throw new Error("Thread not found");

    if (thread.spaceId) {
      await verifySpaceMembership(ctx, thread.spaceId, user._id);
    } else if (thread.userId !== user._id) {
      throw new Error("Not authorized");
    }

    // Delete all messages in the thread
    const messages = await ctx.db
      .query("chatMessages")
      .withIndex("by_thread", (q: any) => q.eq("threadId", args.threadId))
      .collect();
    for (const msg of messages) {
      await ctx.db.delete(msg._id);
    }

    await ctx.db.delete(args.threadId);
  },
});

// ── 6. sendMessage ──────────────────────────────────────────────────────────
export const sendMessage = mutation({
  args: {
    threadId: v.id("chatThreads"),
    content: v.string(),
  },
  handler: async (ctx, args) => {
    const user = await getUser(ctx);
    const thread = await ctx.db.get(args.threadId);
    if (!thread) throw new Error("Thread not found");

    if (thread.spaceId) {
      await verifySpaceMembership(ctx, thread.spaceId, user._id);
    } else if (thread.userId !== user._id) {
      throw new Error("Not authorized");
    }

    const now = Date.now();
    await ctx.db.insert("chatMessages", {
      threadId: args.threadId,
      role: "user",
      content: args.content,
      createdAt: now,
    });

    await ctx.db.patch(args.threadId, { updatedAt: now });
  },
});

// ── 7. saveAssistantMessage ─────────────────────────────────────────────────
export const saveAssistantMessage = mutation({
  args: {
    threadId: v.id("chatThreads"),
    content: v.string(),
    model: v.string(),
  },
  handler: async (ctx, args) => {
    // This is called internally after streaming completes
    const thread = await ctx.db.get(args.threadId);
    if (!thread) throw new Error("Thread not found");

    await ctx.db.insert("chatMessages", {
      threadId: args.threadId,
      role: "assistant",
      content: args.content,
      model: args.model,
      createdAt: Date.now(),
    });
  },
});

// ── 8. listModels ───────────────────────────────────────────────────────────
export const listModels = action({
  args: {},
  handler: async () => {
    const apiKey = process.env.OPENROUTER_API_KEY;
    if (!apiKey) throw new Error("OPENROUTER_API_KEY not set");

    const res = await fetch("https://openrouter.ai/api/v1/models", {
      headers: { Authorization: `Bearer ${apiKey}` },
    });

    if (!res.ok) {
      throw new Error(`OpenRouter API error: ${res.status}`);
    }

    const data = await res.json();
    // Return a simplified list: id, name, provider
    return (data.data || []).map((m: any) => ({
      id: m.id,
      name: m.name || m.id,
      provider: m.id.split("/")[0],
    }));
  },
});
```

**Step 2: Verify it deploys**

Run: `npx convex dev --once`
Expected: All functions deploy without errors.

**Step 3: Commit**

```bash
git add convex/chats.ts
git commit -m "feat: add Convex chat queries, mutations, and listModels action"
```

---

### Task 3: Add Streaming HTTP Endpoint to Convex

**Files:**
- Modify: `convex/http.ts` (add POST /chat/stream route)

**Step 1: Add the streaming chat endpoint**

Add this route to `convex/http.ts` before `export default http;`:

```typescript
http.route({
  path: "/chat/stream",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    // Parse request body
    const body = await request.json();
    const { threadId, messageContent } = body;

    if (!threadId || !messageContent) {
      return new Response(JSON.stringify({ error: "Missing threadId or messageContent" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }

    // Authenticate via Authorization header
    const authHeader = request.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      });
    }

    // Save the user message first
    await ctx.runMutation(api.chats.sendMessage, {
      threadId,
      content: messageContent,
    });

    // Load thread to get model
    const thread = await ctx.runQuery(api.chats.getThread, { threadId });
    if (!thread) {
      return new Response(JSON.stringify({ error: "Thread not found" }), {
        status: 404,
        headers: { "Content-Type": "application/json" },
      });
    }

    // Load message history
    const messages = await ctx.runQuery(api.chats.getMessages, { threadId });

    // Build OpenRouter messages array
    const openRouterMessages = messages.map((m: any) => ({
      role: m.role,
      content: m.content,
    }));

    const apiKey = process.env.OPENROUTER_API_KEY;
    if (!apiKey) {
      return new Response(JSON.stringify({ error: "OPENROUTER_API_KEY not configured" }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }

    // Call OpenRouter with streaming
    const openRouterRes = await fetch("https://openrouter.ai/api/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model: thread.model,
        messages: openRouterMessages,
        stream: true,
      }),
    });

    if (!openRouterRes.ok) {
      const errText = await openRouterRes.text();
      return new Response(JSON.stringify({ error: `OpenRouter error: ${openRouterRes.status} ${errText}` }), {
        status: 502,
        headers: { "Content-Type": "application/json" },
      });
    }

    // Stream the SSE response through to the client, accumulating for save
    const reader = openRouterRes.body?.getReader();
    if (!reader) {
      return new Response(JSON.stringify({ error: "No response body" }), {
        status: 502,
        headers: { "Content-Type": "application/json" },
      });
    }

    let fullContent = "";
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();

    const stream = new ReadableStream({
      async pull(controller) {
        while (true) {
          const { done, value } = await reader.read();
          if (done) {
            // Send a final event with the complete content marker
            controller.enqueue(encoder.encode("data: [DONE]\n\n"));
            controller.close();

            // Save the assistant message to Convex
            if (fullContent.trim()) {
              await ctx.runMutation(api.chats.saveAssistantMessage, {
                threadId,
                content: fullContent,
                model: thread.model,
              });
            }
            return;
          }

          // Parse SSE chunks to accumulate content
          const chunk = decoder.decode(value, { stream: true });
          const lines = chunk.split("\n");
          for (const line of lines) {
            if (line.startsWith("data: ") && line !== "data: [DONE]") {
              try {
                const json = JSON.parse(line.slice(6));
                const delta = json.choices?.[0]?.delta?.content;
                if (delta) {
                  fullContent += delta;
                }
              } catch {
                // Skip unparseable lines
              }
            }
          }

          // Pass the raw SSE through to the client
          controller.enqueue(value);
        }
      },
    });

    return new Response(stream, {
      headers: {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        Connection: "keep-alive",
      },
    });
  }),
});
```

You'll also need to add the `api` import at the top if not already present. The existing file already imports `api` from `./_generated/api`.

**Note:** The `sendMessage` and `getThread` queries need auth context. Since the HTTP action uses `ctx.runMutation`/`ctx.runQuery`, auth is handled by forwarding the request's identity. Update the HTTP handler to use `request` identity properly — the HTTP action in Convex receives the auth from the Authorization header automatically when configured with Clerk.

**Step 2: Add getThread query to chats.ts**

Add this query to `convex/chats.ts` (it was referenced in the HTTP handler but not included in Task 2):

```typescript
// ── getThread ───────────────────────────────────────────────────────────────
export const getThread = query({
  args: { threadId: v.id("chatThreads") },
  handler: async (ctx, args) => {
    return await ctx.db.get(args.threadId);
  },
});
```

**Step 3: Verify deployment**

Run: `npx convex dev --once`
Expected: Deploys without errors.

**Step 4: Commit**

```bash
git add convex/http.ts convex/chats.ts
git commit -m "feat: add /chat/stream SSE proxy endpoint"
```

---

### Task 4: Create ChatController (Sync + Streaming Client)

**Files:**
- Create: `Sources/JackApp/Sync/ChatController.swift`

**Step 1: Create the ChatController**

This follows the same pattern as `TodoListController` — a `@MainActor @Observable` singleton that talks to Convex via `ConvexHTTPClient`.

```swift
import Foundation

/// A chat thread from the Convex backend.
struct ConvexChatThread: Identifiable {
    let id: String
    let title: String
    let model: String
    let spaceId: String?
    let createdAt: Double
    let updatedAt: Double
}

/// A chat message from the Convex backend.
struct ConvexChatMessage: Identifiable {
    let id: String
    let threadId: String
    let role: String       // "user" or "assistant"
    let content: String
    let model: String?
    let createdAt: Double
}

/// An OpenRouter model available for chat.
struct OpenRouterModel: Identifiable {
    let id: String
    let name: String
    let provider: String
}

/// Fetches and manages chat threads/messages from the Convex HTTP API.
@MainActor @Observable
final class ChatController {

    static let shared = ChatController()

    private(set) var threads: [ConvexChatThread] = []
    private(set) var messages: [ConvexChatMessage] = []
    private(set) var availableModels: [OpenRouterModel] = []
    private(set) var isLoading = false
    private(set) var isStreaming = false
    var streamedContent = ""
    var error: String?

    // Favorite model IDs, persisted in UserDefaults
    var favoriteModelIds: Set<String> {
        didSet {
            let array = Array(favoriteModelIds)
            UserDefaults.standard.set(array, forKey: "chat_favorite_models")
        }
    }

    private var streamTask: Task<Void, Never>?

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: "chat_favorite_models") ?? []
        favoriteModelIds = Set(saved)
    }

    // MARK: - Threads

    func fetchThreads(spaceId: String?) async {
        isLoading = true
        error = nil
        do {
            let token = try await ConvexHTTPClient.getToken()
            var args: [String: Any] = [:]
            if let spaceId { args["spaceId"] = spaceId }

            let result = try await ConvexHTTPClient.query(
                function: "chats:listThreads",
                args: args,
                token: token
            )

            guard let items = result as? [[String: Any]] else {
                threads = []
                isLoading = false
                return
            }
            threads = items.compactMap { parseThread($0) }
        } catch {
            self.error = error.localizedDescription
            NSLog("[Chat] Failed to fetch threads: %@", String(describing: error))
        }
        isLoading = false
    }

    func createThread(title: String, model: String, spaceId: String?) async -> String? {
        do {
            let token = try await ConvexHTTPClient.getToken()
            var args: [String: Any] = ["title": title, "model": model]
            if let spaceId { args["spaceId"] = spaceId }

            let result = try await ConvexHTTPClient.mutation(
                function: "chats:createThread",
                args: args,
                token: token
            )
            return result as? String
        } catch {
            self.error = error.localizedDescription
            NSLog("[Chat] Failed to create thread: %@", String(describing: error))
            return nil
        }
    }

    func updateThread(threadId: String, title: String? = nil, model: String? = nil) async {
        do {
            let token = try await ConvexHTTPClient.getToken()
            var args: [String: Any] = ["threadId": threadId]
            if let title { args["title"] = title }
            if let model { args["model"] = model }

            nonisolated(unsafe) let sendableArgs = args
            _ = try await ConvexHTTPClient.mutation(
                function: "chats:updateThread",
                args: sendableArgs,
                token: token
            )
        } catch {
            self.error = error.localizedDescription
            NSLog("[Chat] Failed to update thread: %@", String(describing: error))
        }
    }

    func deleteThread(threadId: String) async {
        do {
            let token = try await ConvexHTTPClient.getToken()
            _ = try await ConvexHTTPClient.mutation(
                function: "chats:deleteThread",
                args: ["threadId": threadId],
                token: token
            )
            threads.removeAll { $0.id == threadId }
        } catch {
            self.error = error.localizedDescription
            NSLog("[Chat] Failed to delete thread: %@", String(describing: error))
        }
    }

    // MARK: - Messages

    func fetchMessages(threadId: String) async {
        do {
            let token = try await ConvexHTTPClient.getToken()
            let result = try await ConvexHTTPClient.query(
                function: "chats:getMessages",
                args: ["threadId": threadId],
                token: token
            )
            guard let items = result as? [[String: Any]] else {
                messages = []
                return
            }
            messages = items.compactMap { parseMessage($0) }
        } catch {
            self.error = error.localizedDescription
            NSLog("[Chat] Failed to fetch messages: %@", String(describing: error))
        }
    }

    // MARK: - Streaming

    /// Send a message and stream the AI response.
    func sendAndStream(threadId: String, content: String) {
        guard !isStreaming else { return }
        isStreaming = true
        streamedContent = ""

        streamTask = Task { [weak self] in
            guard let self else { return }

            do {
                let token = try await ConvexHTTPClient.getToken()

                let url = URL(string: "\(AppConfig.convexSiteUrl)/chat/stream")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

                let body: [String: Any] = [
                    "threadId": threadId,
                    "messageContent": content,
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

                guard statusCode == 200 else {
                    await MainActor.run {
                        self.error = "Stream failed with HTTP \(statusCode)"
                        self.isStreaming = false
                    }
                    return
                }

                for try await line in asyncBytes.lines {
                    if Task.isCancelled { break }

                    guard line.hasPrefix("data: ") else { continue }
                    let payload = String(line.dropFirst(6))

                    if payload == "[DONE]" { break }

                    guard let data = payload.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]],
                          let delta = choices.first?["delta"] as? [String: Any],
                          let content = delta["content"] as? String
                    else { continue }

                    await MainActor.run {
                        self.streamedContent += content
                    }
                }

                // Refresh messages to pick up the saved assistant message
                await self.fetchMessages(threadId: threadId)
                await self.fetchThreads(spaceId: self.threads.first(where: { $0.id == threadId })?.spaceId)

            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    NSLog("[Chat] Streaming error: %@", String(describing: error))
                }
            }

            await MainActor.run {
                self.isStreaming = false
                self.streamedContent = ""
            }
        }
    }

    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        streamedContent = ""
    }

    // MARK: - Models

    func fetchModels() async {
        do {
            let token = try await ConvexHTTPClient.getToken()
            let result = try await ConvexHTTPClient.action(
                function: "chats:listModels",
                args: [:],
                token: token
            )
            guard let items = result as? [[String: Any]] else {
                availableModels = []
                return
            }
            availableModels = items.compactMap { item in
                guard let id = item["id"] as? String,
                      let name = item["name"] as? String,
                      let provider = item["provider"] as? String
                else { return nil }
                return OpenRouterModel(id: id, name: name, provider: provider)
            }
        } catch {
            NSLog("[Chat] Failed to fetch models: %@", String(describing: error))
        }
    }

    func toggleFavorite(modelId: String) {
        if favoriteModelIds.contains(modelId) {
            favoriteModelIds.remove(modelId)
        } else {
            favoriteModelIds.insert(modelId)
        }
    }

    // MARK: - Parsing

    private func parseThread(_ item: [String: Any]) -> ConvexChatThread? {
        guard let id = item["_id"] as? String,
              let title = item["title"] as? String,
              let model = item["model"] as? String,
              let createdAt = item["_creationTime"] as? Double,
              let updatedAt = item["updatedAt"] as? Double
        else { return nil }

        return ConvexChatThread(
            id: id,
            title: title,
            model: model,
            spaceId: item["spaceId"] as? String,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func parseMessage(_ item: [String: Any]) -> ConvexChatMessage? {
        guard let id = item["_id"] as? String,
              let threadId = item["threadId"] as? String,
              let role = item["role"] as? String,
              let content = item["content"] as? String,
              let createdAt = item["_creationTime"] as? Double
        else { return nil }

        return ConvexChatMessage(
            id: id,
            threadId: threadId,
            role: role,
            content: content,
            model: item["model"] as? String,
            createdAt: createdAt
        )
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build` (or your project's compile script)
Expected: Compiles without errors.

**Step 3: Commit**

```bash
git add Sources/JackApp/Sync/ChatController.swift
git commit -m "feat: add ChatController with thread/message CRUD and SSE streaming"
```

---

### Task 5: Create ChatSideSheetController

**Files:**
- Create: `Sources/JackApp/ChatSideSheetController.swift`

**Step 1: Create the controller**

Follows the exact same pattern as `TodoSideSheetController` — singleton with `KeyInterceptingPanel`, Observable state, keyboard delegate.

```swift
import AppKit
import SwiftUI

// MARK: - ChatSheetKeyboardDelegate

@MainActor protocol ChatSheetKeyboardDelegate: AnyObject {
    func chatSheetDidPressEscape()
    func chatSheetDidPressCommandN()
    func chatSheetDidPressCommandDelete()
}

// MARK: - ChatKeyInterceptingPanel

private final class ChatKeyInterceptingPanel: NSPanel {
    weak var keyboardDelegate: ChatSheetKeyboardDelegate?
    var isTextInputActive = false

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        let keyCode = event.keyCode
        let isRepeat = event.isARepeat
        let commandHeld = event.modifierFlags.contains(.command)

        // Escape always handled
        if keyCode == 53 {
            if !isRepeat { keyboardDelegate?.chatSheetDidPressEscape() }
            return
        }

        // Cmd+N — new thread
        if commandHeld && keyCode == 45 && !isRepeat {
            keyboardDelegate?.chatSheetDidPressCommandN()
            return
        }

        // Cmd+Delete — delete thread
        if commandHeld && (keyCode == 51 || keyCode == 117) && !isRepeat {
            keyboardDelegate?.chatSheetDidPressCommandDelete()
            return
        }

        // All other keys pass through to SwiftUI (chat is text-heavy)
        super.keyDown(with: event)
    }
}

// MARK: - ChatSideSheetState

@MainActor @Observable
final class ChatSideSheetState {
    var isVisible = false
    var selectedThreadId: String?
    var isCreatingThread = false
    var newThreadTitle = ""
    var inputText = ""
    var isConfirmingDelete = false

    func reset() {
        isCreatingThread = false
        newThreadTitle = ""
        inputText = ""
        isConfirmingDelete = false
    }
}

// MARK: - ChatSideSheetController

@MainActor
final class ChatSideSheetController: ChatSheetKeyboardDelegate {

    static let shared = ChatSideSheetController()

    private var panel: ChatKeyInterceptingPanel?
    let sheetState = ChatSideSheetState()
    var chatController: ChatController = .shared
    var spaceController: SpaceController = SpaceController()

    private static let defaultWidth: CGFloat = 550
    private static let minWidth: CGFloat = 400
    private static let maxWidth: CGFloat = 800

    private var currentWidth: CGFloat {
        get {
            CGFloat(UserDefaults.standard.double(forKey: "chat_sheet_width").nonZero ?? Double(Self.defaultWidth))
        }
        set {
            UserDefaults.standard.set(Double(newValue), forKey: "chat_sheet_width")
        }
    }

    // MARK: - Toggle

    func toggle() {
        if sheetState.isVisible {
            hide()
        } else {
            show()
        }
    }

    // MARK: - Show

    func show() {
        guard !sheetState.isVisible else { return }

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let sheetHeight = screenFrame.height
        let width = currentWidth
        let size = NSSize(width: width, height: sheetHeight)

        if panel == nil {
            let p = ChatKeyInterceptingPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isReleasedWhenClosed = false
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.isFloatingPanel = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.keyboardDelegate = self
            panel = p
        }

        guard let panel else { return }
        sheetState.reset()
        sheetState.isVisible = true

        let sheetView = ChatSideSheetView(
            sheetState: sheetState,
            chatController: chatController,
            spaceController: spaceController,
            onResize: { [weak self] newWidth in
                guard let self else { return }
                let clamped = min(Self.maxWidth, max(Self.minWidth, newWidth))
                self.currentWidth = clamped
                self.updatePanelFrame()
            }
        )
        .frame(width: size.width, height: size.height)

        let hostingView = NSHostingView(rootView: sheetView)
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hostingView
        panel.setContentSize(size)

        let finalX = screenFrame.maxX - width
        let finalY = screenFrame.minY
        panel.setFrameOrigin(NSPoint(x: finalX, y: finalY))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()

        // Fetch threads and models
        Task {
            await chatController.fetchThreads(spaceId: spaceController.currentSpaceId)
            await chatController.fetchModels()
        }
    }

    // MARK: - Hide

    func hide() {
        guard let panel, sheetState.isVisible else { return }
        chatController.cancelStream()
        sheetState.isVisible = false
        panel.contentView = nil
        panel.orderOut(nil)
    }

    // MARK: - Panel Resize

    private func updatePanelFrame() {
        guard let panel, sheetState.isVisible else { return }
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = currentWidth
        let size = NSSize(width: width, height: screenFrame.height)

        let finalX = screenFrame.maxX - width
        let finalY = screenFrame.minY
        panel.setFrame(NSRect(origin: NSPoint(x: finalX, y: finalY), size: size), display: true)

        if let hostingView = panel.contentView as? NSHostingView<ChatSideSheetView> {
            hostingView.frame = NSRect(origin: .zero, size: size)
        }
    }

    // MARK: - ChatSheetKeyboardDelegate

    func chatSheetDidPressEscape() {
        if sheetState.isCreatingThread {
            sheetState.isCreatingThread = false
            sheetState.newThreadTitle = ""
        } else if sheetState.isConfirmingDelete {
            sheetState.isConfirmingDelete = false
        } else {
            hide()
        }
    }

    func chatSheetDidPressCommandN() {
        sheetState.isCreatingThread = true
        sheetState.newThreadTitle = ""
    }

    func chatSheetDidPressCommandDelete() {
        guard sheetState.selectedThreadId != nil else { return }
        sheetState.isConfirmingDelete = true
    }
}

// MARK: - Double extension

private extension Double {
    var nonZero: Double? {
        self == 0 ? nil : self
    }
}
```

**Step 2: Verify it compiles**

Run the compile script.
Expected: Compiles (ChatSideSheetView doesn't exist yet, so this may fail — that's expected, move to Task 6).

**Step 3: Commit**

```bash
git add Sources/JackApp/ChatSideSheetController.swift
git commit -m "feat: add ChatSideSheetController with KeyInterceptingPanel and state"
```

---

### Task 6: Create ChatSideSheetView

**Files:**
- Create: `Sources/JackApp/ChatSideSheetView.swift`

**Step 1: Create the view**

This is the two-column SwiftUI view — thread sidebar on the left, chat area on the right.

```swift
import SwiftUI

struct ChatSideSheetView: View {
    @Bindable var sheetState: ChatSideSheetState
    @Bindable var chatController: ChatController
    var spaceController: SpaceController
    var onResize: ((CGFloat) -> Void)?

    @State private var modelSearchText = ""
    @State private var showModelPicker = false
    @State private var dragStartWidth: CGFloat?

    private let sidebarWidth: CGFloat = 160

    var body: some View {
        HStack(spacing: 0) {
            // Drag handle for resize
            resizeHandle

            // Thread sidebar
            threadSidebar
                .frame(width: sidebarWidth)

            Divider().opacity(0.3)

            // Chat area
            chatArea
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .padding(4)
        .preferredColorScheme(.dark)
    }

    // MARK: - Resize Handle

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Dragging left edge: negative x = wider
                        let delta = -value.translation.width
                        let panelFrame = NSApp.keyWindow?.frame ?? .zero
                        let newWidth = panelFrame.width + delta
                        onResize?(newWidth)
                    }
            )
    }

    // MARK: - Thread Sidebar

    private var threadSidebar: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Chats")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: {
                    sheetState.isCreatingThread = true
                    sheetState.newThreadTitle = ""
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().opacity(0.3)

            // New thread input
            if sheetState.isCreatingThread {
                newThreadInputView
                Divider().opacity(0.3)
            }

            // Thread list
            ScrollView {
                LazyVStack(spacing: 0) {
                    if chatController.threads.isEmpty && !chatController.isLoading {
                        VStack(spacing: 6) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 20))
                                .foregroundStyle(.tertiary)
                            Text("No chats yet")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text("Press ⌘N")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                    } else {
                        ForEach(chatController.threads) { thread in
                            threadRow(thread)
                        }
                    }
                }
            }
        }
    }

    private func threadRow(_ thread: ConvexChatThread) -> some View {
        let isSelected = thread.id == sheetState.selectedThreadId

        return VStack(alignment: .leading, spacing: 2) {
            Text(thread.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)

            Text(thread.model.components(separatedBy: "/").last ?? thread.model)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectThread(thread.id)
        }
        .contextMenu {
            Button("Delete", role: .destructive) {
                Task {
                    await chatController.deleteThread(threadId: thread.id)
                    if sheetState.selectedThreadId == thread.id {
                        sheetState.selectedThreadId = chatController.threads.first?.id
                    }
                }
            }
        }
    }

    private var newThreadInputView: some View {
        VStack(spacing: 6) {
            TextField("Chat title...", text: $sheetState.newThreadTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit {
                    createNewThread()
                }

            // Model picker for new thread
            if !chatController.availableModels.isEmpty {
                modelPickerCompact
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05))
    }

    @State private var selectedModelForNewThread = "anthropic/claude-sonnet-4"

    private var modelPickerCompact: some View {
        Menu {
            // Favorites first
            let favorites = chatController.availableModels.filter { chatController.favoriteModelIds.contains($0.id) }
            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites) { model in
                        Button(model.name) {
                            selectedModelForNewThread = model.id
                        }
                    }
                }
            }

            Section("All Models") {
                ForEach(chatController.availableModels.prefix(50)) { model in
                    Button(model.name) {
                        selectedModelForNewThread = model.id
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.system(size: 9))
                Text(selectedModelForNewThread.components(separatedBy: "/").last ?? selectedModelForNewThread)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.white.opacity(0.08))
            )
        }
        .menuStyle(.borderlessButton)
    }

    // MARK: - Chat Area

    private var chatArea: some View {
        VStack(spacing: 0) {
            if let threadId = sheetState.selectedThreadId,
               let thread = chatController.threads.first(where: { $0.id == threadId }) {
                // Top bar
                chatTopBar(thread)
                Divider().opacity(0.3)

                // Messages
                messagesView
                Divider().opacity(0.3)

                // Input
                chatInputView
            } else {
                // Empty state
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("Select or create a chat")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Text("⌘N to start a new conversation")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func chatTopBar(_ thread: ConvexChatThread) -> some View {
        HStack(spacing: 8) {
            Text(thread.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Spacer()

            // Model badge
            Text(thread.model.components(separatedBy: "/").last ?? thread.model)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.white.opacity(0.08))
                )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(chatController.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }

                    // Streaming indicator
                    if chatController.isStreaming && !chatController.streamedContent.isEmpty {
                        streamingBubble
                            .id("streaming")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: chatController.messages.count) { _, _ in
                if let lastId = chatController.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
            .onChange(of: chatController.streamedContent) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
            }
        }
    }

    private func messageBubble(_ message: ConvexChatMessage) -> some View {
        let isUser = message.role == "user"

        return HStack {
            if isUser { Spacer(minLength: 40) }

            Text(message.content)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isUser ? Color.accentColor.opacity(0.2) : Color.white.opacity(0.08))
                )
                .foregroundStyle(isUser ? .primary : .primary)

            if !isUser { Spacer(minLength: 40) }
        }
    }

    private var streamingBubble: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                    .opacity(0.8)

                Text(chatController.streamedContent)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )

            Spacer(minLength: 40)
        }
    }

    private var chatInputView: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message...", text: $sheetState.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...4)
                .onSubmit {
                    if !NSEvent.modifierFlags.contains(.shift) {
                        sendMessage()
                    }
                }

            Button(action: sendMessage) {
                Image(systemName: chatController.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(
                        sheetState.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chatController.isStreaming
                            ? .tertiary
                            : .accentColor
                    )
            }
            .buttonStyle(.plain)
            .disabled(sheetState.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chatController.isStreaming)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func selectThread(_ threadId: String) {
        sheetState.selectedThreadId = threadId
        Task {
            await chatController.fetchMessages(threadId: threadId)
        }
    }

    private func createNewThread() {
        let title = sheetState.newThreadTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        Task {
            if let threadId = await chatController.createThread(
                title: title,
                model: selectedModelForNewThread,
                spaceId: spaceController.currentSpaceId
            ) {
                await chatController.fetchThreads(spaceId: spaceController.currentSpaceId)
                sheetState.selectedThreadId = threadId
                sheetState.isCreatingThread = false
                sheetState.newThreadTitle = ""
            }
        }
    }

    private func sendMessage() {
        if chatController.isStreaming {
            chatController.cancelStream()
            return
        }

        let text = sheetState.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let threadId = sheetState.selectedThreadId else { return }

        sheetState.inputText = ""
        chatController.sendAndStream(threadId: threadId, content: text)
    }
}
```

**Step 2: Verify it compiles**

Run the compile script.
Expected: Compiles successfully.

**Step 3: Commit**

```bash
git add Sources/JackApp/ChatSideSheetView.swift
git commit -m "feat: add ChatSideSheetView with thread sidebar and streaming chat"
```

---

### Task 7: Add Global Shortcut for Chat Sheet

**Files:**
- Modify: `Sources/JackApp/GlobalFnShortcutMonitor.swift`
- Modify: `Sources/JackApp/DictationController.swift`

**Step 1: Add chat sheet shortcut slot to GlobalFnShortcutMonitor**

In `GlobalFnShortcutMonitor.swift`, add alongside the existing todo sheet shortcut fields (~line 77-79):

```swift
// Multi-key chat sheet shortcut
var onChatSheetKeyPressed: (() -> Void)?
private var chatSheetShortcut: InvocationShortcut?
private var isChatSheetShortcutActive = false
```

Add the setter method alongside `setTodoSheetShortcut` (~line 96-99):

```swift
func setChatSheetShortcut(_ shortcut: InvocationShortcut?) {
    chatSheetShortcut = shortcut
    isChatSheetShortcutActive = false
}
```

Add the modifier-based matching block right after the todo sheet shortcut block (~line 249-263), following the same pattern:

```swift
// Chat sheet shortcut: modifier-based matching
if let csShortcut = chatSheetShortcut {
    if csShortcut != invocationShortcut {
        let csResult = evaluateModifierShortcut(csShortcut, keyCode: keyCode, isActive: isChatSheetShortcutActive)
        if let csResult {
            if csResult, !isChatSheetShortcutActive {
                isChatSheetShortcutActive = true
                onChatSheetKeyPressed?()
            } else if !csResult {
                isChatSheetShortcutActive = false
            }
            return true
        }
    }
}
```

Add the non-modifier key variant matching block right after the todo sheet non-modifier block (~line 383-394):

```swift
// Chat sheet shortcut (non-modifier key variant)
if let csShortcut = chatSheetShortcut, csShortcut != invocationShortcut {
    if matchesKeyEvent(csShortcut, keyCode: keyCode, isKeyDown: isKeyDown) {
        if isKeyDown {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat {
                onChatSheetKeyPressed?()
            }
        }
        return true
    }
}
```

**Step 2: Add chat sheet shortcut to DictationController**

In `DictationController.swift`, add these fields alongside the todo sheet fields:

Near line 73 (published properties):
```swift
@Published private(set) var chatSheetShortcut: InvocationShortcut?
```

Near line 79 (capturing flags):
```swift
@Published var isCapturingChatSheetKey = false
```

Add DefaultsKey (~line 338):
```swift
static let chatSheetShortcutJSON = "chat_sheet_shortcut_json"
```

In the `loadDefaults()` method, add chat sheet loading alongside todo sheet loading (~line 440):
```swift
if let jsonData = defaults.data(forKey: DefaultsKey.chatSheetShortcutJSON),
   let shortcut = try? JSONDecoder().decode(InvocationShortcut.self, from: jsonData) {
    initialChatSheetShortcut = shortcut
}
```

(Add a local var `initialChatSheetShortcut` similar to the todo pattern, then assign):
```swift
chatSheetShortcut = initialChatSheetShortcut
```

In the shortcut monitor wiring (~line 556-561), add:
```swift
if let initialChatSheetShortcut = chatSheetShortcut {
    shortcutMonitor.setChatSheetShortcut(initialChatSheetShortcut)
}
shortcutMonitor.onChatSheetKeyPressed = { [weak self] in
    Task { @MainActor [weak self] in
        self?.handleChatSheetShortcut()
    }
}
```

Add `handleChatSheetShortcut()` alongside `handleTodoSheetShortcut()` (~line 1062):
```swift
private func handleChatSheetShortcut() {
    guard !isCapturingInvocationKey, !isCapturingVoiceNoteSwitchKey, !isCapturingScreenRecordingKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey, !isCapturingChatSheetKey else {
        return
    }
    ChatSideSheetController.shared.toggle()
}
```

Add `setChatSheetShortcut()` private method alongside `setTodoSheetShortcut()` (~line 2295):
```swift
private func setChatSheetShortcut(_ shortcut: InvocationShortcut) {
    chatSheetShortcut = shortcut
    shortcutMonitor.setChatSheetShortcut(shortcut)
    if let data = try? JSONEncoder().encode(shortcut) {
        UserDefaults.standard.set(data, forKey: DefaultsKey.chatSheetShortcutJSON)
    }
}
```

Add the `isCapturingChatSheetKey` flag to ALL the guard statements that check other capturing flags (search for `isCapturingTodoSheetKey` and add `!isCapturingChatSheetKey` alongside it in every occurrence).

**Step 3: Set default shortcut**

In the defaults loading section, set a default shortcut if none exists:
```swift
// Default: Control+Shift+A (keyCode 0 = A)
let defaultChatSheetShortcut = InvocationShortcut(
    primaryKeyCode: 0,
    modifiers: UInt(NSEvent.ModifierFlags.control.rawValue | NSEvent.ModifierFlags.shift.rawValue)
)
```

**Step 4: Verify it compiles**

Run the compile script.
Expected: Compiles successfully.

**Step 5: Commit**

```bash
git add Sources/JackApp/GlobalFnShortcutMonitor.swift Sources/JackApp/DictationController.swift
git commit -m "feat: add global shortcut slot for chat side sheet (Ctrl+Shift+A)"
```

---

### Task 8: Wire ChatSideSheetController into App + Settings

**Files:**
- Modify: `Sources/JackApp/ContentView.swift` (or wherever settings UI lives)
- Modify: `Sources/JackApp/JackApp.swift` (if needed for initialization)

**Step 1: Identify where TodoSideSheetController is wired into the app**

Search for `TodoSideSheetController` references in `JackApp.swift` and `ContentView.swift` and replicate for `ChatSideSheetController`.

The key integration point: make sure `ChatSideSheetController.shared.spaceController` is set to the same `SpaceController` instance used by the app. Follow the exact same pattern as `TodoSideSheetController`.

**Step 2: Add settings UI for the chat shortcut**

In the settings view (same file that has the todo sheet shortcut settings), add a row for "AI Chat Shortcut" that allows capturing a new shortcut. Follow the exact same pattern as the todo sheet shortcut row:

```swift
// AI Chat Sheet Shortcut row — same pattern as Todo Sheet
HStack {
    Text("AI Chat")
    Spacer()
    Text(dictationController.chatSheetShortcutDisplayName)
        .foregroundStyle(.secondary)
    Button(dictationController.isCapturingChatSheetKey ? "Press keys..." : "Set") {
        dictationController.startCapturingChatSheetKey()
    }
}
```

Add the `chatSheetShortcutDisplayName` computed property to `DictationController`:
```swift
var chatSheetShortcutDisplayName: String {
    chatSheetShortcut?.displayName ?? "Not Set"
}
```

**Step 3: Add capturing methods to DictationController**

Follow the same pattern as `startCapturingTodoSheetKey()` / `finishCapturingTodoSheetKey()`:

```swift
func startCapturingChatSheetKey() {
    guard !isCapturingInvocationKey, !isCapturingVoiceNoteSwitchKey, !isCapturingScreenRecordingKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey, !isCapturingChatSheetKey else {
        return
    }
    isCapturingChatSheetKey = true
}

func finishCapturingChatSheetKey(with shortcut: InvocationShortcut) {
    guard isCapturingChatSheetKey else { return }
    isCapturingChatSheetKey = false
    setChatSheetShortcut(shortcut)
}

func clearChatSheetShortcut() {
    chatSheetShortcut = nil
    shortcutMonitor.setChatSheetShortcut(nil)
    UserDefaults.standard.removeObject(forKey: DefaultsKey.chatSheetShortcutJSON)
}
```

**Step 4: Verify it compiles and test manually**

Run the compile script.
Expected: Compiles. When running the app, pressing Ctrl+Shift+A should toggle the chat panel.

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: wire ChatSideSheetController into app and add settings UI"
```

---

### Task 9: Polish and Edge Cases

**Files:**
- Various files from previous tasks

**Step 1: Handle the delete confirmation flow**

In `ChatSideSheetView`, add a confirmation alert/overlay when `sheetState.isConfirmingDelete` is true:

```swift
.alert("Delete Chat?", isPresented: $sheetState.isConfirmingDelete) {
    Button("Delete", role: .destructive) {
        if let threadId = sheetState.selectedThreadId {
            Task {
                await chatController.deleteThread(threadId: threadId)
                await chatController.fetchThreads(spaceId: spaceController.currentSpaceId)
                sheetState.selectedThreadId = chatController.threads.first?.id
            }
        }
    }
    Button("Cancel", role: .cancel) {}
} message: {
    Text("This will permanently delete this chat and all its messages.")
}
```

**Step 2: Auto-select first thread on open**

In `ChatSideSheetController.show()`, after fetching threads, auto-select the first one:

```swift
Task {
    await chatController.fetchThreads(spaceId: spaceController.currentSpaceId)
    await chatController.fetchModels()
    if sheetState.selectedThreadId == nil, let firstThread = chatController.threads.first {
        sheetState.selectedThreadId = firstThread.id
        await chatController.fetchMessages(threadId: firstThread.id)
    }
}
```

**Step 3: Add relative timestamp helper**

Add a helper function to `ChatSideSheetView` for displaying relative timestamps on thread rows:

```swift
private func relativeTime(_ timestamp: Double) -> String {
    let date = Date(timeIntervalSince1970: timestamp / 1000)
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}
```

Then use it in `threadRow`:
```swift
Text(relativeTime(thread.updatedAt))
    .font(.system(size: 9))
    .foregroundStyle(.quaternary)
```

**Step 4: Verify everything compiles and works**

Run the compile script.
Expected: Full compile success.

**Step 5: Commit**

```bash
git add -A
git commit -m "fix: add delete confirmation, auto-select thread, and relative timestamps"
```

---

## Summary of All Files

### New files:
1. `convex/chats.ts` — Convex queries, mutations, actions for chat
2. `Sources/JackApp/Sync/ChatController.swift` — Chat data sync + streaming client
3. `Sources/JackApp/ChatSideSheetController.swift` — Panel controller (mirrors TodoSideSheetController)
4. `Sources/JackApp/ChatSideSheetView.swift` — SwiftUI view with thread sidebar + chat

### Modified files:
5. `convex/schema.ts` — Add chatThreads + chatMessages tables
6. `convex/http.ts` — Add POST /chat/stream SSE proxy endpoint
7. `Sources/JackApp/GlobalFnShortcutMonitor.swift` — Add chat sheet shortcut slot
8. `Sources/JackApp/DictationController.swift` — Add chat sheet shortcut persistence + capturing
9. `Sources/JackApp/ContentView.swift` — Add chat shortcut settings row
10. `Sources/JackApp/JackApp.swift` — Wire ChatSideSheetController
