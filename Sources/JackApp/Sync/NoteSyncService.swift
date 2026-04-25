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
        spaceId: String?,
        text: String,
        dayStamp: String,
        timestamp: String
    ) async throws {
        if let spaceId {
            try await client.mutation("notes:create", with: [
                "spaceId": spaceId,
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
