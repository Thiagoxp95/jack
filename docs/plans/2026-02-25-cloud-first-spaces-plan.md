# Cloud-First Recordings + Custom Spaces Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace Clerk organizations with custom Convex spaces, make recordings always upload to cloud, and share content across space members in real-time.

**Architecture:** New `spaces`, `space_members`, `space_invitations` Convex tables replace Clerk orgs. All `organizationId` fields become `spaceId`. A new `UploadQueue` handles background upload with retry after export. `RecordingsLibraryView` switches from local file scanning to Convex queries.

**Tech Stack:** Convex (TypeScript), SwiftUI/Swift (macOS), Clerk (auth only)

**Design doc:** `docs/plans/2026-02-25-cloud-first-spaces-design.md`

---

## Task 1: Add new Convex tables to schema

**Files:**
- Modify: `convex/schema.ts`

**Step 1: Update schema with new tables and modified fields**

Replace the entire contents of `convex/schema.ts` with:

```typescript
import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
  users: defineTable({
    clerkId: v.string(),
    email: v.string(),
    firstName: v.optional(v.string()),
    lastName: v.optional(v.string()),
    name: v.optional(v.string()),
    imageUrl: v.optional(v.string()),
    createdAt: v.optional(v.number()),
    updatedAt: v.optional(v.number()),
  })
    .index("by_clerkId", ["clerkId"])
    .index("by_email", ["email"]),

  spaces: defineTable({
    name: v.string(),
    ownerId: v.id("users"),
    createdAt: v.number(),
  })
    .index("by_owner", ["ownerId"]),

  space_members: defineTable({
    spaceId: v.id("spaces"),
    userId: v.id("users"),
    role: v.union(v.literal("owner"), v.literal("member")),
    joinedAt: v.number(),
  })
    .index("by_space", ["spaceId"])
    .index("by_user", ["userId"])
    .index("by_space_user", ["spaceId", "userId"]),

  space_invitations: defineTable({
    spaceId: v.id("spaces"),
    invitedByUserId: v.id("users"),
    email: v.string(),
    status: v.union(
      v.literal("pending"),
      v.literal("accepted"),
      v.literal("declined")
    ),
    createdAt: v.number(),
  })
    .index("by_space", ["spaceId"])
    .index("by_email", ["email"]),

  notes: defineTable({
    spaceId: v.optional(v.id("spaces")),
    userId: v.optional(v.id("users")),
    text: v.string(),
    dayStamp: v.string(),
    timestamp: v.string(),
  })
    .index("by_space", ["spaceId"])
    .index("by_space_user", ["spaceId", "userId"]),

  recordings: defineTable({
    spaceId: v.optional(v.id("spaces")),
    userId: v.optional(v.id("users")),
    title: v.optional(v.string()),
    duration: v.number(),
    storageId: v.optional(v.id("_storage")),
    thumbnailStorageId: v.optional(v.id("_storage")),
    shareToken: v.optional(v.string()),
    shareEnabled: v.optional(v.boolean()),
    fileSize: v.optional(v.number()),
    filename: v.optional(v.string()),
    mimeType: v.optional(v.string()),
    recordedAt: v.optional(v.number()),
    transcription: v.optional(v.string()),
    transcriptionStatus: v.optional(v.string()),
    chunkStorageIds: v.optional(v.array(v.string())),
  })
    .index("by_space", ["spaceId"])
    .index("by_space_user", ["spaceId", "userId"])
    .index("by_share_token", ["shareToken"]),
});
```

**Step 2: Verify schema compiles**

Run: `cd /Users/txp/Pessoal/jack-v2 && npx convex dev --once`

Expected: Schema pushes successfully (existing data has `organizationId` which becomes an extra field — Convex allows extra fields not in schema).

**Step 3: Commit**

```bash
git add convex/schema.ts
git commit -m "feat(convex): add spaces, space_members, space_invitations tables; replace organizationId with spaceId"
```

---

## Task 2: Create `convex/spaces.ts` — all space CRUD, membership, invitations

**Files:**
- Create: `convex/spaces.ts`

**Step 1: Create the spaces module**

Create `convex/spaces.ts`:

