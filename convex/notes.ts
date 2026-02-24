import { v } from "convex/values";
import { mutation, query } from "./_generated/server";

export const list = query({
  args: { organizationId: v.optional(v.string()) },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    if (args.organizationId) {
      return await ctx.db
        .query("notes")
        .withIndex("by_org", (q) => q.eq("organizationId", args.organizationId))
        .order("desc")
        .collect();
    }

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) return [];

    return await ctx.db
      .query("notes")
      .withIndex("by_org_user", (q) =>
        q.eq("organizationId", undefined).eq("userId", user._id)
      )
      .order("desc")
      .collect();
  },
});

export const create = mutation({
  args: {
    organizationId: v.optional(v.string()),
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

    return await ctx.db.insert("notes", {
      organizationId: args.organizationId,
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
    targetOrganizationId: v.optional(v.string()),
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

    await ctx.db.patch(args.noteId, {
      organizationId: args.targetOrganizationId,
    });
  },
});
