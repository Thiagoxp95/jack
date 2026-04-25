import { v } from "convex/values";
import { mutation, query } from "./_generated/server";

export const create = mutation({
  args: { name: v.string() },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found. Call syncUser first.");

    const spaceId = await ctx.db.insert("spaces", {
      name: args.name,
      ownerId: user._id,
      createdAt: Date.now(),
    });

    await ctx.db.insert("space_members", {
      spaceId,
      userId: user._id,
      role: "owner",
      joinedAt: Date.now(),
    });

    return spaceId;
  },
});

export const list = query({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) return [];

    const memberships = await ctx.db
      .query("space_members")
      .withIndex("by_user", (q) => q.eq("userId", user._id))
      .collect();

    const spaces = await Promise.all(
      memberships.map(async (m) => {
        const space = await ctx.db.get(m.spaceId);
        if (!space) return null;
        return { ...space, role: m.role };
      }),
    );

    return spaces.filter(Boolean);
  },
});

export const get = query({
  args: { spaceId: v.id("spaces") },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found");

    const membership = await ctx.db
      .query("space_members")
      .withIndex("by_space_user", (q) =>
        q.eq("spaceId", args.spaceId).eq("userId", user._id),
      )
      .unique();
    if (!membership) throw new Error("Not a member of this space");

    return await ctx.db.get(args.spaceId);
  },
});

export const update = mutation({
  args: { spaceId: v.id("spaces"), name: v.string() },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found");

    const membership = await ctx.db
      .query("space_members")
      .withIndex("by_space_user", (q) =>
        q.eq("spaceId", args.spaceId).eq("userId", user._id),
      )
      .unique();
    if (!membership || membership.role !== "owner")
      throw new Error("Only the owner can rename this space");

    await ctx.db.patch(args.spaceId, { name: args.name });
  },
});

export const remove = mutation({
  args: { spaceId: v.id("spaces") },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found");

    const membership = await ctx.db
      .query("space_members")
      .withIndex("by_space_user", (q) =>
        q.eq("spaceId", args.spaceId).eq("userId", user._id),
      )
      .unique();
    if (!membership || membership.role !== "owner")
      throw new Error("Only the owner can delete this space");

    // Delete all recordings and their storage
    const recordings = await ctx.db
      .query("recordings")
      .withIndex("by_space", (q) => q.eq("spaceId", args.spaceId))
      .collect();
    for (const recording of recordings) {
      if (recording.storageId) {
        await ctx.storage.delete(recording.storageId);
      }
      if (recording.thumbnailStorageId) {
        await ctx.storage.delete(recording.thumbnailStorageId);
      }
      await ctx.db.delete(recording._id);
    }

    // Delete all notes
    const notes = await ctx.db
      .query("notes")
      .withIndex("by_space", (q) => q.eq("spaceId", args.spaceId))
      .collect();
    for (const note of notes) {
      await ctx.db.delete(note._id);
    }

    // Delete all members
    const members = await ctx.db
      .query("space_members")
      .withIndex("by_space", (q) => q.eq("spaceId", args.spaceId))
      .collect();
    for (const member of members) {
      await ctx.db.delete(member._id);
    }

    // Delete all invitations
    const invitations = await ctx.db
      .query("space_invitations")
      .withIndex("by_space", (q) => q.eq("spaceId", args.spaceId))
      .collect();
    for (const invitation of invitations) {
      await ctx.db.delete(invitation._id);
    }

    // Delete the space itself
    await ctx.db.delete(args.spaceId);
  },
});

export const invite = mutation({
  args: { spaceId: v.id("spaces"), email: v.string() },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found");

    const membership = await ctx.db
      .query("space_members")
      .withIndex("by_space_user", (q) =>
        q.eq("spaceId", args.spaceId).eq("userId", user._id),
      )
      .unique();
    if (!membership || membership.role !== "owner")
      throw new Error("Only the owner can invite members");

    const email = args.email.toLowerCase();

    // Check if the invitee already has an account
    const invitedUser = await ctx.db
      .query("users")
      .withIndex("by_email", (q) => q.eq("email", email))
      .unique();

    if (invitedUser) {
      // Check if already a member
      const existingMembership = await ctx.db
        .query("space_members")
        .withIndex("by_space_user", (q) =>
          q.eq("spaceId", args.spaceId).eq("userId", invitedUser._id),
        )
        .unique();
      if (existingMembership)
        throw new Error("User is already a member of this space");

      // Auto-accept: create membership and accepted invitation
      await ctx.db.insert("space_members", {
        spaceId: args.spaceId,
        userId: invitedUser._id,
        role: "member",
        joinedAt: Date.now(),
      });

      await ctx.db.insert("space_invitations", {
        spaceId: args.spaceId,
        invitedByUserId: user._id,
        email,
        status: "accepted",
        createdAt: Date.now(),
      });

      return { autoAccepted: true };
    }

    // Check for duplicate pending invitation
    const existingInvitations = await ctx.db
      .query("space_invitations")
      .withIndex("by_email", (q) => q.eq("email", email))
      .collect();
    const duplicatePending = existingInvitations.find(
      (inv) => inv.spaceId === args.spaceId && inv.status === "pending",
    );
    if (duplicatePending)
      throw new Error("A pending invitation already exists for this email");

    // Create pending invitation
    await ctx.db.insert("space_invitations", {
      spaceId: args.spaceId,
      invitedByUserId: user._id,
      email,
      status: "pending",
      createdAt: Date.now(),
    });

    return { autoAccepted: false };
  },
});