```typescript
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";

// Helper: get current user from Clerk identity
async function getCurrentUser(ctx: any) {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) throw new Error("Unauthenticated");
  const user = await ctx.db
    .query("users")
    .withIndex("by_clerkId", (q: any) => q.eq("clerkId", identity.subject))
    .unique();
  if (!user) throw new Error("User not found. Call syncUser first.");
  return user;
}

// Helper: verify user is a member of a space
async function verifyMembership(ctx: any, spaceId: any, userId: any) {
  const membership = await ctx.db
    .query("space_members")
    .withIndex("by_space_user", (q: any) =>
      q.eq("spaceId", spaceId).eq("userId", userId)
    )
    .unique();
  if (!membership) throw new Error("Not a member of this space");
  return membership;
}

// Helper: verify user is owner of a space
async function verifyOwner(ctx: any, spaceId: any, userId: any) {
  const membership = await verifyMembership(ctx, spaceId, userId);
  if (membership.role !== "owner") throw new Error("Only the space owner can do this");
  return membership;
}

export const create = mutation({
  args: { name: v.string() },
  handler: async (ctx, args) => {
    const user = await getCurrentUser(ctx);
    const now = Date.now();

    const spaceId = await ctx.db.insert("spaces", {
      name: args.name,
      ownerId: user._id,
      createdAt: now,
    });

    await ctx.db.insert("space_members", {
      spaceId,
      userId: user._id,
      role: "owner",
      joinedAt: now,
    });

    return spaceId;
  },
});

export const list = query({
  args: {},
  handler: async (ctx) => {
    const user = await getCurrentUser(ctx);

    const memberships = await ctx.db
      .query("space_members")
      .withIndex("by_user", (q: any) => q.eq("userId", user._id))
      .collect();

    const spaces = await Promise.all(
      memberships.map(async (m: any) => {
        const space = await ctx.db.get(m.spaceId);
        if (!space) return null;
        return { ...space, role: m.role };
      })
    );

    return spaces.filter(Boolean);
  },
});

export const get = query({
  args: { spaceId: v.id("spaces") },
  handler: async (ctx, args) => {
    const user = await getCurrentUser(ctx);
    await verifyMembership(ctx, args.spaceId, user._id);
    return await ctx.db.get(args.spaceId);
  },
});

export const update = mutation({
  args: { spaceId: v.id("spaces"), name: v.string() },
  handler: async (ctx, args) => {
    const user = await getCurrentUser(ctx);
    await verifyOwner(ctx, args.spaceId, user._id);
    await ctx.db.patch(args.spaceId, { name: args.name });
  },
});

export const remove = mutation({
  args: { spaceId: v.id("spaces") },
  handler: async (ctx, args) => {
    const user = await getCurrentUser(ctx);
    await verifyOwner(ctx, args.spaceId, user._id);

    // Delete all recordings + their storage
    const recordings = await ctx.db
      .query("recordings")
      .withIndex("by_space", (q: any) => q.eq("spaceId", args.spaceId))
      .collect();
    for (const rec of recordings) {
      if (rec.storageId) await ctx.storage.delete(rec.storageId);
      if (rec.thumbnailStorageId) await ctx.storage.delete(rec.thumbnailStorageId);
      await ctx.db.delete(rec._id);
    }

    // Delete all notes
    const notes = await ctx.db
      .query("notes")
      .withIndex("by_space", (q: any) => q.eq("spaceId", args.spaceId))
      .collect();
    for (const note of notes) {
      await ctx.db.delete(note._id);
    }

    // Delete all memberships
    const members = await ctx.db
      .query("space_members")
      .withIndex("by_space", (q: any) => q.eq("spaceId", args.spaceId))
      .collect();
    for (const m of members) {
      await ctx.db.delete(m._id);
    }

    // Delete all invitations
    const invitations = await ctx.db
      .query("space_invitations")
      .withIndex("by_space", (q: any) => q.eq("spaceId", args.spaceId))
      .collect();
    for (const inv of invitations) {
      await ctx.db.delete(inv._id);
    }

    // Delete the space itself
    await ctx.db.delete(args.spaceId);
  },
});

export const invite = mutation({
  args: { spaceId: v.id("spaces"), email: v.string() },
  handler: async (ctx, args) => {
    const user = await getCurrentUser(ctx);
    await verifyOwner(ctx, args.spaceId, user._id);

    const normalizedEmail = args.email.toLowerCase().trim();

    // Check if already a member
    const existingUser = await ctx.db
      .query("users")
      .withIndex("by_email", (q: any) => q.eq("email", normalizedEmail))
      .unique();

    if (existingUser) {
      const existingMembership = await ctx.db
        .query("space_members")
        .withIndex("by_space_user", (q: any) =>
          q.eq("spaceId", args.spaceId).eq("userId", existingUser._id)
        )
        .unique();
      if (existingMembership) {
        throw new Error("User is already a member of this space");
      }

      // Auto-accept: user already has an account
      await ctx.db.insert("space_members", {
        spaceId: args.spaceId,
        userId: existingUser._id,
        role: "member",
        joinedAt: Date.now(),
      });

      await ctx.db.insert("space_invitations", {
        spaceId: args.spaceId,
        invitedByUserId: user._id,
        email: normalizedEmail,
        status: "accepted",
        createdAt: Date.now(),
      });

      return { autoAccepted: true };
    }

    // Check for duplicate pending invitation
    const existingInvite = await ctx.db
      .query("space_invitations")
      .withIndex("by_email", (q: any) => q.eq("email", normalizedEmail))
      .filter((q: any) =>
        q.and(
          q.eq(q.field("spaceId"), args.spaceId),
          q.eq(q.field("status"), "pending")
        )
      )
      .unique();
    if (existingInvite) {
      throw new Error("Invitation already pending for this email");
    }

    await ctx.db.insert("space_invitations", {
      spaceId: args.spaceId,
      invitedByUserId: user._id,
      email: normalizedEmail,
      status: "pending",
      createdAt: Date.now(),
    });

    return { autoAccepted: false };
  },
});

export const acceptInvitation = mutation({
  args: { invitationId: v.id("space_invitations") },
  handler: async (ctx, args) => {
    const user = await getCurrentUser(ctx);
    const invitation = await ctx.db.get(args.invitationId);
    if (!invitation) throw new Error("Invitation not found");
    if (invitation.status !== "pending") throw new Error("Invitation is no longer pending");
    if (invitation.email !== user.email.toLowerCase()) {
      throw new Error("This invitation is not for you");
    }

    await ctx.db.patch(args.invitationId, { status: "accepted" });

    // Check not already a member (edge case)
    const existing = await ctx.db
      .query("space_members")
      .withIndex("by_space_user", (q: any) =>
        q.eq("spaceId", invitation.spaceId).eq("userId", user._id)
      )
      .unique();
    if (!existing) {
      await ctx.db.insert("space_members", {
        spaceId: invitation.spaceId,
        userId: user._id,
        role: "member",
        joinedAt: Date.now(),
      });
    }
  },
});

export const declineInvitation = mutation({
  args: { invitationId: v.id("space_invitations") },
  handler: async (ctx, args) => {
    const user = await getCurrentUser(ctx);
    const invitation = await ctx.db.get(args.invitationId);
    if (!invitation) throw new Error("Invitation not found");
    if (invitation.email !== user.email.toLowerCase()) {
      throw new Error("This invitation is not for you");
    }
    await ctx.db.patch(args.invitationId, { status: "declined" });
  },
});

export const pendingInvitations = query({
  args: {},
  handler: async (ctx) => {
    const user = await getCurrentUser(ctx);
    const email = user.email.toLowerCase();

    const invitations = await ctx.db
      .query("space_invitations")
      .withIndex("by_email", (q: any) => q.eq("email", email))
      .filter((q: any) => q.eq(q.field("status"), "pending"))
      .collect();

    // Enrich with space name
    return await Promise.all(
      invitations.map(async (inv: any) => {
        const space = await ctx.db.get(inv.spaceId);
        return {
          ...inv,
          spaceName: space?.name ?? "Unknown",
        };
      })
    );
  },
});

export const removeMember = mutation({
  args: { spaceId: v.id("spaces"), userId: v.id("users") },
  handler: async (ctx, args) => {
    const user = await getCurrentUser(ctx);
    await verifyOwner(ctx, args.spaceId, user._id);

    if (args.userId === user._id) {
      throw new Error("Owner cannot remove themselves. Delete the space instead.");
    }

    const membership = await ctx.db
      .query("space_members")
      .withIndex("by_space_user", (q: any) =>
        q.eq("spaceId", args.spaceId).eq("userId", args.userId)
      )
      .unique();
    if (!membership) throw new Error("User is not a member");
    await ctx.db.delete(membership._id);
  },
});

export const leaveSpace = mutation({
  args: { spaceId: v.id("spaces") },
  handler: async (ctx, args) => {
    const user = await getCurrentUser(ctx);
    const membership = await verifyMembership(ctx, args.spaceId, user._id);

    if (membership.role === "owner") {
      throw new Error("Owner cannot leave. Delete the space instead.");
    }

    await ctx.db.delete(membership._id);
  },
});

export const members = query({
  args: { spaceId: v.id("spaces") },
  handler: async (ctx, args) => {
    const user = await getCurrentUser(ctx);
    await verifyMembership(ctx, args.spaceId, user._id);

    const memberships = await ctx.db
      .query("space_members")
      .withIndex("by_space", (q: any) => q.eq("spaceId", args.spaceId))
      .collect();

    return await Promise.all(
      memberships.map(async (m: any) => {
        const memberUser = await ctx.db.get(m.userId);
        return {
          _id: m._id,
          userId: m.userId,
          role: m.role,
          joinedAt: m.joinedAt,
          email: memberUser?.email ?? "",
          firstName: memberUser?.firstName,
          lastName: memberUser?.lastName,
          imageUrl: memberUser?.imageUrl,
        };
      })
    );
  },
});
```

