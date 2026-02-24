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

  notes: defineTable({
    organizationId: v.optional(v.string()),
    userId: v.optional(v.id("users")),
    text: v.string(),
    dayStamp: v.string(),
    timestamp: v.string(),
  })
    .index("by_org", ["organizationId"])
    .index("by_org_user", ["organizationId", "userId"]),

  recordings: defineTable({
    organizationId: v.optional(v.string()),
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
    .index("by_org", ["organizationId"])
    .index("by_org_user", ["organizationId", "userId"])
    .index("by_share_token", ["shareToken"]),
});
