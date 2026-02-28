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
  }).index("by_owner", ["ownerId"]),

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
      v.literal("declined"),
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
    // Legacy fields from pre-auth recordings
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

  todoLists: defineTable({
    spaceId: v.optional(v.id("spaces")),
    userId: v.id("users"),
    name: v.string(),
    color: v.optional(v.string()),
    sortOrder: v.optional(v.number()),
    createdAt: v.number(),
  })
    .index("by_space", ["spaceId"])
    .index("by_space_user", ["spaceId", "userId"]),

  todos: defineTable({
    spaceId: v.optional(v.id("spaces")),
    userId: v.id("users"),
    title: v.string(),
    description: v.optional(v.string()),
    status: v.union(v.literal("todo"), v.literal("in_progress"), v.literal("done")),
    priority: v.union(v.literal("none"), v.literal("low"), v.literal("medium"), v.literal("high")),
    listId: v.optional(v.id("todoLists")),
    tags: v.optional(v.array(v.string())),
    dueDate: v.optional(v.string()),
    dueTime: v.optional(v.string()),
    reminders: v.optional(v.array(v.object({
      at: v.number(),
      scheduledFunctionId: v.optional(v.id("_scheduled_functions")),
      delivered: v.optional(v.boolean()),
    }))),
    completedAt: v.optional(v.number()),
    rawTranscription: v.optional(v.string()),
    createdAt: v.number(),
  })
    .index("by_space", ["spaceId"])
    .index("by_space_user", ["spaceId", "userId"])
    .index("by_list", ["listId"])
    .index("by_status", ["status"]),

  chatThreads: defineTable({
    spaceId: v.optional(v.id("spaces")),
    userId: v.id("users"),
    title: v.string(),
    model: v.string(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_space", ["spaceId"])
    .index("by_space_user", ["spaceId", "userId"]),

  chatMessages: defineTable({
    threadId: v.id("chatThreads"),
    role: v.union(v.literal("user"), v.literal("assistant")),
    content: v.string(),
    model: v.optional(v.string()),
    createdAt: v.number(),
  }).index("by_thread", ["threadId"]),
});