**Step 2: Verify it compiles**

Run: `cd /Users/txp/Pessoal/jack-v2 && npx convex dev --once`

Expected: Deploys successfully.

**Step 3: Commit**

```bash
git add convex/spaces.ts
git commit -m "feat(convex): add spaces module with CRUD, membership, and invitations"
```

---

## Task 3: Update `recordings.ts` — replace organizationId with spaceId

**Files:**
- Modify: `convex/recordings.ts`

**Step 1: Rewrite recordings.ts**

Replace `convex/recordings.ts` with the updated version. Key changes:
- All `organizationId` args/fields → `spaceId` (type `v.optional(v.id("spaces"))`)
- `list` verifies membership when spaceId is provided
- `create` uses `spaceId`
- `moveToSpace` verifies target membership, uses `spaceId`
- Remove `deleteByOrganization` (handled by `spaces:remove`)
- `createAndShare` accepts optional `spaceId`

```typescript
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";

export const list = query({
  args: { spaceId: v.optional(v.id("spaces")) },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    if (args.spaceId) {
      // Verify membership
      const user = await ctx.db
        .query("users")
        .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
        .unique();
      if (user) {
        const membership = await ctx.db
          .query("space_members")
          .withIndex("by_space_user", (q) =>
            q.eq("spaceId", args.spaceId!).eq("userId", user._id)
          )
          .unique();
        if (!membership) throw new Error("Not a member of this space");
      }

      return await ctx.db
        .query("recordings")
        .withIndex("by_space", (q) => q.eq("spaceId", args.spaceId))
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
      .withIndex("by_space_user", (q) =>
        q.eq("spaceId", undefined).eq("userId", user._id)
      )
      .order("desc")
      .collect();
  },
});

export const create = mutation({
  args: {
    spaceId: v.optional(v.id("spaces")),
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

    // Verify membership if targeting a space
    if (args.spaceId) {
      const membership = await ctx.db
        .query("space_members")
        .withIndex("by_space_user", (q) =>
          q.eq("spaceId", args.spaceId!).eq("userId", user._id)
        )
        .unique();
      if (!membership) throw new Error("Not a member of this space");
    }

    return await ctx.db.insert("recordings", {
      spaceId: args.spaceId,
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

export const createAndShare = mutation({
  args: {
    spaceId: v.optional(v.id("spaces")),
    title: v.string(),
    duration: v.number(),
    storageId: v.optional(v.id("_storage")),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found. Call syncUser first.");

    const recordingId = await ctx.db.insert("recordings", {
      spaceId: args.spaceId,
      userId: user._id,
      title: args.title,
      duration: args.duration,
      storageId: args.storageId,
    });

    const chars =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    let token = "";
    for (let i = 0; i < 12; i++) {
      token += chars.charAt(Math.floor(Math.random() * chars.length));
    }

    await ctx.db.patch(recordingId, {
      shareToken: token,
      shareEnabled: true,
    });

    return token;
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
    targetSpaceId: v.optional(v.id("spaces")),
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

    // Verify membership in target space
    if (args.targetSpaceId) {
      const membership = await ctx.db
        .query("space_members")
        .withIndex("by_space_user", (q) =>
          q.eq("spaceId", args.targetSpaceId!).eq("userId", user._id)
        )
        .unique();
      if (!membership) throw new Error("Not a member of target space");
    }

    await ctx.db.patch(args.recordingId, {
      spaceId: args.targetSpaceId,
    });
  },
});
```

