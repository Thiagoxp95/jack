# Todo Mode Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a voice-dictated Todo mode with LLM structuring (OpenRouter + Vercel AI SDK), lists, tags, priorities, reminders, and list/Kanban UI views.

**Architecture:** Mirror the existing Notes mode pattern. A new `.todo` RecordingOutputMode is activated by a dedicated key (T) during recording. After local Parakeet transcription, raw text is sent to a Convex action that calls OpenRouter to extract structured todo data, saves it, and schedules reminders. The UI adds a Todos section with list and Kanban views.

**Tech Stack:** Swift/SwiftUI (macOS client), Convex (backend), Vercel AI SDK + OpenRouter (LLM), UNUserNotificationCenter (reminders)

---

### Task 1: Install npm dependencies

**Files:**
- Modify: `package.json`

**Step 1: Install Vercel AI SDK and OpenRouter provider**

```bash
cd /Users/txp/Pessoal/jack-v2
npm install ai @openrouter/ai-sdk-provider zod
```

**Step 2: Verify installation**

```bash
node -e "require('ai'); require('@openrouter/ai-sdk-provider'); require('zod'); console.log('OK')"
```

Expected: `OK`

**Step 3: Commit**

```bash
git add package.json package-lock.json
git commit -m "chore: add Vercel AI SDK and OpenRouter provider dependencies"
```

---

### Task 2: Add todos and todoLists tables to Convex schema

**Files:**
- Modify: `convex/schema.ts:48` (before the closing `});`)

**Step 1: Add the new table definitions**

Add after the `recordings` table definition (after line 78) in `convex/schema.ts`:

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
    .index("by_space_user", ["spaceId", "userId"]),

  todos: defineTable({
    spaceId: v.optional(v.id("spaces")),
    userId: v.id("users"),
    title: v.string(),
    description: v.optional(v.string()),
    status: v.union(v.literal("todo"), v.literal("in_progress"), v.literal("done")),
    priority: v.union(v.literal("none"), v.literal("low"), v.literal("medium"), v.literal("high")),
    listId: v.optional(v.id("todoLists")),
    tags: v.optional(v.array(v.string())),
    dueDate: v.optional(v.string()),
    dueTime: v.optional(v.string()),
    reminders: v.optional(v.array(v.object({
      at: v.number(),
      scheduledFunctionId: v.optional(v.id("_scheduled_functions")),
      delivered: v.optional(v.boolean()),
    }))),
    completedAt: v.optional(v.number()),
    rawTranscription: v.optional(v.string()),
    createdAt: v.number(),
  })
    .index("by_space", ["spaceId"])
    .index("by_space_user", ["spaceId", "userId"])
    .index("by_list", ["listId"])
    .index("by_status", ["status"]),
```

**Step 2: Push schema to verify it's valid**

```bash
npx convex dev --once
```

Expected: Schema validation passes, new tables created.

**Step 3: Commit**

```bash
git add convex/schema.ts
git commit -m "feat: add todos and todoLists tables to Convex schema"
```

---

### Task 3: Create Convex CRUD functions for todoLists

**Files:**
- Create: `convex/todoLists.ts`

**Step 1: Create the todoLists functions file**

```typescript
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";

export const list = query({
  args: { spaceId: v.optional(v.id("spaces")) },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) return [];

    if (args.spaceId) {
      const membership = await ctx.db
        .query("space_members")
        .withIndex("by_space_user", (q) =>
          q.eq("spaceId", args.spaceId!).eq("userId", user._id),
        )
        .unique();
      if (!membership) throw new Error("Not a member of this space");

      return await ctx.db
        .query("todoLists")
        .withIndex("by_space", (q) => q.eq("spaceId", args.spaceId))
        .collect();
    }

    return await ctx.db
      .query("todoLists")
      .withIndex("by_space_user", (q) =>
        q.eq("spaceId", undefined).eq("userId", user._id),
      )
      .collect();
  },
});

export const create = mutation({
  args: {
    spaceId: v.optional(v.id("spaces")),
    name: v.string(),
    color: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found");

    if (args.spaceId) {
      const membership = await ctx.db
        .query("space_members")
        .withIndex("by_space_user", (q) =>
          q.eq("spaceId", args.spaceId!).eq("userId", user._id),
        )
        .unique();
      if (!membership) throw new Error("Not a member of this space");
    }

    return await ctx.db.insert("todoLists", {
      spaceId: args.spaceId,
      userId: user._id,
      name: args.name,
      color: args.color,
      createdAt: Date.now(),
    });
  },
});

export const update = mutation({
  args: {
    listId: v.id("todoLists"),
    name: v.optional(v.string()),
    color: v.optional(v.string()),
    sortOrder: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const list = await ctx.db.get(args.listId);
    if (!list) throw new Error("List not found");

    const patch: Record<string, unknown> = {};
    if (args.name !== undefined) patch.name = args.name;
    if (args.color !== undefined) patch.color = args.color;
    if (args.sortOrder !== undefined) patch.sortOrder = args.sortOrder;

    await ctx.db.patch(args.listId, patch);
  },
});

export const remove = mutation({
  args: { listId: v.id("todoLists") },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");
    await ctx.db.delete(args.listId);
  },
});
```

**Step 2: Verify it compiles**

```bash
npx convex dev --once
```

Expected: No errors.

**Step 3: Commit**

```bash
git add convex/todoLists.ts
git commit -m "feat: add todoLists CRUD functions"
```

---

### Task 4: Create Convex CRUD functions for todos

**Files:**
- Create: `convex/todos.ts`

**Step 1: Create the todos functions file**

```typescript
import { v } from "convex/values";
import {
  action,
  internalMutation,
  mutation,
  query,
} from "./_generated/server";
import { internal } from "./_generated/api";

export const list = query({
  args: { spaceId: v.optional(v.id("spaces")) },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) return [];

    if (args.spaceId) {
      const membership = await ctx.db
        .query("space_members")
        .withIndex("by_space_user", (q) =>
          q.eq("spaceId", args.spaceId!).eq("userId", user._id),
        )
        .unique();
      if (!membership) throw new Error("Not a member of this space");

      return await ctx.db
        .query("todos")
        .withIndex("by_space", (q) => q.eq("spaceId", args.spaceId))
        .order("desc")
        .collect();
    }

    return await ctx.db
      .query("todos")
      .withIndex("by_space_user", (q) =>
        q.eq("spaceId", undefined).eq("userId", user._id),
      )
      .order("desc")
      .collect();
  },
});

