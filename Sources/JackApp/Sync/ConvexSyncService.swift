import ClerkKit
@preconcurrency import ConvexMobile
import Foundation

/// Manages the ``ConvexClientWithAuth`` lifecycle for data synchronisation.
///
/// Use ``initialize(deploymentUrl:)`` once at app launch and
/// ``authenticate()`` after a Clerk session becomes active.
@MainActor @Observable
final class ConvexSyncService {
    private(set) var client: ConvexClientWithAuth<ClerkKit.User>?

    func initialize(deploymentUrl: String) {
        let provider = ClerkAuthProvider()
        client = ConvexClientWithAuth(
            deploymentUrl: deploymentUrl,
            authProvider: provider
        )
    }

    func authenticate() async {
        guard let client else { return }
        let result = await client.loginFromCache()
        if case .success = result {
            try? await client.mutation("users:syncUser", with: [:])
        }
    }

    func teardown() {
        client = nil
    }
}
