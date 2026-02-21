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
    case exporting
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

// MARK: - WebcamPosition

enum WebcamPosition: String, CaseIterable, Identifiable {
    case bottomLeft
    case bottomRight
    case topLeft
    case topRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        }
    }
}

// MARK: - WebcamSize

enum WebcamSize: CGFloat, CaseIterable, Identifiable {
    case small = 80
    case medium = 120
    case large = 180

    var id: CGFloat { rawValue }

    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
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
