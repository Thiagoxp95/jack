import { mutation, query } from "./_generated/server";

export const syncUser = mutation({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const clerkId = identity.subject;
    const existing = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", clerkId))
      .unique();

    let userId;

    if (existing) {
      await ctx.db.patch(existing._id, {
        email: identity.email ?? existing.email,
        firstName: identity.givenName ?? existing.firstName,
        lastName: identity.familyName ?? existing.lastName,
        imageUrl: identity.pictureUrl ?? existing.imageUrl,
      });
      userId = existing._id;
    } else {
      userId = await ctx.db.insert("users", {
        clerkId,
        email: identity.email ?? "",
        firstName: identity.givenName,
        lastName: identity.familyName,
        imageUrl: identity.pictureUrl,
      });
    }

    // Auto-accept pending space invitations for this user's email
    const userEmail = (identity.email ?? "").toLowerCase();
    if (userEmail) {
      const pendingInvitations = await ctx.db
        .query("space_invitations")
        .withIndex("by_email", (q) => q.eq("email", userEmail))
        .collect();

      for (const invitation of pendingInvitations) {
        if (invitation.status !== "pending") continue;

        // Check not already a member
        const existingMembership = await ctx.db
          .query("space_members")
          .withIndex("by_space_user", (q) =>
            q.eq("spaceId", invitation.spaceId).eq("userId", userId),
          )
          .unique();
        if (existingMembership) continue;

        // Create membership
        await ctx.db.insert("space_members", {
          spaceId: invitation.spaceId,
          userId,
          role: "member",
          joinedAt: Date.now(),
        });

        // Mark invitation as accepted
        await ctx.db.patch(invitation._id, { status: "accepted" as const });
      }
    }

    return userId;
  },
});

export const currentUser = query({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) return null;

    return await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
  },
});
