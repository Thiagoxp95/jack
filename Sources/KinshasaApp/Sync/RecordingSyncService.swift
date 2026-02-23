@preconcurrency import ConvexMobile
import Foundation

/// Syncs recordings and video files to the Convex backend.
@MainActor
final class RecordingSyncService {
    private let client: ConvexClient

    init(client: ConvexClient) {
        self.client = client
    }

    /// Uploads a recording's video file to Convex storage and creates the
    /// associated metadata record.
    func uploadRecording(
        organizationId: String,
        title: String,
        duration: Double,
        videoFileURL: URL
    ) async throws {
        // 1. Obtain a one-time upload URL from the backend.
        let uploadUrl: String = try await client.mutation(
            "storage:generateUploadUrl",
            with: [:]
        )

        // 2. Upload the video data to the returned URL.
        let videoData = try Data(contentsOf: videoFileURL)
        var request = URLRequest(url: URL(string: uploadUrl)!)
        request.httpMethod = "POST"
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        request.httpBody = videoData
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw RecordingSyncError.uploadFailed
        }

        // 3. Create the recording metadata in the database.
        try await client.mutation("recordings:create", with: [
            "organizationId": organizationId,
            "title": title,
            "duration": duration,
        ])
    }
}

enum RecordingSyncError: LocalizedError {
    case uploadFailed

    var errorDescription: String? {
        switch self {
        case .uploadFailed:
            return "Failed to upload recording file"
        }
    }
}