**Step 2: Verify**

Run: `cd /Users/txp/Pessoal/jack-v2 && npx convex dev --once`

**Step 3: Commit**

```bash
git add convex/recordings.ts
git commit -m "feat(convex): replace organizationId with spaceId in recordings, add membership checks"
```

---

## Task 4: Update `notes.ts` — replace organizationId with spaceId

**Files:**
- Modify: `convex/notes.ts`

**Step 1: Rewrite notes.ts**

Same pattern as recordings. Replace `convex/notes.ts`:

```typescript
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";

export const list = query({
  args: { spaceId: v.optional(v.id("spaces")) },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    if (args.spaceId) {
      const user = await ctx.db
        .query("users")
        .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
        .unique();
      if (user) {
        const membership = await ctx.db
          .query("space_members")
          .withIndex("by_space_user", (q) =>
            q.eq("spaceId", args.spaceId!).eq("userId", user._id)
          )
          .unique();
        if (!membership) throw new Error("Not a member of this space");
      }

      return await ctx.db
        .query("notes")
        .withIndex("by_space", (q) => q.eq("spaceId", args.spaceId))
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
      .withIndex("by_space_user", (q) =>
        q.eq("spaceId", undefined).eq("userId", user._id)
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
          q.eq("spaceId", args.targetSpaceId!).eq("userId", user._id)
        )
        .unique();
      if (!membership) throw new Error("Not a member of target space");
    }

    await ctx.db.patch(args.noteId, {
      spaceId: args.targetSpaceId,
    });
  },
});
```

**Step 2: Verify**

Run: `cd /Users/txp/Pessoal/jack-v2 && npx convex dev --once`

**Step 3: Commit**

```bash
git add convex/notes.ts
git commit -m "feat(convex): replace organizationId with spaceId in notes, add membership checks"
```

---

## Task 5: Update `users.ts` — auto-accept invitations on syncUser

**Files:**
- Modify: `convex/users.ts`

**Step 1: Add auto-accept logic to syncUser**

After upserting the user record, check `space_invitations` by email and auto-accept any pending ones:

```typescript
import { v } from "convex/values";
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
    const email = (identity.email ?? "").toLowerCase();

    if (existing) {
      await ctx.db.patch(existing._id, {
        email: email || existing.email,
        firstName: identity.givenName ?? existing.firstName,
        lastName: identity.familyName ?? existing.lastName,
        imageUrl: identity.pictureUrl ?? existing.imageUrl,
      });
      userId = existing._id;
    } else {
      userId = await ctx.db.insert("users", {
        clerkId,
        email,
        firstName: identity.givenName,
        lastName: identity.familyName,
        imageUrl: identity.pictureUrl,
      });
    }

    // Auto-accept pending space invitations for this email
    if (email) {
      const pendingInvitations = await ctx.db
        .query("space_invitations")
        .withIndex("by_email", (q) => q.eq("email", email))
        .filter((q) => q.eq(q.field("status"), "pending"))
        .collect();

      for (const invitation of pendingInvitations) {
        // Check not already a member
        const existingMembership = await ctx.db
          .query("space_members")
          .withIndex("by_space_user", (q) =>
            q.eq("spaceId", invitation.spaceId).eq("userId", userId)
          )
          .unique();

        if (!existingMembership) {
          await ctx.db.insert("space_members", {
            spaceId: invitation.spaceId,
            userId,
            role: "member",
            joinedAt: Date.now(),
          });
        }

        await ctx.db.patch(invitation._id, { status: "accepted" });
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
```

**Step 2: Verify**

Run: `cd /Users/txp/Pessoal/jack-v2 && npx convex dev --once`

**Step 3: Commit**

```bash
git add convex/users.ts
git commit -m "feat(convex): auto-accept pending space invitations on syncUser"
```

---

## Task 6: Clean up AuthController — remove Clerk org properties

**Files:**
- Modify: `Sources/JackApp/Auth/AuthController.swift`

**Step 1: Remove org-related code**

Remove the following from `AuthController.swift`:
- `currentOrganization` computed property (lines 22-25)
- `organizations` computed property (lines 27-29)
- `setActiveOrganization(_:)` method (lines 75-81)
- Remove `import ClerkKit` line only if no other ClerkKit references remain (they do — `Clerk.shared`, `ClerkKit.User` — so keep it)

The file should become:

```swift
import ClerkKit
@preconcurrency import ConvexMobile
import Foundation

@MainActor @Observable
final class AuthController {
    private(set) var convexClient: ConvexClientWithAuth<ClerkKit.User>?

    var isSignedIn: Bool { Clerk.shared.session != nil }
    var currentUser: ClerkKit.User? { Clerk.shared.user }

    // MARK: - Convex lifecycle

    func initializeConvex(deploymentUrl: String) {
        let provider = ClerkAuthProvider()
        convexClient = ConvexClientWithAuth(
            deploymentUrl: deploymentUrl,
            authProvider: provider
        )
    }

    func authenticateConvex() async {
        guard let client = convexClient else { return }
        let result = await client.loginFromCache()
        switch result {
        case .success:
            do {
                try await client.mutation("users:syncUser", with: [:])
            } catch {
                print("[AuthController] syncUser mutation failed: \(error)")
            }
        case .failure(let error):
            print("[AuthController] Convex auth failed: \(error)")
        }
    }

    // MARK: - Sign in / out

    func signIn(email: String, password: String) async throws {
        let signIn = try await Clerk.shared.auth.signInWithPassword(
            identifier: email,
            password: password
        )
        if signIn.status == .complete {
            await authenticateConvex()
        }
    }

    func signOut() async throws {
        convexClient = nil
        try await Clerk.shared.auth.signOut()
    }
}
```

