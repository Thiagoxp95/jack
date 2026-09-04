import Foundation

/// Thin client for Meta's Muse Voice Transcribe batch endpoint.
///
/// Unlike the other cloud transcription models, this one does not go through
/// the Convex proxy: `ConvexHTTPClient.getToken()` has thrown `notSignedIn`
/// since auth was removed, so every proxied model is unreachable in shipped
/// builds. Muse follows the cleanup providers instead — the user's own key in
/// the keychain, called straight from the app. That also drops a base64
/// round-trip through Convex out of the path between the last word and the
/// paste.
enum MetaVoiceClient {

    static let transcribeURL = "https://api.meta.ai/v1/asr/transcribe"

    /// The only model on this endpoint today. Kept here rather than passed in
    /// because the request shape below is specific to it.
    static let defaultModel = "muse-voice-transcribe-1.0"

    /// Single-turn mode: no endpointing, no diarization. What dictation wants.
    static let pushToTalkMode = "PUSH_TO_TALK"

    /// Multi-speaker mode: Muse returns turn-level segments carrying a speaker
    /// label and turn-level timestamps. Labels are scoped to one request, so
    /// "Speaker A" in one chunk is not necessarily "Speaker A" in the next —
    /// meeting mode works around that by transcribing the microphone and the
    /// system-audio tracks separately, so at least "you" is stable throughout.
    ///
    /// Overridable at runtime because the mode spelling is the one part of this
    /// endpoint we could not verify against Meta's docs; if it turns out to be
    /// something else, `defaults write com.jack.app.v2 muse_diarization_mode
    /// <NAME>` fixes it without a rebuild.
    static var diarizationMode: String {
        let stored = UserDefaults.standard.string(forKey: "muse_diarization_mode")
        return (stored?.isEmpty == false ? stored! : "DIARIZATION")
    }

    /// One speaker turn out of a diarized response.
    struct Turn: Sendable, Equatable {
        /// Muse's own label ("A", "Speaker 1", …), when it sent one.
        let speaker: String?
        let text: String
        /// Seconds from the start of the submitted audio, when reported.
        let start: TimeInterval?
        let end: TimeInterval?
    }

    enum Failure: LocalizedError {
        case missingKey
        case http(status: Int, body: String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "No Meta API key set. Add one in Settings → Transcription Model."
            case let .http(status, body):
                return "Meta HTTP \(status): \(body)"
            case .malformedResponse:
                return "Unexpected response shape from Meta."
            }
        }

        var userFacingSummary: String {
            switch self {
            case .missingKey:
                return "No Meta key set"
            case let .http(status, _) where status == 401 || status == 403:
                return "Meta rejected your API key (\(status))"
            case let .http(status, _) where status == 413:
                return "Recording too long for Meta (32 MB / 10 min limit)"
            case let .http(status, _):
                return "Meta error \(status)"
            case .malformedResponse:
                return "Unexpected reply from Meta"
            }
        }
    }

    /// Transcribes a recorded WAV file as a single turn.
    ///
    /// The endpoint wants mono 16-bit PCM at 16 or 24 kHz, which is exactly
    /// what `AudioCaptureService` already writes, so the file goes up as-is.
    static func transcribe(
        audioFileURL: URL,
        apiKey: String,
        model: String = defaultModel
    ) async throws -> String {
        let json = try await post(
            audioFileURL: audioFileURL,
            apiKey: apiKey,
            model: model,
            mode: pushToTalkMode
        )

        // `transcript` is the whole clip. `turns` only carries text of its own
        // in the diarization modes; joining it here means a future mode switch
        // degrades to a flat transcript instead of an empty paste. Speaker
        // labels are dropped either way — they must never reach the paste.
        if let transcript = json["transcript"] as? String {
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let turns = json["turns"] as? [[String: Any]] {
            let joined = turns.compactMap { $0["transcript"] as? String }.joined(separator: " ")
            return joined.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw Failure.malformedResponse
    }

    /// Transcribes a WAV file in diarization mode, returning speaker turns.
    ///
    /// Same 10 minute / 32 MB per-file ceiling as `transcribe` — meeting mode
    /// splits its recording into sub-limit chunks before calling this.
    static func diarize(
        audioFileURL: URL,
        apiKey: String,
        model: String = defaultModel,
        mode: String = diarizationMode
    ) async throws -> [Turn] {
        let json = try await post(
            audioFileURL: audioFileURL,
            apiKey: apiKey,
            model: model,
            mode: mode
        )

        if let rawTurns = json["turns"] as? [[String: Any]] {
            let turns = rawTurns.compactMap(parseTurn)
            if !turns.isEmpty { return turns }
        }

        // Some responses (and every non-diarization mode) carry only the flat
        // transcript. One unlabeled turn beats throwing away the words.
        if let transcript = (json["transcript"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !transcript.isEmpty
        {
            return [Turn(speaker: nil, text: transcript, start: nil, end: nil)]
        }

        // An empty response is what silence looks like, not a failure.
        if json["turns"] != nil || json["transcript"] != nil { return [] }
        throw Failure.malformedResponse
    }

    // MARK: - Request plumbing

    private static func post(
        audioFileURL: URL,
        apiKey: String,
        model: String,
        mode: String
    ) async throws -> [String: Any] {
        guard !apiKey.isEmpty else { throw Failure.missingKey }

        let audioData = try Data(contentsOf: audioFileURL)
        let boundary = "Boundary-\(UUID().uuidString)"
        let requestJSON = #"{"mode":"\#(mode)","model":"\#(model)","audioEncoding":"WAV"}"#

        var body = Data()
        func append(_ string: String) {
            body.append(Data(string.utf8))
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"request\"\r\n")
        append("Content-Type: application/json\r\n\r\n")
        append("\(requestJSON)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"audio\"; filename=\"recording.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: URL(string: transcribeURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        // A 10-minute chunk is a real upload; the default 60s is not enough.
        request.timeoutInterval = 300

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformedResponse
        }
        return json
    }

    // MARK: - Response parsing

    /// Key names are read defensively: the diarized shape is the part of this
    /// endpoint we have the least documentation for, and a turn that parses
    /// with a missing timestamp is worth far more than a thrown error.
    private static func parseTurn(_ raw: [String: Any]) -> Turn? {
        let text = firstString(in: raw, keys: ["transcript", "text", "content"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }

        let speaker = firstString(in: raw, keys: ["speaker", "speakerId", "speaker_id", "speakerLabel", "speaker_label"])
        return Turn(
            speaker: speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
            text: text,
            start: seconds(in: raw, keys: ["startTime", "start_time", "start", "beginTime", "offset"]),
            end: seconds(in: raw, keys: ["endTime", "end_time", "end", "finishTime"])
        )
    }

    private static func firstString(in raw: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = raw[key] as? String, !value.isEmpty { return value }
            // Speaker ids sometimes arrive as plain integers.
            if let value = raw[key] as? Int { return String(value) }
        }
        return nil
    }

    /// Accepts seconds or milliseconds: a `…Ms`/`…Millis` key is milliseconds,
    /// and so is any bare value large enough that seconds would be absurd for a
    /// chunk that can never exceed 10 minutes.
    private static func seconds(in raw: [String: Any], keys: [String]) -> TimeInterval? {
        for key in keys {
            for candidate in [key, key + "Ms", key + "Millis", key + "_ms"] {
                guard let number = raw[candidate] as? NSNumber else { continue }
                let value = number.doubleValue
                let isMillis = candidate != key || value > 3_600
                return isMillis ? value / 1_000 : value
            }
        }
        return nil
    }
}
