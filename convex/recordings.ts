import { v } from "convex/values";
import { mutation, query } from "./_generated/server";

export const list = query({
  args: { organizationId: v.string() },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    return await ctx.db
      .query("recordings")
      .withIndex("by_org", (q) => q.eq("organizationId", args.organizationId))
      .order("desc")
      .collect();
  },
});

export const create = mutation({
  args: {
    organizationId: v.string(),
    title: v.string(),
    duration: v.number(),
    storageId: v.optional(v.id("_storage")),
    thumbnailStorageId: v.optional(v.id("_storage")),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found. Call syncUser first.");

    return await ctx.db.insert("recordings", {
      organizationId: args.organizationId,
      userId: user._id,
      title: args.title,
      duration: args.duration,
      storageId: args.storageId,
      thumbnailStorageId: args.thumbnailStorageId,
    });
  },
});

export const remove = mutation({
  args: { recordingId: v.id("recordings") },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const recording = await ctx.db.get(args.recordingId);
    if (recording?.storageId) {
      await ctx.storage.delete(recording.storageId);
    }
    if (recording?.thumbnailStorageId) {
      await ctx.storage.delete(recording.thumbnailStorageId);
    }
    await ctx.db.delete(args.recordingId);
  },
});
