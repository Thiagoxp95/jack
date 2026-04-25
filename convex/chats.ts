import { v } from "convex/values";
import {
  action,
  internalMutation,
  internalQuery,
  mutation,
  query,
} from "./_generated/server";

// ── 1. listThreads ──────────────────────────────────────────────────────────────
export const listThreads = query({
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
        .query("chatThreads")
        .withIndex("by_space", (q) => q.eq("spaceId", args.spaceId))
        .order("desc")
        .collect();
    }

    // Personal threads (no space)
    return await ctx.db
      .query("chatThreads")
      .withIndex("by_space_user", (q) =>
        q.eq("spaceId", undefined).eq("userId", user._id),
      )
      .order("desc")
      .collect();
  },
});

// ── 2. getThread ────────────────────────────────────────────────────────────────
export const getThread = query({
  args: { threadId: v.id("chatThreads") },
  handler: async (ctx, args) => {
    return await ctx.db.get(args.threadId);
  },
});

// ── 3. getMessages ──────────────────────────────────────────────────────────────
export const getMessages = query({
  args: { threadId: v.id("chatThreads") },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found");

    const thread = await ctx.db.get(args.threadId);
    if (!thread) throw new Error("Thread not found");

    // Verify ownership or space membership
    if (thread.spaceId) {
      const membership = await ctx.db
        .query("space_members")
        .withIndex("by_space_user", (q) =>
          q.eq("spaceId", thread.spaceId!).eq("userId", user._id),
        )
        .unique();
      if (!membership) throw new Error("Not a member of this space");
    } else if (thread.userId !== user._id) {
      throw new Error("Not authorized to view this thread");
    }

    return await ctx.db
      .query("chatMessages")
      .withIndex("by_thread", (q) => q.eq("threadId", args.threadId))
      .order("asc")
      .collect();
  },
});

