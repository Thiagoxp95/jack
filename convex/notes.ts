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
      // Verify membership
      const membership = await ctx.db
        .query("space_members")
        .withIndex("by_space_user", (q) =>
          q.eq("spaceId", args.spaceId!).eq("userId", user._id),
        )
        .unique();
      if (!membership) throw new Error("Not a member of this space");

      return await ctx.db
        .query("notes")
        .withIndex("by_space", (q) => q.eq("spaceId", args.spaceId))
        .order("desc")
        .collect();
    }

    // Personal notes (no space)
    return await ctx.db
      .query("notes")
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
    text: v.string(),
    dayStamp: v.string(),
    timestamp: v.string(),
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

    return await ctx.db.insert("notes", {
      spaceId: args.spaceId,
      userId: user._id,
      text: args.text,
      dayStamp: args.dayStamp,
      timestamp: args.timestamp,
    });
  },
});

export const remove = mutation({
  args: { noteId: v.id("notes") },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");
    await ctx.db.delete(args.noteId);
  },
});

export const moveToSpace = mutation({
  args: {
    noteId: v.id("notes"),
    targetSpaceId: v.optional(v.id("spaces")),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const note = await ctx.db.get(args.noteId);
    if (!note) throw new Error("Note not found");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found");
    if (!note.userId || note.userId !== user._id) {
      throw new Error("Not authorized to move this note");
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

    await ctx.db.patch(args.noteId, {
      spaceId: args.targetSpaceId,
    });
  },
});
