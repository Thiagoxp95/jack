# Spaces + Shareable Recordings Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add spaces (personal + Clerk orgs) with sidebar switcher, shareable recording links via Convex HTTP, a recordings library window, and cross-space item movement.

**Architecture:** Personal space uses `organizationId: null` with userId-scoped queries. Team spaces use Clerk organization IDs. A new `SpaceController` manages active space state. Shareable recordings use Convex HTTP endpoints serving a static HTML video player. The recordings library is a separate macOS window with a grid layout.

**Tech Stack:** SwiftUI, Clerk iOS SDK (ClerkKit), Convex (backend + HTTP endpoints), ConvexMobile (Swift client)

---

## Task 1: Update Convex Schema — Add Share Fields to Recordings

**Files:**
- Modify: `convex/schema.ts:28-45`

**Step 1: Add shareToken and shareEnabled fields to recordings table**

In `convex/schema.ts`, update the `recordings` table definition:

```typescript
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
```

**Step 2: Deploy schema**

Run: `cd /Users/txp/Pessoal/jack-v2 && npx convex dev`
Expected: Schema pushed successfully with new fields and index.

**Step 3: Commit**

```bash
git add convex/schema.ts
git commit -m "feat(schema): add shareToken and shareEnabled to recordings table"
```

---

## Task 2: Update Convex Queries — Dual-Mode Space Queries

**Files:**
- Modify: `convex/notes.ts:4-16`
- Modify: `convex/recordings.ts:4-16`

**Step 1: Update notes:list to support personal space (null organizationId)**

Replace the `list` query in `convex/notes.ts`:

```typescript
export const list = query({
  args: { organizationId: v.optional(v.string()) },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    if (args.organizationId) {
      // Team space: filter by organizationId
      return await ctx.db
        .query("notes")
        .withIndex("by_org", (q) => q.eq("organizationId", args.organizationId))
        .order("desc")
        .collect();
    }

    // Personal space: filter by userId (organizationId is undefined)
    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) return [];

    return (await ctx.db
      .query("notes")
      .withIndex("by_org_user", (q) =>
        q.eq("organizationId", undefined).eq("userId", user._id)
      )
      .order("desc")
      .collect());
  },
});
```

**Step 2: Update notes:create to accept optional organizationId**

In `convex/notes.ts`, change `args.organizationId` from `v.string()` to `v.optional(v.string())`:

```typescript
export const create = mutation({
  args: {
    organizationId: v.optional(v.string()),
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
      organizationId: args.organizationId,
      userId: user._id,
      text: args.text,
      dayStamp: args.dayStamp,
      timestamp: args.timestamp,
    });
  },
});
```

**Step 3: Update recordings:list to support personal space**

Replace the `list` query in `convex/recordings.ts`:

```typescript
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

    return (await ctx.db
      .query("recordings")
      .withIndex("by_org_user", (q) =>
        q.eq("organizationId", undefined).eq("userId", user._id)
      )
      .order("desc")
      .collect());
  },
});
```

**Step 4: Update recordings:create to accept optional organizationId**

In `convex/recordings.ts`, change the `organizationId` arg to `v.optional(v.string())`:

```typescript
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
```

**Step 5: Commit**

```bash
git add convex/notes.ts convex/recordings.ts
git commit -m "feat(convex): update notes and recordings queries for personal space support"
```

---

## Task 3: Add Sharing + Move Mutations to Convex

**Files:**
- Modify: `convex/recordings.ts` (append)
- Modify: `convex/notes.ts` (append)

**Step 1: Add sharing mutations to recordings.ts**

Append to `convex/recordings.ts`:

