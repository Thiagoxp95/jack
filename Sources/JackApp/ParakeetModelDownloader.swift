import FluidAudio
import Foundation

/// Byte-accurate progress for one Parakeet weight download.
struct ParakeetDownloadProgress: Sendable, Equatable {
    let completedBytes: Int64
    let totalBytes: Int64

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }

    var percent: Int {
        Int((fraction * 100).rounded(.down))
    }

    /// "212 MB of 483 MB" — shown next to the progress bar in settings.
    var byteSummary: String {
        "\(Self.megabytes(completedBytes)) of \(Self.megabytes(totalBytes))"
    }

    private static func megabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum ParakeetModelDownloadError: LocalizedError {
    case listingFailed(String)
    case transferFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .listingFailed(reason):
            return "Could not list the speech model files. \(reason)"
        case let .transferFailed(path, reason):
            return "Download of \(path) failed. \(reason)"
        }
    }
}

/// Downloads the Parakeet CoreML weights with real byte-level progress.
///
/// FluidAudio fetches the models itself, but its `ProgressHandler` is declared
/// unused, so a model switch would otherwise sit on an indeterminate spinner
/// for ~450 MB. We pull the exact same file set first — same destination, same
/// filter — and FluidAudio then finds everything on disk and skips its own
/// download.
actor ParakeetModelDownloader {
    private static let apiHost = "https://huggingface.co"

    /// Mirrors `DownloadUtils.downloadRepo`: everything inside a required
    /// `.mlmodelc` directory, plus the root-level json/txt files (the
    /// vocabulary lives there).
    private static var requiredModelDirectories: Set<String> {
        ModelNames.ASR.requiredModels
    }

    private struct TreeEntry: Decodable {
        struct LFSInfo: Decodable {
            let size: Int64?
        }

        let type: String
        let path: String
        let size: Int64?
        let lfs: LFSInfo?

        var byteSize: Int64 {
            lfs?.size ?? size ?? 0
        }
    }

    struct PendingFile {
        let path: String
        let byteSize: Int64
        let destination: URL
    }

    /// The exact file set the CoreML engine needs, with sizes from HuggingFace.
    /// Exposed so tests can check the filter without pulling 450 MB.
    func manifest(version: AsrModelVersion) async throws -> [PendingFile] {
        let repoDirectory = AsrModels.defaultCacheDirectory(for: version)
        return try await listRepositoryFiles(remotePath: Self.remotePath(for: version))
            .filter { Self.isRequired(path: $0.path) }
            .map {
                PendingFile(
                    path: $0.path,
                    byteSize: $0.byteSize,
                    destination: repoDirectory.appendingPathComponent($0.path)
                )
            }
    }

    /// Fetches every file the CoreML engine needs for `version`, reporting
    /// progress as bytes land. Already-present files count as complete, so a
    /// half-finished download resumes at file granularity.
    func download(
        version: AsrModelVersion,
        onProgress: @escaping @Sendable (ParakeetDownloadProgress) -> Void
    ) async throws {
        let remotePath = Self.remotePath(for: version)
        let repoDirectory = AsrModels.defaultCacheDirectory(for: version)
        try FileManager.default.createDirectory(at: repoDirectory, withIntermediateDirectories: true)

        var pending: [PendingFile] = []
        var mutableTotal: Int64 = 0
        var completedBytes: Int64 = 0

        for file in try await manifest(version: version) {
            mutableTotal += file.byteSize

            if Self.fileIsComplete(at: file.destination, expectedSize: file.byteSize) {
                completedBytes += file.byteSize
                continue
            }

            pending.append(file)
        }

        let totalBytes = mutableTotal

        // URLSession reports every ~16 KB; collapse that to one update per
        // whole percent so the UI layer isn't woken thousands of times.
        let throttle = ProgressThrottle(emit: onProgress)
        throttle.send(ParakeetDownloadProgress(completedBytes: completedBytes, totalBytes: totalBytes), force: true)

        guard !pending.isEmpty else { return }

        for file in pending {
            try Task.checkCancellation()

            let baseCompleted = completedBytes
            try await downloadFile(
                remotePath: remotePath,
                file: file,
                onBytesWritten: { written in
                    throttle.send(
                        ParakeetDownloadProgress(
                            completedBytes: baseCompleted + written,
                            totalBytes: totalBytes
                        )
                    )
                }
            )

            completedBytes += file.byteSize
            throttle.send(
                ParakeetDownloadProgress(completedBytes: completedBytes, totalBytes: totalBytes),
                force: true
            )
        }
    }

    // MARK: - Remote listing

    private func listRepositoryFiles(remotePath: String) async throws -> [TreeEntry] {
        guard let url = URL(string: "\(Self.apiHost)/api/models/\(remotePath)/tree/main?recursive=true") else {
            throw ParakeetModelDownloadError.listingFailed("Invalid repository path \(remotePath).")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw ParakeetModelDownloadError.listingFailed(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ParakeetModelDownloadError.listingFailed("HuggingFace returned HTTP \(http.statusCode).")
        }

        do {
            return try JSONDecoder().decode([TreeEntry].self, from: data).filter { $0.type == "file" }
        } catch {
            throw ParakeetModelDownloadError.listingFailed(error.localizedDescription)
        }
    }

    // MARK: - Transfer

    func downloadFile(
        remotePath: String,
        file: PendingFile,
        onBytesWritten: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let encodedPath = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path
        guard let url = URL(string: "\(Self.apiHost)/\(remotePath)/resolve/main/\(encodedPath)") else {
            throw ParakeetModelDownloadError.transferFailed(path: file.path, reason: "Invalid file URL.")
        }

        try FileManager.default.createDirectory(
            at: file.destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let delegate = FileDownloadDelegate(destination: file.destination, onBytesWritten: onBytesWritten)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let task = session.downloadTask(with: URLRequest(url: url, timeoutInterval: 1_800))

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.attach(continuation: continuation)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw ParakeetModelDownloadError.transferFailed(path: file.path, reason: error.localizedDescription)
        }
    }

    // MARK: - Helpers

    static func remotePath(for version: AsrModelVersion) -> String {
        switch version {
        case .v2:
            return "FluidInference/parakeet-tdt-0.6b-v2-coreml"
        case .v3:
            return "FluidInference/parakeet-tdt-0.6b-v3-coreml"
        }
    }

    private static func isRequired(path: String) -> Bool {
        if let root = path.split(separator: "/").first,
           requiredModelDirectories.contains(String(root))
        {
            return true
        }
        return !path.contains("/") && (path.hasSuffix(".json") || path.hasSuffix(".txt"))
    }

    /// A file counts as done only when its size matches the manifest — a
    /// truncated leftover from an interrupted run gets refetched.
    private static func fileIsComplete(at url: URL, expectedSize: Int64) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else {
            return false
        }
        return expectedSize <= 0 || size.int64Value == expectedSize
    }
}