**Step 2: Verify it builds**

Run: `cd /Users/txp/Pessoal/jack-v2 && swift build 2>&1 | head -30`

Expected: May have downstream compile errors (e.g., `SpaceSettingsSheet` referencing Clerk orgs). That's expected — we fix those in later tasks.

**Step 3: Commit**

```bash
git add Sources/JackApp/Auth/AuthController.swift
git commit -m "refactor: remove Clerk organization properties from AuthController"
```

---

## Task 7: Refactor SpaceController — query Convex instead of Clerk orgs

**Files:**
- Modify: `Sources/JackApp/SpaceController.swift`

**Step 1: Remove ClerkKit import and rewrite space operations**

Key changes:
- Remove `import ClerkKit`
- `refreshSpaces()` → call `spaces:list` via `ConvexHTTPClient` instead of `user.getOrganizationMemberships()`
- `switchSpace(to:)` → just update UserDefaults, no Clerk `setActive` call
- `deleteSpace(_:)` → call `spaces:remove` instead of Clerk org destroy + manual cascade
- Add `currentSpaceId` property (replaces `currentOrganizationId`)
- Add `createSpace(name:)`, `inviteToSpace(spaceId:email:)`, `fetchPendingInvitations()`, `acceptInvitation(id:)`, `declineInvitation(id:)`, `fetchMembers(spaceId:)`, `removeMember(spaceId:userId:)`, `leaveSpace(spaceId:)`

The `Space` struct, `SpaceColor`, `SpaceIcon`, and `SpaceAppearanceStore` remain unchanged.

In `SpaceController`, replace the `refreshSpaces`, `switchSpace`, `currentOrganizationId`, and `deleteSpace` implementations. Add new methods for invitations and membership. The full replacement for the `SpaceController` class (lines 272-436) is:

