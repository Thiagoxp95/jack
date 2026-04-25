import AppKit
import AVFoundation
import ClerkKit
import Foundation

/// Background export + upload queue with retry and persistence.
///
/// After the user clicks Save in the editor, the session is enqueued here.
/// The queue exports the video, uploads to Convex storage, creates the
/// recording metadata, then deletes the local file.
@MainActor @Observable
final class UploadQueue {

    static let shared = UploadQueue()

    enum UploadStatus: String, Codable {
        case exporting
        case queued
        case uploading
        case failed
        case completed
    }

    struct PendingUpload: Codable, Identifiable {
        let id: UUID
        var filePath: String
        let title: String
        let duration: Double
        let spaceId: String?
        var status: UploadStatus
        var retryCount: Int
        let createdAt: Date
        var exportProgress: Double
        var lastError: String?
    }

    /// In-memory export jobs (not persisted — if app quits mid-export, the
    /// raw session directory is gone anyway).
    struct ExportJob {
        let id: UUID
        let session: RecordingSession
        let editor: VideoEditorController
        let config: ExportConfiguration
    }

    private(set) var pending: [PendingUpload] = []
    private var isProcessing = false
    private var activeExportJobs: [UUID: ExportJob] = [:]

    private static let backoffDelays: [TimeInterval] = [5, 30, 120, 600]
    private static let maxRetries = 5

    private init() {
        loadFromDisk()
    }

    // MARK: - Public API

    /// Enqueue an export-then-upload job. The pending item appears immediately
    /// in the UI with `.exporting` status. Export runs in the background.
    func enqueueExport(
        session: RecordingSession,
        editor: VideoEditorController,
        config: ExportConfiguration,
        title: String,
        duration: Double,
        spaceId: String?
    ) {
        let id = UUID()
        let upload = PendingUpload(
            id: id,
            filePath: "",
            title: title,
            duration: duration,
            spaceId: spaceId,
            status: .exporting,
            retryCount: 0,
            createdAt: Date(),
            exportProgress: 0
        )
        pending.append(upload)

        activeExportJobs[id] = ExportJob(
            id: id,
            session: session,
            editor: editor,
            config: config
        )

        Task { await runExport(id: id) }
    }

    func enqueue(filePath: String, title: String, duration: Double, spaceId: String?) {
        let upload = PendingUpload(
            id: UUID(),
            filePath: filePath,
            title: title,
            duration: duration,
            spaceId: spaceId,
            status: .queued,
            retryCount: 0,
            createdAt: Date(),
            exportProgress: 1
        )
        pending.append(upload)
        saveToDisk()
        processQueue()
    }

    func retryFailed() {
        for i in pending.indices where pending[i].status == .failed {
            pending[i].status = .queued
            pending[i].retryCount = 0
        }
        saveToDisk()
        processQueue()
    }

    // MARK: - Export

    private func runExport(id: UUID) async {
        guard let job = activeExportJobs[id] else { return }

        do {
            let service = ExportService()
            try await service.exportWithEffects(
                session: job.session,
                editor: job.editor,
                config: job.config,
                progress: { [weak self] value in
                    Task { @MainActor [weak self] in
                        guard let self,
                              let idx = self.pending.firstIndex(where: { $0.id == id })
                        else { return }
                        self.pending[idx].exportProgress = value
                    }
                }
            )

            // Export done — clean up raw session files and transition to upload
            try? FileManager.default.removeItem(at: job.session.sessionDirectory)

            guard let idx = pending.firstIndex(where: { $0.id == id }) else { return }
            pending[idx].filePath = job.config.outputURL.path
            pending[idx].status = .queued
            pending[idx].exportProgress = 1
            activeExportJobs.removeValue(forKey: id)
            saveToDisk()
            processQueue()

        } catch {
            NSLog("[UploadQueue] Export failed: %@", String(describing: error))
            guard let idx = pending.firstIndex(where: { $0.id == id }) else { return }
            pending[idx].status = .failed
            activeExportJobs.removeValue(forKey: id)
        }
    }

    // MARK: - Upload Queue

    func processQueue() {
        guard !isProcessing else { return }
        isProcessing = true

        Task {
            while let index = pending.firstIndex(where: { $0.status == .queued }) {
                pending[index].status = .uploading
                saveToDisk()

                let upload = pending[index]
                let success = await performUpload(upload)

                if success {
                    // Delete local file
                    try? FileManager.default.removeItem(atPath: upload.filePath)
                    pending.remove(at: index)
                    saveToDisk()
                    NotificationCenter.default.post(name: .recordingExported, object: nil)
                } else {
                    let newRetryCount = upload.retryCount + 1
                    if newRetryCount >= Self.maxRetries {
                        pending[index].status = .failed
                        pending[index].retryCount = newRetryCount
                    } else {
                        pending[index].status = .failed
                        pending[index].retryCount = newRetryCount
                        // Schedule retry with backoff
                        let delayIndex = min(newRetryCount - 1, Self.backoffDelays.count - 1)
                        let delay = Self.backoffDelays[delayIndex]
                        Task {
                            try? await Task.sleep(for: .seconds(delay))
                            if let idx = self.pending.firstIndex(where: { $0.id == upload.id }),
                               self.pending[idx].status == .failed {
                                self.pending[idx].status = .queued
                                self.saveToDisk()
                                self.processQueue()
                            }
                        }
                    }
                    saveToDisk()
                }
            }
            isProcessing = false
        }
    }