export const create = mutation({
  args: {
    spaceId: v.optional(v.id("spaces")),
    title: v.string(),
    description: v.optional(v.string()),
    status: v.optional(
      v.union(v.literal("todo"), v.literal("in_progress"), v.literal("done")),
    ),
    priority: v.optional(
      v.union(
        v.literal("none"),
        v.literal("low"),
        v.literal("medium"),
        v.literal("high"),
      ),
    ),
    listId: v.optional(v.id("todoLists")),
    tags: v.optional(v.array(v.string())),
    dueDate: v.optional(v.string()),
    dueTime: v.optional(v.string()),
    rawTranscription: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found");

    if (args.spaceId) {
      const membership = await ctx.db
        .query("space_members")
        .withIndex("by_space_user", (q) =>
          q.eq("spaceId", args.spaceId!).eq("userId", user._id),
        )
        .unique();
      if (!membership) throw new Error("Not a member of this space");
    }

    return await ctx.db.insert("todos", {
      spaceId: args.spaceId,
      userId: user._id,
      title: args.title,
      description: args.description,
      status: args.status ?? "todo",
      priority: args.priority ?? "none",
      listId: args.listId,
      tags: args.tags,
      dueDate: args.dueDate,
      dueTime: args.dueTime,
      rawTranscription: args.rawTranscription,
      createdAt: Date.now(),
    });
  },
});

export const update = mutation({
  args: {
    todoId: v.id("todos"),
    title: v.optional(v.string()),
    description: v.optional(v.string()),
    status: v.optional(
      v.union(v.literal("todo"), v.literal("in_progress"), v.literal("done")),
    ),
    priority: v.optional(
      v.union(
        v.literal("none"),
        v.literal("low"),
        v.literal("medium"),
        v.literal("high"),
      ),
    ),
    listId: v.optional(v.id("todoLists")),
    tags: v.optional(v.array(v.string())),
    dueDate: v.optional(v.string()),
    dueTime: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const todo = await ctx.db.get(args.todoId);
    if (!todo) throw new Error("Todo not found");

    const patch: Record<string, unknown> = {};
    if (args.title !== undefined) patch.title = args.title;
    if (args.description !== undefined) patch.description = args.description;
    if (args.priority !== undefined) patch.priority = args.priority;
    if (args.listId !== undefined) patch.listId = args.listId;
    if (args.tags !== undefined) patch.tags = args.tags;
    if (args.dueDate !== undefined) patch.dueDate = args.dueDate;
    if (args.dueTime !== undefined) patch.dueTime = args.dueTime;

    if (args.status !== undefined) {
      patch.status = args.status;
      if (args.status === "done") {
        patch.completedAt = Date.now();
      } else {
        patch.completedAt = undefined;
      }
    }

    await ctx.db.patch(args.todoId, patch);
  },
});

export const remove = mutation({
  args: { todoId: v.id("todos") },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const todo = await ctx.db.get(args.todoId);
    if (!todo) throw new Error("Todo not found");

    // Cancel any scheduled reminders
    if (todo.reminders) {
      for (const reminder of todo.reminders) {
        if (reminder.scheduledFunctionId) {
          try {
            await ctx.scheduler.cancel(reminder.scheduledFunctionId);
          } catch {
            // Already fired or cancelled — ignore
          }
        }
      }
    }

    await ctx.db.delete(args.todoId);
  },
});

export const moveToSpace = mutation({
  args: {
    todoId: v.id("todos"),
    targetSpaceId: v.optional(v.id("spaces")),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const todo = await ctx.db.get(args.todoId);
    if (!todo) throw new Error("Todo not found");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found");
    if (todo.userId !== user._id) throw new Error("Not authorized");

    if (args.targetSpaceId) {
      const membership = await ctx.db
        .query("space_members")
        .withIndex("by_space_user", (q) =>
          q.eq("spaceId", args.targetSpaceId!).eq("userId", user._id),
        )
        .unique();
      if (!membership) throw new Error("Not a member of the target space");
    }

    await ctx.db.patch(args.todoId, { spaceId: args.targetSpaceId });
  },
});

// Internal mutation for scheduling reminders
export const fireReminder = internalMutation({
  args: {
    todoId: v.id("todos"),
    reminderIndex: v.number(),
  },
  handler: async (ctx, args) => {
    const todo = await ctx.db.get(args.todoId);
    if (!todo) return;
    if (todo.status === "done") return;

    // Mark the specific reminder as delivered
    if (todo.reminders) {
      const updated = [...todo.reminders];
      if (updated[args.reminderIndex]) {
        updated[args.reminderIndex] = {
          ...updated[args.reminderIndex],
          delivered: true,
        };
        await ctx.db.patch(args.todoId, { reminders: updated });
      }
    }
  },
});

// Internal mutation used by the processAndCreate action
export const insertFromAction = internalMutation({
  args: {
    userId: v.id("users"),
    spaceId: v.optional(v.id("spaces")),
    title: v.string(),
    description: v.optional(v.string()),
    status: v.union(v.literal("todo"), v.literal("in_progress"), v.literal("done")),
    priority: v.union(
      v.literal("none"),
      v.literal("low"),
      v.literal("medium"),
      v.literal("high"),
    ),
    listId: v.optional(v.id("todoLists")),
    tags: v.optional(v.array(v.string())),
    dueDate: v.optional(v.string()),
    dueTime: v.optional(v.string()),
    reminders: v.optional(v.array(v.object({
      at: v.number(),
      scheduledFunctionId: v.optional(v.id("_scheduled_functions")),
      delivered: v.optional(v.boolean()),
    }))),
    rawTranscription: v.optional(v.string()),
    createdAt: v.number(),
  },
  handler: async (ctx, args) => {
    const todoId = await ctx.db.insert("todos", args);

    // Schedule reminders
    if (args.reminders) {
      const updatedReminders = [];
      for (let i = 0; i < args.reminders.length; i++) {
        const reminder = args.reminders[i];
        if (reminder.at > Date.now()) {
          const scheduledId = await ctx.scheduler.runAt(
            reminder.at,
            internal.todos.fireReminder,
            { todoId, reminderIndex: i },
          );
          updatedReminders.push({ ...reminder, scheduledFunctionId: scheduledId });
        } else {
          updatedReminders.push({ ...reminder, delivered: true });
        }
      }
      await ctx.db.patch(todoId, { reminders: updatedReminders });
    }

    return todoId;
  },
});

// Query for pending (delivered but unacknowledged) reminders
export const pendingReminders = query({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) return [];

    // Get all non-done todos for this user that have delivered reminders
    const allTodos = await ctx.db
      .query("todos")
      .filter((q) => q.eq(q.field("userId"), user._id))
      .collect();

    return allTodos.filter((todo) => {
      if (todo.status === "done") return false;
      if (!todo.reminders) return false;
      return todo.reminders.some((r) => r.delivered === true);
    });
  },
});

