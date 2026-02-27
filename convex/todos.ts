import { v } from "convex/values";
import {
  action,
  internalMutation,
  internalQuery,
  mutation,
  query,
} from "./_generated/server";
import { internal } from "./_generated/api";

// ── 1. list ────────────────────────────────────────────────────────────────────
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

    // Personal todos (no space)
    return await ctx.db
      .query("todos")
      .withIndex("by_space_user", (q) =>
        q.eq("spaceId", undefined).eq("userId", user._id),
      )
      .order("desc")
      .collect();
  },
});

// ── 2. create ──────────────────────────────────────────────────────────────────
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
    if (!user) throw new Error("User not found. Call syncUser first.");

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

// ── 3. update ──────────────────────────────────────────────────────────────────
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
    if (args.status !== undefined) {
      patch.status = args.status;
      if (args.status === "done") {
        patch.completedAt = Date.now();
      } else {
        patch.completedAt = undefined;
      }
    }
    if (args.priority !== undefined) patch.priority = args.priority;
    if (args.listId !== undefined) patch.listId = args.listId;
    if (args.tags !== undefined) patch.tags = args.tags;
    if (args.dueDate !== undefined) patch.dueDate = args.dueDate;
    if (args.dueTime !== undefined) patch.dueTime = args.dueTime;

    await ctx.db.patch(args.todoId, patch);
  },
});

// ── 4. remove ──────────────────────────────────────────────────────────────────
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
            // Scheduled function may have already fired or been cancelled
          }
        }
      }
    }

    await ctx.db.delete(args.todoId);
  },
});

// ── 5. moveToSpace ─────────────────────────────────────────────────────────────
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
    if (todo.userId !== user._id) {
      throw new Error("Not authorized to move this todo");
    }

    if (args.targetSpaceId) {
      const membership = await ctx.db
        .query("space_members")
        .withIndex("by_space_user", (q) =>
          q.eq("spaceId", args.targetSpaceId!).eq("userId", user._id),
        )
        .unique();
      if (!membership) throw new Error("Not a member of the target space");
    }

    await ctx.db.patch(args.todoId, {
      spaceId: args.targetSpaceId,
    });
  },
});

// ── 6. fireReminder ────────────────────────────────────────────────────────────
export const fireReminder = internalMutation({
  args: {
    todoId: v.id("todos"),
    reminderIndex: v.number(),
  },
  handler: async (ctx, args) => {
    const todo = await ctx.db.get(args.todoId);
    if (!todo) return;
    if (todo.status === "done") return;

    const reminders = todo.reminders ? [...todo.reminders] : [];
    if (args.reminderIndex < 0 || args.reminderIndex >= reminders.length)
      return;

    reminders[args.reminderIndex] = {
      ...reminders[args.reminderIndex],
      delivered: true,
    };

    await ctx.db.patch(args.todoId, { reminders });
  },
});

// ── 7. insertFromAction ────────────────────────────────────────────────────────
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
    reminders: v.optional(
      v.array(
        v.object({
          at: v.number(),
          scheduledFunctionId: v.optional(v.id("_scheduled_functions")),
          delivered: v.optional(v.boolean()),
        }),
      ),
    ),
    rawTranscription: v.optional(v.string()),
    createdAt: v.number(),
  },
  handler: async (ctx, args) => {
    const todoId = await ctx.db.insert("todos", {
      userId: args.userId,
      spaceId: args.spaceId,
      title: args.title,
      description: args.description,
      status: args.status,
      priority: args.priority,
      listId: args.listId,
      tags: args.tags,
      dueDate: args.dueDate,
      dueTime: args.dueTime,
      reminders: args.reminders,
      rawTranscription: args.rawTranscription,
      createdAt: args.createdAt,
    });

    // Schedule future reminders
    if (args.reminders && args.reminders.length > 0) {
      const now = Date.now();
      const updatedReminders = [...args.reminders];

      for (let i = 0; i < updatedReminders.length; i++) {
        const reminder = updatedReminders[i];
        if (reminder.at > now) {
          const scheduledId = await ctx.scheduler.runAt(
            reminder.at,
            internal.todos.fireReminder,
            { todoId, reminderIndex: i },
          );
          updatedReminders[i] = {
            ...reminder,
            scheduledFunctionId: scheduledId,
          };
        }
      }

      await ctx.db.patch(todoId, { reminders: updatedReminders });
    }

    return todoId;
  },
});