/// Collapses the download delegate's firehose into one callback per percent.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let emit: @Sendable (ParakeetDownloadProgress) -> Void
    private var lastPercent = -1

    init(emit: @escaping @Sendable (ParakeetDownloadProgress) -> Void) {
        self.emit = emit
    }

    func send(_ progress: ParakeetDownloadProgress, force: Bool = false) {
        lock.lock()
        let percent = progress.percent
        let shouldEmit = force || percent != lastPercent
        if shouldEmit {
            lastPercent = percent
        }
        lock.unlock()

        guard shouldEmit else { return }
        emit(progress)
    }
}

/// Bridges `URLSessionDownloadTask` progress and completion into async/await.
/// The temp file must be moved inside `didFinishDownloadingTo`, before the
/// delegate callback returns, so the move happens here rather than in the
/// awaiting task.
private final class FileDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onBytesWritten: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var pendingResult: Result<Void, Error>?
    private var hasFinished = false

    init(destination: URL, onBytesWritten: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.onBytesWritten = onBytesWritten
    }

    func attach(continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let pendingResult {
            lock.unlock()
            continuation.resume(with: pendingResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite _: Int64
    ) {
        onBytesWritten(totalBytesWritten)
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "HuggingFace returned HTTP \(http.statusCode).",
            ])))
            return
        }

        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            finish(.success(()))
            return
        }
        finish(.failure(error))
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !hasFinished else {
            lock.unlock()
            return
        }
        hasFinished = true

        guard let continuation else {
            pendingResult = result
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}