    // MARK: - Upload

    private func performUpload(_ upload: PendingUpload) async -> Bool {
        func setError(_ message: String) {
            if let idx = pending.firstIndex(where: { $0.id == upload.id }) {
                pending[idx].lastError = message
            }
        }

        do {
            // 0. Check file exists
            let fileURL = URL(fileURLWithPath: upload.filePath)
            guard FileManager.default.fileExists(atPath: upload.filePath) else {
                let msg = "File not found: \(upload.filePath)"
                NSLog("[UploadQueue] %@", msg)
                setError(msg)
                return false
            }

            // Ensure user record exists before uploading
            try await ConvexHTTPClient.ensureUserSynced()

            let token = try await ConvexHTTPClient.getToken()

            // 1. Get upload URL
            let uploadUrlValue = try await ConvexHTTPClient.mutation(
                function: "storage:generateUploadUrl",
                token: token
            )
            guard let uploadUrl = uploadUrlValue as? String else {
                let msg = "No upload URL returned from Convex"
                NSLog("[UploadQueue] %@", msg)
                setError(msg)
                return false
            }

            // 2. Upload file
            var request = URLRequest(url: URL(string: uploadUrl)!)
            request.httpMethod = "POST"
            request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 300

            let (responseData, response) = try await URLSession.shared.upload(
                for: request, fromFile: fileURL
            )
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard statusCode == 200 else {
                let body = String(data: responseData.prefix(500), encoding: .utf8) ?? "<binary>"
                let msg = "File upload HTTP \(statusCode): \(body)"
                NSLog("[UploadQueue] %@", msg)
                setError(msg)
                return false
            }

            // 3. Extract storageId
            let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
            guard let storageId = json?["storageId"] as? String else {
                let msg = "No storageId in upload response"
                NSLog("[UploadQueue] %@", msg)
                setError(msg)
                return false
            }

            // 4. Generate and upload thumbnail
            var thumbnailStorageId: String?
            var ogImageStorageId: String?
            let thumbResult = Self.generateThumbnail(for: fileURL)
            if let thumbData = thumbResult {
                thumbnailStorageId = try? await Self.uploadData(
                    thumbData,
                    contentType: "image/jpeg",
                    token: token
                )
                NSLog("[UploadQueue] Thumbnail uploaded: %@", thumbnailStorageId ?? "nil")
            }

            // 5. Generate and upload OG preview image (branded thumbnail for link previews)
            if let thumbData = thumbResult,
               let thumbImage = NSImage(data: thumbData)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let ogData = Self.generateOGImage(thumbnail: thumbImage, title: upload.title, duration: upload.duration) {
                ogImageStorageId = try? await Self.uploadData(
                    ogData,
                    contentType: "image/jpeg",
                    token: token
                )
                NSLog("[UploadQueue] OG image uploaded: %@", ogImageStorageId ?? "nil")
            }

            // 6. Create recording with sharing enabled
            var args: [String: Any] = [
                "title": upload.title,
                "duration": upload.duration,
                "storageId": storageId,
            ]
            if let spaceId = upload.spaceId {
                args["spaceId"] = spaceId
            }
            if let thumbnailStorageId {
                args["thumbnailStorageId"] = thumbnailStorageId
            }
            if let ogImageStorageId {
                args["ogImageStorageId"] = ogImageStorageId
            }

            _ = try await ConvexHTTPClient.mutation(
                function: "recordings:createAndShare",
                args: args,
                token: token
            )

            NSLog("[UploadQueue] Upload complete: %@", upload.title)
            return true
        } catch {
            let msg = String(describing: error)
            NSLog("[UploadQueue] Upload failed: %@", msg)
            setError(msg)
            return false
        }
    }

    // MARK: - Persistence

