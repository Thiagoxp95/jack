import Foundation
import NaturalLanguage

// MARK: - EmbeddingService

/// On-device sentence embeddings via `NLContextualEmbedding` (macOS 14+).
///
/// The underlying model assets are downloaded once by the system (needs network);
/// until they are present, `embed(_:)` returns nil and callers store text
/// unembedded for later backfill. The non-Sendable `NLContextualEmbedding`
/// instance is confined to this actor.
public actor EmbeddingService {
    public enum AssetState: String, Sendable {
        case available
        case notAvailable
        case notLoaded
    }

    private let embedding: NLContextualEmbedding?
    private var isLoaded = false

    /// When true, never trigger an asset download (headless MCP process).
    private let allowsAssetRequests: Bool

    public init(allowsAssetRequests: Bool = true) {
        self.allowsAssetRequests = allowsAssetRequests
        // Latin-script model covers English + most European languages.
        self.embedding = NLContextualEmbedding(script: .latin)
    }

    /// Stable identifier stored alongside each vector so a model change can trigger re-embeds.
    public var modelIdentifier: String {
        embedding.map { "\($0.modelIdentifier)-r\($0.revision)" } ?? "unavailable"
    }

    public var dimension: Int {
        embedding?.dimension ?? 0
    }

    public func assetState() -> AssetState {
        guard let embedding else { return .notAvailable }
        return embedding.hasAvailableAssets ? .available : .notAvailable
    }

    /// One-time system asset download. Safe to call repeatedly.
    @discardableResult
    public func downloadAssetsIfNeeded() async -> Bool {
        guard let embedding else { return false }
        if embedding.hasAvailableAssets { return true }
        guard allowsAssetRequests else { return false }
        do {
            let result = try await embedding.requestAssets()
            return result == .available
        } catch {
            return false
        }
    }

    /// Mean-pooled sentence vector, or nil if assets aren't available.
    public func embed(_ text: String) -> [Float]? {
        guard let embedding, embedding.hasAvailableAssets else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        do {
            if !isLoaded {
                try embedding.load()
                isLoaded = true
            }
            // NLContextualEmbedding handles long text, but cap input defensively.
            let input = String(trimmed.prefix(8_000))
            let result = try embedding.embeddingResult(for: input, language: nil)

            let dim = embedding.dimension
            var sum = [Double](repeating: 0, count: dim)
            var tokenCount = 0
            result.enumerateTokenVectors(in: input.startIndex..<input.endIndex) { vector, _ in
                guard vector.count == dim else { return true }
                for i in 0..<dim { sum[i] += vector[i] }
                tokenCount += 1
                return true
            }
            guard tokenCount > 0 else { return nil }
            let inverse = 1 / Double(tokenCount)
            return sum.map { Float($0 * inverse) }
        } catch {
            return nil
        }
    }
}
