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
