# Spaces + Shareable Recordings Design

**Date:** 2026-02-23
**Status:** Approved

## Overview

Add "Spaces" concept (personal + team), auto-default to personal space on login, shareable recording links, a recordings library window, and cross-space item movement.

## Decisions

- **Spaces**: UI concept. Personal space = `organizationId: null` (userId-scoped). Team spaces = Clerk organizations.
- **Default space**: "Pessoal" personal space, always first. No mandatory org picker on login.
- **Share page**: Convex HTTP endpoint + static HTML video player.
- **Naming**: "Spaces" in all UI (not "organizations" or "workspaces").
- **Data isolation**: Strictly per-space. Moving items is explicit.
- **Recordings library**: Separate macOS window with grid layout.
- **Move UX**: Right-click context menu → "Move to..." → space submenu.

## 1. Data Model

### Schema Changes (convex/schema.ts)

**recordings table** — add:
- `shareToken: v.optional(v.string())` — random token for public access
- `shareEnabled: v.optional(v.boolean())` — toggle sharing
- New index: `by_share_token: ["shareToken"]`

No changes needed to notes table.

### Data Routing

| Context | organizationId | Query filter |
|---------|---------------|-------------|
| Personal space | `null` | `userId = currentUser` |
| Team space | Clerk org ID | `organizationId = orgId` |

## 2. Space Selector

### SpaceController (@Observable)

```swift
struct Space: Identifiable {
    let id: String        // "personal" or Clerk org ID
    let name: String      // "Pessoal" or org name
    let isPersonal: Bool
}

@Observable class SpaceController {
    var activeSpace: Space
    var availableSpaces: [Space]
    func switchSpace(to space: Space)
}
```

### Sidebar UI

- Dropdown at top of sidebar
- "Pessoal" always first (person icon)
- Clerk orgs below (org icon)
- "+ Create Space" at bottom

### Switch behavior

1. Update `activeSpace`
2. If team space: `Clerk.shared.auth.setActive(organizationId:)`
3. All views re-query with new space context

## 3. Auth Flow

### Before (current)
```
Sign in → Org Picker (mandatory) → Main App
```

### After
```
Sign in → Main App (personal space)
```

- Remove `OrganizationPickerView` gate from `AuthGateView`
- Go directly to `AuthenticatedRootView`
- Space creation/switching via sidebar

## 4. Shareable Recordings

### Backend

New Convex functions:
- `recordings:enableSharing(recordingId)` — generate shareToken (nanoid), set shareEnabled=true
- `recordings:disableSharing(recordingId)` — set shareEnabled=false
- `recordings:getByShareToken(shareToken)` — public query, returns recording metadata + video URL

### HTTP Endpoint (convex/http.ts)

Route: `GET /share/{token}`
- Looks up recording by shareToken
- Returns HTML page with embedded video player
- Video URL from Convex storage

### Share URL Format
`https://<deployment>.convex.site/share/abc123def`

### HTML Player
- Responsive video element
- Recording title + duration
- Download button
- Works on mobile

### Swift UI
- Share button per recording
- First click: enable sharing + copy URL
- Already shared: copy URL
- Right-click: disable sharing option

## 5. Recordings Library Window

### Window: RecordingsLibraryWindow

- Separate macOS window (not in sidebar)
- Opened from sidebar button or menu

### Layout
- Grid of recording cards (3-4 columns, responsive)
- Card: thumbnail, title (editable), duration, date
- Top bar: search, sort by date/name

### Actions
- **Play**: Open in VideoEditorView
- **Share**: Enable sharing + copy link
- **Move to...**: Right-click → space submenu
- **Delete**: With confirmation dialog

### Data
- Subscribe to `recordings:list` for active space
- Thumbnails from `thumbnailStorageId` via Convex storage URL

## 6. Move Between Spaces

### Convex Mutations
- `notes:moveToSpace(noteId, targetOrgId)` — update organizationId (null for personal)
- `recordings:moveToSpace(recordingId, targetOrgId)` — update organizationId

### Auth
- User must own the item (userId check)
- If target is a team space, user must be a member

### UI
- Right-click context menu on notes and recordings
- "Move to..." → submenu listing available spaces
- Confirmation if moving from personal to team (others will see it)