// Mark a reminder as acknowledged (clear the delivered flag)
export const acknowledgeReminder = mutation({
  args: {
    todoId: v.id("todos"),
    reminderIndex: v.number(),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const todo = await ctx.db.get(args.todoId);
    if (!todo || !todo.reminders) return;

    const updated = [...todo.reminders];
    // Remove the acknowledged reminder
    updated.splice(args.reminderIndex, 1);
    await ctx.db.patch(args.todoId, { reminders: updated.length > 0 ? updated : undefined });
  },
});
```

**Step 2: Verify it compiles**

```bash
npx convex dev --once
```

Expected: No errors.

**Step 3: Commit**

```bash
git add convex/todos.ts
git commit -m "feat: add todos CRUD functions with reminders and internal mutations"
```

---

### Task 5: Create the LLM processing Convex action

**Files:**
- Modify: `convex/todos.ts` (add `processAndCreate` action at the end)

**Step 1: Add the processAndCreate action**

Add at the end of `convex/todos.ts`:

```typescript
// Action: process raw transcription with LLM and create structured todo
export const processAndCreate = action({
  args: {
    rawText: v.string(),
    spaceId: v.optional(v.id("spaces")),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    // Look up user
    const user = await ctx.runQuery(internal.todos.getUserByClerkId, {
      clerkId: identity.subject,
    });
    if (!user) throw new Error("User not found");

    // Verify space membership if spaceId provided
    if (args.spaceId) {
      const isMember = await ctx.runQuery(internal.todos.checkSpaceMembership, {
        spaceId: args.spaceId,
        userId: user._id,
      });
      if (!isMember) throw new Error("Not a member of this space");
    }

    // Call LLM via OpenRouter
    const { generateObject } = await import("ai");
    const { createOpenRouter } = await import("@openrouter/ai-sdk-provider");
    const { z } = await import("zod");

    const openrouter = createOpenRouter({
      apiKey: process.env.OPENROUTER_API_KEY,
    });

    const today = new Date().toISOString().split("T")[0];
    const now = new Date().toISOString().split("T")[1]?.substring(0, 5) ?? "12:00";

    const { object: parsed } = await generateObject({
      model: openrouter("google/gemini-2.0-flash-001"),
      schema: z.object({
        title: z.string().describe("Clean, concise task title"),
        description: z.string().optional().describe("Additional details if mentioned"),
        dueDate: z.string().optional().describe("Due date in yyyy-MM-dd format, resolved relative to today"),
        dueTime: z.string().optional().describe("Due time in HH:mm 24h format"),
        priority: z.enum(["none", "low", "medium", "high"]).describe("Inferred from urgency cues; default none"),
        tags: z.array(z.string()).optional().describe("Context tags like 'work', 'shopping'"),
        listName: z.string().optional().describe("List/project name if user mentions one"),
        reminders: z.array(z.object({
          offsetMinutes: z.number().optional().describe("Minutes before due date, negative = before"),
          absoluteTime: z.string().optional().describe("Absolute time in yyyy-MM-ddTHH:mm format"),
        })).optional().describe("Reminder specifications"),
      }),
      prompt: `You are a task parser. Given a voice transcription, extract a structured todo item.

Rules:
- Clean up filler words and fix grammar for the title
- Today's date is ${today}, current time is ${now}
- Resolve relative dates ("tomorrow", "next Friday", "in 3 days") to yyyy-MM-dd
- Resolve relative times ("at 3pm", "by noon") to HH:mm 24h format
- If no priority is mentioned, use "none"
- If no due date is mentioned, leave it null
- Extract tags from context (e.g., "work task" → tag "work")
- If user says "add to my X list" or "for X project", extract as listName

Transcription: "${args.rawText}"`,
    });

    // Resolve listName to listId if provided
    let listId: string | undefined;
    if (parsed.listName) {
      const lists = await ctx.runQuery(internal.todos.getListsBySpace, {
        spaceId: args.spaceId,
        userId: user._id,
      });
      const match = lists.find(
        (l: { name: string }) => l.name.toLowerCase() === parsed.listName!.toLowerCase(),
      );
      if (match) {
        listId = match._id;
      } else {
        // Auto-create the list
        listId = await ctx.runMutation(internal.todos.createListFromAction, {
          spaceId: args.spaceId,
          userId: user._id,
          name: parsed.listName,
        });
      }
    }

    // Resolve reminder times to absolute timestamps
    const resolvedReminders: Array<{ at: number }> = [];
    if (parsed.reminders) {
      for (const r of parsed.reminders) {
        if (r.absoluteTime) {
          const ts = new Date(r.absoluteTime).getTime();
          if (!isNaN(ts)) resolvedReminders.push({ at: ts });
        } else if (r.offsetMinutes != null && parsed.dueDate) {
          const dueStr = parsed.dueTime
            ? `${parsed.dueDate}T${parsed.dueTime}`
            : `${parsed.dueDate}T09:00`;
          const dueTs = new Date(dueStr).getTime();
          if (!isNaN(dueTs)) {
            resolvedReminders.push({ at: dueTs + r.offsetMinutes * 60_000 });
          }
        }
      }
    }

    // Insert via internal mutation (so we can schedule reminders transactionally)
    const todoId = await ctx.runMutation(internal.todos.insertFromAction, {
      userId: user._id,
      spaceId: args.spaceId,
      title: parsed.title,
      description: parsed.description,
      status: "todo",
      priority: parsed.priority,
      listId: listId as any,
      tags: parsed.tags,
      dueDate: parsed.dueDate,
      dueTime: parsed.dueTime,
      reminders: resolvedReminders.length > 0 ? resolvedReminders : undefined,
      rawTranscription: args.rawText,
      createdAt: Date.now(),
    });

    return todoId;
  },
});
```

**Step 2: Add the internal helper queries/mutations**

Add these internal helpers to the same file, before the `processAndCreate` action:

```typescript
// Internal helpers for the processAndCreate action
export const getUserByClerkId = internalQuery({
  args: { clerkId: v.string() },
  handler: async (ctx, args) => {
    return await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", args.clerkId))
      .unique();
  },
});

export const checkSpaceMembership = internalQuery({
  args: { spaceId: v.id("spaces"), userId: v.id("users") },
  handler: async (ctx, args) => {
    const membership = await ctx.db
      .query("space_members")
      .withIndex("by_space_user", (q) =>
        q.eq("spaceId", args.spaceId).eq("userId", args.userId),
      )
      .unique();
    return !!membership;
  },
});

export const getListsBySpace = internalQuery({
  args: { spaceId: v.optional(v.id("spaces")), userId: v.id("users") },
  handler: async (ctx, args) => {
    if (args.spaceId) {
      return await ctx.db
        .query("todoLists")
        .withIndex("by_space", (q) => q.eq("spaceId", args.spaceId))
        .collect();
    }
    return await ctx.db
      .query("todoLists")
      .withIndex("by_space_user", (q) =>
        q.eq("spaceId", undefined).eq("userId", args.userId),
      )
      .collect();
  },
});

