import Foundation

// MARK: - KnowledgeSource

/// Where a knowledge-base entry came from.
public enum KnowledgeSource: String, Codable, Sendable, CaseIterable {
    case paste
    case note
    case todo
    case chat
    case screenshotOCR = "screenshot_ocr"
}

// MARK: - KnowledgeEntry

/// A single unit of the knowledge base: one thing the user said (or one OCR'd screenshot).
/// Stored one-per-line in `entries.jsonl`; embeddings live in a separate sidecar.
public struct KnowledgeEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    /// ISO-8601 timestamp of when the entry was captured.
    public let ts: String
    public let source: KnowledgeSource
    public let text: String
    /// `yyyy-MM-dd` of the daily note file this entry belongs to, when applicable.
    public let dayStamp: String?
    /// Absolute path to the screenshot this OCR text came from, when applicable.
    public let imagePath: String?

    public init(
        id: String = UUID().uuidString,
        ts: String,
        source: KnowledgeSource,
        text: String,
        dayStamp: String? = nil,
        imagePath: String? = nil
    ) {
        self.id = id
        self.ts = ts
        self.source = source
        self.text = text
        self.dayStamp = dayStamp
        self.imagePath = imagePath
    }

    public var date: Date? {
        (try? Date(ts, strategy: Self.isoStyle)) ?? (try? Date(ts, strategy: .iso8601))
    }

    public static func timestamp(for date: Date = .now) -> String {
        date.formatted(isoStyle)
    }

    private static let isoStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

// MARK: - EmbeddingRecord

/// One line of `embeddings.jsonl`: points into `vectors.bin`.
public struct EmbeddingRecord: Codable, Sendable, Equatable {
    public let id: String
    /// Byte offset into `vectors.bin` where this entry's vector starts.
    public let offset: UInt64
    /// Number of Float32 components.
    public let dim: Int
    /// Identifier of the embedding model that produced the vector.
    public let model: String

    public init(id: String, offset: UInt64, dim: Int, model: String) {
        self.id = id
        self.offset = offset
        self.dim = dim
        self.model = model
    }
}

// MARK: - KnowledgeStats

public struct KnowledgeStats: Sendable, Equatable {
    public let entryCount: Int
    public let embeddedCount: Int
    public var backlogCount: Int { max(0, entryCount - embeddedCount) }

    public init(entryCount: Int, embeddedCount: Int) {
        self.entryCount = entryCount
        self.embeddedCount = embeddedCount
    }
}

// MARK: - SearchHit

public struct KnowledgeSearchHit: Sendable, Equatable {
    public let entry: KnowledgeEntry
    /// Cosine similarity in [-1, 1] for vector search; substring-match heuristic otherwise.
    public let score: Float

    public init(entry: KnowledgeEntry, score: Float) {
        self.entry = entry
        self.score = score
    }
}
