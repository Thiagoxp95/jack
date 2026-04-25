import ClerkKit
@preconcurrency import ConvexMobile
import Foundation

/// Bridges ClerkKit's session tokens to ConvexMobile's ``AuthProvider`` protocol.
///
/// The ``AuthProvider`` protocol methods are nonisolated, but Clerk APIs require
/// `@MainActor`. The `@preconcurrency import ConvexMobile` above suppresses
/// the cross-isolation conformance diagnostic. We conform to `@unchecked Sendable`
/// because the mutable state (`tokenRefreshTask`) is only ever accessed on
/// `@MainActor`.
final class ClerkAuthProvider: AuthProvider, @unchecked Sendable {
    typealias T = ClerkKit.User

    @MainActor private var tokenRefreshTask: Task<Void, Never>?

    func login(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> ClerkKit.User {
        let (session, user) = try await MainActor.run {
            guard let session = Clerk.shared.session, let user = Clerk.shared.user else {
                throw ClerkAuthProviderError.noSession
            }
            return (session, user)
        }

        let token = try await session.getToken(.init(template: "convex"))
        onIdToken(token)
        await startTokenRefreshListener(onIdToken: onIdToken)
        return user
    }

    func loginFromCache(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> ClerkKit.User {
        let (session, user) = try await MainActor.run {
            guard let session = Clerk.shared.session, let user = Clerk.shared.user else {
                throw ClerkAuthProviderError.noSession
            }
            return (session, user)
        }

        let token = try await session.getToken(.init(template: "convex"))
        onIdToken(token)
        await startTokenRefreshListener(onIdToken: onIdToken)
        return user
    }

    func logout() async throws {
        await MainActor.run {
            tokenRefreshTask?.cancel()
            tokenRefreshTask = nil
        }
        try await Clerk.shared.auth.signOut()
    }

    nonisolated func extractIdToken(from authResult: ClerkKit.User) -> String {
        // The token is pushed via `onIdToken` in login/loginFromCache.
        // ConvexMobile uses this only as a fallback; return empty.
        ""
    }

    // MARK: - Private

    @MainActor
    private func startTokenRefreshListener(onIdToken: @Sendable @escaping (String?) -> Void) {
        tokenRefreshTask?.cancel()
        tokenRefreshTask = Task { @MainActor in
            for await event in Clerk.shared.auth.events {
                guard !Task.isCancelled else { return }
                switch event {
                case .tokenRefreshed:
                    let freshToken = try? await Clerk.shared.session?.getToken(
                        .init(template: "convex")
                    )
                    onIdToken(freshToken)
                case .signedOut:
                    onIdToken(nil)
                default:
                    break
                }
            }
        }
    }
}

enum ClerkAuthProviderError: LocalizedError {
    case noSession

    var errorDescription: String? {
        switch self {
        case .noSession:
            return "No active Clerk session. User must sign in first."
        }
    }
}