// ── 4. createThread ─────────────────────────────────────────────────────────────
export const createThread = mutation({
  args: {
    spaceId: v.optional(v.id("spaces")),
    title: v.string(),
    model: v.string(),
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

// ── 5. updateThread ─────────────────────────────────────────────────────────────
export const updateThread = mutation({
  args: {
    threadId: v.id("chatThreads"),
    title: v.optional(v.string()),
    model: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found");

    const thread = await ctx.db.get(args.threadId);
    if (!thread) throw new Error("Thread not found");

    // Verify ownership or space membership
    if (thread.spaceId) {
      const membership = await ctx.db
        .query("space_members")
        .withIndex("by_space_user", (q) =>
          q.eq("spaceId", thread.spaceId!).eq("userId", user._id),
        )
        .unique();
      if (!membership) throw new Error("Not a member of this space");
    } else if (thread.userId !== user._id) {
      throw new Error("Not authorized to update this thread");
    }

    const patch: Record<string, unknown> = { updatedAt: Date.now() };
    if (args.title !== undefined) patch.title = args.title;
    if (args.model !== undefined) patch.model = args.model;

    await ctx.db.patch(args.threadId, patch);
  },
});

// ── 6. deleteThread ─────────────────────────────────────────────────────────────
export const deleteThread = mutation({
  args: { threadId: v.id("chatThreads") },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found");

    const thread = await ctx.db.get(args.threadId);
    if (!thread) throw new Error("Thread not found");

    // Verify ownership or space membership
    if (thread.spaceId) {
      const membership = await ctx.db
        .query("space_members")
        .withIndex("by_space_user", (q) =>
          q.eq("spaceId", thread.spaceId!).eq("userId", user._id),
        )
        .unique();
      if (!membership) throw new Error("Not a member of this space");
    } else if (thread.userId !== user._id) {
      throw new Error("Not authorized to delete this thread");
    }

    // Delete all messages in the thread first
    const messages = await ctx.db
      .query("chatMessages")
      .withIndex("by_thread", (q) => q.eq("threadId", args.threadId))
      .collect();
    for (const message of messages) {
      await ctx.db.delete(message._id);
    }

    // Delete the thread
    await ctx.db.delete(args.threadId);
  },
});

// ── 7. sendMessage ──────────────────────────────────────────────────────────────
export const sendMessage = mutation({
  args: {
    threadId: v.id("chatThreads"),
    content: v.string(),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found");

    const thread = await ctx.db.get(args.threadId);
    if (!thread) throw new Error("Thread not found");

    // Verify ownership or space membership
    if (thread.spaceId) {
      const membership = await ctx.db
        .query("space_members")
        .withIndex("by_space_user", (q) =>
          q.eq("spaceId", thread.spaceId!).eq("userId", user._id),
        )
        .unique();
      if (!membership) throw new Error("Not a member of this space");
    } else if (thread.userId !== user._id) {
      throw new Error("Not authorized to send messages in this thread");
    }

    // Insert the user message
    const messageId = await ctx.db.insert("chatMessages", {
      threadId: args.threadId,
      role: "user",
      content: args.content,
      createdAt: Date.now(),
    });

    // Update the thread's updatedAt
    await ctx.db.patch(args.threadId, { updatedAt: Date.now() });

    return messageId;
  },
});

// ── 8. saveAssistantMessage ─────────────────────────────────────────────────────
export const saveAssistantMessage = mutation({
  args: {
    threadId: v.id("chatThreads"),
    content: v.string(),
    model: v.string(),
  },
  handler: async (ctx, args) => {
    const thread = await ctx.db.get(args.threadId);
    if (!thread) throw new Error("Thread not found");

    // Insert the assistant message
    const messageId = await ctx.db.insert("chatMessages", {
      threadId: args.threadId,
      role: "assistant",
      content: args.content,
      model: args.model,
      createdAt: Date.now(),
    });

    // Update the thread's updatedAt
    await ctx.db.patch(args.threadId, { updatedAt: Date.now() });

    return messageId;
  },
});

// ── Internal functions (for HTTP actions, no auth check) ────────────────────

export const internalSendMessage = internalMutation({
  args: {
    threadId: v.id("chatThreads"),
    content: v.string(),
  },
  handler: async (ctx, args) => {
    const thread = await ctx.db.get(args.threadId);
    if (!thread) throw new Error("Thread not found");

    const messageId = await ctx.db.insert("chatMessages", {
      threadId: args.threadId,
      role: "user",
      content: args.content,
      createdAt: Date.now(),
    });

    await ctx.db.patch(args.threadId, { updatedAt: Date.now() });
    return messageId;
  },
});

export const internalGetThread = internalQuery({
  args: { threadId: v.id("chatThreads") },
  handler: async (ctx, args) => {
    return await ctx.db.get(args.threadId);
  },
});

export const internalGetMessages = internalQuery({
  args: { threadId: v.id("chatThreads") },
  handler: async (ctx, args) => {
    return await ctx.db
      .query("chatMessages")
      .withIndex("by_thread", (q) => q.eq("threadId", args.threadId))
      .order("asc")
      .collect();
  },
});

export const internalSaveAssistantMessage = internalMutation({
  args: {
    threadId: v.id("chatThreads"),
    content: v.string(),
    model: v.string(),
  },
  handler: async (ctx, args) => {
    const thread = await ctx.db.get(args.threadId);
    if (!thread) throw new Error("Thread not found");

    const messageId = await ctx.db.insert("chatMessages", {
      threadId: args.threadId,
      role: "assistant",
      content: args.content,
      model: args.model,
      createdAt: Date.now(),
    });

    await ctx.db.patch(args.threadId, { updatedAt: Date.now() });
    return messageId;
  },
});

// ── 9. listModels ───────────────────────────────────────────────────────────────
export const listModels = action({
  args: {},
  handler: async () => {
    const apiKey = process.env.OPENROUTER_API_KEY;
    if (!apiKey) throw new Error("OPENROUTER_API_KEY not configured");

    const response = await fetch("https://openrouter.ai/api/v1/models", {
      headers: {
        Authorization: `Bearer ${apiKey}`,
      },
    });

    if (!response.ok) {
      throw new Error(`Failed to fetch models: ${response.statusText}`);
    }

    const data = await response.json();

    return (data.data as Array<{ id: string; name: string; description?: string }>).map(
      (model: { id: string; name: string }) => ({
        id: model.id,
        name: model.name,
        provider: model.id.split("/")[0],
      }),
    );
  },
});