export const acceptInvitation = mutation({
  args: { invitationId: v.id("space_invitations") },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found");

    const invitation = await ctx.db.get(args.invitationId);
    if (!invitation) throw new Error("Invitation not found");
    if (invitation.status !== "pending")
      throw new Error("Invitation is no longer pending");
    if (invitation.email !== user.email.toLowerCase())
      throw new Error("This invitation is not for your account");

    await ctx.db.patch(args.invitationId, { status: "accepted" });

    await ctx.db.insert("space_members", {
      spaceId: invitation.spaceId,
      userId: user._id,
      role: "member",
      joinedAt: Date.now(),
    });
  },
});

export const declineInvitation = mutation({
  args: { invitationId: v.id("space_invitations") },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found");

    const invitation = await ctx.db.get(args.invitationId);
    if (!invitation) throw new Error("Invitation not found");
    if (invitation.status !== "pending")
      throw new Error("Invitation is no longer pending");
    if (invitation.email !== user.email.toLowerCase())
      throw new Error("This invitation is not for your account");

    await ctx.db.patch(args.invitationId, { status: "declined" });
  },
});

export const pendingInvitations = query({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) return [];

    const email = user.email.toLowerCase();
    const invitations = await ctx.db
      .query("space_invitations")
      .withIndex("by_email", (q) => q.eq("email", email))
      .collect();

    const pending = invitations.filter((inv) => inv.status === "pending");

    return Promise.all(
      pending.map(async (inv) => {
        const space = await ctx.db.get(inv.spaceId);
        return {
          ...inv,
          spaceName: space?.name ?? "Unknown Space",
        };
      }),
    );
  },
});

export const pendingInvitationsForSpace = query({
  args: { spaceId: v.id("spaces") },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found");

    // Verify caller is a member of the space
    const membership = await ctx.db
      .query("space_members")
      .withIndex("by_space_user", (q) =>
        q.eq("spaceId", args.spaceId).eq("userId", user._id),
      )
      .unique();
    if (!membership) throw new Error("Not a member of this space");

    const invitations = await ctx.db
      .query("space_invitations")
      .withIndex("by_space", (q) => q.eq("spaceId", args.spaceId))
      .collect();

    return invitations
      .filter((inv) => inv.status === "pending")
      .map((inv) => ({
        _id: inv._id,
        email: inv.email,
        createdAt: inv.createdAt,
      }));
  },
});

export const removeMember = mutation({
  args: { spaceId: v.id("spaces"), userId: v.id("users") },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found");

    const membership = await ctx.db
      .query("space_members")
      .withIndex("by_space_user", (q) =>
        q.eq("spaceId", args.spaceId).eq("userId", user._id),
      )
      .unique();
    if (!membership || membership.role !== "owner")
      throw new Error("Only the owner can remove members");

    if (args.userId === user._id)
      throw new Error("Owner cannot remove themselves");

    const targetMembership = await ctx.db
      .query("space_members")
      .withIndex("by_space_user", (q) =>
        q.eq("spaceId", args.spaceId).eq("userId", args.userId),
      )
      .unique();
    if (!targetMembership) throw new Error("User is not a member");

    await ctx.db.delete(targetMembership._id);
  },
});

export const leaveSpace = mutation({
  args: { spaceId: v.id("spaces") },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found");

    const membership = await ctx.db
      .query("space_members")
      .withIndex("by_space_user", (q) =>
        q.eq("spaceId", args.spaceId).eq("userId", user._id),
      )
      .unique();
    if (!membership) throw new Error("Not a member of this space");
    if (membership.role === "owner")
      throw new Error("Owner cannot leave the space. Delete it instead.");

    await ctx.db.delete(membership._id);
  },
});

export const members = query({
  args: { spaceId: v.id("spaces") },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found");

    const membership = await ctx.db
      .query("space_members")
      .withIndex("by_space_user", (q) =>
        q.eq("spaceId", args.spaceId).eq("userId", user._id),
      )
      .unique();
    if (!membership) throw new Error("Not a member of this space");

    const allMembers = await ctx.db
      .query("space_members")
      .withIndex("by_space", (q) => q.eq("spaceId", args.spaceId))
      .collect();

    return Promise.all(
      allMembers.map(async (m) => {
        const memberUser = await ctx.db.get(m.userId);
        return {
          _id: m._id,
          userId: m.userId,
          role: m.role,
          joinedAt: m.joinedAt,
          name: memberUser?.name ?? memberUser?.firstName ?? "Unknown",
          email: memberUser?.email ?? "",
          imageUrl: memberUser?.imageUrl,
        };
      }),
    );
  },
});