// ── 8. pendingReminders ────────────────────────────────────────────────────────
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

    // Get all non-done todos for this user that may have reminders
    const allTodos = await ctx.db
      .query("todos")
      .withIndex("by_space_user", (q) =>
        q.eq("spaceId", undefined).eq("userId", user._id),
      )
      .collect();

    // Also get todos from spaces the user belongs to
    const memberships = await ctx.db
      .query("space_members")
      .withIndex("by_user", (q) => q.eq("userId", user._id))
      .collect();

    for (const membership of memberships) {
      const spaceTodos = await ctx.db
        .query("todos")
        .withIndex("by_space", (q) => q.eq("spaceId", membership.spaceId))
        .collect();
      allTodos.push(...spaceTodos);
    }

    // Filter to non-done todos with at least one delivered reminder
    return allTodos.filter(
      (todo) =>
        todo.status !== "done" &&
        todo.userId === user._id &&
        todo.reminders?.some((r) => r.delivered === true),
    );
  },
});

// ── 9. acknowledgeReminder ─────────────────────────────────────────────────────
export const acknowledgeReminder = mutation({
  args: {
    todoId: v.id("todos"),
    reminderIndex: v.number(),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const todo = await ctx.db.get(args.todoId);
    if (!todo) throw new Error("Todo not found");

    const reminders = todo.reminders ? [...todo.reminders] : [];
    if (args.reminderIndex < 0 || args.reminderIndex >= reminders.length) {
      throw new Error("Invalid reminder index");
    }

    reminders.splice(args.reminderIndex, 1);

    await ctx.db.patch(args.todoId, {
      reminders: reminders.length > 0 ? reminders : undefined,
    });
  },
});

// ── 10. getUserByClerkId ───────────────────────────────────────────────────────
export const getUserByClerkId = internalQuery({
  args: { clerkId: v.string() },
  handler: async (ctx, args) => {
    return await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", args.clerkId))
      .unique();
  },
});