export const createListFromAction = internalMutation({
  args: {
    spaceId: v.optional(v.id("spaces")),
    userId: v.id("users"),
    name: v.string(),
  },
  handler: async (ctx, args) => {
    return await ctx.db.insert("todoLists", {
      spaceId: args.spaceId,
      userId: args.userId,
      name: args.name,
      createdAt: Date.now(),
    });
  },
});
```

Update the imports at the top of `convex/todos.ts` to include `internalQuery`:

```typescript
import {
  action,
  internalMutation,
  internalQuery,
  mutation,
  query,
} from "./_generated/server";
```

**Step 3: Add OPENROUTER_API_KEY env var to Convex**

```bash
npx convex env set OPENROUTER_API_KEY <your-key>
```

**Step 4: Verify it compiles**

```bash
npx convex dev --once
```

Expected: No errors.

**Step 5: Commit**

```bash
git add convex/todos.ts
git commit -m "feat: add LLM-powered processAndCreate action for voice-to-todo"
```

---

### Task 6: Add `.todo` to RecordingOutputMode

**Files:**
- Modify: `Sources/JackApp/ShortcutTypes.swift:69-83`

**Step 1: Add the todo case**

In `ShortcutTypes.swift`, add `.todo` to the enum and update `title`:

```swift
enum RecordingOutputMode: String, CaseIterable, Identifiable {
    case paste
    case voiceNote
    case todo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paste:
            return "Paste"
        case .voiceNote:
            return "Voice Note"
        case .todo:
            return "Todo"
        }
    }
}
```

**Step 2: Fix all switch exhaustiveness errors**

The compiler will report non-exhaustive switch errors. Update these locations in `DictationController.swift`:

In `listeningBubbleMessage()` (~line 796):
```swift
private func listeningBubbleMessage() -> String {
    switch recordingOutputMode {
    case .paste:
        return "Listening..."
    case .voiceNote:
        return "Listening (Note Mode)..."
    case .todo:
        return "Listening (Todo Mode)..."
    }
}
```

In `listeningStatusText(isLive:)` (~line 805):
```swift
private func listeningStatusText(isLive: Bool) -> String {
    switch (recordingOutputMode, isLive) {
    case (.paste, false):
        return "Listening..."
    case (.paste, true):
        return "Listening... (live)"
    case (.voiceNote, false):
        return "Listening... (note mode)"
    case (.voiceNote, true):
        return "Listening... (note mode, live)"
    case (.todo, false):
        return "Listening... (todo mode)"
    case (.todo, true):
        return "Listening... (todo mode, live)"
    }
}
```

In `handleTranscriptionResult(_:)` (~line 1086), add the `.todo` case after `.voiceNote`:
```swift
case .todo:
    statusText = "Creating todo..."
    Task { await syncTodoToConvex(text: cleaned) }
    bubble.hide()
```

In `showBubble(message:isRecording:isTranscribing:)` (~line 1566), update `isNoteMode` to handle both modes:
```swift
private func showBubble(message: String, isRecording: Bool, isTranscribing: Bool = false) {
    syncSpaceAppearance()
    indicatorPreviewHideTask?.cancel()
    indicatorPreviewHideTask = nil
    bubbleHideTask?.cancel()
    bubble.show(
        message: message,
        isRecording: isRecording,
        isTranscribing: isTranscribing,
        isNoteMode: recordingOutputMode == .voiceNote,
        isTodoMode: recordingOutputMode == .todo,
        riveAssetPath: riveAssetPathIfEnabled(forRecordingState: isRecording),
        htmlIndicatorMarkup: (isRecording || isTranscribing) ? preferredCustomSVGMarkup() : nil,
        useBuiltInWaveIndicator: builtInWaveIndicatorEnabled
    )
}
```

**Step 3: Compile to check**

```bash
swift build 2>&1 | head -30
```

Expected: May still have errors from FloatingBubbleController (Task 8 fixes those). The ShortcutTypes and DictationController switch statements should be resolved.

**Step 4: Commit**

```bash
git add Sources/JackApp/ShortcutTypes.swift Sources/JackApp/DictationController.swift
git commit -m "feat: add .todo case to RecordingOutputMode with status text"
```

---

### Task 7: Add todo switch key to GlobalFnShortcutMonitor

**Files:**
- Modify: `Sources/JackApp/GlobalFnShortcutMonitor.swift`

**Step 1: Add todo switch properties and callback**

Add after the existing voice note switch properties (~line 34):

```swift
var onTodoSwitchKeyPressed: (() -> Void)?

// Add these private properties after the voiceNoteSwitch ones (~line 36):
private var todoSwitchKeyCode: Int64?
private var todoSwitchArmed = false
private var consumeTodoSwitchKeyUp = false
```

**Step 2: Add setter method**

Add after `setVoiceNoteSwitchKeyCode` (~line 47):

```swift
func setTodoSwitchKeyCode(_ keyCode: Int64?) {
    todoSwitchKeyCode = keyCode
    consumeTodoSwitchKeyUp = false
}

func setTodoSwitchArmed(_ armed: Bool) {
    todoSwitchArmed = armed
    if !armed {
        consumeTodoSwitchKeyUp = false
    }
}
```

**Step 3: Update handleFlagsChanged to arm todo switch**

In `handleFlagsChanged`, where `voiceNoteSwitchArmed` is set to true (line 218-219), add todo arming:

```swift
if keyDown {
    isInvocationKeyPressed = true
    if voiceNoteSwitchKeyCode != nil {
        voiceNoteSwitchArmed = true
    }
    if todoSwitchKeyCode != nil {
        todoSwitchArmed = true
    }
    onEvent?(.down)
```

And in the key-up branch, reset todo state:

After `voiceNoteSwitchArmed = false` in the `stop()` method (~line 188):
```swift
todoSwitchArmed = false
consumeTodoSwitchKeyUp = false
```

**Step 4: Update handleKeyEvent to handle todo key**

Add a new block in `handleKeyEvent` after the voice note switch block (~after line 287):

```swift
if let todoSwitchKeyCode,
   keyCode == todoSwitchKeyCode
{
    if isKeyDown {
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if isRepeat {
            return todoSwitchArmed
        }

        guard todoSwitchArmed else {
            return false
        }

        consumeTodoSwitchKeyUp = true
        onTodoSwitchKeyPressed?()
        return true
    }

    if consumeTodoSwitchKeyUp {
        consumeTodoSwitchKeyUp = false
        return true
    }

    return false
}
```

**Step 5: Also arm in the keyDown path for non-modifier invocation keys**

In the section around line 304-306 where voice note switch is armed for keyDown:

```swift
isInvocationKeyPressed = isKeyDown
if isKeyDown, voiceNoteSwitchKeyCode != nil {
    voiceNoteSwitchArmed = true
}
if isKeyDown, todoSwitchKeyCode != nil {
    todoSwitchArmed = true
}
```

**Step 6: Commit**

```bash
git add Sources/JackApp/GlobalFnShortcutMonitor.swift
git commit -m "feat: add todo switch key handling to GlobalFnShortcutMonitor"
```

---

### Task 8: Update FloatingBubbleController for todo mode icon

**Files:**
- Modify: `Sources/JackApp/FloatingBubbleController.swift`

**Step 1: Update PillIndicatorView.update() to handle todo mode**

Change the method signature (~line 196) and logic:

```swift
func update(isRecording: Bool, isTranscribing: Bool, isNoteMode: Bool, isTodoMode: Bool, level: Double, shouldPulse: Bool) {
    let normalizedLevel = max(0, min(1, CGFloat(level)))
    isActive = isRecording || isTranscribing

    // Mode icon swap
    let newMode: Int = isTodoMode ? 2 : (isNoteMode ? 1 : 0)
    if newMode != currentMode {
        currentMode = newMode
        if isTodoMode {
            if let img = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Todo") {
                iconImageView.image = img
            }
            iconEmojiLabel.isHidden = true
            iconImageView.isHidden = false
        } else if isNoteMode {
            if let img = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Note") {
                iconImageView.image = img
            }
            iconEmojiLabel.isHidden = true
            iconImageView.isHidden = false
        } else if let saved = savedSpaceIcon {
            applyIcon(saved)
        }
    }

    // ... rest unchanged
