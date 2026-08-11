import FluidAudio
import XCTest
@testable import JackApp

/// These hit huggingface.co: the manifest is what makes the percentage
/// trustworthy, so it is checked against the live repo rather than a fixture.
final class ParakeetModelDownloaderTests: XCTestCase {
    func testManifestCoversExactlyTheFilesFluidAudioNeeds() async throws {
        let manifest = try await ParakeetModelDownloader().manifest(version: .v3)
        let paths = manifest.map(\.path)

        for model in ModelNames.ASR.requiredModels {
            XCTAssertTrue(
                paths.contains { $0.hasPrefix("\(model)/") },
                "manifest is missing \(model)"
            )
        }

        XCTAssertTrue(paths.contains(ModelNames.ASR.vocabularyFile), "vocabulary must be fetched")

        // The repo also ships int4 encoders, mlpackages and alternate joints —
        // pulling those would inflate a 460 MB download to 3 GB.
        for path in paths {
            let root = String(path.split(separator: "/").first ?? "")
            let isRequiredModel = ModelNames.ASR.requiredModels.contains(root)
            let isRootMetadata = !path.contains("/") && (path.hasSuffix(".json") || path.hasSuffix(".txt"))
            XCTAssertTrue(isRequiredModel || isRootMetadata, "unexpected file in manifest: \(path)")
        }

        let total = manifest.reduce(Int64(0)) { $0 + $1.byteSize }
        XCTAssertGreaterThan(total, 400_000_000, "total looks too small to be the real weights")
        XCTAssertLessThan(total, 700_000_000, "total suggests optional variants leaked in")
    }

    func testDownloadFileWritesTheFileAndReportsBytes() async throws {
        let downloader = ParakeetModelDownloader()
        let manifest = try await downloader.manifest(version: .v3)
        let vocabulary = try XCTUnwrap(manifest.first { $0.path == ModelNames.ASR.vocabularyFile })

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jack-downloader-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent(vocabulary.path)
        let observed = ByteObserver()

        try await downloader.downloadFile(
            remotePath: ParakeetModelDownloader.remotePath(for: .v3),
            file: .init(path: vocabulary.path, byteSize: vocabulary.byteSize, destination: destination),
            onBytesWritten: { observed.record($0) }
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual(attributes[.size] as? Int64, vocabulary.byteSize)
        XCTAssertEqual(observed.maximum, vocabulary.byteSize, "progress must reach the file's full size")
    }
}

private final class ByteObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var highWaterMark: Int64 = 0

    func record(_ bytes: Int64) {
        lock.lock()
        highWaterMark = max(highWaterMark, bytes)
        lock.unlock()
    }

    var maximum: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return highWaterMark
    }
}
