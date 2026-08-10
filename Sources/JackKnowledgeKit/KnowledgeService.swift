import Foundation

// MARK: - KnowledgeService

/// Facade over the store + embedding service — the only type the app and MCP
/// server need to talk to.
public final class KnowledgeService: Sendable {
    public let store: KnowledgeStore
    public let embeddings: EmbeddingService

    public init(
        directoryURL: URL = KnowledgeStore.defaultDirectoryURL(),
        readOnly: Bool = false,
        allowsAssetRequests: Bool = true
    ) {
        self.store = KnowledgeStore(directoryURL: directoryURL, readOnly: readOnly)
        self.embeddings = EmbeddingService(allowsAssetRequests: allowsAssetRequests)
    }

    // MARK: - Ingestion

    /// Store one utterance/OCR result. Embeds inline when model assets are
    /// available; otherwise the entry is stored unembedded for later backfill.
    @discardableResult
    public func ingest(
        text: String,
        source: KnowledgeSource,
        date: Date = .now,
        dayStamp: String? = nil,
        imagePath: String? = nil
    ) async -> KnowledgeEntry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let entry = KnowledgeEntry(
            ts: KnowledgeEntry.timestamp(for: date),
            source: source,
            text: trimmed,
            dayStamp: dayStamp,
            imagePath: imagePath
        )
        let vector = await embeddings.embed(trimmed)
        let model = vector == nil ? nil : await embeddings.modelIdentifier
        do {
            try await store.append(entry, vector: vector, model: model)
            return entry
        } catch {
            NSLog("[JackKnowledge] Failed to append entry: %@", String(describing: error))
            return nil
        }
    }

    /// Embed every entry that has no vector for the current model.
    /// Returns the number of entries embedded.
    @discardableResult
    public func backfillMissingEmbeddings() async -> Int {
        guard await embeddings.assetState() == .available else { return 0 }
        let model = await embeddings.modelIdentifier
        let backlog = await store.unembeddedEntries(model: model)
        var embedded = 0
        for entry in backlog {
            guard let vector = await embeddings.embed(entry.text) else { continue }
            do {
                try await store.attachEmbedding(id: entry.id, vector: vector, model: model)
                embedded += 1
            } catch {
                NSLog("[JackKnowledge] Backfill failed for %@: %@", entry.id, String(describing: error))
            }
        }
        return embedded
    }

    // MARK: - Queries

    public struct SearchResult: Sendable {
        public let hits: [KnowledgeSearchHit]
        /// False when the store fell back to substring matching (no embedding assets).
        public let usedVectorSearch: Bool
    }

    public func search(query: String, limit: Int = 10, source: KnowledgeSource? = nil) async -> SearchResult {
        await store.reloadIfChanged()
        if let vector = await embeddings.embed(query) {
            let hits = await store.search(vector: vector, limit: limit, source: source)
            // If nothing is embedded yet, vectors won't match anything — fall through.
            if !hits.isEmpty {
                return SearchResult(hits: hits, usedVectorSearch: true)
            }
        }
        let hits = await store.search(text: query, limit: limit, source: source)
        return SearchResult(hits: hits, usedVectorSearch: false)
    }

    public func recent(limit: Int = 20, source: KnowledgeSource? = nil, since: Date? = nil) async -> [KnowledgeEntry] {
        await store.reloadIfChanged()
        return await store.recent(limit: limit, source: source, since: since)
    }

    public func stats() async -> KnowledgeStats {
        await store.reloadIfChanged()
        return await store.stats()
    }
}