```swift
@MainActor @Observable
final class SpaceController {
    private(set) var activeSpace: Space = .personal
    private(set) var availableSpaces: [Space] = [.personal]
    private(set) var pendingInvitations: [PendingInvitation] = []

    struct PendingInvitation: Identifiable {
        let id: String
        let spaceId: String
        let spaceName: String
        let email: String
    }

    struct SpaceMember: Identifiable {
        let id: String
        let userId: String
        let role: String
        let email: String
        let firstName: String?
        let lastName: String?
    }

    /// Tracked color/icon maps — mutating these triggers @Observable updates.
    private var colorMap: [String: SpaceColor] = [:]
    private var iconMap: [String: SpaceIcon] = [:]

    private static let activeSpaceKey = "activeSpaceId"
    private static let activeSpaceNameKey = "activeSpaceName"

    init() {
        if let raw = UserDefaults.standard.dictionary(forKey: "spaceColors") as? [String: String] {
            for (id, val) in raw {
                if let c = SpaceColor(rawValue: val) { colorMap[id] = c }
            }
        }
        if let raw = UserDefaults.standard.dictionary(forKey: "spaceIcons") as? [String: String] {
            for (id, val) in raw {
                if let icon = SpaceIcon(serialized: val) { iconMap[id] = icon }
            }
        }

        if let savedId = UserDefaults.standard.string(forKey: Self.activeSpaceKey),
           savedId != "personal"
        {
            let savedName = UserDefaults.standard.string(forKey: Self.activeSpaceNameKey) ?? savedId
            activeSpace = Space(id: savedId, name: savedName, isPersonal: false)
        }
    }

    // MARK: - Color

    var activeSpaceColor: SpaceColor {
        colorMap[activeSpace.id] ?? .blue
    }

    func color(for space: Space) -> SpaceColor {
        colorMap[space.id] ?? .blue
    }

    func setColor(_ color: SpaceColor, for space: Space) {
        colorMap[space.id] = color
        SpaceAppearanceStore.setColor(color, for: space.id)
    }

    // MARK: - Icon

    var activeSpaceIcon: SpaceIcon {
        activeSpace.isPersonal ? .personal : (iconMap[activeSpace.id] ?? .defaultTeam)
    }

    func icon(for space: Space) -> SpaceIcon {
        space.isPersonal ? .personal : (iconMap[space.id] ?? .defaultTeam)
    }

    func setIcon(_ icon: SpaceIcon, for space: Space) {
        iconMap[space.id] = icon
        SpaceAppearanceStore.setIcon(icon, for: space.id)
    }

    // MARK: - Spaces

    /// The spaceId to pass to Convex queries.
    /// Returns nil for personal space.
    var currentSpaceId: String? {
        activeSpace.isPersonal ? nil : activeSpace.id
    }

    func refreshSpaces() async {
        var spaces: [Space] = [.personal]

        do {
            let token = try await ConvexHTTPClient.getToken()
            let result = try await ConvexHTTPClient.query(
                function: "spaces:list",
                args: [:],
                token: token
            )

            if let items = result as? [[String: Any]] {
                for item in items {
                    if let id = item["_id"] as? String,
                       let name = item["name"] as? String {
                        spaces.append(Space(id: id, name: name, isPersonal: false))
                    }
                }
            }
        } catch {
            NSLog("[SpaceController] Failed to fetch spaces: %@", String(describing: error))
        }

        availableSpaces = spaces

        if !activeSpace.isPersonal,
           !spaces.contains(where: { $0.id == activeSpace.id })
        {
            activeSpace = .personal
            persistActiveSpace()
        }
    }

    func switchSpace(to space: Space) {
        activeSpace = space
        persistActiveSpace()
    }

    func createSpace(name: String) async throws -> String {
        let token = try await ConvexHTTPClient.getToken()
        let result = try await ConvexHTTPClient.mutation(
            function: "spaces:create",
            args: ["name": name],
            token: token
        )
        guard let spaceId = result as? String else {
            throw SpaceError.unexpected("No spaceId returned")
        }
        await refreshSpaces()
        return spaceId
    }

    func deleteSpace(_ space: Space) async throws {
        guard !space.isPersonal else { return }

        let token = try await ConvexHTTPClient.getToken()
        _ = try await ConvexHTTPClient.mutation(
            function: "spaces:remove",
            args: ["spaceId": space.id],
            token: token
        )

        activeSpace = .personal
        persistActiveSpace()
        await refreshSpaces()
    }

    // MARK: - Invitations

    func inviteToSpace(spaceId: String, email: String) async throws {
        let token = try await ConvexHTTPClient.getToken()
        _ = try await ConvexHTTPClient.mutation(
            function: "spaces:invite",
            args: ["spaceId": spaceId, "email": email],
            token: token
        )
    }

    func fetchPendingInvitations() async {
        do {
            let token = try await ConvexHTTPClient.getToken()
            let result = try await ConvexHTTPClient.query(
                function: "spaces:pendingInvitations",
                args: [:],
                token: token
            )

            guard let items = result as? [[String: Any]] else {
                pendingInvitations = []
                return
            }

            pendingInvitations = items.compactMap { item in
                guard let id = item["_id"] as? String,
                      let spaceId = item["spaceId"] as? String,
                      let spaceName = item["spaceName"] as? String,
                      let email = item["email"] as? String
                else { return nil }
                return PendingInvitation(id: id, spaceId: spaceId, spaceName: spaceName, email: email)
            }
        } catch {
            NSLog("[SpaceController] Failed to fetch invitations: %@", String(describing: error))
        }
    }

    func acceptInvitation(id: String) async throws {
        let token = try await ConvexHTTPClient.getToken()
        _ = try await ConvexHTTPClient.mutation(
            function: "spaces:acceptInvitation",
            args: ["invitationId": id],
            token: token
        )
        await refreshSpaces()
        await fetchPendingInvitations()
    }

    func declineInvitation(id: String) async throws {
        let token = try await ConvexHTTPClient.getToken()
        _ = try await ConvexHTTPClient.mutation(
            function: "spaces:declineInvitation",
            args: ["invitationId": id],
            token: token
        )
        await fetchPendingInvitations()
    }

    // MARK: - Members

    func fetchMembers(spaceId: String) async throws -> [SpaceMember] {
        let token = try await ConvexHTTPClient.getToken()
        let result = try await ConvexHTTPClient.query(
            function: "spaces:members",
            args: ["spaceId": spaceId],
            token: token
        )

        guard let items = result as? [[String: Any]] else { return [] }

        return items.compactMap { item in
            guard let id = item["_id"] as? String,
                  let userId = item["userId"] as? String,
                  let role = item["role"] as? String,
                  let email = item["email"] as? String
            else { return nil }
            return SpaceMember(
                id: id,
                userId: userId,
                role: role,
                email: email,
                firstName: item["firstName"] as? String,
                lastName: item["lastName"] as? String
            )
        }
    }

    func removeMember(spaceId: String, userId: String) async throws {
        let token = try await ConvexHTTPClient.getToken()
        _ = try await ConvexHTTPClient.mutation(
            function: "spaces:removeMember",
            args: ["spaceId": spaceId, "userId": userId],
            token: token
        )
    }

    func leaveSpace(spaceId: String) async throws {
        let token = try await ConvexHTTPClient.getToken()
        _ = try await ConvexHTTPClient.mutation(
            function: "spaces:leaveSpace",
            args: ["spaceId": spaceId],
            token: token
        )
        activeSpace = .personal
        persistActiveSpace()
        await refreshSpaces()
    }

    // MARK: - Private

    private func persistActiveSpace() {
        UserDefaults.standard.set(activeSpace.id, forKey: Self.activeSpaceKey)
        UserDefaults.standard.set(activeSpace.name, forKey: Self.activeSpaceNameKey)
    }
}

enum SpaceError: LocalizedError {
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .unexpected(let msg): return msg
        }
    }
}
```

