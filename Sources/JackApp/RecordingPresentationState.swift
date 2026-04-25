import Foundation

struct RecordingPresentationState: Equatable {
    let message: String
    let isRecording: Bool
    let isTranscribing: Bool
    let usesActiveAppearance: Bool
    let isNoteMode: Bool
    let isTodoMode: Bool
    let isAiMode: Bool

    static func starting() -> RecordingPresentationState {
        RecordingPresentationState(
            message: "Starting...",
            isRecording: false,
            isTranscribing: false,
            usesActiveAppearance: true,
            isNoteMode: false,
            isTodoMode: false,
            isAiMode: false
        )
    }

    static func listening(outputMode: RecordingOutputMode, isLive _: Bool) -> RecordingPresentationState {
        let message: String
        switch outputMode {
        case .paste:
            message = "Listening..."
        case .voiceNote:
            message = "Listening... (Note Mode)"
        case .todo:
            message = "Listening... (Todo Mode)"
        case .aiChat:
            message = "Listening... (AI Mode)"
        }

        return RecordingPresentationState(
            message: message,
            isRecording: true,
            isTranscribing: false,
            usesActiveAppearance: true,
            isNoteMode: outputMode == .voiceNote,
            isTodoMode: outputMode == .todo,
            isAiMode: outputMode == .aiChat
        )
    }

    static func transcribing() -> RecordingPresentationState {
        RecordingPresentationState(
            message: "Transcribing...",
            isRecording: false,
            isTranscribing: true,
            usesActiveAppearance: true,
            isNoteMode: false,
            isTodoMode: false,
            isAiMode: false
        )
    }
}