```

Replace the `currentIsNoteMode` property with `currentMode: Int`:

```swift
private var currentMode: Int = 0  // 0=space, 1=note, 2=todo
```

Remove the old `currentIsNoteMode` property.

**Step 2: Update FloatingBubbleController.show() signature**

Add `isTodoMode` parameter (~line 289):

```swift
func show(
    message _: String,
    isRecording: Bool,
    isTranscribing: Bool,
    isNoteMode: Bool = false,
    isTodoMode: Bool = false,
    riveAssetPath _: String?,
    htmlIndicatorMarkup _: String?,
    useBuiltInWaveIndicator _: Bool
) {
```

Add `currentIsTodoMode` property and pass it through:

```swift
private var currentIsTodoMode = false
```

In `show()`, set it and pass to `pillView?.update()`:

```swift
currentIsTodoMode = isTodoMode
// ...
pillView?.update(
    isRecording: isRecording,
    isTranscribing: isTranscribing,
    isNoteMode: isNoteMode,
    isTodoMode: isTodoMode,
    level: currentLevel,
    shouldPulse: false
)
```

In `applyReactiveUpdate()`, also pass `isTodoMode`:

```swift
pillView?.update(
    isRecording: currentIsRecording,
    isTranscribing: currentIsTranscribing,
    isNoteMode: currentIsNoteMode,
    isTodoMode: currentIsTodoMode,
    level: currentLevel,
    shouldPulse: shouldPulse
)
```

**Step 3: Commit**

```bash
git add Sources/JackApp/FloatingBubbleController.swift
git commit -m "feat: add todo mode checklist icon to floating bubble"
```

---

### Task 9: Wire todo switch key in DictationController

**Files:**
- Modify: `Sources/JackApp/DictationController.swift`

**Step 1: Add published properties**

Add after `screenRecordingKeyCode` (~line 65):

```swift
@Published private(set) var todoSwitchKeyCode: Int64
@Published var isCapturingTodoSwitchKey = false
```

Add after `lastNoteSavedAt` (~line 157):

```swift
@Published private(set) var lastTodoSavedAt: Date?
```

**Step 2: Add DefaultsKey**

Add in the `DefaultsKey` enum (~line 238):

```swift
static let todoSwitchKeyCode = "todo_switch_key_code"
```

**Step 3: Add KeyCaptureTarget case**

In `KeyCaptureTarget` enum (~line 255):

```swift
case todoSwitch
```

**Step 4: Initialize in init()**

In the initializer, after the screenRecordingKeyCode loading (~line 298):

```swift
if let stored = defaults.object(forKey: DefaultsKey.todoSwitchKeyCode) as? Int {
    todoSwitchKeyCode = Int64(stored)
} else {
    todoSwitchKeyCode = 17 // T key
}
```

Also initialize in the shortcutMonitor setup (~line 340):

```swift
shortcutMonitor.setTodoSwitchKeyCode(todoSwitchKeyCode)
```

**Step 5: Wire the callback**

After `shortcutMonitor.onVoiceNoteSwitchKeyPressed` (~line 358):

```swift
shortcutMonitor.onTodoSwitchKeyPressed = { [weak self] in
    Task { @MainActor [weak self] in
        self?.setTodoMode()
    }
}
```

**Step 6: Add setTodoMode method**

Add near `toggleRecordingOutputMode()` (~line 759):

```swift
private func setTodoMode() {
    guard isRecording, !isTranscribing else {
        return
    }

    recordingOutputMode = recordingOutputMode == .todo ? .paste : .todo
    statusText = listeningStatusText(isLive: false)
    showBubble(message: listeningBubbleMessage(), isRecording: true)
}
```

**Step 7: Add syncTodoToConvex method**

Add after `syncNoteToConvex` (~after line 1175):

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

**Step 8: Update shortcutMonitor arming**

In `beginRecording()`, where `setVoiceNoteSwitchArmed(true)` is called, add:

```swift
shortcutMonitor.setTodoSwitchArmed(true)
```

In all places where `setVoiceNoteSwitchArmed(false)` is called (error handlers, stop recording), add:

```swift
shortcutMonitor.setTodoSwitchArmed(false)
```

**Step 9: Commit**

```bash
git add Sources/JackApp/DictationController.swift
git commit -m "feat: wire todo switch key and syncTodoToConvex in DictationController"
```

---

### Task 10: Add ConvexHTTPClient.action() method

**Files:**
- Modify: `Sources/JackApp/Sync/ConvexHTTPClient.swift`

**Step 1: Add the action method**

Add after the existing `query()` method (~line 73):

```swift
/// Call a Convex action via the HTTP API.
/// This is `nonisolated` so it can be called from any actor context.
nonisolated static func action(
    function: String,
    args: [String: Any] = [:],
    token: String,
    deploymentUrl: String = AppConfig.convexDeploymentUrl
) async throws -> Any {
    try await call(
        endpoint: "action",
        function: function,
        args: args,
        token: token,
        deploymentUrl: deploymentUrl
    )
}
```

**Step 2: Verify it compiles**

The existing `call()` method already handles all endpoints generically — it just needs the endpoint string. No other changes needed.

**Step 3: Commit**

```bash
git add Sources/JackApp/Sync/ConvexHTTPClient.swift
git commit -m "feat: add action() method to ConvexHTTPClient"
```

---

### Task 11: Create TodoListController

**Files:**
- Create: `Sources/JackApp/Sync/TodoListController.swift`

**Step 1: Create the controller**

Model after `NoteListController.swift`:

```swift
import Foundation

struct ConvexTodo: Identifiable {
    let id: String
    let title: String
    let description: String?
    let status: String
    let priority: String
    let listId: String?
    let tags: [String]?
    let dueDate: String?
    let dueTime: String?
    let completedAt: Double?
    let rawTranscription: String?
    let createdAt: Double
    let spaceId: String?
    let reminders: [[String: Any]]?
}

struct ConvexTodoList: Identifiable {
    let id: String
    let name: String
    let color: String?
    let spaceId: String?
}

@MainActor @Observable
final class TodoListController {

    private(set) var todos: [ConvexTodo] = []
    private(set) var lists: [ConvexTodoList] = []
    private(set) var pendingReminderTodos: [ConvexTodo] = []
    private(set) var isLoading = false
    var error: String?

    private var reminderPollTask: Task<Void, Never>?

    func fetchTodos(spaceId: String?) async {
        isLoading = true
        error = nil

        do {
            let token = try await ConvexHTTPClient.getToken()

            var args: [String: Any] = [:]
            if let spaceId {
                args["spaceId"] = spaceId
            }

            let result = try await ConvexHTTPClient.query(
                function: "todos:list",
                args: args,
                token: token
            )

            guard let items = result as? [[String: Any]] else {
                todos = []
                isLoading = false
                return
            }

            todos = items.compactMap { parseTodo($0) }
        } catch {
            self.error = error.localizedDescription
            NSLog("[TodoList] Failed to fetch todos: %@", String(describing: error))
        }

        isLoading = false
    }

    func fetchLists(spaceId: String?) async {
        do {
            let token = try await ConvexHTTPClient.getToken()

            var args: [String: Any] = [:]
            if let spaceId {
                args["spaceId"] = spaceId
            }

            let result = try await ConvexHTTPClient.query(
                function: "todoLists:list",
                args: args,
                token: token
            )

            guard let items = result as? [[String: Any]] else {
                lists = []
                return
            }

            lists = items.compactMap { item in
                guard let id = item["_id"] as? String,
                      let name = item["name"] as? String
                else { return nil }

                return ConvexTodoList(
                    id: id,
                    name: name,
                    color: item["color"] as? String,
                    spaceId: item["spaceId"] as? String
                )
            }
        } catch {
            NSLog("[TodoList] Failed to fetch lists: %@", String(describing: error))
        }
    }

    func updateTodo(todoId: String, fields: [String: Any]) async {
        do {
            let token = try await ConvexHTTPClient.getToken()
            var args = fields
            args["todoId"] = todoId

            _ = try await ConvexHTTPClient.mutation(
                function: "todos:update",
                args: args,
                token: token
            )
        } catch {
            NSLog("[TodoList] Failed to update todo: %@", String(describing: error))
            self.error = error.localizedDescription
        }
    }

    func deleteTodo(todoId: String) async {
        do {
            let token = try await ConvexHTTPClient.getToken()

            _ = try await ConvexHTTPClient.mutation(
                function: "todos:remove",
                args: ["todoId": todoId],
                token: token
            )

            todos.removeAll { $0.id == todoId }
        } catch {
            NSLog("[TodoList] Failed to delete todo: %@", String(describing: error))
            self.error = error.localizedDescription
        }
    }

    func createList(name: String, color: String?, spaceId: String?) async {
        do {
            let token = try await ConvexHTTPClient.getToken()
            var args: [String: Any] = ["name": name]
            if let color { args["color"] = color }
            if let spaceId { args["spaceId"] = spaceId }

            _ = try await ConvexHTTPClient.mutation(
                function: "todoLists:create",
                args: args,
                token: token
            )
        } catch {
            NSLog("[TodoList] Failed to create list: %@", String(describing: error))
            self.error = error.localizedDescription
        }
    }

    func createTodo(title: String, spaceId: String?, listId: String? = nil, priority: String = "none", dueDate: String? = nil) async {
        do {
            let token = try await ConvexHTTPClient.getToken()
            var args: [String: Any] = ["title": title]
            if let spaceId { args["spaceId"] = spaceId }
            if let listId { args["listId"] = listId }
            if let dueDate { args["dueDate"] = dueDate }
            args["priority"] = priority

            _ = try await ConvexHTTPClient.mutation(
                function: "todos:create",
                args: args,
                token: token
            )
        } catch {
            NSLog("[TodoList] Failed to create todo: %@", String(describing: error))
            self.error = error.localizedDescription
        }
    }

    // MARK: - Reminder Polling

    func startReminderPolling() {
        stopReminderPolling()
        reminderPollTask = Task {
            while !Task.isCancelled {
                await pollPendingReminders()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stopReminderPolling() {
        reminderPollTask?.cancel()
        reminderPollTask = nil
    }

    func acknowledgeReminder(todoId: String, reminderIndex: Int) async {
        do {
            let token = try await ConvexHTTPClient.getToken()
            _ = try await ConvexHTTPClient.mutation(
                function: "todos:acknowledgeReminder",
                args: ["todoId": todoId, "reminderIndex": reminderIndex],
                token: token
            )
            pendingReminderTodos.removeAll { $0.id == todoId }
        } catch {
            NSLog("[TodoList] Failed to acknowledge reminder: %@", String(describing: error))
        }
    }

    // MARK: - Private

    private func pollPendingReminders() async {
        do {
            let token = try await ConvexHTTPClient.getToken()
            let result = try await ConvexHTTPClient.query(
                function: "todos:pendingReminders",
                args: [:],
                token: token
            )

            guard let items = result as? [[String: Any]] else {
                pendingReminderTodos = []
                return
            }

            let newPending = items.compactMap { parseTodo($0) }
            let previousIds = Set(pendingReminderTodos.map(\.id))
            let brandNew = newPending.filter { !previousIds.contains($0.id) }

            pendingReminderTodos = newPending

            // Fire notifications for newly appeared reminders
            for todo in brandNew {
                await fireReminderNotification(for: todo)
            }
        } catch {
            NSLog("[TodoList] Failed to poll reminders: %@", String(describing: error))
        }
    }

    private func fireReminderNotification(for todo: ConvexTodo) async {
        let content = UNMutableNotificationContent()
        content.title = "Todo Reminder"
        content.body = todo.title
        if let dueDate = todo.dueDate {
            content.body += " (due: \(dueDate))"
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "todo-reminder-\(todo.id)",
            content: content,
            trigger: nil // Fire immediately
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            NSLog("[TodoList] Failed to show notification: %@", String(describing: error))
        }
    }

    private func parseTodo(_ item: [String: Any]) -> ConvexTodo? {
        guard let id = item["_id"] as? String,
              let title = item["title"] as? String,
              let status = item["status"] as? String,
              let priority = item["priority"] as? String,
              let createdAt = item["_creationTime"] as? Double
        else { return nil }

        return ConvexTodo(
            id: id,
            title: title,
            description: item["description"] as? String,
            status: status,
            priority: priority,
            listId: item["listId"] as? String,
            tags: item["tags"] as? [String],
            dueDate: item["dueDate"] as? String,
            dueTime: item["dueTime"] as? String,
            completedAt: item["completedAt"] as? Double,
            rawTranscription: item["rawTranscription"] as? String,
            createdAt: createdAt,
            spaceId: item["spaceId"] as? String,
            reminders: item["reminders"] as? [[String: Any]]
        )
    }
}
```

**Step 2: Add `import UserNotifications` at the top**

```swift
import Foundation
import UserNotifications
```

**Step 3: Commit**

```bash
git add Sources/JackApp/Sync/TodoListController.swift
git commit -m "feat: add TodoListController with CRUD, reminder polling, and notifications"
```

---

### Task 12: Add Todos section to SettingsSection and sidebar

**Files:**
- Modify: `Sources/JackApp/ContentView.swift:737-790`

**Step 1: Add `.todos` case to SettingsSection**

In the enum (~line 737), add after `notes`:

```swift
case todos
```

Add to `title`:
```swift
case .todos:
    return "Todos"
```

Add to `subtitle`:
```swift
case .todos:
    return "Voice-created todos with lists, priorities, and reminders."
```

Add to `systemImage`:
```swift
case .todos:
    return "checklist"
```

**Step 2: Add TodoListController state**

Add after `noteListController` state (~line 14):

```swift
@State private var todoListController = TodoListController()
```

**Step 3: Add todo view in the detail area**

In the NavigationSplitView detail section where the `switch selectedSection` handles each case, add:

```swift
case .todos:
    TodosView(
        controller: todoListController,
        spaceController: spaceController
    )
```

(The TodosView will be created in Task 13.)

**Step 4: Commit**

```bash
git add Sources/JackApp/ContentView.swift
git commit -m "feat: add Todos section to sidebar navigation"
```

---

### Task 13: Create TodosView (List View)

**Files:**
- Create: `Sources/JackApp/Todos/TodosView.swift`

**Step 1: Create the view**

```swift
import SwiftUI

enum TodoViewMode: String, CaseIterable {
    case list
    case kanban

    var title: String {
        switch self {
        case .list: return "List"
        case .kanban: return "Kanban"
        }
    }

    var icon: String {
        switch self {
        case .list: return "list.bullet"
        case .kanban: return "rectangle.split.3x1"
        }
    }
}

struct TodosView: View {
    var controller: TodoListController
    var spaceController: SpaceController

    @State private var viewMode: TodoViewMode = .list
    @State private var showAddTodo = false
    @State private var newTodoTitle = ""
    @State private var filterPriority: String?
    @State private var expandedTodoId: String?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Button {
                    showAddTodo.toggle()
                } label: {
                    Label("Add Todo", systemImage: "plus")
                }

                Spacer()

                // View mode picker
                Picker("View", selection: $viewMode) {
                    ForEach(TodoViewMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.icon)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if showAddTodo {
                HStack {
                    TextField("What needs to be done?", text: $newTodoTitle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            guard !newTodoTitle.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            Task {
                                await controller.createTodo(
                                    title: newTodoTitle,
                                    spaceId: spaceController.currentSpaceId
                                )
                                newTodoTitle = ""
                                showAddTodo = false
                                await controller.fetchTodos(spaceId: spaceController.currentSpaceId)
                            }
                        }
                    Button("Cancel") {
                        showAddTodo = false
                        newTodoTitle = ""
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }

            // Content
            switch viewMode {
            case .list:
                TodoListView(
                    controller: controller,
                    spaceController: spaceController,
                    expandedTodoId: $expandedTodoId
                )
            case .kanban:
                TodoKanbanView(
                    controller: controller,
                    spaceController: spaceController
                )
            }
        }
        .task {
            await controller.fetchLists(spaceId: spaceController.currentSpaceId)
            await controller.fetchTodos(spaceId: spaceController.currentSpaceId)
            controller.startReminderPolling()
        }
        .onChange(of: spaceController.activeSpace.id) {
            Task {
                await controller.fetchLists(spaceId: spaceController.currentSpaceId)
                await controller.fetchTodos(spaceId: spaceController.currentSpaceId)
            }
        }
    }
}

// MARK: - List View

struct TodoListView: View {
    var controller: TodoListController
    var spaceController: SpaceController
    @Binding var expandedTodoId: String?

    var body: some View {
        if controller.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if controller.todos.isEmpty {
            ContentUnavailableView(
                "No Todos",
                systemImage: "checklist",
                description: Text("Press your todo key during recording to create voice todos, or tap + above.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Group by list
                    let grouped = Dictionary(grouping: controller.todos) { $0.listId ?? "" }
                    let listOrder = controller.lists.map(\.id) + [""]

                    ForEach(listOrder, id: \.self) { listId in
                        if let todos = grouped[listId], !todos.isEmpty {
                            let listName = controller.lists.first(where: { $0.id == listId })?.name ?? "No List"

                            Section {
                                ForEach(todos) { todo in
                                    TodoRowView(
                                        todo: todo,
                                        isExpanded: expandedTodoId == todo.id,
                                        controller: controller,
                                        spaceController: spaceController,
                                        onToggleExpand: {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                expandedTodoId = expandedTodoId == todo.id ? nil : todo.id
                                            }
                                        }
                                    )
                                }
                            } header: {
                                Text(listName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 12)
                                    .padding(.bottom, 4)
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
    }
}

// MARK: - Todo Row

struct TodoRowView: View {
    let todo: ConvexTodo
    let isExpanded: Bool
    var controller: TodoListController
    var spaceController: SpaceController
    let onToggleExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // Checkbox
                Button {
                    let newStatus = todo.status == "done" ? "todo" : "done"
                    Task {
                        await controller.updateTodo(todoId: todo.id, fields: ["status": newStatus])
                        await controller.fetchTodos(spaceId: spaceController.currentSpaceId)
                    }
                } label: {
                    Image(systemName: todo.status == "done" ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(todo.status == "done" ? .green : .secondary)
                }
                .buttonStyle(.plain)

                // Priority indicator
                priorityDots

                // Title
                Text(todo.title)
                    .strikethrough(todo.status == "done")
                    .foregroundStyle(todo.status == "done" ? .secondary : .primary)
                    .lineLimit(isExpanded ? nil : 1)

                Spacer()

                // Due date
                if let dueDate = todo.dueDate {
                    Text(dueDate)
                        .font(.caption)
                        .foregroundStyle(isDueSoon(dueDate) ? .red : .secondary)
                }

                // Delete
                Button {
                    Task {
                        await controller.deleteTodo(todoId: todo.id)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(isExpanded ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                onToggleExpand()
            }

            if isExpanded {
                TodoDetailView(
                    todo: todo,
                    controller: controller,
                    spaceController: spaceController
                )
                .padding(.leading, 52)
                .padding(.trailing, 16)
                .padding(.bottom, 8)
            }

            Divider()
                .padding(.leading, 52)
        }
    }

    @ViewBuilder
    private var priorityDots: some View {
        let color = priorityColor(todo.priority)
        let count = priorityDotCount(todo.priority)

        if count > 0 {
            HStack(spacing: 2) {
                ForEach(0..<count, id: \.self) { _ in
                    Circle()
                        .fill(color)
                        .frame(width: 5, height: 5)
                }
            }
            .frame(width: 20)
        } else {
            Color.clear.frame(width: 20)
        }
    }

    private func priorityColor(_ priority: String) -> Color {
        switch priority {
        case "high": return .red
        case "medium": return .orange
        case "low": return .blue
        default: return .clear
        }
    }

    private func priorityDotCount(_ priority: String) -> Int {
        switch priority {
        case "high": return 3
        case "medium": return 2
        case "low": return 1
        default: return 0
        }
    }

    private func isDueSoon(_ dateStr: String) -> Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateStr) else { return false }
        return date <= Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    }
}

// MARK: - Detail View (inline edit)

struct TodoDetailView: View {
    let todo: ConvexTodo
    var controller: TodoListController
    var spaceController: SpaceController

    @State private var editTitle: String = ""
    @State private var editDescription: String = ""
    @State private var editPriority: String = "none"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let desc = todo.description, !desc.isEmpty {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                // Priority picker
                Picker("Priority", selection: Binding(
                    get: { todo.priority },
                    set: { newVal in
                        Task {
                            await controller.updateTodo(todoId: todo.id, fields: ["priority": newVal])
                            await controller.fetchTodos(spaceId: spaceController.currentSpaceId)
                        }
                    }
                )) {
                    Text("None").tag("none")
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }
                .pickerStyle(.menu)
                .fixedSize()

                // Status picker
                Picker("Status", selection: Binding(
                    get: { todo.status },
                    set: { newVal in
                        Task {
                            await controller.updateTodo(todoId: todo.id, fields: ["status": newVal])
                            await controller.fetchTodos(spaceId: spaceController.currentSpaceId)
                        }
                    }
                )) {
                    Text("To Do").tag("todo")
                    Text("In Progress").tag("in_progress")
                    Text("Done").tag("done")
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

            // Tags
            if let tags = todo.tags, !tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary))
                    }
                }
            }
        }
    }
}
```

**Step 2: Create the directory**

```bash
mkdir -p Sources/JackApp/Todos
```

**Step 3: Commit**

```bash
git add Sources/JackApp/Todos/TodosView.swift
git commit -m "feat: add TodosView with list view, inline editing, and priority indicators"
```

---

### Task 14: Create TodoKanbanView

**Files:**
- Create: `Sources/JackApp/Todos/TodoKanbanView.swift`

**Step 1: Create the Kanban view**

```swift
import SwiftUI

struct TodoKanbanView: View {
    var controller: TodoListController
    var spaceController: SpaceController

    private let columns: [(status: String, title: String)] = [
        ("todo", "To Do"),
        ("in_progress", "In Progress"),
        ("done", "Done"),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(columns, id: \.status) { column in
                KanbanColumn(
                    title: column.title,
                    status: column.status,
                    todos: controller.todos.filter { $0.status == column.status }
                        .sorted { sortByPriorityThenDate($0, $1) },
                    controller: controller,
                    spaceController: spaceController
                )

                if column.status != "done" {
                    Divider()
                }
            }
        }
    }

    private func sortByPriorityThenDate(_ a: ConvexTodo, _ b: ConvexTodo) -> Bool {
        let priorityOrder = ["high": 0, "medium": 1, "low": 2, "none": 3]
        let pa = priorityOrder[a.priority] ?? 3
        let pb = priorityOrder[b.priority] ?? 3
        if pa != pb { return pa < pb }
        return (a.dueDate ?? "9999") < (b.dueDate ?? "9999")
    }
}

struct KanbanColumn: View {
    let title: String
    let status: String
    let todos: [ConvexTodo]
    var controller: TodoListController
    var spaceController: SpaceController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(todos.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(todos) { todo in
                        KanbanCard(
                            todo: todo,
                            controller: controller,
                            spaceController: spaceController
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .onDrop(of: [.text], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.text", options: nil) { data, _ in
            guard let data = data as? Data,
                  let todoId = String(data: data, encoding: .utf8)
            else { return }

            Task { @MainActor in
                await controller.updateTodo(todoId: todoId, fields: ["status": status])
                await controller.fetchTodos(spaceId: spaceController.currentSpaceId)
            }
        }
        return true
    }
}

struct KanbanCard: View {
    let todo: ConvexTodo
    var controller: TodoListController
    var spaceController: SpaceController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(todo.title)
                .font(.caption)
                .lineLimit(3)
                .strikethrough(todo.status == "done")

            HStack(spacing: 6) {
                // Priority
                if todo.priority != "none" {
                    Text(todo.priority.capitalized)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(priorityColor(todo.priority).opacity(0.2))
                        )
                        .foregroundStyle(priorityColor(todo.priority))
                }

                Spacer()

                // Due date
                if let dueDate = todo.dueDate {
                    Text(dueDate)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        )
        .onDrag {
            NSItemProvider(object: todo.id as NSString)
        }
    }

    private func priorityColor(_ priority: String) -> Color {
        switch priority {
        case "high": return .red
        case "medium": return .orange
        case "low": return .blue
        default: return .clear
        }
    }
}
```

**Step 2: Commit**

```bash
git add Sources/JackApp/Todos/TodoKanbanView.swift
git commit -m "feat: add TodoKanbanView with drag-and-drop status updates"
```

---

### Task 15: Add todo switch key settings UI

**Files:**
- Modify: `Sources/JackApp/ContentView.swift` (in the shortcuts settings section)

**Step 1: Add key capture row for todo switch key**

Find the existing shortcuts section in ContentView (search for "Voice Note Switch Key" or the voice note key capture UI). Add a similar row after it for the todo switch key:

```swift
// Todo Switch Key
keyCaptureRow(
    title: "Todo Switch Key",
    detail: "Press during recording to switch to Todo mode",
    keyName: InvocationKey.displayName(for: controller.todoSwitchKeyCode),
    isCapturing: controller.isCapturingTodoSwitchKey,
    onStartCapture: { controller.startCapturingKey(for: .todoSwitch) },
    onStopCapture: { controller.stopCapturingKey() }
)
```

Note: You'll need to add the `.todoSwitch` handling in `startCapturingKey(for:)` and the key assignment logic in the DictationController, following the same pattern as `.voiceNoteSwitch`.

**Step 2: Commit**

```bash
git add Sources/JackApp/ContentView.swift
git commit -m "feat: add todo switch key capture to shortcuts settings"
```

---

### Task 16: Request notification permissions

**Files:**
- Modify: `Sources/JackApp/JackApp.swift` or `Sources/JackApp/DictationController.swift`

**Step 1: Request notification permission on launch**

In the app startup flow (e.g., `JackApp.swift` or in `DictationController.initialize()`), add:

```swift
import UserNotifications

// In the startup sequence:
UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
    if let error {
        NSLog("[Notifications] Permission error: %@", error.localizedDescription)
    }
}
```

**Step 2: Commit**

```bash
git add Sources/JackApp/JackApp.swift
git commit -m "feat: request notification permissions for todo reminders"
```

---

### Task 17: Build and integration test

**Step 1: Build the full project**

```bash
cd /Users/txp/Pessoal/jack-v2
swift build 2>&1
```

Expected: Clean build with no errors.

**Step 2: Deploy Convex functions**

```bash
npx convex dev --once
```

Expected: All functions deploy successfully.

**Step 3: Manual integration test**

1. Launch the app
2. Press Fn to start recording, then press T → bubble should show checklist icon
3. Dictate "remind me to buy groceries tomorrow at 5pm, high priority"
4. Release Fn → status should show "Creating todo..."
5. Open Todos section in sidebar → todo should appear with:
   - Title: "Buy groceries"
   - Priority: High (red dots)
   - Due date: tomorrow's date
   - Reminder scheduled
6. Click the todo to expand → edit priority, status
7. Switch to Kanban view → todo should be in "To Do" column
8. Drag it to "In Progress" → status updates

**Step 4: Commit any fixes**

```bash
git add -A
git commit -m "fix: address integration test issues"
```