```typescript
export const enableSharing = mutation({
  args: { recordingId: v.id("recordings") },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const recording = await ctx.db.get(args.recordingId);
    if (!recording) throw new Error("Recording not found");

    // If already has a token, just enable
    if (recording.shareToken) {
      await ctx.db.patch(args.recordingId, { shareEnabled: true });
      return recording.shareToken;
    }

    // Generate a random share token
    const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
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
    await ctx.db.patch(args.recordingId, { shareEnabled: false });
  },
});

export const getByShareToken = query({
  args: { shareToken: v.string() },
  handler: async (ctx, args) => {
    const recording = await ctx.db
      .query("recordings")
      .withIndex("by_share_token", (q) => q.eq("shareToken", args.shareToken))
      .unique();

    if (!recording || !recording.shareEnabled) return null;

    const videoUrl = recording.storageId
      ? await ctx.storage.getUrl(recording.storageId)
      : null;

    return {
      title: recording.title ?? "Untitled Recording",
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

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found");

    const recording = await ctx.db.get(args.recordingId);
    if (!recording) throw new Error("Recording not found");
    if (recording.userId?.toString() !== user._id.toString()) {
      throw new Error("Not authorized to move this recording");
    }

    await ctx.db.patch(args.recordingId, {
      organizationId: args.targetOrganizationId,
    });
  },
});
```

**Step 2: Add moveToSpace mutation to notes.ts**

Append to `convex/notes.ts`:

```typescript
export const moveToSpace = mutation({
  args: {
    noteId: v.id("notes"),
    targetOrganizationId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_clerkId", (q) => q.eq("clerkId", identity.subject))
      .unique();
    if (!user) throw new Error("User not found");

    const note = await ctx.db.get(args.noteId);
    if (!note) throw new Error("Note not found");
    if (note.userId?.toString() !== user._id.toString()) {
      throw new Error("Not authorized to move this note");
    }

    await ctx.db.patch(args.noteId, {
      organizationId: args.targetOrganizationId,
    });
  },
});
```

**Step 3: Commit**

```bash
git add convex/recordings.ts convex/notes.ts
git commit -m "feat(convex): add sharing mutations and moveToSpace for recordings and notes"
```

---

## Task 4: Create Convex HTTP Endpoint for Shared Recordings

**Files:**
- Create: `convex/http.ts`

**Step 1: Create the HTTP routes file**

Create `convex/http.ts`:

```typescript
import { httpRouter } from "convex/server";
import { httpAction } from "./_generated/server";
import { api } from "./_generated/api";

const http = httpRouter();

http.route({
  path: "/share/{token}",
  method: "GET",
  handler: httpAction(async (ctx, request) => {
    const url = new URL(request.url);
    const token = url.pathname.split("/share/")[1];
    if (!token) {
      return new Response("Not found", { status: 404 });
    }

    const recording = await ctx.runQuery(api.recordings.getByShareToken, {
      shareToken: token,
    });

    if (!recording || !recording.videoUrl) {
      return new Response(notFoundPage(), {
        status: 404,
        headers: { "Content-Type": "text/html" },
      });
    }

    const html = playerPage(
      recording.title,
      recording.videoUrl,
      recording.duration
    );

    return new Response(html, {
      status: 200,
      headers: { "Content-Type": "text/html" },
    });
  }),
});

function formatDuration(seconds: number): string {
  const mins = Math.floor(seconds / 60);
  const secs = Math.floor(seconds % 60);
  return `${mins}:${secs.toString().padStart(2, "0")}`;
}

function playerPage(title: string, videoUrl: string, duration: number): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${escapeHtml(title)} - Jack</title>
  <meta property="og:title" content="${escapeHtml(title)}">
  <meta property="og:type" content="video.other">
  <meta property="og:video" content="${escapeHtml(videoUrl)}">
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: #0a0a0a;
      color: #fff;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      padding: 20px;
    }
    .container {
      max-width: 960px;
      width: 100%;
    }
    video {
      width: 100%;
      border-radius: 12px;
      background: #111;
    }
    .info {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-top: 16px;
      padding: 0 4px;
    }
    .title {
      font-size: 18px;
      font-weight: 600;
    }
    .meta {
      color: #888;
      font-size: 14px;
    }
    .actions { margin-top: 12px; display: flex; gap: 8px; }
    .btn {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 8px 16px;
      border-radius: 8px;
      border: 1px solid #333;
      background: #1a1a1a;
      color: #fff;
      font-size: 14px;
      cursor: pointer;
      text-decoration: none;
      transition: background 0.2s;
    }
    .btn:hover { background: #2a2a2a; }
    .brand {
      margin-top: 32px;
      color: #555;
      font-size: 12px;
    }
    .brand a { color: #888; text-decoration: none; }
  </style>
</head>
<body>
  <div class="container">
    <video controls autoplay playsinline>
      <source src="${escapeHtml(videoUrl)}" type="video/mp4">
      Your browser does not support the video tag.
    </video>
    <div class="info">
      <span class="title">${escapeHtml(title)}</span>
      <span class="meta">${formatDuration(duration)}</span>
    </div>
    <div class="actions">
      <a class="btn" href="${escapeHtml(videoUrl)}" download>
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">
          <path d="M8 2v9M4 8l4 4 4-4M2 14h12"/>
        </svg>
        Download
      </a>
    </div>
    <p class="brand">Shared via <a href="https://jack.com">Jack</a></p>
  </div>
</body>
</html>`;
}

