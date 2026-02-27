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
        .query("todoLists")
        .withIndex("by_space", (q) => q.eq("spaceId", args.spaceId))
        .collect();
    }

    // Personal todo lists (no space)
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
