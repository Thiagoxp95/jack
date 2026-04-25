import ClerkKit
@preconcurrency import ConvexMobile
import Foundation

/// Central controller that owns the ``ConvexClientWithAuth`` instance and
/// exposes Clerk session/user state to SwiftUI views.
///
/// Typical usage:
/// 1. Call ``initializeConvex(deploymentUrl:)`` once at app launch.
/// 2. Call ``authenticateConvex()`` whenever Clerk's session becomes active.
/// 3. Read ``isSignedIn`` and ``currentUser``
///    from SwiftUI views that observe this object.
@MainActor @Observable
final class AuthController {
    // ConvexClientWithAuth is not Sendable; `@preconcurrency import` above
    // suppresses the cross-isolation sending diagnostic.
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

    func authenticateConvex() async -> Bool {
        // 1. Sync user via HTTP — this is what uploads, todos, chats etc. depend on.
        //    Must succeed before anything else.
        do {
            try await ConvexHTTPClient.ensureUserSynced()
        } catch {
            print("[AuthController] HTTP syncUser failed: \(error)")
            return false
        }

        // 2. Authenticate the ConvexMobile bridge (used for real-time subscriptions).
        //    Failure here is non-fatal — HTTP operations will still work.
        guard let client = convexClient else { return true }
        let result = await client.loginFromCache()
        switch result {
        case .success:
            break
        case .failure(let error):
            print("[AuthController] ConvexMobile auth failed (non-fatal): \(error)")
        }
        return true
    }

    // MARK: - Sign in / out

    @discardableResult
    func signIn(email: String, password: String) async throws -> Bool {
        let signIn = try await Clerk.shared.auth.signInWithPassword(
            identifier: email,
            password: password
        )
        if signIn.status == .complete {
            return await authenticateConvex()
        }
        return false
    }

    func signOut() async throws {
        convexClient = nil
        ConvexHTTPClient.resetSyncState()
        try await Clerk.shared.auth.signOut()
    }
}
