import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
  users: defineTable({
    clerkId: v.string(),
    email: v.string(),
    firstName: v.optional(v.string()),
    lastName: v.optional(v.string()),
    imageUrl: v.optional(v.string()),
  })
    .index("by_clerkId", ["clerkId"])
    .index("by_email", ["email"]),

  notes: defineTable({
    organizationId: v.string(),
    userId: v.id("users"),
    text: v.string(),
    dayStamp: v.string(),
    timestamp: v.string(),
  })
    .index("by_org", ["organizationId"])
    .index("by_org_user", ["organizationId", "userId"]),

  recordings: defineTable({
    organizationId: v.string(),
    userId: v.id("users"),
    title: v.string(),
    duration: v.number(),
    storageId: v.optional(v.id("_storage")),
    thumbnailStorageId: v.optional(v.id("_storage")),
  })
    .index("by_org", ["organizationId"])
    .index("by_org_user", ["organizationId", "userId"]),
});
