import AVFoundation
import CoreGraphics
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - AppMode

enum AppMode: String, Equatable {
    case dictation
    case screenRecording
}

// MARK: - RecordingState

enum RecordingState: String, Equatable {
    case idle
    case setup
    case countdown
    case recording
    case paused
    case stopped
    case editing
}

// MARK: - CaptureSourceType

enum CaptureSourceType: String, CaseIterable, Identifiable {
    case screen
    case window
    case region

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screen: return "Full Screen"
        case .window: return "Window"
        case .region: return "Region"
        }
    }

    var iconName: String {
        switch self {
        case .screen: return "rectangle.dashed"
        case .window: return "macwindow"
        case .region: return "crop"
        }
    }
}

// MARK: - RecordingFPS

enum RecordingFPS: Int, CaseIterable, Identifiable {
    case thirty = 30
    case sixty = 60
    case oneTwenty = 120

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .thirty: return "30 FPS"
        case .sixty: return "60 FPS"
        case .oneTwenty: return "120 FPS"
        }
    }
}

// MARK: - VideoCodec

enum VideoCodec: String, CaseIterable, Identifiable {
    case h264
    case h265

    var id: String { rawValue }

    var label: String {
        switch self {
        case .h264: return "H.264"
        case .h265: return "H.265 (HEVC)"
        }
    }
}

// MARK: - ExportQuality

enum ExportQuality: String, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case lossless

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .lossless: return "Lossless"
        }
    }
}

// MARK: - ExportResolution

enum ExportResolution: String, CaseIterable, Identifiable {
    case original
    case p1080 = "1080p"
    case p720 = "720p"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "Original"
        case .p1080: return "1080p"
        case .p720: return "720p"
        }
    }
}

// MARK: - ExportFileFormat

enum ExportFileFormat: String, CaseIterable, Identifiable {
    case mp4
    case mov

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mp4: return "MP4"
        case .mov: return "MOV"
        }
    }

    var utType: UTType {
        switch self {
        case .mp4: return .mpeg4Movie
        case .mov: return .quickTimeMovie
        }
    }

    var avFileType: AVFileType {
        switch self {
        case .mp4: return .mp4
        case .mov: return .mov
        }
    }

    var fileExtension: String {
        switch self {
        case .mp4: return "mp4"
        case .mov: return "mov"
        }
    }
}

// MARK: - ExportAspectRatio

enum ExportAspectRatio: String, CaseIterable, Identifiable {
    case original
    case sixteenByNine
    case fourByThree
    case oneByOne
    case nineBySixteen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "Original"
        case .sixteenByNine: return "16:9"
        case .fourByThree: return "4:3"
        case .oneByOne: return "1:1"
        case .nineBySixteen: return "9:16"
        }
    }

    /// Target width/height ratio, or nil for original.
    var ratio: CGFloat? {
        switch self {
        case .original: return nil
        case .sixteenByNine: return 16.0 / 9.0
        case .fourByThree: return 4.0 / 3.0
        case .oneByOne: return 1.0
        case .nineBySixteen: return 9.0 / 16.0
        }
    }
}

// MARK: - WebcamDefaults

enum WebcamDefaults {
    static let minDiameter: CGFloat = 60
    static let maxDiameter: CGFloat = 300
    static let defaultDiameter: CGFloat = 120
}

// MARK: - CursorStyle

enum CursorStyle: String, CaseIterable, Identifiable {
    case white
    case black
    case yellow
    case pink
    case blue
    case green
    case orange

    var id: String { rawValue }

    var label: String {
        switch self {
        case .white: return "White"
        case .black: return "Black"
        case .yellow: return "Yellow"
        case .pink: return "Pink"
        case .blue: return "Blue"
        case .green: return "Green"
        case .orange: return "Orange"
        }
    }

    var fillHex: String {
        switch self {
        case .white: return "#FFFFFF"
        case .black: return "#1A1A1A"
        case .yellow: return "#FFD60A"
        case .pink: return "#FF375F"
        case .blue: return "#0A84FF"
        case .green: return "#30D158"
        case .orange: return "#FF9F0A"
        }
    }

    var strokeHex: String {
        switch self {
        case .white: return "#000000"
        case .black: return "#FFFFFF"
        case .yellow: return "#000000"
        case .pink: return "#FFFFFF"
        case .blue: return "#FFFFFF"
        case .green: return "#000000"
        case .orange: return "#000000"
        }
    }
}

// MARK: - MarkerColor

enum MarkerColor: String, CaseIterable, Identifiable {
    case blue, red, green, yellow, orange, purple

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue: return .blue
        case .red: return .red
        case .green: return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .purple: return .purple
        }
    }
}

