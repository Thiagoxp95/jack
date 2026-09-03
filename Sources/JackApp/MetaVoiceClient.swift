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

    /// Transcribes a recorded WAV file.
    ///
    /// The endpoint wants mono 16-bit PCM at 16 or 24 kHz, which is exactly
    /// what `AudioCaptureService` already writes, so the file goes up as-is.
    static func transcribe(
        audioFileURL: URL,
        apiKey: String,
        model: String = defaultModel
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw Failure.missingKey }

        let audioData = try Data(contentsOf: audioFileURL)
        let boundary = "Boundary-\(UUID().uuidString)"

        // PUSH_TO_TALK tells Meta the clip is a single turn: no endpointing and
        // no diarization, which is what dictation wants. The alternative modes
        // split the audio into speaker-labelled turns.
        let requestJSON = #"{"mode":"PUSH_TO_TALK","model":"\#(model)","audioEncoding":"WAV"}"#

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

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformedResponse
        }

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
}