// ── 11. checkSpaceMembership ───────────────────────────────────────────────────
export const checkSpaceMembership = internalQuery({
  args: {
    spaceId: v.id("spaces"),
    userId: v.id("users"),
  },
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

// ── 12. getListsBySpace ────────────────────────────────────────────────────────
export const getListsBySpace = internalQuery({
  args: {
    spaceId: v.optional(v.id("spaces")),
    userId: v.id("users"),
  },
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

// ── 13. createListFromAction ───────────────────────────────────────────────────
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

// ── 14. processAndCreate ───────────────────────────────────────────────────────
export const processAndCreate = action({
  args: {
    rawText: v.string(),
    spaceId: v.optional(v.id("spaces")),
  },
  handler: async (ctx, args): Promise<string> => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.runQuery(internal.todos.getUserByClerkId, {
      clerkId: identity.subject,
    });
    if (!user) throw new Error("User not found");

    if (args.spaceId) {
      const isMember = await ctx.runQuery(
        internal.todos.checkSpaceMembership,
        { spaceId: args.spaceId, userId: user._id },
      );
      if (!isMember) throw new Error("Not a member of this space");
    }

    // Dynamic imports for AI dependencies
    const { generateObject } = await import("ai");
    const { createOpenRouter } = await import("@openrouter/ai-sdk-provider");
    const { z } = await import("zod");

    const openrouter = createOpenRouter({
      apiKey: process.env.OPENROUTER_API_KEY,
    });

    const today = new Date();
    const todayStr = today.toISOString().split("T")[0];
    const currentTime = today.toTimeString().split(" ")[0].slice(0, 5);
    const dayOfWeek = today.toLocaleDateString("en-US", { weekday: "long" });

    const { object: parsed } = await generateObject({
      model: openrouter("google/gemini-2.0-flash-001"),
      schema: z.object({
        title: z.string(),
        description: z.string().optional(),
        dueDate: z
          .string()
          .optional()
          .describe("Due date in yyyy-MM-dd format"),
        dueTime: z
          .string()
          .optional()
          .describe("Due time in HH:mm format"),
        priority: z.enum(["none", "low", "medium", "high"]),
        tags: z.array(z.string()).optional(),
        listName: z
          .string()
          .optional()
          .describe("Name of the todo list to place this in"),
        reminders: z
          .array(
            z.object({
              offsetMinutes: z
                .number()
                .optional()
                .describe(
                  "Minutes before dueDate/dueTime to fire the reminder",
                ),
              absoluteTime: z
                .string()
                .optional()
                .describe(
                  "Absolute ISO datetime string for the reminder if no due date",
                ),
            }),
          )
          .optional(),
      }),
      system: `You are a task extraction assistant. The user will dictate a todo item.
Your job:
- Clean up filler words (um, uh, like, etc.) and produce a concise title.
- Extract an optional longer description if the user provides extra context.
- Resolve relative dates (e.g. "tomorrow", "next Monday", "in 3 days") against today: ${todayStr} (${dayOfWeek}). Current time: ${currentTime}.
- Extract priority if mentioned (urgent/critical = high, important = medium, low priority = low, otherwise none).
- Extract tags from hashtags or explicit tag mentions.
- Extract a list name if the user says "add to <list>" or "put in <list>".
- If the user mentions a reminder (e.g. "remind me 10 minutes before", "remind me at 9am", "remind me in 5 minutes"), include it.
  - For relative reminders like "remind me in X minutes/hours", compute the absolute ISO datetime from the current time and use absoluteTime.
  - For reminders relative to a due date (e.g. "remind me 10 minutes before"), use offsetMinutes.
  - IMPORTANT: "remind me in 2 minutes" means absoluteTime = current time + 2 minutes. Always set absoluteTime for time-relative reminders.
- If the user says "remind me in X minutes" without specifying a separate due date/time, still set dueDate to today and dueTime to the computed time (current time + X minutes).
- Output valid JSON matching the schema.`,
      prompt: args.rawText,
    });

    console.log("[processAndCreate] LLM parsed:", JSON.stringify(parsed));

    // Resolve listName to listId
    let listId: string | undefined;
    if (parsed.listName) {
      const lists = await ctx.runQuery(internal.todos.getListsBySpace, {
        spaceId: args.spaceId,
        userId: user._id,
      });

      const match = lists.find(
        (l: { name: string }) =>
          l.name.toLowerCase() === parsed.listName!.toLowerCase(),
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
    let reminders:
      | Array<{
          at: number;
          scheduledFunctionId?: undefined;
          delivered?: undefined;
        }>
      | undefined;

    if (parsed.reminders && parsed.reminders.length > 0) {
      reminders = [];
      for (const r of parsed.reminders) {
        let at: number | undefined;

        if (r.absoluteTime) {
          at = new Date(r.absoluteTime).getTime();
        } else if (r.offsetMinutes !== undefined && parsed.dueDate) {
          // Compute from dueDate + dueTime
          const dueDateTimeStr = parsed.dueTime
            ? `${parsed.dueDate}T${parsed.dueTime}:00`
            : `${parsed.dueDate}T09:00:00`;
          const dueTimestamp = new Date(dueDateTimeStr).getTime();
          at = dueTimestamp - r.offsetMinutes * 60 * 1000;
        } else if (r.offsetMinutes !== undefined) {
          // No due date — treat offset as "from now"
          at = Date.now() + r.offsetMinutes * 60 * 1000;
        }

        if (at && !isNaN(at)) {
          reminders.push({ at });
        }
      }
      if (reminders.length === 0) reminders = undefined;
    }

    // Insert the todo via internal mutation
    const todoId = await ctx.runMutation(internal.todos.insertFromAction, {
      userId: user._id,
      spaceId: args.spaceId,
      title: parsed.title,
      description: parsed.description,
      status: "todo" as const,
      priority: parsed.priority,
      listId: listId as any,
      tags: parsed.tags,
      dueDate: parsed.dueDate,
      dueTime: parsed.dueTime,
      reminders,
      rawTranscription: args.rawText,
      createdAt: Date.now(),
    });

    return todoId;
  },
});
