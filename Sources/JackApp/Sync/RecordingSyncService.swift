@preconcurrency import ConvexMobile
import Foundation

/// Syncs recordings and video files to the Convex backend.
///
/// Intentionally NOT `@MainActor` — the upload involves FFI calls through
/// ConvexMobile's Rust bridge and Clerk token refresh, both of which can
/// deadlock if the main actor is held during `await`.
final class RecordingSyncService: Sendable {
    private let client: ConvexClient

    init(client: ConvexClient) {
        self.client = client
    }

    /// Uploads a recording's video file to Convex storage and creates the
    /// associated metadata record.
    func uploadRecording(
        spaceId: String?,
        title: String,
        duration: Double,
        videoFileURL: URL
    ) async throws {
        NSLog("[Jack Upload] Starting upload for: %@", videoFileURL.lastPathComponent)

        // 1. Obtain a one-time upload URL from the backend.
        NSLog("[Jack Upload] Requesting upload URL from Convex...")
        let uploadUrl: String = try await client.mutation(
            "storage:generateUploadUrl",
            with: [:]
        )
        NSLog("[Jack Upload] Got upload URL: %@", String(uploadUrl.prefix(80)))

        // 2. Upload the video file to the returned URL (stream from disk, not memory).
        var request = URLRequest(url: URL(string: uploadUrl)!)
        request.httpMethod = "POST"
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300 // 5 minutes for large videos

        NSLog("[Jack Upload] Uploading file (%@ bytes)...",
              String(describing: (try? FileManager.default.attributesOfItem(atPath: videoFileURL.path)[.size]) ?? "unknown"))
        let (responseData, response) = try await URLSession.shared.upload(
            for: request, fromFile: videoFileURL
        )
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: responseData, encoding: .utf8) ?? "<binary>"
            NSLog("[Jack Upload] Upload failed: HTTP %d — %@", statusCode, body)
            throw RecordingSyncError.uploadFailed
        }
        NSLog("[Jack Upload] File uploaded successfully")

        // 3. Extract the storageId from the upload response.
        let storageId: String
        do {
            let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
            guard let sid = json?["storageId"] as? String else {
                NSLog("[Jack Upload] No storageId in response: %@",
                      String(data: responseData, encoding: .utf8) ?? "<binary>")
                throw RecordingSyncError.uploadFailed
            }
            storageId = sid
        }
        NSLog("[Jack Upload] Got storageId: %@", storageId)

        // 4. Create the recording metadata in the database.
        NSLog("[Jack Upload] Creating recording record...")
        if let spaceId {
            try await client.mutation("recordings:create", with: [
                "spaceId": spaceId,
                "title": title,
                "duration": duration,
                "storageId": storageId,
            ])
        } else {
            try await client.mutation("recordings:create", with: [
                "title": title,
                "duration": duration,
                "storageId": storageId,
            ])
        }
        NSLog("[Jack Upload] Recording created successfully")
    }

    /// Uploads a video file, creates a recording record, enables sharing, and
    /// returns the shareable URL.
    func uploadAndShare(
        title: String,
        duration: Double,
        videoFileURL: URL,
        onStatus: @Sendable @escaping (String) -> Void = { _ in }
    ) async throws -> String {
        NSLog("[Jack Share] Starting upload and share for: %@", videoFileURL.lastPathComponent)

        // 1. Obtain a one-time upload URL.
        onStatus("Step 1/4: Getting upload URL...")
        NSLog("[Jack Share] Step 1: Requesting upload URL...")
        let uploadUrl: String = try await client.mutation(
            "storage:generateUploadUrl",
            with: [:]
        )
        NSLog("[Jack Share] Step 1 done. URL: %@", String(uploadUrl.prefix(80)))

        // 2. Upload the video file.
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: videoFileURL.path)[.size] as? UInt64) ?? 0
        let fileSizeStr = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
        onStatus("Step 2/4: Uploading \(fileSizeStr)...")
        NSLog("[Jack Share] Step 2: Uploading file (%@)...", fileSizeStr)

        var request = URLRequest(url: URL(string: uploadUrl)!)
        request.httpMethod = "POST"
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        let (responseData, response) = try await URLSession.shared.upload(
            for: request, fromFile: videoFileURL
        )
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        NSLog("[Jack Share] Step 2 done. HTTP %d, body: %@", statusCode,
              String(data: responseData.prefix(500), encoding: .utf8) ?? "<binary>")
        guard statusCode == 200 else {
            let body = String(data: responseData, encoding: .utf8) ?? "HTTP \(statusCode)"
            throw RecordingSyncError.shareFailed("Upload failed: \(body)")
        }

        // 3. Extract storageId.
        onStatus("Step 3/4: Processing...")
        NSLog("[Jack Share] Step 3: Extracting storageId...")
        let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        guard let storageId = json?["storageId"] as? String else {
            let body = String(data: responseData, encoding: .utf8) ?? "<binary>"
            NSLog("[Jack Share] Step 3 FAILED: no storageId in: %@", body)
            throw RecordingSyncError.shareFailed("No storageId in response")
        }
        NSLog("[Jack Share] Step 3 done. storageId: %@", storageId)

        // 4. Create the recording and enable sharing in a single mutation.
        onStatus("Step 4/4: Creating share link...")
        NSLog("[Jack Share] Step 4: Calling createAndShare...")
        let token: String = try await client.mutation("recordings:createAndShare", with: [
            "title": title,
            "duration": duration,
            "storageId": storageId,
        ])
        NSLog("[Jack Share] Step 4 done. Token: %@", token)

        let shareUrl = AppConfig.convexSiteUrl + "/share/" + token
        NSLog("[Jack Share] Complete! URL: %@", shareUrl)
        onStatus("Done! Link copied.")
        return shareUrl
    }
}

enum RecordingSyncError: LocalizedError {
    case uploadFailed
    case shareFailed(String)

    var errorDescription: String? {
        switch self {
        case .uploadFailed:
            return "Failed to upload recording file"
        case .shareFailed(let detail):
            return "Share failed: \(detail)"
        }
    }
}
