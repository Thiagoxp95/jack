import AppKit
import Foundation
import JackKnowledgeKit

// MARK: - Transcript model

/// Who said a line. The microphone track is always you; everything that came
/// out of the speakers is somebody else, labelled with whatever Muse called
/// them inside that one chunk.
enum MeetingSpeaker: Sendable, Equatable {
    case you
    case other(String?)

    var label: String {
        switch self {
        case .you:
            return "You"
        case let .other(name):
            guard let name, !name.isEmpty else { return "Them" }
            // Muse hands back bare labels like "A" or "1"; spell them out so a
            // transcript line reads as a name rather than as a stray letter.
            if name.count <= 2 { return "Speaker \(name)" }
            return name
        }
    }
}

struct MeetingTurn: Sendable, Equatable {
    let speaker: MeetingSpeaker
    let text: String
    /// Seconds from the start of the meeting, when the transcriber reported it.
    let start: TimeInterval?

    var timestampLabel: String? {
        guard let start else { return nil }
        let total = Int(start.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    var transcriptLine: String {
        guard let timestampLabel else { return "\(speaker.label): \(text)" }
        return "[\(timestampLabel)] \(speaker.label): \(text)"
    }
}

// MARK: - MeetingController

/// Meeting mode: records both sides of a call, transcribes it in chunks as it
/// runs, and files the result in the knowledge base with an LLM summary.
///
/// Chunks are transcribed the moment they close rather than at the end, so
/// stopping an hour-long meeting costs one chunk's upload, not sixty minutes of
/// it. Each chunk's two tracks go up as separate diarization requests — see
/// `MeetingAudioCapture` for why they are kept apart.
@MainActor
final class MeetingController: ObservableObject {

    enum Phase: Equatable {
        case idle
        /// Recording; chunks are already being transcribed in the background.
        case recording
        /// Stopped, waiting on the outstanding chunk transcriptions.
        case transcribing
        case summarizing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    /// Markdown summary of the most recent meeting, when one was produced.
    @Published private(set) var lastSummary: String?
    @Published private(set) var lastTranscript: String?
    @Published private(set) var lastError: String?

    var isActive: Bool { phase != .idle }

    /// Status-line text for the settings window and the menu bar.
    var onStatus: ((String) -> Void)?
    /// Floating confirmation near the pointer: symbol, message, tint.
    var onToast: ((String, String, NSColor) -> Void)?

    /// Read at call time rather than captured, so changing a key or model in
    /// settings takes effect on the next meeting without rewiring anything.
    var metaApiKey: () -> String = { "" }
    var openRouterApiKey: () -> String = { "" }
    var summaryModelId: () -> String = { OpenRouterClient.defaultCleanupModel }

    private let knowledge: KnowledgeService
    private var capture = MeetingAudioCapture()

    /// Chunk index → its in-flight (or finished) transcription.
    private var chunkTasks: [Int: Task<[MeetingTurn], Never>] = [:]
    private var title: String = ""
    private var startedAt: Date?
    private var tickTimer: Timer?

    init(knowledge: KnowledgeService) {
        self.knowledge = knowledge
    }

    // MARK: - Control

    func toggle() {
        if isActive {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard phase == .idle else { return }

        guard !metaApiKey().isEmpty else {
            report(error: "Meeting mode needs a Meta API key — add one in Settings → Transcription Model.")
            return
        }

        lastError = nil
        lastSummary = nil
        lastTranscript = nil
        chunkTasks = [:]
        capture = MeetingAudioCapture()
        capture.onChunkReady = { [weak self] chunk in
            self?.scheduleTranscription(of: chunk)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await capture.start()
                startedAt = Date()
                title = Self.makeTitle(startedAt: startedAt ?? Date())
                phase = .recording
                startTicking()
                onToast?("person.wave.2.fill", "Meeting recording", .systemGreen)
                onStatus?("Meeting mode recording — \(title)")
            } catch {
                await capture.discard()
                report(error: error.localizedDescription)
            }
        }
    }

    func stop() {
        guard phase == .recording else { return }
        phase = .transcribing
        stopTicking()
        onStatus?("Transcribing meeting…")
        onToast?("waveform", "Transcribing meeting…", .controlAccentColor)

        Task { @MainActor [weak self] in
            guard let self else { return }
            await finish()
        }
    }

    /// Throws the recording away without transcribing it.
    func cancel() {
        guard phase == .recording else { return }
        for task in chunkTasks.values { task.cancel() }
        chunkTasks = [:]
        phase = .idle
        stopTicking()

        Task { @MainActor [weak self] in
            guard let self else { return }
            await capture.discard()
            onStatus?("Meeting discarded.")
        }
    }

    // MARK: - Pipeline

    private func scheduleTranscription(of chunk: MeetingAudioCapture.Chunk) {
        let apiKey = metaApiKey()
        chunkTasks[chunk.index] = Task.detached(priority: .utility) {
            await Self.transcribe(chunk: chunk, apiKey: apiKey)
        }
    }

    private func finish() async {
        // The tail of the meeting is whatever had not rotated yet.
        if let final = await capture.stop() {
            scheduleTranscription(of: final)
        }

        var turns: [MeetingTurn] = []
        for index in chunkTasks.keys.sorted() {
            guard let task = chunkTasks[index] else { continue }
            turns.append(contentsOf: await task.value)
        }
        chunkTasks = [:]
        await capture.discard()

        guard !turns.isEmpty else {
            phase = .idle
            report(error: "Nothing was transcribed — no audio made it into the meeting recording.")
            return
        }

        let transcript = turns.map(\.transcriptLine).joined(separator: "\n")
        lastTranscript = transcript
        let meetingTitle = title

        await ingestTranscript(turns: turns, title: meetingTitle)

        phase = .summarizing
        onStatus?("Summarizing meeting…")
        let summary = await summarize(transcript: transcript, title: meetingTitle)

        if let summary {
            lastSummary = summary
            _ = await ingest(text: summary, source: .meetingSummary, title: meetingTitle)
        }

        phase = .idle
        let duration = elapsedLabel()
        elapsed = 0
        onStatus?("Meeting saved to knowledge base — \(meetingTitle) (\(duration))")
        onToast?("brain.head.profile", summary == nil ? "Meeting saved" : "Meeting saved + summarized", .systemGreen)
    }

    /// One chunk: both tracks, in parallel, merged back into wall-clock order.
    nonisolated private static func transcribe(
        chunk: MeetingAudioCapture.Chunk,
        apiKey: String
    ) async -> [MeetingTurn] {
        async let mic = turns(at: chunk.micURL, apiKey: apiKey)
        async let system = turns(at: chunk.systemURL, apiKey: apiKey)

        let micTurns = await mic.map {
            MeetingTurn(speaker: .you, text: $0.text, start: absolute($0.start, in: chunk))
        }
        let systemTurns = await system.map {
            MeetingTurn(speaker: .other($0.speaker), text: $0.text, start: absolute($0.start, in: chunk))
        }

        for url in [chunk.micURL, chunk.systemURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }

        // Without timestamps there is nothing to interleave on, so each side
        // stays in its own run rather than being shuffled arbitrarily.
        let merged = micTurns + systemTurns
        guard merged.allSatisfy({ $0.start != nil }) else { return merged }
        return merged.sorted { ($0.start ?? 0) < ($1.start ?? 0) }
    }

    nonisolated private static func turns(at url: URL?, apiKey: String) async -> [MetaVoiceClient.Turn] {
        guard let url else { return [] }
        do {
            return try await MetaVoiceClient.diarize(audioFileURL: url, apiKey: apiKey)
        } catch {
            let summary = (error as? MetaVoiceClient.Failure)?.userFacingSummary ?? error.localizedDescription
            NSLog("[Silky] Meeting chunk %@ failed: %@", url.lastPathComponent, summary)
            return []
        }
    }

    nonisolated private static func absolute(_ start: TimeInterval?, in chunk: MeetingAudioCapture.Chunk) -> TimeInterval? {
        guard let start else { return nil }
        return chunk.startOffset + start
    }

    // MARK: - Knowledge base

    /// Filed in blocks rather than as one wall of text: an hour-long transcript
    /// embeds to a single vector that matches nothing in particular, whereas a
    /// couple of minutes of conversation is the size a search actually wants.
    private func ingestTranscript(turns: [MeetingTurn], title: String) async {
        let blocks = Self.groupIntoBlocks(turns)
        for block in blocks {
            _ = await ingest(text: block, source: .meeting, title: title)
        }
    }

    nonisolated private static let blockCharacterBudget = 1_200

    nonisolated static func groupIntoBlocks(_ turns: [MeetingTurn]) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        var length = 0

        for turn in turns {
            let line = turn.transcriptLine
            if length > 0, length + line.count > blockCharacterBudget {
                blocks.append(current.joined(separator: "\n"))
                current = []
                length = 0
            }
            current.append(line)
            length += line.count + 1
        }
        if !current.isEmpty {
            blocks.append(current.joined(separator: "\n"))
        }
        return blocks
    }

    @discardableResult
    private func ingest(text: String, source: KnowledgeSource, title: String) async -> KnowledgeEntry? {
        let service = knowledge
        return await Task.detached(priority: .utility) {
            await service.ingest(text: text, source: source, sessionTitle: title)
        }.value
    }

    // MARK: - Summary

    private func summarize(transcript: String, title: String) async -> String? {
        let apiKey = openRouterApiKey()
        guard !apiKey.isEmpty else {
            NSLog("[Silky] Meeting summary skipped: no OpenRouter key")
            return nil
        }

        // Generous but bounded: past this, the meeting is long enough that the
        // tail matters more than a complete verbatim record.
        let bounded = transcript.count > 400_000
            ? String(transcript.suffix(400_000))
            : transcript

        do {
            let summary = try await OpenRouterClient.complete(
                model: summaryModelId(),
                messages: [
                    .system(Self.summaryPrompt),
                    .user("Meeting: \(title)\n\nTranscript:\n\(bounded)"),
                ],
                apiKey: apiKey,
                maxTokens: 1_500,
                timeout: 180
            )
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            let summary = (error as? OpenRouterClient.Failure)?.userFacingSummary ?? error.localizedDescription
            NSLog("[Silky] Meeting summary failed: %@", summary)
            onStatus?("Meeting saved, but the summary failed: \(summary)")
            return nil
        }
    }

    /// "You" is the microphone track, so the model can be told outright who
    /// that is rather than having to guess an owner for each action item.
    static let summaryPrompt = """
    You summarize meeting transcripts. The transcript is speaker-labelled: \
    "You" is the person whose Mac recorded the meeting; every other label is \
    somebody else on the call. Labels may restart within a long meeting, so \
    treat them as hints, not identities.

    Reply with GitHub-flavored Markdown and nothing else, in this shape:

    ## Summary
    3-6 bullets covering what was discussed and why it mattered.

    ## Decisions
    Decisions that were actually made. Omit this heading entirely if none were.

    ## Action items
    One bullet per commitment, each starting with the owner in bold (**You** \
    when it is the recorder's, the speaker label otherwise, **Unassigned** when \
    nobody took it). Include any due date that was said out loud. Omit this \
    heading entirely if there are no action items.

    Never invent content that is not in the transcript. Where the transcript is \
    garbled, say so instead of guessing.
    """

    // MARK: - Timing

    private func startTicking() {
        stopTicking()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startedAt else { return }
                elapsed = Date().timeIntervalSince(startedAt)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    func elapsedLabel() -> String {
        let total = Int(elapsed.rounded())
        if total >= 3_600 {
            return String(format: "%d:%02d:%02d", total / 3_600, (total % 3_600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func makeTitle(startedAt: Date) -> String {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let stamp = formatter.string(from: startedAt)
        guard let app, !app.isEmpty, app != "Silky" else { return "Meeting \(stamp)" }
        return "\(app) meeting \(stamp)"
    }

    private func report(error message: String) {
        phase = .idle
        stopTicking()
        elapsed = 0
        lastError = message
        onStatus?(message)
        onToast?("exclamationmark.triangle.fill", "Meeting mode failed", .systemOrange)
        NSLog("[Silky] Meeting mode: %@", message)
    }
}
