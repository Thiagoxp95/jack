@preconcurrency import ConvexMobile
import Foundation

/// Syncs voice notes to the Convex backend.
@MainActor
final class NoteSyncService {
    private let client: ConvexClient

    init(client: ConvexClient) {
        self.client = client
    }

    func uploadNote(
        organizationId: String?,
        text: String,
        dayStamp: String,
        timestamp: String
    ) async throws {
        if let orgId = organizationId {
            try await client.mutation("notes:create", with: [
                "organizationId": orgId,
                "text": text,
                "dayStamp": dayStamp,
                "timestamp": timestamp,
            ])
        } else {
            try await client.mutation("notes:create", with: [
                "text": text,
                "dayStamp": dayStamp,
                "timestamp": timestamp,
            ])
        }
    }
}
