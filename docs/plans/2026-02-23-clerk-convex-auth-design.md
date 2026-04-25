# Clerk + Convex Authentication & Organizations Design

## Summary

Integrate Clerk authentication and Convex backend into the Jack macOS app to enable user accounts, organization workspaces, and cloud sync of notes and recordings.

## Architecture

```
macOS App (SwiftUI)
├── ClerkKit (auth + orgs)
├── Custom macOS Auth & Org Views
└── Convex Swift Client (real-time data sync)
         │                        │
    Clerk Cloud              Convex Cloud
    (Auth, Orgs)             (DB, Files, Functions)
```

### Auth Flow

1. App launches → `Clerk.configure(publishableKey:)`
2. `AuthGateView` checks `Clerk.shared.session`
3. No session → show `SignInView` / `SignUpView`
4. User authenticates → Clerk session established
5. `ClerkAuthProvider` gets JWT via `session.getToken(.init(template: "convex"))`
6. JWT passed to `ConvexClientWithAuth` for backend auth
7. Token auto-refreshes via Clerk's `auth.events` stream

### Organization Flow

1. After sign-in → check `user.organizationMemberships`
2. No orgs → prompt to create one (required for app usage)
3. Multiple orgs → `OrganizationPickerView` to select active org
4. Active org set via `clerk.auth.setActive(sessionId:organizationId:)`
5. All data queries scoped by `organizationId` from JWT claims

## Components

### 1. ClerkAuthProvider (bridges Clerk → Convex)

Implements `convex-swift`'s `AuthProvider` protocol:

```swift
final class ClerkAuthProvider: AuthProvider {
  typealias T = User  // Clerk User

  func login(onIdToken: @escaping (String?) -> Void) async throws -> User {
    // 1. Clerk sign-in already completed at this point
    // 2. Get Convex JWT from Clerk session
    let token = try await Clerk.shared.session?.getToken(
      .init(template: "convex")
    )
    onIdToken(token)
    // 3. Listen for token refresh events
    listenForTokenRefresh(onIdToken: onIdToken)
    return Clerk.shared.user!
  }

  func loginFromCache(onIdToken: @escaping (String?) -> Void) async throws -> User {
    // Re-use existing Clerk session, refresh token if needed
    let token = try await Clerk.shared.session?.getToken(
      .init(template: "convex")
    )
    onIdToken(token)
    listenForTokenRefresh(onIdToken: onIdToken)
    return Clerk.shared.user!
  }

  func logout() async throws {
    try await Clerk.shared.auth.signOut()
  }

  func extractIdToken(from user: User) -> String {
    // Token already passed via onIdToken callback
    ""
  }
}
```

### 2. AuthController (@Observable)

Central auth state management:

```swift
@Observable @MainActor
final class AuthController {
  let clerk = Clerk.shared
  var convexClient: ConvexClientWithAuth<User>?

  var isSignedIn: Bool { clerk.session != nil }
  var currentUser: User? { clerk.user }
  var currentOrganization: Organization? {
    clerk.session?.lastActiveOrganizationId.flatMap { orgId in
      clerk.user?.organizationMemberships?.first { $0.organization.id == orgId }?.organization
    }
  }

  func signIn(email: String, password: String) async throws { ... }
  func signUp(email: String, password: String, firstName: String, lastName: String) async throws { ... }
  func signOut() async throws { ... }
  func setActiveOrganization(_ org: Organization) async throws { ... }
  func createOrganization(name: String) async throws -> Organization { ... }
}
```

### 3. macOS Auth Views

`ClerkKitUI` is iOS-only, so we build custom macOS SwiftUI views:

- **`AuthGateView`** — Root view: shows auth when signed out, org picker when no active org, main app when ready
- **`SignInView`** — Email + password form, OAuth buttons (Google, Apple), link to sign up
- **`SignUpView`** — Registration form with email verification code flow
- **`VerificationCodeView`** — 6-digit code entry for email verification
- **`OrganizationPickerView`** — List orgs, create new, switch active
- **`CreateOrganizationView`** — Name + slug form
- **`OrganizationSettingsView`** — Members list, invite form, role management, pending invitations

### 4. Convex Backend

Node.js project at repo root (alongside Swift sources):

**`convex/auth.config.ts`**
```typescript
export default {
  providers: [{
    domain: process.env.CLERK_JWT_ISSUER_DOMAIN!,
    applicationID: "convex",
  }],
};
```

**`convex/schema.ts`** — Core tables:
- `users` — Synced from Clerk (clerkId, email, name, imageUrl)
- `notes` — Voice note transcriptions (organizationId, userId, text, createdAt)
- `recordings` — Recording metadata (organizationId, userId, title, duration, storageId)

All data scoped by `organizationId` from authenticated user's active org.

**Convex functions:**
- `users.ts` — `syncUser` mutation (upsert on first login), `getUser` query
- `notes.ts` — `create`, `list` (by org), `get`, `update`, `delete`
- `recordings.ts` — `create`, `list` (by org), `get`, `delete`
- `storage.ts` — `generateUploadUrl` mutation for video file uploads

### 5. Data Sync

**Notes:** After transcription completes, call Convex mutation to save note text + metadata.

**Recordings:** After export completes:
1. Call `storage.generateUploadUrl()` to get upload URL
2. Upload video file to Convex file storage
3. Call `recordings.create()` with metadata + storageId

All queries use `organizationId` from the JWT claims to scope data access.

## New Dependencies

### Swift (Package.swift)
- `clerk-ios` from `https://github.com/clerk/clerk-ios` (v1.0.0+)
- `convex-swift` from `https://github.com/get-convex/convex-swift`

### Node.js (convex/)
- `convex` — Convex functions runtime
- Clerk JWT issuer domain as environment variable

## File Structure

```
Sources/JackApp/
├── Auth/
│   ├── ClerkAuthProvider.swift      # Bridges Clerk → Convex AuthProvider
│   ├── AuthController.swift         # Central auth state management
│   └── Views/
│       ├── AuthGateView.swift       # Root: auth gate → org gate → app
│       ├── SignInView.swift         # Email/password + OAuth
│       ├── SignUpView.swift         # Registration flow
│       ├── VerificationCodeView.swift # Email code verification
│       ├── OrganizationPickerView.swift # Org list + switcher
│       ├── CreateOrganizationView.swift # Create org form
│       └── OrganizationSettingsView.swift # Members, invites, roles
├── Sync/
│   ├── ConvexSyncService.swift      # Manages Convex client lifecycle
│   ├── NoteSyncService.swift        # Note upload/download
│   └── RecordingSyncService.swift   # Recording upload/download
convex/
├── auth.config.ts
├── schema.ts
├── users.ts
├── notes.ts
├── recordings.ts
└── storage.ts
```

## Dashboard Setup Required

### Clerk Dashboard
1. Create "convex" JWT template (do NOT rename)
2. Enable organizations feature
3. Configure sign-in methods (email/password, Google OAuth, Apple)
4. Copy publishable key and JWT issuer URL

### Convex Dashboard
1. Set `CLERK_JWT_ISSUER_DOMAIN` environment variable
2. Deploy convex functions
