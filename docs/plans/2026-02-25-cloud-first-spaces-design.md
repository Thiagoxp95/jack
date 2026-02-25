# Cloud-First Recordings + Custom Spaces Design

**Date:** 2026-02-25
**Status:** Approved

## Goals

1. Recordings always upload to Convex cloud immediately after export (no local-only option)
2. All space members see recordings and notes in real-time
3. Replace Clerk organizations with custom `spaces` tables in Convex
4. Keep Clerk for authentication only (sign-in, JWT tokens, user identity)

## Decisions

- **Space membership:** Invite-by-email
- **Upload behavior:** Silent background upload with retry on failure
- **Local files:** Deleted after confirmed cloud upload
- **Space creation:** Any authenticated user, no limits
- **Role model:** Flat - all members equal; only space creator manages members and deletes space
- **Personal space:** No table row; `spaceId = nil/undefined` means personal

---

## Data Model

### New: `spaces`

```
spaces {
  name: string
  ownerId: Id<"users">
  createdAt: number
}
  index("by_owner", ["ownerId"])
```

### New: `space_members`

```
space_members {
  spaceId: Id<"spaces">
  userId: Id<"users">
  role: "owner" | "member"
  joinedAt: number
}
  index("by_space", ["spaceId"])
  index("by_user", ["userId"])
  index("by_space_user", ["spaceId", "userId"])
```

### New: `space_invitations`

```
space_invitations {
  spaceId: Id<"spaces">
  invitedByUserId: Id<"users">
  email: string
  status: "pending" | "accepted" | "declined"
  createdAt: number
}
  index("by_space", ["spaceId"])
  index("by_email", ["email"])
```

### Modified: `recordings`

Replace `organizationId` with `spaceId`:

```
recordings {
  spaceId: v.optional(v.id("spaces"))  // nil = personal
  userId: v.optional(v.id("users"))
  title, duration, storageId, thumbnailStorageId, shareToken, shareEnabled, ...
}
  index("by_space", ["spaceId"])
  index("by_space_user", ["spaceId", "userId"])
  index("by_share_token", ["shareToken"])
```

### Modified: `notes`

Same pattern - replace `organizationId` with `spaceId`.

---

## Convex Functions

### New: `spaces.ts`

- `create(name)` - Create space, add creator as owner in space_members
- `list()` - All spaces where current user is a member
- `get(spaceId)` - Single space (must be member)
- `update(spaceId, name)` - Rename (owner only)
- `remove(spaceId)` - Cascade delete recordings/notes/members/invitations (owner only)
- `invite(spaceId, email)` - Create invitation; auto-accept if invitee has account
- `acceptInvitation(invitationId)` - Accept and create space_members entry
- `declineInvitation(invitationId)` - Mark declined
- `pendingInvitations()` - Invitations for current user's email
- `removeMember(spaceId, userId)` - Owner removes member
- `leaveSpace(spaceId)` - Member leaves (owner cannot)
- `members(spaceId)` - List members with user info

### Modified: `recordings.ts`

- All functions: `organizationId` -> `spaceId`
- `list(spaceId?)` - Verify membership if spaceId provided
- `create(..., spaceId?)` - Same replacement
- `moveToSpace(recordingId, targetSpaceId?)` - Verify target membership
- Remove `deleteByOrganization` (cascade handled by `spaces:remove`)

### Modified: `notes.ts`

Same as recordings.

### Modified: `users.ts`

- `syncUser()` - After upsert, auto-accept pending invitations matching user's email

---

## Swift Changes

### SpaceController

- Remove all Clerk organization API calls
- `loadSpaces()` -> query `spaces:list` via ConvexHTTPClient
- `createSpace(name:)` -> call `spaces:create`
- `deleteSpace(spaceId:)` -> call `spaces:remove`
- `switchSpace(to:)` -> update UserDefaults only (no Clerk session switch)
- Keep local colors/icons in UserDefaults
- Add invitation methods: invite, fetchPending, accept, decline

### AuthController

- Remove `currentOrganization`, `organizations`, `setActiveOrganization()`
- Keep Clerk sign-in/sign-out and Convex client init unchanged

### Delete: RecordingSpaceStore.swift

No longer needed - space assignment happens at upload time.

### ExportDialogView

- Export to temp dir (`~/Library/Caches/Actionfy/exports/`)
- On success, enqueue upload via UploadQueue
- Remove "Show in Finder" option

### New: UploadQueue.swift

Background upload queue:

```swift
@Observable
final class UploadQueue {
    struct PendingUpload: Codable {
        let id: UUID
        let filePath: String
        let title: String
        let duration: Double
        let spaceId: String?
        var status: Status  // queued | uploading | failed(retryCount)
        var createdAt: Date
    }

    func enqueue(filePath:, title:, duration:, spaceId:)
    func processQueue()
}
```

- Retry: exponential backoff (5s, 30s, 2min, 10min), max 5 retries
- Persisted to disk (JSON in Application Support)
- Processes on app launch and after each enqueue
- Deletes local file after successful upload

### RecordingsLibraryView

- Show only Convex recordings (via `recordings:list(spaceId:)`)
- Show pending uploads from UploadQueue with "syncing" indicator
- Remove local file scanning

### Other files

- `RecordingSyncService.swift` - Use `spaceId` instead of `organizationId`
- `NoteListController.swift` - Same replacement
- `CreateOrganizationView.swift` -> `CreateSpaceView.swift`
- `OrganizationSettingsView.swift` -> `SpaceSettingsView.swift`
- `ContentView.swift` - Remove Clerk org references
- `RecordingsLibraryWindowController.swift` - Pass spaceId

### Unchanged

- ExportService.swift (video rendering)
- RecordingSessionController.swift (capture pipeline)
- ClerkAuthProvider.swift (auth)
- SignInView.swift
- ConvexHTTPClient.swift
- DictationController, FloatingBubbleController, GlobalFnShortcutMonitor
