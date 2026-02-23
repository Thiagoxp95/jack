import ClerkKit
@preconcurrency import ConvexMobile
import Foundation

/// Central controller that owns the ``ConvexClientWithAuth`` instance and
/// exposes Clerk session/user state to SwiftUI views.
///
/// Typical usage:
/// 1. Call ``initializeConvex(deploymentUrl:)`` once at app launch.
/// 2. Call ``authenticateConvex()`` whenever Clerk's session becomes active.
/// 3. Read ``isSignedIn``, ``currentUser``, and ``currentOrganization``
///    from SwiftUI views that observe this object.
@MainActor @Observable
final class AuthController {
    // ConvexClientWithAuth is not Sendable; `@preconcurrency import` above
    // suppresses the cross-isolation sending diagnostic.
    private(set) var convexClient: ConvexClientWithAuth<ClerkKit.User>?

    var isSignedIn: Bool { Clerk.shared.session != nil }
    var currentUser: ClerkKit.User? { Clerk.shared.user }

    var currentOrganization: ClerkKit.Organization? {
        guard let memberships = Clerk.shared.user?.organizationMemberships else { return nil }
        return memberships.first?.organization
    }

    var organizations: [ClerkKit.Organization] {
        Clerk.shared.user?.organizationMemberships?.map(\.organization) ?? []
    }

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

    // MARK: - Organizations

    func setActiveOrganization(_ org: ClerkKit.Organization) async throws {
        guard let sessionId = Clerk.shared.session?.id else { return }
        try await Clerk.shared.auth.setActive(
            sessionId: sessionId,
            organizationId: org.id
        )
    }
}
