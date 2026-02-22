import CoreGraphics
import Foundation

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

// MARK: - CutRegion

struct CutRegion: Identifiable, Equatable {
    let id: UUID
    let inPoint: Double
    let outPoint: Double

    init(id: UUID = UUID(), inPoint: Double, outPoint: Double) {
        self.id = id
        self.inPoint = inPoint
        self.outPoint = outPoint
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