**Step 2: Verify it compiles (may have downstream errors, that's OK)**

Run: `cd /Users/txp/Pessoal/jack-v2 && swift build 2>&1 | head -50`

**Step 3: Commit**

```bash
git add Sources/JackApp/SpaceController.swift
git commit -m "refactor: SpaceController queries Convex spaces instead of Clerk orgs"
```

---

## Task 8: Update NoteListController — organizationId to spaceId

**Files:**
- Modify: `Sources/JackApp/Sync/NoteListController.swift`

**Step 1: Replace all organizationId references**

- `ConvexNote.organizationId` → `ConvexNote.spaceId`
- `fetchNotes(organizationId:)` → `fetchNotes(spaceId:)`
- `moveNote(noteId:, toOrganizationId:)` → `moveNote(noteId:, toSpaceId:)`
- Update Convex function arg keys from `"organizationId"` to `"spaceId"` and `"targetOrganizationId"` to `"targetSpaceId"`
- Remove `import ClerkKit`

**Step 2: Commit**

```bash
git add Sources/JackApp/Sync/NoteListController.swift
git commit -m "refactor: NoteListController uses spaceId instead of organizationId"
```

---

## Task 9: Update RecordingSyncService — organizationId to spaceId

**Files:**
- Modify: `Sources/JackApp/Sync/RecordingSyncService.swift`

**Step 1: Replace organizationId param**

- `uploadRecording(organizationId:, ...)` → `uploadRecording(spaceId:, ...)`
- Change `"organizationId": orgId` → `"spaceId": spaceId` in the mutation args

**Step 2: Commit**

```bash
git add Sources/JackApp/Sync/RecordingSyncService.swift
git commit -m "refactor: RecordingSyncService uses spaceId instead of organizationId"
```

---

## Task 10: Create UploadQueue — background upload with retry

**Files:**
- Create: `Sources/JackApp/Sync/UploadQueue.swift`

**Step 1: Implement UploadQueue**

Create `Sources/JackApp/Sync/UploadQueue.swift` with:

- `PendingUpload` struct (Codable): id, filePath, title, duration, spaceId, status, retryCount, createdAt
- `UploadStatus` enum: queued, uploading, failed, completed
- Persistence: save/load queue as JSON from `~/Library/Application Support/Jack/upload_queue.json`
- `enqueue(filePath:, title:, duration:, spaceId:)` — adds item, saves, starts processing
- `processQueue()` — iterates queued items, uploads via `ConvexHTTPClient`, deletes local file on success
- `retryFailed()` — resets failed items to queued
- Exponential backoff delays: [5, 30, 120, 600] seconds
- Max 5 retries before staying in failed state
- Posts `Notification.Name.recordingExported` after successful upload

The UploadQueue should NOT be `@MainActor` — it does network I/O. Use `@Observable` with `@MainActor` for the published properties only. Or simpler: make it `@MainActor @Observable` and do the actual upload in a `Task.detached`.

**Step 2: Commit**

```bash
git add Sources/JackApp/Sync/UploadQueue.swift
git commit -m "feat: add UploadQueue with background upload and retry"
```

---

## Task 11: Update ExportDialogView — export to temp + enqueue upload

**Files:**
- Modify: `Sources/JackApp/ScreenRecording/ExportDialogView.swift`

**Step 1: Change export output to temp directory**

- Change `generateOutputURL()` to use `~/Library/Caches/Jack/exports/` instead of `RecordingSessionController.exportDirectory`
- After export success, call `UploadQueue.shared.enqueue(...)` instead of `RecordingSpaceStore.assign()`
- Use `spaceController.currentSpaceId` instead of `spaceController.currentOrganizationId`
- Remove "Show in Finder" button from `doneContent`
- Change done content to say "Export complete. Uploading in background..."

**Step 2: Commit**

```bash
git add Sources/JackApp/ScreenRecording/ExportDialogView.swift
git commit -m "refactor: ExportDialogView exports to temp dir and enqueues cloud upload"
```

---

## Task 12: Rewrite RecordingsLibraryView — Convex-only, no local files

**Files:**
- Modify: `Sources/JackApp/RecordingsLibrary/RecordingsLibraryView.swift`

**Step 1: Rewrite to fetch from Convex**

Major changes:
- Replace `LocalRecordingItem` with `CloudRecordingItem` (id from Convex `_id`, title, duration, videoUrl, storageId)
- `loadRecordings()` → call `recordings:list` via `ConvexHTTPClient` with `spaceId`
- Remove local file scanning, `AVURLAsset` duration loading, local thumbnail generation
- Use `spaceController.currentSpaceId` instead of `currentOrganizationId`
- Show pending uploads from `UploadQueue.shared.pending` with syncing badge
- Remove "Show in Finder" from context menu
- "Share Link" uses existing `SharingController` (but adapted for cloud recordings — no re-upload needed since already in Convex, just call `enableSharing`)
- "Move to..." calls `recordings:moveToSpace` with `targetSpaceId`
- Delete calls `recordings:remove` mutation
- Remove all `RecordingSpaceStore` references

**Step 2: Commit**

```bash
git add Sources/JackApp/RecordingsLibrary/RecordingsLibraryView.swift
git commit -m "refactor: RecordingsLibraryView fetches from Convex, shows upload queue status"
```

---

## Task 13: Delete RecordingSpaceStore.swift

**Files:**
- Delete: `Sources/JackApp/RecordingsLibrary/RecordingSpaceStore.swift`

**Step 1: Delete the file**

```bash
git rm Sources/JackApp/RecordingsLibrary/RecordingSpaceStore.swift
```

**Step 2: Search for any remaining references**

Run: `grep -r "RecordingSpaceStore" Sources/`

Expected: No results (all references removed in previous tasks).

**Step 3: Commit**

```bash
git commit -m "chore: delete RecordingSpaceStore (replaced by cloud-first upload)"
```

---

## Task 14: Refactor CreateOrganizationView → CreateSpaceView

**Files:**
- Modify: `Sources/JackApp/Auth/Views/CreateOrganizationView.swift`

**Step 1: Rewrite to call Convex instead of Clerk API**

- Rename struct to `CreateSpaceView`
- Remove `import Security`
- Change `onCreated: (Organization) -> Void` to `onCreated: (Space) -> Void`
- `create()` method: call `spaceController.createSpace(name:)` instead of `createOrganizationViaAPI`
- Remove all Clerk Frontend API code: `createOrganizationViaAPI`, `readDeviceTokenFromKeychain`, `clerkFrontendAPIBaseURL`, `padBase64`, `urlEncode`
- Remove `CreateOrgError` enum
- Keep the color/icon picker UI unchanged
- On success: create `Space(id: spaceId, name: orgName, isPersonal: false)`, apply color/icon, call `onCreated`

**Step 2: Commit**

```bash
git add Sources/JackApp/Auth/Views/CreateOrganizationView.swift
git commit -m "refactor: CreateOrganizationView → CreateSpaceView, uses Convex spaces"
```

---

## Task 15: Refactor OrganizationSettingsView → SpaceMembersView

**Files:**
- Modify: `Sources/JackApp/Auth/Views/OrganizationSettingsView.swift`

**Step 1: Rewrite to use SpaceController for members/invitations**

- Rename struct to `SpaceMembersView`
- Change init param from `organization: Organization` to `spaceController: SpaceController`
- Remove `import ClerkKit`
- Remove role picker (flat membership — no roles beyond owner)
- `loadMembers()` → call `spaceController.fetchMembers(spaceId:)`
- `invite()` → call `spaceController.inviteToSpace(spaceId:, email:)`
- Display `SpaceController.SpaceMember` instead of `OrganizationMembership`
- Remove `memberDisplayName` and `initials` helpers that used `OrganizationMembership` — rewrite for `SpaceMember`

**Step 2: Commit**

```bash
git add Sources/JackApp/Auth/Views/OrganizationSettingsView.swift
git commit -m "refactor: OrganizationSettingsView → SpaceMembersView, uses Convex spaces"
```

---

## Task 16: Update SpaceSettingsSheet — remove Clerk org lookup

**Files:**
- Modify: `Sources/JackApp/SpaceSettingsSheet.swift`

**Step 1: Replace Clerk org member lookup with SpaceMembersView**

- Remove `import ClerkKit`
- Replace the block at lines 111-118 that looks up `Clerk.shared.user?.organizationMemberships` with:
  ```swift
  if !spaceController.activeSpace.isPersonal {
      Divider()
      SpaceMembersView(spaceController: spaceController)
  }
  ```

**Step 2: Commit**

```bash
git add Sources/JackApp/SpaceSettingsSheet.swift
git commit -m "refactor: SpaceSettingsSheet uses SpaceMembersView instead of Clerk orgs"
```

---

## Task 17: Update ContentView — wire up new space types

**Files:**
- Modify: `Sources/JackApp/ContentView.swift`

**Step 1: Update CreateSpace sheet**

Replace the `.sheet(isPresented: $showCreateSpace)` block (lines 126-135):
- Change `CreateOrganizationView` to `CreateSpaceView`
- Change `onCreated` closure from receiving `Organization` to `Space`
- Use `spaceController.switchSpace(to: newSpace)` (no longer async)

**Step 2: Update notes section**

Replace all `spaceController.currentOrganizationId` with `spaceController.currentSpaceId` in `notesSection` (lines 276, 311-314).

Replace note card context menu: change `note.organizationId` to `note.spaceId`, change `toOrganizationId:` to `toSpaceId:`.

**Step 3: Remove import if possible**

Check if `import ClerkKit` is still needed in ContentView. It's used for `Clerk.shared.user` in the sidebar. Keep it.

**Step 4: Commit**

```bash
git add Sources/JackApp/ContentView.swift
git commit -m "refactor: ContentView uses CreateSpaceView and spaceId throughout"
```

---

## Task 18: Update AuthGateView — remove Clerk org refresh

**Files:**
- Modify: `Sources/JackApp/Auth/Views/AuthGateView.swift`

**Step 1: Minor updates**

In `AuthenticatedRootView.body` `.task` modifier (line 238):
- Change `await spaceController.refreshSpaces()` — this already calls Convex now, so no code change needed here. But verify it doesn't reference any Clerk org APIs.
- `switchSpace(to:)` is no longer async, so change `await spaceController.switchSpace(to:)` if called anywhere.

Actually, looking at this file, the only reference is line 238 which calls `refreshSpaces()` — already updated in Task 7. No changes needed here unless `switchSpace` is called (it's not in this file).

**Step 2: Verify no Clerk org references remain**

Run: `grep -rn "organizationMemberships\|Organization\b\|org\.id\|org\.name\|setActiveOrganization\|getOrganizationMemberships" Sources/JackApp/`

Expected: No matches (except possibly `Organization` type references in files we haven't touched — those should be gone after Tasks 14-15).

**Step 3: Commit (if changes made)**

```bash
git add Sources/JackApp/Auth/Views/AuthGateView.swift
git commit -m "refactor: AuthGateView cleaned up for Convex-based spaces"
```

---

## Task 19: Full build and fix compile errors

**Files:**
- Various Swift files as needed

**Step 1: Build the project**

Run: `cd /Users/txp/Pessoal/jack-v2 && swift build 2>&1`

**Step 2: Fix any remaining compile errors**

Common issues to expect:
- `currentOrganizationId` → `currentSpaceId` missed references
- `RecordingSpaceStore` references not yet removed
- `Organization` type references from ClerkKit
- `switchSpace(to:)` was async, now sync — remove `await` where called

Fix each error, re-build, repeat until clean.

**Step 3: Commit**

```bash
git add -A
git commit -m "fix: resolve remaining compile errors from spaces refactor"
```

---

## Task 20: Deploy Convex and verify end-to-end

**Step 1: Push Convex changes**

Run: `cd /Users/txp/Pessoal/jack-v2 && npx convex dev --once`

Expected: All functions deploy successfully.

**Step 2: Run the app**

Build and run the app. Verify:
- Sign in works (Clerk auth unchanged)
- Personal space shows recordings and notes
- Can create a new space
- Can invite a member by email
- Recording export triggers background upload
- Recording appears in library after upload
- Notes section shows notes scoped to active space

**Step 3: Final commit**

```bash
git add -A
git commit -m "feat: cloud-first recordings and custom Convex spaces — complete refactor"
```