// MARK: - TimelineMarker

struct TimelineMarker: Identifiable, Equatable {
    let id: UUID
    var time: TimeInterval
    var label: String
    var color: MarkerColor

    init(id: UUID = UUID(), time: TimeInterval, label: String = "", color: MarkerColor = .blue) {
        self.id = id
        self.time = time
        self.label = label
        self.color = color
    }
}

// MARK: - TimelineSegment

struct TimelineSegment: Identifiable, Equatable {
    let id: UUID
    let sourceStart: TimeInterval
    let sourceEnd: TimeInterval
    var enabled: Bool
    /// Per-segment microphone volume (0.0–2.0). Multiplied with master mic volume.
    var micVolume: Float
    /// Per-segment system audio volume (0.0–2.0). Multiplied with master system volume.
    var systemVolume: Float

    init(
        id: UUID = UUID(),
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval,
        enabled: Bool = true,
        micVolume: Float = 1.0,
        systemVolume: Float = 1.0
    ) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.enabled = enabled
        self.micVolume = micVolume
        self.systemVolume = systemVolume
    }

    var sourceDuration: TimeInterval {
        sourceEnd - sourceStart
    }
}

// MARK: - CursorEvent

struct CursorEvent: Codable, Equatable {
    let t: Double
    let x: Double
    let y: Double
    let click: String?

    init(t: Double, x: Double, y: Double, click: String? = nil) {
        self.t = t
        self.x = x
        self.y = y
        self.click = click
    }
}

// MARK: - CursorTrackingData

struct CursorTrackingData: Codable {
    let framerate: Int
    let events: [CursorEvent]
}

// MARK: - ZoomKeyframe

struct ZoomKeyframe: Identifiable, Equatable {
    let id: UUID
    let startTime: Double
    let endTime: Double
    let zoomLevel: Double

    init(id: UUID = UUID(), startTime: Double, endTime: Double, zoomLevel: Double) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.zoomLevel = zoomLevel
    }
}

// MARK: - RecordingSession

struct RecordingSession {
    let id: UUID
    let sessionDirectory: URL
    let startDate: Date
    var duration: TimeInterval
    let captureSourceType: CaptureSourceType
    let fps: RecordingFPS
    /// Screen dimensions in points (for mapping cursor coordinates to video).
    var screenSize: CGSize = .zero

    var screenVideoURL: URL {
        sessionDirectory.appendingPathComponent("screen.mov")
    }

    var systemAudioURL: URL {
        sessionDirectory.appendingPathComponent("system_audio.caf")
    }

    var micAudioURL: URL {
        sessionDirectory.appendingPathComponent("mic_audio.caf")
    }

    var cursorDataURL: URL {
        sessionDirectory.appendingPathComponent("cursor_data.json")
    }

    var webcamVideoURL: URL {
        sessionDirectory.appendingPathComponent("webcam.mov")
    }

    init(
        id: UUID = UUID(),
        sessionDirectory: URL,
        startDate: Date = .now,
        duration: TimeInterval = 0,
        captureSourceType: CaptureSourceType,
        fps: RecordingFPS
    ) {
        self.id = id
        self.sessionDirectory = sessionDirectory
        self.startDate = startDate
        self.duration = duration
        self.captureSourceType = captureSourceType
        self.fps = fps
    }
}

// MARK: - Subtitle Types

enum SubtitlePosition: String, Codable, CaseIterable, Sendable {
    case top, middle, bottom
}

enum SubtitleAudioSource: String, Codable, CaseIterable, Sendable {
    case microphone, systemAudio, both
}

struct SubtitleWord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var text: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var confidence: Float

    init(id: UUID = UUID(), text: String, startTime: TimeInterval, endTime: TimeInterval, confidence: Float) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

struct SubtitleLine: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var words: [SubtitleWord]

    var sourceStart: TimeInterval {
        words.first?.startTime ?? 0
    }

    var sourceEnd: TimeInterval {
        words.last?.endTime ?? 0
    }

    init(id: UUID = UUID(), words: [SubtitleWord]) {
        self.id = id
        self.words = words
    }
}

struct SubtitleConfiguration: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var fontFamily: String = ".AppleSystemUIFont"
    var fontSize: CGFloat = 72
    var activeColor: String = "#FFFFFF"
    var inactiveColor: String = "#888888"
    var backgroundColor: String = "#00000080"
    var backgroundEnabled: Bool = true
    var position: SubtitlePosition = .bottom
    var audioSource: SubtitleAudioSource = .microphone
}