function notFoundPage(): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Recording Not Found - Jack</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: #0a0a0a;
      color: #fff;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .container { text-align: center; }
    h1 { font-size: 24px; margin-bottom: 8px; }
    p { color: #888; }
  </style>
</head>
<body>
  <div class="container">
    <h1>Recording Not Found</h1>
    <p>This recording may have been removed or sharing was disabled.</p>
  </div>
</body>
</html>`;
}

function escapeHtml(str: string): string {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export default http;
```

**Step 2: Deploy and verify**

Run: `npx convex dev`
Expected: HTTP routes deployed. Test by visiting `https://<deployment>.convex.site/share/nonexistent` — should show 404 page.

**Step 3: Commit**

```bash
git add convex/http.ts
git commit -m "feat(convex): add HTTP endpoint for shareable recording player page"
```

---

## Task 5: Create SpaceController (Swift)

**Files:**
- Create: `Sources/JackApp/SpaceController.swift`

**Step 1: Create the SpaceController**

```swift
import ClerkKit
import Foundation

struct Space: Identifiable, Hashable {
    let id: String
    let name: String
    let isPersonal: Bool

    static let personal = Space(id: "personal", name: "Pessoal", isPersonal: true)
}

@MainActor @Observable
final class SpaceController {
    private(set) var activeSpace: Space = .personal
    private(set) var availableSpaces: [Space] = [.personal]

    /// Refresh the list of available spaces from Clerk memberships.
    func refreshSpaces() {
        var spaces: [Space] = [.personal]
        if let memberships = Clerk.shared.user?.organizationMemberships {
            for membership in memberships {
                let org = membership.organization
                spaces.append(Space(id: org.id, name: org.name, isPersonal: false))
            }
        }
        availableSpaces = spaces
    }

    /// Switch to a different space.
    func switchSpace(to space: Space) async {
        activeSpace = space

        if !space.isPersonal {
            // Set the Clerk active organization
            guard let sessionId = Clerk.shared.session?.id else { return }
            try? await Clerk.shared.auth.setActive(
                sessionId: sessionId,
                organizationId: space.id
            )
        }
    }

    /// The organizationId to pass to Convex queries.
    /// Returns nil for personal space, org ID for team spaces.
    var currentOrganizationId: String? {
        activeSpace.isPersonal ? nil : activeSpace.id
    }
}
```

**Step 2: Commit**

```bash
git add Sources/JackApp/SpaceController.swift
git commit -m "feat: add SpaceController for managing spaces (personal + Clerk orgs)"
```

---

## Task 6: Simplify Auth Flow — Remove Mandatory Org Picker

**Files:**
- Modify: `Sources/JackApp/Auth/Views/AuthGateView.swift:24-39`

**Step 1: Remove the organization membership gate**

In `AuthGateView.swift`, replace the body's `Group` content (lines 25-38) with:

```swift
Group {
    if !clerk.isLoaded {
        loadingView
    } else if clerk.session == nil {
        SignInView(onSignedIn: {
            initializeConvexIfNeeded()
        })
    } else {
        AuthenticatedRootView(authController: authController)
    }
}
```

This removes the `OrganizationPickerView` gate entirely. Users go straight to the app after sign-in.

**Step 2: Commit**

```bash
git add Sources/JackApp/Auth/Views/AuthGateView.swift
git commit -m "feat(auth): remove mandatory org picker, go directly to app after sign-in"
```

---

## Task 7: Add Space Selector to Sidebar

**Files:**
- Modify: `Sources/JackApp/Auth/Views/AuthGateView.swift` (pass SpaceController)
- Modify: `Sources/JackApp/ContentView.swift`

**Step 1: Create SpaceController in AuthGateView and pass it through**

In `AuthGateView.swift`, add a `@State` property:

```swift
@State private var spaceController = SpaceController()
```

Update the `AuthenticatedRootView` usage to pass it:

```swift
AuthenticatedRootView(authController: authController, spaceController: spaceController)
```

Update `AuthenticatedRootView` to accept and pass `spaceController`:

```swift
private struct AuthenticatedRootView: View {
    let authController: AuthController
    let spaceController: SpaceController

    @StateObject private var controller = DictationController()
    @State private var recordingController = RecordingSessionController()

    var body: some View {
        ContentView(
            controller: controller,
            recordingController: recordingController,
            spaceController: spaceController
        )
        .frame(minWidth: 640, minHeight: 460)
        .task {
            await controller.initialize()
            await recordingController.initialize()
            spaceController.refreshSpaces()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            controller.applicationWillTerminate()
        }
    }
}
```

**Step 2: Add space selector to ContentView sidebar**

In `ContentView.swift`, add the `spaceController` parameter:

```swift
struct ContentView: View {
    @ObservedObject var controller: DictationController
    @Bindable var recordingController: RecordingSessionController
    var spaceController: SpaceController
    // ... existing @State properties
```

Add a space picker at the top of the sidebar, above the `List`:

```swift
NavigationSplitView {
    VStack(spacing: 0) {
        // Space selector
        Menu {
            ForEach(spaceController.availableSpaces) { space in
                Button {
                    Task { await spaceController.switchSpace(to: space) }
                } label: {
                    Label(
                        space.name,
                        systemImage: space.isPersonal ? "person.fill" : "building.2.fill"
                    )
                }
            }
            Divider()
            Button {
                // Show create space sheet
            } label: {
                Label("Create Space", systemImage: "plus")
            }
        } label: {
            HStack {
                Image(systemName: spaceController.activeSpace.isPersonal ? "person.fill" : "building.2.fill")
                    .foregroundStyle(.secondary)
                Text(spaceController.activeSpace.name)
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)

        Divider()

        // Existing list
        List(SettingsSection.allCases, selection: $selectedSection) { section in
            Label(section.title, systemImage: section.systemImage)
                .tag(section)
        }
        .listStyle(.sidebar)
    }
    .navigationTitle("Jack")
    // ... existing safeAreaInset
```

**Step 3: Rename "Organization" sidebar section to "Space Settings"**

In the `SettingsSection` enum, rename:
- `case organization` → `case spaceSettings`
- Title: `"Space Settings"`
- Subtitle: `"Manage your space, members, and invitations."`
- System image: keep `"building.2"`

**Step 4: Commit**

```bash
git add Sources/JackApp/Auth/Views/AuthGateView.swift Sources/JackApp/ContentView.swift
git commit -m "feat(ui): add space selector to sidebar, pass SpaceController through view hierarchy"
```

---

## Task 8: Update Sync Services for Optional organizationId

**Files:**
- Modify: `Sources/JackApp/Sync/NoteSyncService.swift:13-25`
- Modify: `Sources/JackApp/Sync/RecordingSyncService.swift:15-45`

**Step 1: Make organizationId optional in NoteSyncService**

```swift
func uploadNote(
    organizationId: String?,
    text: String,
    dayStamp: String,
    timestamp: String
) async throws {
    var args: [String: ConvexEncodable] = [
        "text": text,
        "dayStamp": dayStamp,
        "timestamp": timestamp,
    ]
    if let orgId = organizationId {
        args["organizationId"] = orgId
    }
    try await client.mutation("notes:create", with: args)
}
```

**Step 2: Make organizationId optional in RecordingSyncService**

```swift
func uploadRecording(
    organizationId: String?,
    title: String,
    duration: Double,
    videoFileURL: URL
) async throws {
    // 1. Obtain upload URL
    let uploadUrl: String = try await client.mutation(
        "storage:generateUploadUrl",
        with: [:]
    )

    // 2. Upload video data
    let videoData = try Data(contentsOf: videoFileURL)
    var request = URLRequest(url: URL(string: uploadUrl)!)
    request.httpMethod = "POST"
    request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
    request.httpBody = videoData
    let (_, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
          httpResponse.statusCode == 200 else {
        throw RecordingSyncError.uploadFailed
    }

    // 3. Create metadata
    var args: [String: ConvexEncodable] = [
        "title": title,
        "duration": duration,
    ]
    if let orgId = organizationId {
        args["organizationId"] = orgId
    }
    try await client.mutation("recordings:create", with: args)
}
```

**Step 3: Commit**

```bash
git add Sources/JackApp/Sync/NoteSyncService.swift Sources/JackApp/Sync/RecordingSyncService.swift
git commit -m "feat(sync): make organizationId optional in sync services for personal space"
```

---

## Task 9: Create Recordings Library Window

**Files:**
- Create: `Sources/JackApp/RecordingsLibrary/RecordingsLibraryView.swift`
- Create: `Sources/JackApp/RecordingsLibrary/RecordingsLibraryWindowController.swift`
- Modify: `Sources/JackApp/ContentView.swift` (add "Open Recordings" button)

**Step 1: Create RecordingsLibraryView**

```swift
import SwiftUI

struct RecordingsLibraryView: View {
    let spaceController: SpaceController
    let authController: AuthController

    @State private var recordings: [RecordingItem] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .dateDesc

    enum SortOrder: String, CaseIterable {
        case dateDesc = "Newest"
        case dateAsc = "Oldest"
        case nameAsc = "Name A-Z"
    }

    var filteredRecordings: [RecordingItem] {
        var items = recordings
        if !searchText.isEmpty {
            items = items.filter {
                ($0.title ?? "").localizedCaseInsensitiveContains(searchText)
            }
        }
        switch sortOrder {
        case .dateDesc:
            items.sort { ($0.creationTime ?? 0) > ($1.creationTime ?? 0) }
        case .dateAsc:
            items.sort { ($0.creationTime ?? 0) < ($1.creationTime ?? 0) }
        case .nameAsc:
            items.sort { ($0.title ?? "") < ($1.title ?? "") }
        }
        return items
    }

    private let columns = [
        GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 16)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Recordings")
                    .font(.title2.bold())
                Text("(\(spaceController.activeSpace.name))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Sort", selection: $sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
            .padding(16)

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search recordings...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
            .padding(.horizontal, 16)

            Divider().padding(.top, 12)

            // Grid
            if isLoading {
                Spacer()
                ProgressView("Loading recordings...")
                Spacer()
            } else if filteredRecordings.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No recordings yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filteredRecordings) { recording in
                            RecordingCard(
                                recording: recording,
                                spaces: spaceController.availableSpaces,
                                onShare: { shareRecording(recording) },
                                onDelete: { deleteRecording(recording) },
                                onMove: { space in moveRecording(recording, to: space) }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .task { await loadRecordings() }
        .onChange(of: spaceController.activeSpace) { _, _ in
            Task { await loadRecordings() }
        }
    }

    private func loadRecordings() async {
        guard let client = authController.convexClient else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            var args: [String: ConvexEncodable] = [:]
            if let orgId = spaceController.currentOrganizationId {
                args["organizationId"] = orgId
            }
            recordings = try await client.query("recordings:list", with: args)
        } catch {
            NSLog("[RecordingsLibrary] Failed to load: \(error)")
        }
    }

    private func shareRecording(_ recording: RecordingItem) {
        guard let client = authController.convexClient else { return }
        Task {
            do {
                let token: String = try await client.mutation(
                    "recordings:enableSharing",
                    with: ["recordingId": recording.id]
                )
                let shareUrl = "\(AppConfig.convexSiteUrl)/share/\(token)"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(shareUrl, forType: .string)
            } catch {
                NSLog("[RecordingsLibrary] Share failed: \(error)")
            }
        }
    }

    private func deleteRecording(_ recording: RecordingItem) {
        guard let client = authController.convexClient else { return }
        Task {
            try? await client.mutation(
                "recordings:remove",
                with: ["recordingId": recording.id]
            )
            await loadRecordings()
        }
    }

    private func moveRecording(_ recording: RecordingItem, to space: Space) {
        guard let client = authController.convexClient else { return }
        Task {
            var args: [String: ConvexEncodable] = ["recordingId": recording.id]
            if !space.isPersonal {
                args["targetOrganizationId"] = space.id
            }
            try? await client.mutation("recordings:moveToSpace", with: args)
            await loadRecordings()
        }
    }
}

struct RecordingCard: View {
    let recording: RecordingItem
    let spaces: [Space]
    let onShare: () -> Void
    let onDelete: () -> Void
    let onMove: (Space) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Thumbnail placeholder
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .aspectRatio(16/9, contentMode: .fit)
                .overlay {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(recording.title ?? "Untitled")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                Text(formatDuration(recording.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contextMenu {
            Button("Share Link") { onShare() }
            Divider()
            Menu("Move to...") {
                ForEach(spaces) { space in
                    Button(space.name) { onMove(space) }
                }
            }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

struct RecordingItem: Identifiable, Decodable {
    let id: String
    let title: String?
    let duration: Double
    let creationTime: Double?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case title
        case duration
        case creationTime = "_creationTime"
    }
}
```

Note: The `RecordingItem` Decodable struct may need adjustment depending on how ConvexMobile returns query results. Check the ConvexMobile docs for exact decoding patterns.

**Step 2: Create RecordingsLibraryWindowController**

```swift
import AppKit
import SwiftUI

@MainActor
final class RecordingsLibraryWindowController {
    private var window: NSWindow?

    func show(spaceController: SpaceController, authController: AuthController) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = RecordingsLibraryView(
            spaceController: spaceController,
            authController: authController
        )

        let hostingController = NSHostingController(rootView: view)
        let newWindow = NSWindow(contentViewController: hostingController)
        newWindow.title = "Recordings Library"
        newWindow.setContentSize(NSSize(width: 800, height: 600))
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        window = newWindow
    }
}
```

**Step 3: Add "Open Recordings" button to ContentView sidebar**

In `ContentView.swift`, in the `safeAreaInset(edge: .bottom)` section, add a button before "Open Setup Wizard":

```swift
Button {
    recordingsWindow.show(
        spaceController: spaceController,
        authController: authController
    )
} label: {
    Label("Recordings Library", systemImage: "square.grid.2x2")
        .frame(maxWidth: .infinity, alignment: .leading)
}
.buttonStyle(.bordered)
```

Add the state property to ContentView:

```swift
@State private var recordingsWindow = RecordingsLibraryWindowController()
```

You'll also need to pass `authController` through to ContentView (add it as a parameter, pass from AuthenticatedRootView).

**Step 4: Commit**

```bash
git add Sources/JackApp/RecordingsLibrary/
git add Sources/JackApp/ContentView.swift
git commit -m "feat: add recordings library window with grid view, share, move, and delete"
```

---

## Task 10: Add convexSiteUrl to AppConfig

**Files:**
- Modify: `Sources/JackApp/Auth/AppConfig.swift`

**Step 1: Add site URL for share links**

```swift
enum AppConfig {
    #if DEBUG
    static let clerkPublishableKey = "pk_test_YW1wbGUtbWluay04MC5jbGVyay5hY2NvdW50cy5kZXYk"
    static let convexDeploymentUrl = "https://cheery-gull-259.convex.cloud"
    static let convexSiteUrl = "https://cheery-gull-259.convex.site"
    #else
    static let clerkPublishableKey = "pk_live_Y2xlcmsuYWN0aW9uZnkuY29tJA"
    static let convexDeploymentUrl = "https://judicious-pony-481.convex.cloud"
    static let convexSiteUrl = "https://judicious-pony-481.convex.site"
    #endif
}
```

**Step 2: Commit**

```bash
git add Sources/JackApp/Auth/AppConfig.swift
git commit -m "feat(config): add convexSiteUrl for shareable recording links"
```

---

## Task 11: Wire Up Create Space from Sidebar

**Files:**
- Modify: `Sources/JackApp/ContentView.swift` (add sheet for CreateOrganizationView)

**Step 1: Add create space sheet**

Add state to ContentView:

```swift
@State private var showCreateSpace = false
```

In the space selector `Menu`, update the "Create Space" button:

```swift
Button {
    showCreateSpace = true
} label: {
    Label("Create Space", systemImage: "plus")
}
```

Add the sheet to the NavigationSplitView:

```swift
.sheet(isPresented: $showCreateSpace) {
    CreateOrganizationView { org in
        showCreateSpace = false
        spaceController.refreshSpaces()
        Task {
            let newSpace = Space(id: org.id, name: org.name, isPersonal: false)
            await spaceController.switchSpace(to: newSpace)
        }
    }
}
```

**Step 2: Commit**

```bash
git add Sources/JackApp/ContentView.swift
git commit -m "feat(ui): wire up Create Space from sidebar space selector"
```

---

## Task 12: Add Right-Click "Move to..." on Notes

**Files:**
- Modify: `Sources/JackApp/ContentView.swift` (noteCard function)

**Step 1: Add context menu to noteCard**

Update the `noteCard` function to accept spaceController and authController, and add a context menu:

```swift
private func noteCard(_ note: VoiceNote) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        // ... existing content
    }
    .padding(14)
    .background(/* existing */)
    .overlay(/* existing */)
    .contextMenu {
        Menu("Move to...") {
            ForEach(spaceController.availableSpaces) { space in
                Button(space.name) {
                    moveNote(note, to: space)
                }
            }
        }
    }
}

private func moveNote(_ note: VoiceNote, to space: Space) {
    guard let client = authController.convexClient else { return }
    Task {
        var args: [String: ConvexEncodable] = ["noteId": note.convexId]
        if !space.isPersonal {
            args["targetOrganizationId"] = space.id
        }
        try? await client.mutation("notes:moveToSpace", with: args)
    }
}
```

Note: This requires the `VoiceNote` model to include its Convex document ID. If it doesn't already have this field, you'll need to add it when loading notes from Convex.

**Step 2: Commit**

```bash
git add Sources/JackApp/ContentView.swift
git commit -m "feat(notes): add right-click 'Move to...' context menu for notes"
```

---

## Summary of All Tasks

| # | Task | Files | Scope |
|---|------|-------|-------|
| 1 | Update schema (share fields) | `convex/schema.ts` | Backend |
| 2 | Dual-mode space queries | `convex/notes.ts`, `convex/recordings.ts` | Backend |
| 3 | Sharing + move mutations | `convex/recordings.ts`, `convex/notes.ts` | Backend |
| 4 | HTTP endpoint for share page | `convex/http.ts` (new) | Backend |
| 5 | SpaceController | `SpaceController.swift` (new) | Swift |
| 6 | Remove org picker gate | `AuthGateView.swift` | Swift |
| 7 | Sidebar space selector | `AuthGateView.swift`, `ContentView.swift` | Swift |
| 8 | Optional orgId in sync services | `NoteSyncService.swift`, `RecordingSyncService.swift` | Swift |
| 9 | Recordings library window | New `RecordingsLibrary/` dir, `ContentView.swift` | Swift |
| 10 | Add convexSiteUrl config | `AppConfig.swift` | Swift |
| 11 | Wire up Create Space | `ContentView.swift` | Swift |
| 12 | Note move context menu | `ContentView.swift` | Swift |

**Recommended execution order:** Tasks 1-4 (backend) first, then 5-12 (Swift). Tasks 1-4 can be done in sequence. Tasks 5-6 are independent. Tasks 7-12 depend on Task 5.
