import ClerkKit
import SwiftUI

@main
struct KinshasaApp: App {
    init() {
        Clerk.configure(publishableKey: AppConfig.clerkPublishableKey)
    }

    var body: some Scene {
        WindowGroup {
            AuthGateView()
                .environment(Clerk.shared)
        }
    }
}
