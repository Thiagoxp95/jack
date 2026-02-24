import { v } from "convex/values";
import { mutation, query } from "./_generated/server";

export const list = query({
  args: { organizationId: v.optional(v.string()) },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    if (args.organizationId) {
      return await ctx.db
        .query("recordings")
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
      .query("recordings")
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

export const enableSharing = mutation({
  args: { recordingId: v.id("recordings") },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const recording = await ctx.db.get(args.recordingId);
    if (!recording) throw new Error("Recording not found");

    if (recording.shareToken) {
      await ctx.db.patch(args.recordingId, { shareEnabled: true });
      return recording.shareToken;
    }

    const chars =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    let token = "";
    for (let i = 0; i < 12; i++) {
      token += chars.charAt(Math.floor(Math.random() * chars.length));
    }

    await ctx.db.patch(args.recordingId, {
      shareToken: token,
      shareEnabled: true,
    });
    return token;
  },
});

export const disableSharing = mutation({
  args: { recordingId: v.id("recordings") },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const recording = await ctx.db.get(args.recordingId);
    if (!recording) throw new Error("Recording not found");

    await ctx.db.patch(args.recordingId, { shareEnabled: false });
  },
});

export const getByShareToken = query({
  args: { shareToken: v.string() },
  handler: async (ctx, args) => {
    const recording = await ctx.db
      .query("recordings")
      .withIndex("by_share_token", (q) =>
        q.eq("shareToken", args.shareToken)
      )
      .unique();

    if (!recording || !recording.shareEnabled) return null;

    let videoUrl: string | null = null;
    if (recording.storageId) {
      videoUrl = await ctx.storage.getUrl(recording.storageId);
    }

    return {
      title: recording.title,
      duration: recording.duration,
      videoUrl,
    };
  },
});

export const moveToSpace = mutation({
  args: {
    recordingId: v.id("recordings"),
    targetOrganizationId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const recording = await ctx.db.get(args.recordingId);
    if (!recording) throw new Error("Recording not found");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found");
    if (!recording.userId || recording.userId !== user._id) {
      throw new Error("Not authorized to move this recording");
    }

    await ctx.db.patch(args.recordingId, {
      organizationId: args.targetOrganizationId,
    });
  },
});
