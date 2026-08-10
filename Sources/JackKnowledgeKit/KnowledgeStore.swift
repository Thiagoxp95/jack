import Foundation

// MARK: - KnowledgeStore

/// On-disk knowledge base: append-only JSONL entries plus a binary vector sidecar.
///
/// Layout inside the store directory:
///   - `entries.jsonl`     one `KnowledgeEntry` per line (text + metadata, no vectors)
///   - `vectors.bin`       raw little-endian Float32, `dim` floats per embedded entry
///   - `embeddings.jsonl`  one `EmbeddingRecord` per line pointing into `vectors.bin`
///   - `.lock`             flock target serializing writers
///
/// Single-writer design: the app writes, the MCP CLI opens the store read-only and
/// reloads when file sizes/mtimes change. Readers tolerate a torn final line (no
/// trailing newline) and embedding records whose offsets fall past the end of
/// `vectors.bin` — both simply ignored until the writer finishes.
public actor KnowledgeStore {
    public enum StoreError: Error {
        case readOnly
        case lockFailed
    }

    public nonisolated let directoryURL: URL
    public nonisolated let readOnly: Bool

    private let fileManager = FileManager.default

    // In-memory state
    private var entries: [KnowledgeEntry] = []
    private var entryIndexByID: [String: Int] = [:]
    /// Normalized vectors keyed by entry id.
    private var vectors: [String: [Float]] = [:]
    private var embeddedModelByID: [String: String] = [:]
    private var loaded = false

    // Change detection for read-only reloads
    private var lastEntriesSize: UInt64 = 0
    private var lastEmbeddingsSize: UInt64 = 0

    private var entriesURL: URL { directoryURL.appendingPathComponent("entries.jsonl") }
    private var vectorsURL: URL { directoryURL.appendingPathComponent("vectors.bin") }
    private var embeddingsURL: URL { directoryURL.appendingPathComponent("embeddings.jsonl") }
    private var lockURL: URL { directoryURL.appendingPathComponent(".lock") }

    public init(directoryURL: URL = KnowledgeStore.defaultDirectoryURL(), readOnly: Bool = false) {
        self.directoryURL = directoryURL
        self.readOnly = readOnly
    }

    public static func defaultDirectoryURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["JACK_KNOWLEDGE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jack/knowledge", isDirectory: true)
    }

    // MARK: - Loading

    public func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        reloadFromDisk()
    }

    /// Re-read the files if they grew since the last load (cheap stat check).
    public func reloadIfChanged() {
        guard loaded else {
            ensureLoaded()
            return
        }
        let entriesSize = fileSize(entriesURL)
        let embeddingsSize = fileSize(embeddingsURL)
        if entriesSize != lastEntriesSize || embeddingsSize != lastEmbeddingsSize {
            reloadFromDisk()
        }
    }

    private func reloadFromDisk() {
        entries = []
        entryIndexByID = [:]
        vectors = [:]
        embeddedModelByID = [:]

        let decoder = JSONDecoder()

        for line in completeLines(of: entriesURL) {
            guard let entry = try? decoder.decode(KnowledgeEntry.self, from: Data(line.utf8)) else { continue }
            // Last write wins on duplicate ids (shouldn't happen, but be safe).
            if let existing = entryIndexByID[entry.id] {
                entries[existing] = entry
            } else {
                entryIndexByID[entry.id] = entries.count
                entries.append(entry)
            }
        }

        let vectorData = (try? Data(contentsOf: vectorsURL)) ?? Data()
        for line in completeLines(of: embeddingsURL) {
            guard let record = try? decoder.decode(EmbeddingRecord.self, from: Data(line.utf8)) else { continue }
            let byteCount = record.dim * MemoryLayout<Float>.size
            let end = Int(record.offset) + byteCount
            guard record.dim > 0, end <= vectorData.count else { continue } // dangling reference
            var vector = [Float](repeating: 0, count: record.dim)
            _ = vector.withUnsafeMutableBytes { dest in
                vectorData.copyBytes(to: dest, from: Int(record.offset)..<end)
            }
            vectors[record.id] = Self.normalized(vector)
            embeddedModelByID[record.id] = record.model
        }

        lastEntriesSize = fileSize(entriesURL)
        lastEmbeddingsSize = fileSize(embeddingsURL)
    }

    /// All full (newline-terminated) lines of a JSONL file; a torn final line is dropped.
    private func completeLines(of url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        var usable = data
        if data.last != UInt8(ascii: "\n"), let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
            usable = data.prefix(through: lastNewline)
        } else if data.last != UInt8(ascii: "\n") {
            return [] // single torn line, nothing complete yet
        }
        guard let text = String(data: usable, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func fileSize(_ url: URL) -> UInt64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    // MARK: - Writing

    /// Append an entry, optionally with its embedding, as one locked transaction.
    /// Write order (vectors → embeddings index → entry) guarantees readers never
    /// observe an entry or index line that references missing bytes.
    public func append(_ entry: KnowledgeEntry, vector: [Float]?, model: String?) throws {
        guard !readOnly else { throw StoreError.readOnly }
        ensureLoaded()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let lock = try acquireLock()
        defer { releaseLock(lock) }

        if let vector, let model, !vector.isEmpty {
            try appendVectorLocked(id: entry.id, vector: vector, model: model)
        }

        let encoder = JSONEncoder()
        var line = try encoder.encode(entry)
        line.append(UInt8(ascii: "\n"))
        try appendData(line, to: entriesURL)

        if let existing = entryIndexByID[entry.id] {
            entries[existing] = entry
        } else {
            entryIndexByID[entry.id] = entries.count
            entries.append(entry)
        }
        lastEntriesSize = fileSize(entriesURL)
    }

    /// Attach an embedding to an already-stored entry (backfill path).
    public func attachEmbedding(id: String, vector: [Float], model: String) throws {
        guard !readOnly else { throw StoreError.readOnly }
        ensureLoaded()
        guard !vector.isEmpty else { return }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let lock = try acquireLock()
        defer { releaseLock(lock) }
        try appendVectorLocked(id: id, vector: vector, model: model)
    }

    private func appendVectorLocked(id: String, vector: [Float], model: String) throws {
        if !fileManager.fileExists(atPath: vectorsURL.path) {
            fileManager.createFile(atPath: vectorsURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: vectorsURL)
        defer { try? handle.close() }
        let offset = try handle.seekToEnd()
        var little = vector.map { $0.bitPattern.littleEndian }
        let bytes = little.withUnsafeMutableBytes { Data($0) }
        try handle.write(contentsOf: bytes)
        try handle.synchronize() // vectors durable before the index references them

        let record = EmbeddingRecord(id: id, offset: offset, dim: vector.count, model: model)
        var line = try JSONEncoder().encode(record)
        line.append(UInt8(ascii: "\n"))
        try appendData(line, to: embeddingsURL)

        vectors[id] = Self.normalized(vector)
        embeddedModelByID[id] = model
        lastEmbeddingsSize = fileSize(embeddingsURL)
    }

    private func appendData(_ data: Data, to url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    // MARK: - Locking (flock on a sidecar file)

    private func acquireLock() throws -> Int32 {
        let fd = open(lockURL.path, O_CREAT | O_WRONLY, 0o644)
        guard fd >= 0 else { throw StoreError.lockFailed }
        guard flock(fd, LOCK_EX) == 0 else {
            close(fd)
            throw StoreError.lockFailed
        }
        return fd
    }

    private func releaseLock(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }

    // MARK: - Queries

    public func stats() -> KnowledgeStats {
        ensureLoaded()
        return KnowledgeStats(entryCount: entries.count, embeddedCount: vectors.count)
    }

    public func allEntries() -> [KnowledgeEntry] {
        ensureLoaded()
        return entries
    }

    /// Entries that have no embedding yet (or were embedded by a different model).
    public func unembeddedEntries(model: String) -> [KnowledgeEntry] {
        ensureLoaded()
        return entries.filter { embeddedModelByID[$0.id] != model }
    }

    public func recent(limit: Int, source: KnowledgeSource?, since: Date?) -> [KnowledgeEntry] {
        ensureLoaded()
        var result = entries
        if let source { result = result.filter { $0.source == source } }
        if let since { result = result.filter { ($0.date ?? .distantPast) >= since } }
        result.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return Array(result.prefix(max(0, limit)))
    }

    /// Cosine search against a (not necessarily normalized) query vector.
    public func search(vector query: [Float], limit: Int, source: KnowledgeSource?) -> [KnowledgeSearchHit] {
        ensureLoaded()
        let normalizedQuery = Self.normalized(query)
        guard !normalizedQuery.isEmpty else { return [] }

        var hits: [KnowledgeSearchHit] = []
        for entry in entries {
            if let source, entry.source != source { continue }
            guard let vector = vectors[entry.id], vector.count == normalizedQuery.count else { continue }
            var dot: Float = 0
            for i in 0..<vector.count { dot += vector[i] * normalizedQuery[i] }
            hits.append(KnowledgeSearchHit(entry: entry, score: dot))
        }
        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(max(0, limit)))
    }

    /// Case-insensitive substring fallback when no embedding model is available.
    public func search(text query: String, limit: Int, source: KnowledgeSource?) -> [KnowledgeSearchHit] {
        ensureLoaded()
        let needle = query.lowercased()
        let terms = needle.split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }

        var hits: [KnowledgeSearchHit] = []
        for entry in entries {
            if let source, entry.source != source { continue }
            let haystack = entry.text.lowercased()
            let matched = terms.filter { haystack.contains($0) }.count
            guard matched > 0 else { continue }
            hits.append(KnowledgeSearchHit(entry: entry, score: Float(matched) / Float(terms.count)))
        }
        hits.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return ($0.entry.date ?? .distantPast) > ($1.entry.date ?? .distantPast)
        }
        return Array(hits.prefix(max(0, limit)))
    }

    // MARK: - Math

    static func normalized(_ vector: [Float]) -> [Float] {
        var sum: Float = 0
        for value in vector { sum += value * value }
        guard sum > 0 else { return [] }
        let inverse = 1 / sum.squareRoot()
        return vector.map { $0 * inverse }
    }
}