    private static var persistenceURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Jack", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("upload_queue.json")
    }

    private func saveToDisk() {
        // Only persist items that have a file path (i.e., export is done)
        let persistable = pending.filter { !$0.filePath.isEmpty }
        do {
            let data = try JSONEncoder().encode(persistable)
            try data.write(to: Self.persistenceURL, options: .atomic)
        } catch {
            NSLog("[UploadQueue] Failed to save: %@", String(describing: error))
        }
    }

    private func loadFromDisk() {
        do {
            let data = try Data(contentsOf: Self.persistenceURL)
            var loaded = try JSONDecoder().decode([PendingUpload].self, from: data)
            // Reset any uploading items to queued (app was killed mid-upload)
            for i in loaded.indices where loaded[i].status == .uploading {
                loaded[i].status = .queued
            }
            // Remove completed items
            loaded.removeAll { $0.status == .completed }
            // Remove items whose files no longer exist
            loaded.removeAll { !FileManager.default.fileExists(atPath: $0.filePath) }
            pending = loaded
        } catch {
            pending = []
        }
    }

    // MARK: - Thumbnail

    private nonisolated static func generateThumbnail(for videoURL: URL) -> Data? {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)

        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        do {
            let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
            let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
            return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        } catch {
            NSLog("[UploadQueue] Thumbnail generation failed: %@", String(describing: error))
            return nil
        }
    }

    /// Generate a branded OG preview image for link unfurling (Slack, Twitter, etc.)
    /// Layout: video frame fills canvas, dark gradient on left, branding + duration + title overlaid.
    private nonisolated static func generateOGImage(
        thumbnail: CGImage,
        title: String,
        duration: Double
    ) -> Data? {
        let width: CGFloat = 1200
        let height: CGFloat = 630

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return nil
        }

        // Core Graphics origin is bottom-left; flip to top-left for easier layout
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)

        // 1. Draw thumbnail scaled to fill the canvas
        let thumbW = CGFloat(thumbnail.width)
        let thumbH = CGFloat(thumbnail.height)
        let thumbAspect = thumbW / thumbH
        let canvasAspect = width / height

        var drawRect: CGRect
        if thumbAspect > canvasAspect {
            let dh = height
            let dw = dh * thumbAspect
            drawRect = CGRect(x: (width - dw) / 2, y: 0, width: dw, height: dh)
        } else {
            let dw = width
            let dh = dw / thumbAspect
            drawRect = CGRect(x: 0, y: (height - dh) / 2, width: dw, height: dh)
        }
        // Un-flip for image drawing (CGImage draws in CG coords)
        context.saveGState()
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        let flippedRect = CGRect(x: drawRect.origin.x, y: height - drawRect.origin.y - drawRect.height,
                                  width: drawRect.width, height: drawRect.height)
        context.draw(thumbnail, in: flippedRect)
        context.restoreGState()

        // 2. Dark gradient overlay: opaque on left → transparent on right
        let gradientColors = [
            CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.88),
            CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.65),
            CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: gradientColors, locations: [0, 0.45, 0.85]) {
            // Gradient in un-flipped CG coords (left to right is the same)
            context.saveGState()
            context.translateBy(x: 0, y: height)
            context.scaleBy(x: 1, y: -1)
            context.drawLinearGradient(gradient, start: .zero,
                                        end: CGPoint(x: width, y: 0), options: [])
            context.restoreGState()
        }

        // Use NSGraphicsContext for text (needs flipped context, which we already have)
        let gc = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = gc

        // 3. "Jack" branding — top-left
        let brandAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 30, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        NSAttributedString(string: "Jack", attributes: brandAttrs)
            .draw(at: NSPoint(x: 52, y: 44))

        // 4. Duration — bottom-left, above title
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        let durationText = mins > 0 ? "\(mins)m" : "\(secs)s"
        let durationAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 26, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.85),
        ]
        // Clock symbol + duration
        NSAttributedString(string: "\u{23F1} \(durationText)", attributes: durationAttrs)
            .draw(at: NSPoint(x: 52, y: height - 180))

        // 5. Title — large text at bottom-left, max 2 lines
        let titleFont = NSFont.systemFont(ofSize: 52, weight: .bold)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor.white,
        ]
        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.lineBreakMode = .byTruncatingTail
        titleParagraph.maximumLineHeight = 62
        let titleDrawAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor.white,
            .paragraphStyle: titleParagraph,
        ]
        let titleRect = CGRect(x: 52, y: height - 148, width: width * 0.52, height: 130)
        NSAttributedString(string: title, attributes: titleDrawAttrs)
            .draw(in: titleRect)

        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    private nonisolated static func uploadData(
        _ data: Data,
        contentType: String,
        token: String
    ) async throws -> String {
        let uploadUrlValue = try await ConvexHTTPClient.mutation(
            function: "storage:generateUploadUrl",
            token: token
        )
        guard let uploadUrl = uploadUrlValue as? String,
              let url = URL(string: uploadUrl) else {
            throw RecordingSyncError.uploadFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let (responseData, response) = try await URLSession.shared.upload(
            for: request, from: data
        )
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw RecordingSyncError.uploadFailed
        }

        let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        guard let storageId = json?["storageId"] as? String else {
            throw RecordingSyncError.uploadFailed
        }
        return storageId
    }
}
