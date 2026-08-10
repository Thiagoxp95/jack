import Foundation
import Testing
@testable import JackKnowledgeKit

// MARK: - Helpers

private func makeTempStoreDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("jack-knowledge-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func entry(_ text: String, source: KnowledgeSource = .paste, date: Date = .now) -> KnowledgeEntry {
    KnowledgeEntry(ts: KnowledgeEntry.timestamp(for: date), source: source, text: text)
}

// MARK: - Store tests

@Suite("KnowledgeStore")
struct KnowledgeStoreTests {

    @Test("append then reload roundtrip")
    func appendReloadRoundtrip() async throws {
        let dir = makeTempStoreDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = KnowledgeStore(directoryURL: dir)
        let first = entry("hello world", source: .note)
        let second = entry("vector data", source: .paste)
        try await store.append(first, vector: [1, 0, 0], model: "test-model")
        try await store.append(second, vector: [0, 1, 0], model: "test-model")

        // Fresh instance reads from disk.
        let reader = KnowledgeStore(directoryURL: dir, readOnly: true)
        let entries = await reader.allEntries()
        #expect(entries == [first, second])
        let stats = await reader.stats()
        #expect(stats.entryCount == 2)
        #expect(stats.embeddedCount == 2)
    }

    @Test("torn final line is ignored")
    func tornFinalLine() async throws {
        let dir = makeTempStoreDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = KnowledgeStore(directoryURL: dir)
        try await store.append(entry("complete line"), vector: nil, model: nil)

        // Simulate a torn write: partial JSON with no trailing newline.
        let entriesURL = dir.appendingPathComponent("entries.jsonl")
        let handle = try FileHandle(forWritingTo: entriesURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"id":"torn","ts":"2026-"#.utf8))
        try handle.close()

        let reader = KnowledgeStore(directoryURL: dir, readOnly: true)
        let entries = await reader.allEntries()
        #expect(entries.count == 1)
        #expect(entries[0].text == "complete line")
    }

    @Test("dangling vector offset is ignored")
    func danglingVectorOffset() async throws {
        let dir = makeTempStoreDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = KnowledgeStore(directoryURL: dir)
        try await store.append(entry("embedded"), vector: [1, 2, 3], model: "m")

        // Hand-write an embedding record pointing past the end of vectors.bin.
        let record = EmbeddingRecord(id: "ghost", offset: 10_000, dim: 3, model: "m")
        var line = try JSONEncoder().encode(record)
        line.append(UInt8(ascii: "\n"))
        let embeddingsURL = dir.appendingPathComponent("embeddings.jsonl")
        let handle = try FileHandle(forWritingTo: embeddingsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.close()

        let reader = KnowledgeStore(directoryURL: dir, readOnly: true)
        let stats = await reader.stats()
        #expect(stats.embeddedCount == 1)
    }

    @Test("cosine search orders by similarity")
    func cosineOrdering() async throws {
        let dir = makeTempStoreDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = KnowledgeStore(directoryURL: dir)
        let cats = entry("cats")
        let dogs = entry("dogs")
        let cars = entry("cars")
        try await store.append(cats, vector: [1, 0.1, 0], model: "m")
        try await store.append(dogs, vector: [0.9, 0.5, 0], model: "m")
        try await store.append(cars, vector: [0, 0, 1], model: "m")

        let hits = await store.search(vector: [1, 0, 0], limit: 3, source: nil)
        #expect(hits.map(\.entry.id) == [cats.id, dogs.id, cars.id])
        #expect(hits[0].score > hits[1].score)
        #expect(hits[1].score > hits[2].score)
    }

    @Test("substring fallback matches and ranks")
    func substringFallback() async throws {
        let dir = makeTempStoreDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = KnowledgeStore(directoryURL: dir)
        try await store.append(entry("remember to buy milk and eggs"), vector: nil, model: nil)
        try await store.append(entry("the meeting is at noon"), vector: nil, model: nil)

        let hits = await store.search(text: "buy milk", limit: 5, source: nil)
        #expect(hits.count == 1)
        #expect(hits[0].entry.text.contains("milk"))
    }

    @Test("backfill attaches embeddings to unembedded entries")
    func backfillAttach() async throws {
        let dir = makeTempStoreDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = KnowledgeStore(directoryURL: dir)
        let unembedded = entry("no vector yet")
        try await store.append(unembedded, vector: nil, model: nil)

        var backlog = await store.unembeddedEntries(model: "m")
        #expect(backlog.map(\.id) == [unembedded.id])

        try await store.attachEmbedding(id: unembedded.id, vector: [0.5, 0.5], model: "m")
        backlog = await store.unembeddedEntries(model: "m")
        #expect(backlog.isEmpty)

        // And it persists.
        let reader = KnowledgeStore(directoryURL: dir, readOnly: true)
        let stats = await reader.stats()
        #expect(stats.embeddedCount == 1)
    }

    @Test("recent filters by source and sorts newest first")
    func recentFilter() async throws {
        let dir = makeTempStoreDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = KnowledgeStore(directoryURL: dir)
        let old = entry("old note", source: .note, date: Date(timeIntervalSinceNow: -3600))
        let new = entry("new note", source: .note, date: .now)
        let pasted = entry("pasted", source: .paste, date: .now)
        try await store.append(old, vector: nil, model: nil)
        try await store.append(new, vector: nil, model: nil)
        try await store.append(pasted, vector: nil, model: nil)

        let notes = await store.recent(limit: 10, source: .note, since: nil)
        #expect(notes.map(\.id) == [new.id, old.id])

        let recentOnly = await store.recent(limit: 10, source: nil, since: Date(timeIntervalSinceNow: -60))
        #expect(recentOnly.count == 2)
    }

    @Test("readOnly store rejects writes")
    func readOnlyRejects() async throws {
        let dir = makeTempStoreDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = KnowledgeStore(directoryURL: dir, readOnly: true)
        await #expect(throws: KnowledgeStore.StoreError.self) {
            try await store.append(entry("nope"), vector: nil, model: nil)
        }
    }

    @Test("reader picks up appends via reloadIfChanged")
    func readerReload() async throws {
        let dir = makeTempStoreDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = KnowledgeStore(directoryURL: dir)
        try await writer.append(entry("first"), vector: nil, model: nil)

        let reader = KnowledgeStore(directoryURL: dir, readOnly: true)
        #expect(await reader.allEntries().count == 1)

        try await writer.append(entry("second"), vector: nil, model: nil)
        await reader.reloadIfChanged()
        #expect(await reader.allEntries().count == 2)
    }
}
