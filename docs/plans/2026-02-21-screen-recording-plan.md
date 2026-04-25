# Screen Recording Feature — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a Screen Studio-like screen recording feature with setup window, recording controls, and a Metal-powered video editor with cinematic zoom and cursor effects.

**Architecture:** ScreenCaptureKit captures screen/audio, AVCaptureSession captures webcam (shown live on-screen), CGEvent tap tracks cursor. Metal compute shaders composite zoom + cursor effects for real-time editor preview and export via AVAssetWriter.

**Tech Stack:** Swift 6.2, ScreenCaptureKit, Metal, AVFoundation, AppKit (NSPanel), SwiftUI, CoreGraphics (CGEvent)

**Design Doc:** `docs/plans/2026-02-21-screen-recording-design.md`

---

## Phase 1: Foundation Types & State Machine

### Task 1: Recording Types & Enums

**Files:**
- Create: `Sources/JackApp/ScreenRecording/RecordingTypes.swift`

**Step 1: Create the types file**

Follow the pattern from `ShortcutTypes.swift` (String RawValue, CaseIterable, Identifiable).

```swift
import Foundation

// MARK: - Recording State Machine

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

// MARK: - Capture Source

enum CaptureSourceType: String, CaseIterable, Identifiable {
    case screen, window, region
    var id: String { rawValue }
    var title: String {
        switch self {
        case .screen: "Full Screen"
        case .window: "Window"
        case .region: "Region"
        }
    }
    var iconName: String {
        switch self {
        case .screen: "rectangle.on.rectangle"
        case .window: "macwindow"
        case .region: "crop"
        }
    }
}

// MARK: - FPS

enum RecordingFPS: Int, CaseIterable, Identifiable {
    case thirty = 30
    case sixty = 60
    case oneTwenty = 120
    var id: Int { rawValue }
    var label: String { "\(rawValue) FPS" }
}

// MARK: - Export

enum VideoCodec: String, CaseIterable, Identifiable {
    case h264, h265
    var id: String { rawValue }
    var label: String {
        switch self {
        case .h264: "H.264"
        case .h265: "H.265 (HEVC)"
        }
    }
}

enum ExportQuality: String, CaseIterable, Identifiable {
    case low, medium, high, lossless
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum ExportResolution: String, CaseIterable, Identifiable {
    case original, p1080 = "1080p", p720 = "720p"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .original: "Original"
        case .p1080: "1080p"
        case .p720: "720p"
        }
    }
}

// MARK: - Webcam

enum WebcamPosition: String, CaseIterable, Identifiable {
    case bottomLeft, bottomRight, topLeft, topRight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        }
    }
}

enum WebcamSize: CGFloat, CaseIterable, Identifiable {
    case small = 80
    case medium = 120
    case large = 180
    var id: CGFloat { rawValue }
    var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

// MARK: - Cursor Data

struct CursorEvent: Codable, Equatable {
    let t: Double      // timestamp relative to recording start
    let x: Double      // screen x
    let y: Double      // screen y
    var click: String?  // "left", "right", or nil
}

struct CursorTrackingData: Codable {
    let framerate: Int
    var events: [CursorEvent]
}

// MARK: - Zoom Keyframe

struct ZoomKeyframe: Identifiable, Equatable {
    let id: UUID
    var startTime: Double   // seconds
    var endTime: Double     // seconds
    var zoomLevel: Double   // 1.5 - 4.0
}

// MARK: - Edit Decision

struct CutRegion: Identifiable, Equatable {
    let id: UUID
    var inPoint: Double   // seconds
    var outPoint: Double  // seconds
}

// MARK: - Recording Session

struct RecordingSession {
    let id: UUID
    let sessionDirectory: URL
    var screenVideoURL: URL { sessionDirectory.appendingPathComponent("screen.mov") }
    var systemAudioURL: URL { sessionDirectory.appendingPathComponent("system-audio.m4a") }
    var micAudioURL: URL { sessionDirectory.appendingPathComponent("mic-audio.m4a") }
    var cursorDataURL: URL { sessionDirectory.appendingPathComponent("cursor-data.json") }
    var startDate: Date = Date()
    var duration: TimeInterval = 0
    var captureSourceType: CaptureSourceType = .screen
    var fps: RecordingFPS = .sixty
}

// MARK: - App Mode

enum AppMode: String, Equatable {
    case dictation
    case screenRecording
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1 | head -20`

**Step 3: Commit**

```bash
git add Sources/JackApp/ScreenRecording/RecordingTypes.swift
git commit -m "feat(screen-recording): add foundation types and enums"
```

---

## Phase 2: Capture Services

### Task 2: CursorTrackingService

**Files:**
- Create: `Sources/JackApp/ScreenRecording/CursorTrackingService.swift`

**Context:** Reuse the CGEvent tap pattern from `GlobalFnShortcutMonitor.swift` (lines 53-114). That file creates a `CGEvent.tapCreate` with a C callback that routes through userInfo. We do the same but listen for mouse move + click events instead of key events.

**Step 1: Write the service**

```swift
import Foundation
import CoreGraphics

actor CursorTrackingService {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var trackingData: CursorTrackingData
    private var isTracking = false
    private let startTime: Date
    private let framerate: Int

    // Ring buffer for high-frequency updates - flush periodically
    private var eventBuffer: [CursorEvent] = []
    private let bufferFlushThreshold = 500

    init(framerate: Int) {
        self.framerate = framerate
        self.startTime = Date()
        self.trackingData = CursorTrackingData(framerate: framerate, events: [])
        self.eventBuffer.reserveCapacity(bufferFlushThreshold * 2)
    }

    func start() {
        guard !isTracking else { return }
        isTracking = true
        // CGEvent tap must be created on main thread
        Task { @MainActor in
            self.installEventTap()
        }
    }

    func stop() -> CursorTrackingData {
        isTracking = false
        Task { @MainActor in
            self.removeEventTap()
        }
        // Flush remaining buffer
        trackingData.events.append(contentsOf: eventBuffer)
        eventBuffer.removeAll()
        return trackingData
    }

    func recordPosition(x: Double, y: Double, click: String?) {
        guard isTracking else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        let event = CursorEvent(t: elapsed, x: x, y: y, click: click)
        eventBuffer.append(event)
        if eventBuffer.count >= bufferFlushThreshold {
            trackingData.events.append(contentsOf: eventBuffer)
            eventBuffer.removeAll(keepingCapacity: true)
        }
    }

    func writeToFile(url: URL) throws {
        let finalData = CursorTrackingData(
            framerate: framerate,
            events: trackingData.events + eventBuffer
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(finalData)
        try data.write(to: url, options: .atomic)
    }

    @MainActor
    private func installEventTap() {
        let eventMask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue)

        // Store weak ref to self via pointer
        let pointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,  // passive, don't consume events
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passRetained(event) }
                let service = Unmanaged<CursorTrackingService>.fromOpaque(userInfo)
                    .takeUnretainedValue()
                let location = event.location
                var click: String? = nil
                if type == .leftMouseDown { click = "left" }
                else if type == .rightMouseDown { click = "right" }
                Task {
                    await service.recordPosition(x: location.x, y: location.y, click: click)
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: pointer
        ) else {
            print("[CursorTrackingService] Failed to create event tap - check Input Monitoring permission")
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    @MainActor
    private func removeEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1 | head -20`

**Step 3: Commit**

```bash
git add Sources/JackApp/ScreenRecording/CursorTrackingService.swift
git commit -m "feat(screen-recording): add cursor tracking service with CGEvent tap"
```

---

### Task 3: ScreenRecordingService

**Files:**
- Create: `Sources/JackApp/ScreenRecording/ScreenRecordingService.swift`

**Context:** Uses ScreenCaptureKit (macOS 13+). `SCStream` delivers `CMSampleBuffer` frames via `SCStreamOutput` delegate. We write video + system audio to separate `AVAssetWriter` instances. The app already targets macOS 14+.

**Step 1: Write the service**

```swift
import Foundation
import ScreenCaptureKit
import AVFoundation

actor ScreenRecordingService: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var videoWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var isCapturing = false
    private var sessionStartTime: CMTime?

    // Configuration
    private let fps: RecordingFPS
    private let videoOutputURL: URL
    private let audioOutputURL: URL

    init(fps: RecordingFPS, videoOutputURL: URL, audioOutputURL: URL) {
        self.fps = fps
        self.videoOutputURL = videoOutputURL
        self.audioOutputURL = audioOutputURL
        super.init()
    }

    // MARK: - Permission

    static func requestPermission() async -> Bool {
        do {
            // Accessing shareable content triggers the permission prompt
            _ = try await SCShareableContent.current
            return true
        } catch {
            print("[ScreenRecordingService] Permission denied: \(error)")
            return false
        }
    }

    static func hasPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Available Sources

    static func availableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    // MARK: - Start Capture

    func startCapture(
        display: SCDisplay? = nil,
        window: SCWindow? = nil,
        region: CGRect? = nil,
        captureSystemAudio: Bool,
        excludedWindows: [SCWindow] = []
    ) async throws {
        guard !isCapturing else { return }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        // Build content filter
        let filter: SCContentFilter
        if let window {
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else {
            let targetDisplay = display ?? content.displays.first!
            filter = SCContentFilter(
                display: targetDisplay,
                excludingWindows: excludedWindows
            )
        }

        // Configure stream
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps.rawValue))
        config.queueDepth = 8
        config.showsCursor = true  // We track cursor separately for post-processing but show live

        if let region {
            config.sourceRect = region
            config.width = Int(region.width) * 2  // Retina
            config.height = Int(region.height) * 2
        } else {
            // Use display native resolution
            if let targetDisplay = display ?? content.displays.first {
                config.width = targetDisplay.width * 2
                config.height = targetDisplay.height * 2
            }
        }

        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.capturesAudio = captureSystemAudio

        // Setup asset writers
        try setupVideoWriter(width: config.width, height: config.height)
        if captureSystemAudio {
            try setupAudioWriter()
        }

        // Create and start stream
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        if captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        }

        try await stream.startCapture()
        self.stream = stream
        self.isCapturing = true
    }

    // MARK: - Pause / Resume

    func pauseCapture() {
        // ScreenCaptureKit doesn't have native pause - we skip writing frames
        // The RecordingSessionController tracks pause state
    }

    // MARK: - Stop Capture

    func stopCapture() async {
        guard isCapturing else { return }
        isCapturing = false

        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        // Finalize writers
        if let videoInput, let videoWriter {
            videoInput.markAsFinished()
            await videoWriter.finishWriting()
        }
        if let audioInput, let audioWriter {
            audioInput.markAsFinished()
            await audioWriter.finishWriting()
        }

        videoWriter = nil
        videoInput = nil
        audioWriter = nil
        audioInput = nil
        sessionStartTime = nil
    }

    // MARK: - SCStreamOutput

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        Task { await self.handleSampleBuffer(sampleBuffer, type: type) }
    }

    private func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard isCapturing else { return }

        switch type {
        case .screen:
            guard let videoInput, videoInput.isReadyForMoreMediaData else { return }
            if sessionStartTime == nil {
                sessionStartTime = sampleBuffer.presentationTimeStamp
                videoWriter?.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            }
            videoInput.append(sampleBuffer)

        case .audio:
            guard let audioInput, audioInput.isReadyForMoreMediaData else { return }
            if audioWriter?.status == .writing {
                audioInput.append(sampleBuffer)
            }

        @unknown default:
            break
        }
    }

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[ScreenRecordingService] Stream stopped with error: \(error)")
        Task { await self.stopCapture() }
    }

    // MARK: - Writer Setup

    private func setupVideoWriter(width: Int, height: Int) throws {
        // Remove existing file if present
        try? FileManager.default.removeItem(at: videoOutputURL)

        let writer = try AVAssetWriter(outputURL: videoOutputURL, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,  // Raw capture always H.264
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()

        self.videoWriter = writer
        self.videoInput = input
    }

    private func setupAudioWriter() throws {
        try? FileManager.default.removeItem(at: audioOutputURL)

        let writer = try AVAssetWriter(outputURL: audioOutputURL, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        self.audioWriter = writer
        self.audioInput = input
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1 | head -30`

**Step 3: Commit**

```bash
git add Sources/JackApp/ScreenRecording/ScreenRecordingService.swift
git commit -m "feat(screen-recording): add ScreenCaptureKit capture service"
```

---

### Task 4: WebcamCaptureService

**Files:**
- Create: `Sources/JackApp/ScreenRecording/WebcamCaptureService.swift`

**Context:** Uses AVCaptureSession for camera. The webcam overlay is displayed as an on-screen NSPanel (captured by SCStream as part of the screen), so this service just manages the AVCaptureSession and provides a preview layer.

**Step 1: Write the service**

```swift
import Foundation
import AVFoundation
import AppKit

@MainActor
final class WebcamCaptureService {
    private var captureSession: AVCaptureSession?
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    // MARK: - Permission

    static func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    static var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    // MARK: - Available Cameras

    static var availableCameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    // MARK: - Start / Stop

    func start(device: AVCaptureDevice? = nil) throws {
        let session = AVCaptureSession()
        session.sessionPreset = .medium

        let camera = device ?? AVCaptureDevice.default(for: .video)
        guard let camera else {
            throw NSError(domain: "WebcamCaptureService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No camera available"])
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            throw NSError(domain: "WebcamCaptureService", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add camera input"])
        }
        session.addInput(input)

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill

        self.captureSession = session
        self.previewLayer = layer

        session.startRunning()
    }

    func stop() {
        captureSession?.stopRunning()
        captureSession = nil
        previewLayer = nil
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1 | head -20`

**Step 3: Commit**

```bash
git add Sources/JackApp/ScreenRecording/WebcamCaptureService.swift
git commit -m "feat(screen-recording): add webcam capture service"
```

---

### Task 5: MicrophoneCaptureService (for screen recording)

**Files:**
- Create: `Sources/JackApp/ScreenRecording/MicrophoneCaptureService.swift`

**Context:** The existing `AudioCaptureService` records 16kHz mono WAV for speech-to-text. Screen recording needs higher quality (48kHz stereo AAC) mic audio as a separate track. Rather than modify the existing service, create a dedicated one.

**Step 1: Write the service**

```swift
import Foundation
import AVFoundation

@MainActor
final class MicrophoneCaptureService {
    private var audioRecorder: AVAudioRecorder?
    private(set) var outputURL: URL?

    var isRecording: Bool { audioRecorder?.isRecording ?? false }

    // MARK: - Available Devices

    static var availableInputDevices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    // MARK: - Start / Stop

    func startRecording(to url: URL, device: AVCaptureDevice? = nil) throws {
        // Select audio device if specified
        // Note: AVAudioRecorder uses the system default input device
        // To use a specific device, we'd need AVAudioEngine, but for now
        // the system default works fine (user can change in System Settings)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        recorder.record()

        self.audioRecorder = recorder
        self.outputURL = url
    }

    func stopRecording() -> URL? {
        audioRecorder?.stop()
        let url = outputURL
        audioRecorder = nil
        return url
    }

    func pause() {
        audioRecorder?.pause()
    }

    func resume() {
        audioRecorder?.record()
    }

    func currentLevel() -> Float {
        guard let recorder = audioRecorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let avg = recorder.averagePower(forChannel: 0)
        let peak = recorder.peakPower(forChannel: 0)
        let effective = max(avg, peak - 6)
        let normalized = max(0, min(1, (effective + 55) / 55))
        return pow(normalized, 0.72)
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1 | head -20`

**Step 3: Commit**

```bash
git add Sources/JackApp/ScreenRecording/MicrophoneCaptureService.swift
git commit -m "feat(screen-recording): add microphone capture service for screen recording"
```

---

## Phase 3: Recording Session Controller

### Task 6: RecordingSessionController

**Files:**
- Create: `Sources/JackApp/ScreenRecording/RecordingSessionController.swift`

**Context:** Follow the `DictationController` pattern — `@Observable @MainActor` class with `@Published`-like properties (using `@Observable` macro instead since this is new code), service instances as private properties, state machine transitions.

**Step 1: Write the controller**

```swift
import Foundation
import ScreenCaptureKit
import AVFoundation
import Observation

@Observable
@MainActor
final class RecordingSessionController {

    // MARK: - Published State

    private(set) var state: RecordingState = .idle
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var currentSession: RecordingSession?
    private(set) var availableDisplays: [SCDisplay] = []
    private(set) var availableWindows: [SCWindow] = []
    private(set) var hasScreenPermission = false
    private(set) var hasCameraPermission = false

    // Setup configuration (user-editable)
    var sourceType: CaptureSourceType = .screen
    var selectedDisplayIndex: Int = 0
    var selectedWindowID: UInt32?
    var selectedRegion: CGRect?
    var recordMicrophone: Bool = true
    var recordSystemAudio: Bool = true
    var enableWebcam: Bool = false
    var webcamPosition: WebcamPosition = .bottomLeft
    var webcamSize: WebcamSize = .medium
    var fps: RecordingFPS = .sixty

    // MARK: - Services

    private var screenService: ScreenRecordingService?
    private var cursorService: CursorTrackingService?
    private var webcamService = WebcamCaptureService()
    private var micService = MicrophoneCaptureService()

    // MARK: - Timers

    private var elapsedTimer: Task<Void, Never>?
    private var recordingStartDate: Date?

    // MARK: - Session Directory

    private static var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("Jack/recordings", isDirectory: true)
    }

    private static var exportDirectory: URL {
        let docs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Jack Recordings", isDirectory: true)
        return docs
    }

    // MARK: - Initialization

    func initialize() async {
        await refreshPermissions()
        await refreshAvailableSources()
    }

    func refreshPermissions() async {
        hasScreenPermission = await ScreenRecordingService.hasPermission()
        hasCameraPermission = WebcamCaptureService.hasPermission
    }

    func refreshAvailableSources() async {
        do {
            let content = try await ScreenRecordingService.availableContent()
            availableDisplays = content.displays
            availableWindows = content.windows.filter { $0.isOnScreen }
        } catch {
            print("[RecordingSessionController] Failed to get sources: \(error)")
        }
    }

    // MARK: - State Machine

    func openSetup() async {
        state = .setup
        await refreshAvailableSources()
    }

    func cancelSetup() {
        state = .idle
        webcamService.stop()
    }

    func startRecording() async throws {
        guard state == .setup else { return }

        // Create session
        let sessionID = UUID()
        let sessionDir = Self.cacheDirectory.appendingPathComponent(sessionID.uuidString)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        var session = RecordingSession(id: sessionID, sessionDirectory: sessionDir)
        session.captureSourceType = sourceType
        session.fps = fps
        currentSession = session

        // Show countdown
        state = .countdown
        try await Task.sleep(for: .seconds(3))

        guard state == .countdown else { return } // Cancelled during countdown

        // Start cursor tracking
        let cursorService = CursorTrackingService(framerate: fps.rawValue)
        await cursorService.start()
        self.cursorService = cursorService

        // Start screen capture
        let screenService = ScreenRecordingService(
            fps: fps,
            videoOutputURL: session.screenVideoURL,
            audioOutputURL: session.systemAudioURL
        )

        let display = availableDisplays.indices.contains(selectedDisplayIndex)
            ? availableDisplays[selectedDisplayIndex] : nil
        let window = availableWindows.first { $0.windowID == selectedWindowID }

        try await screenService.startCapture(
            display: sourceType == .screen ? display : nil,
            window: sourceType == .window ? window : nil,
            region: sourceType == .region ? selectedRegion : nil,
            captureSystemAudio: recordSystemAudio
        )
        self.screenService = screenService

        // Start mic if enabled
        if recordMicrophone {
            try micService.startRecording(to: session.micAudioURL)
        }

        // Start timer
        state = .recording
        recordingStartDate = Date()
        startElapsedTimer()
    }

    func pauseRecording() {
        guard state == .recording else { return }
        state = .paused
        micService.pause()
        stopElapsedTimer()
    }

    func resumeRecording() {
        guard state == .paused else { return }
        state = .recording
        micService.resume()
        startElapsedTimer()
    }

    func stopRecording() async {
        guard state == .recording || state == .paused else { return }
        state = .stopped
        stopElapsedTimer()

        // Stop all services
        await screenService?.stopCapture()
        _ = micService.stopRecording()

        if let cursorService {
            let cursorData = await cursorService.stop()
            if let session = currentSession {
                try? await cursorService.writeToFile(url: session.cursorDataURL)
            }
        }

        webcamService.stop()

        // Update session duration
        if let start = recordingStartDate {
            currentSession?.duration = Date().timeIntervalSince(start)
        }

        // Transition to editing
        state = .editing
    }

    func finishEditing() {
        // Clean up temp files
        if let session = currentSession {
            try? FileManager.default.removeItem(at: session.sessionDirectory)
        }
        currentSession = nil
        state = .idle
    }

    // MARK: - Timer

    private func startElapsedTimer() {
        elapsedTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if let start = recordingStartDate {
                    elapsedTime = Date().timeIntervalSince(start)
                }
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.cancel()
        elapsedTimer = nil
    }

    // MARK: - Helpers

    var formattedElapsedTime: String {
        let total = Int(elapsedTime)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    static func ensureExportDirectory() throws -> URL {
        let dir = exportDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1 | head -30`

**Step 3: Commit**

```bash
git add Sources/JackApp/ScreenRecording/RecordingSessionController.swift
git commit -m "feat(screen-recording): add recording session controller with state machine"
```

---

## Phase 4: UI — Setup Window

### Task 7: Setup Window Panel Controller

**Files:**
- Create: `Sources/JackApp/ScreenRecording/SetupWindowController.swift`

**Context:** Follow `FloatingBubbleController.swift` pattern for NSPanel creation (lines 389-414). The setup window is a floating panel hosting SwiftUI content via `NSHostingView`.

**Step 1: Write the panel controller**

```swift
import AppKit
import SwiftUI

@MainActor
final class SetupWindowController {
    private var panel: NSPanel?

    func show(controller: RecordingSessionController) {
        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = NSHostingView(
            rootView: RecordingSetupView(controller: controller, onClose: { [weak self] in
                self?.hide()
            })
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Recording Setup"
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1) // #1C1C1E
        panel.level = .floating
        panel.contentView = contentView
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
    }

    func hide() {
        panel?.close()
        panel = nil
    }
}
```

**Step 2: Verify it compiles** (will have missing `RecordingSetupView` — that's next)

**Step 3: Commit together with Task 8**

---

### Task 8: Recording Setup SwiftUI View

**Files:**
- Create: `Sources/JackApp/ScreenRecording/RecordingSetupView.swift`

**Context:** Dark theme SwiftUI view matching the Raycast-inspired onboarding style. Uses `@Observable` controller for bindings.

**Step 1: Write the view**

```swift
import SwiftUI
import ScreenCaptureKit

struct RecordingSetupView: View {
    @Bindable var controller: RecordingSessionController
    var onClose: () -> Void

    @State private var isStarting = false

    var body: some View {
        VStack(spacing: 0) {
            // Source Selection
            sourceSection
            Divider().background(Color.white.opacity(0.1))

            // Audio Options
            audioSection
            Divider().background(Color.white.opacity(0.1))

            // Webcam Options
            webcamSection
            Divider().background(Color.white.opacity(0.1))

            // Recording Options
            recordingOptionsSection

            Spacer()

            // Action Bar
            actionBar
        }
        .padding(20)
        .frame(width: 480, height: 520)
        .background(Color(nsColor: NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)))
        .preferredColorScheme(.dark)
    }

    // MARK: - Source Selection

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source")
                .font(.headline)
                .foregroundStyle(.white)

            Picker("", selection: $controller.sourceType) {
                ForEach(CaptureSourceType.allCases) { type in
                    Label(type.title, systemImage: type.iconName).tag(type)
                }
            }
            .pickerStyle(.segmented)

            switch controller.sourceType {
            case .screen:
                Picker("Display", selection: $controller.selectedDisplayIndex) {
                    ForEach(controller.availableDisplays.indices, id: \.self) { i in
                        let display = controller.availableDisplays[i]
                        Text("Display \(i + 1) (\(display.width)x\(display.height))")
                            .tag(i)
                    }
                }
            case .window:
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(controller.availableWindows, id: \.windowID) { window in
                            windowThumbnail(window)
                        }
                    }
                }
                .frame(height: 80)
            case .region:
                Button("Select Region...") {
                    // Will open region selection overlay (Task 10)
                }
                .buttonStyle(.bordered)

                if let region = controller.selectedRegion {
                    Text("\(Int(region.width)) x \(Int(region.height))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.bottom, 12)
    }

    private func windowThumbnail(_ window: SCWindow) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.05))
                .frame(width: 80, height: 50)
                .overlay {
                    if let appName = window.owningApplication?.applicationName {
                        Text(appName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

            Text(window.title ?? "Untitled")
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.white)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(controller.selectedWindowID == window.windowID
                      ? Color.accentColor.opacity(0.2)
                      : Color.clear)
        )
        .onTapGesture {
            controller.selectedWindowID = window.windowID
        }
    }

    // MARK: - Audio

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Audio")
                .font(.headline)
                .foregroundStyle(.white)

            Toggle("Microphone", isOn: $controller.recordMicrophone)
            Toggle("System Audio", isOn: $controller.recordSystemAudio)
        }
        .padding(.vertical, 12)
    }

    // MARK: - Webcam

    private var webcamSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Webcam")
                .font(.headline)
                .foregroundStyle(.white)

            Toggle("Enable Webcam", isOn: $controller.enableWebcam)

            if controller.enableWebcam {
                HStack(spacing: 8) {
                    Text("Position:")
                        .foregroundStyle(.secondary)
                    ForEach(WebcamPosition.allCases) { pos in
                        Button(pos.label) {
                            controller.webcamPosition = pos
                        }
                        .buttonStyle(.bordered)
                        .tint(controller.webcamPosition == pos ? .accentColor : .gray)
                    }
                }

                Picker("Size", selection: $controller.webcamSize) {
                    ForEach(WebcamSize.allCases) { size in
                        Text(size.label).tag(size)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(.vertical, 12)
    }

    // MARK: - Recording Options

    private var recordingOptionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Options")
                .font(.headline)
                .foregroundStyle(.white)

            HStack {
                Text("Frame Rate:")
                    .foregroundStyle(.secondary)
                Picker("", selection: $controller.fps) {
                    ForEach(RecordingFPS.allCases) { fps in
                        Text(fps.label).tag(fps)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack {
            Button("Cancel") {
                controller.cancelSetup()
                onClose()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(action: {
                isStarting = true
                Task {
                    do {
                        try await controller.startRecording()
                        onClose()
                    } catch {
                        print("[RecordingSetupView] Start failed: \(error)")
                    }
                    isStarting = false
                }
            }) {
                HStack {
                    Image(systemName: "record.circle")
                    Text("Start Recording")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isStarting)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 12)
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1 | head -30`

**Step 3: Commit**

```bash
git add Sources/JackApp/ScreenRecording/SetupWindowController.swift \
      Sources/JackApp/ScreenRecording/RecordingSetupView.swift
git commit -m "feat(screen-recording): add setup window panel and SwiftUI view"
```

---

## Phase 5: UI — Recording Bubble & Webcam Overlay

### Task 9: Recording Status Bubble

**Files:**
- Create: `Sources/JackApp/ScreenRecording/RecordingBubbleController.swift`

**Context:** Follow `FloatingBubbleController.swift` NSPanel pattern. Pill-shaped frosted glass bubble with recording indicator, timer, pause, and stop buttons.

**Step 1: Write the bubble controller**

```swift
import AppKit
import SwiftUI

@MainActor
final class RecordingBubbleController {
    private var panel: NSPanel?

    func show(controller: RecordingSessionController) {
        guard panel == nil else { return }

        let contentView = NSHostingView(
            rootView: RecordingBubbleView(controller: controller)
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.contentView = contentView

        // Position bottom-center, 40px above dock
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 110
            let y = screenFrame.minY + 40
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.makeKeyAndOrderFront(nil)

        // Slide-up animation
        let finalOrigin = panel.frame.origin
        panel.setFrameOrigin(NSPoint(x: finalOrigin.x, y: finalOrigin.y - 60))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(finalOrigin)
        }

        self.panel = panel
    }

    func hide() {
        guard let panel else { return }
        let origin = panel.frame.origin
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrameOrigin(NSPoint(x: origin.x, y: origin.y - 60))
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.close()
            self?.panel = nil
        })
    }
}

// MARK: - Bubble SwiftUI View

struct RecordingBubbleView: View {
    @Bindable var controller: RecordingSessionController

    var body: some View {
        HStack(spacing: 12) {
            // Recording indicator dot
            Circle()
                .fill(controller.state == .paused ? Color.yellow : Color.red)
                .frame(width: 10, height: 10)
                .opacity(controller.state == .paused ? 1.0 : pulsingOpacity)

            // Timer
            Text(controller.formattedElapsedTime)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(controller.state == .paused ? .secondary : .white)

            Divider()
                .frame(height: 20)

            // Pause/Resume button
            Button(action: {
                if controller.state == .recording {
                    controller.pauseRecording()
                } else if controller.state == .paused {
                    controller.resumeRecording()
                }
            }) {
                Image(systemName: controller.state == .paused ? "play.fill" : "pause.fill")
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)

            // Stop button
            Button(action: {
                Task { await controller.stopRecording() }
            }) {
                Image(systemName: "stop.fill")
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .clipShape(Capsule())
    }

    @State private var pulsingOpacity: Double = 1.0

    // Note: actual pulsing animation would be added via .onAppear with withAnimation repeating
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1 | head -20`

**Step 3: Commit**

```bash
git add Sources/JackApp/ScreenRecording/RecordingBubbleController.swift
git commit -m "feat(screen-recording): add recording status bubble with pill UI"
```

---

### Task 10: Webcam Overlay Panel

**Files:**
- Create: `Sources/JackApp/ScreenRecording/WebcamOverlayController.swift`

**Context:** Floating NSPanel with circular mask showing live webcam preview. Draggable and resizable during recording. This window is captured by ScreenCaptureKit as part of the screen.

**Step 1: Write the controller**

```swift
import AppKit
import AVFoundation

@MainActor
final class WebcamOverlayController {
    private var panel: NSPanel?
    private var webcamService: WebcamCaptureService?

    func show(service: WebcamCaptureService, position: WebcamPosition, size: WebcamSize) {
        guard let previewLayer = service.previewLayer else { return }
        self.webcamService = service

        let diameter = size.rawValue
        let contentView = WebcamCircleView(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = diameter / 2
        contentView.layer?.masksToBounds = true
        contentView.layer?.borderWidth = 2
        contentView.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor

        // Add preview layer
        previewLayer.frame = contentView.bounds
        previewLayer.cornerRadius = diameter / 2
        contentView.layer?.addSublayer(previewLayer)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: diameter, height: diameter),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true  // Draggable
        panel.contentView = contentView

        // Position based on preset
        positionPanel(panel, at: position, diameter: diameter)

        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func hide() {
        panel?.close()
        panel = nil
    }

    private func positionPanel(_ panel: NSPanel, at position: WebcamPosition, diameter: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let margin: CGFloat = 20

        let origin: NSPoint
        switch position {
        case .bottomLeft:
            origin = NSPoint(x: frame.minX + margin, y: frame.minY + margin)
        case .bottomRight:
            origin = NSPoint(x: frame.maxX - diameter - margin, y: frame.minY + margin)
        case .topLeft:
            origin = NSPoint(x: frame.minX + margin, y: frame.maxY - diameter - margin)
        case .topRight:
            origin = NSPoint(x: frame.maxX - diameter - margin, y: frame.maxY - diameter - margin)
        }
        panel.setFrameOrigin(origin)
    }
}

// Simple NSView subclass for the circular webcam content
private class WebcamCircleView: NSView {
    override var isFlipped: Bool { false }

    // Support scroll-to-resize
    override func scrollWheel(with event: NSEvent) {
        guard let panel = window as? NSPanel else { return }
        let delta = event.deltaY * 2
        let currentSize = frame.size.width
        let newSize = max(60, min(300, currentSize - delta))
        let origin = panel.frame.origin
        let centerX = origin.x + currentSize / 2
        let centerY = origin.y + currentSize / 2
        panel.setFrame(
            NSRect(x: centerX - newSize / 2, y: centerY - newSize / 2, width: newSize, height: newSize),
            display: true,
            animate: true
        )
        // Update corner radius
        layer?.cornerRadius = newSize / 2
        layer?.sublayers?.forEach { $0.frame = bounds; ($0 as? AVCaptureVideoPreviewLayer)?.cornerRadius = newSize / 2 }
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1 | head -20`

**Step 3: Commit**

```bash
git add Sources/JackApp/ScreenRecording/WebcamOverlayController.swift
git commit -m "feat(screen-recording): add draggable/resizable webcam overlay panel"
```

---

### Task 11: Region Selection Overlay

**Files:**
- Create: `Sources/JackApp/ScreenRecording/RegionSelectionController.swift`

**Context:** Full-screen semi-transparent overlay for freeform region selection. Similar to macOS screenshot tool. Crosshair cursor, drag to select, shift-snap to aspect ratios.

**Step 1: Write the controller**

```swift
import AppKit

@MainActor
final class RegionSelectionController {
    private var overlayWindow: NSWindow?
    private var completion: ((CGRect?) -> Void)?

    func selectRegion(completion: @escaping (CGRect?) -> Void) {
        self.completion = completion

        guard let screen = NSScreen.main else {
            completion(nil)
            return
        }

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.3)
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true

        let contentView = RegionSelectionView(frame: screen.frame) { [weak self] region in
            self?.finish(with: region)
        }
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)

        // Set crosshair cursor
        NSCursor.crosshair.push()

        // ESC to cancel
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.finish(with: nil)
                return nil
            }
            return event
        }

        self.overlayWindow = window
    }

    private func finish(with region: CGRect?) {
        NSCursor.pop()
        overlayWindow?.close()
        overlayWindow = nil
        completion?(region)
        completion = nil
    }
}

// MARK: - Selection View

private class RegionSelectionView: NSView {
    private var dragStart: NSPoint?
    private var dragEnd: NSPoint?
    private var isShiftHeld = false
    private var onComplete: (CGRect?) -> Void

    init(frame: NSRect, onComplete: @escaping (CGRect?) -> Void) {
        self.onComplete = onComplete
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragEnd = dragStart
        isShiftHeld = event.modifierFlags.contains(.shift)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragEnd = convert(event.locationInWindow, from: nil)
        isShiftHeld = event.modifierFlags.contains(.shift)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect = currentRect, rect.width > 10, rect.height > 10 else {
            onComplete(nil)
            return
        }
        // Convert to screen coordinates (flip Y for ScreenCaptureKit)
        let screenRect = CGRect(
            x: rect.origin.x,
            y: frame.height - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
        onComplete(screenRect)
    }

    private var currentRect: CGRect? {
        guard let start = dragStart, let end = dragEnd else { return nil }
        var rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )

        // Snap to aspect ratios when shift is held
        if isShiftHeld {
            let ratios: [(CGFloat, CGFloat)] = [(16, 9), (4, 3), (1, 1), (9, 16)]
            var bestRatio = ratios[0]
            var bestDiff = CGFloat.infinity

            for ratio in ratios {
                let targetAspect = ratio.0 / ratio.1
                let currentAspect = rect.width / max(1, rect.height)
                let diff = abs(currentAspect - targetAspect)
                if diff < bestDiff {
                    bestDiff = diff
                    bestRatio = ratio
                }
            }

            let targetAspect = bestRatio.0 / bestRatio.1
            rect.size.height = rect.width / targetAspect
        }

        return rect
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let rect = currentRect else { return }

        // Draw selection rectangle
        NSColor.white.withAlphaComponent(0.3).setFill()
        NSBezierPath(rect: rect).fill()

        NSColor.white.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1.5
        path.stroke()

        // Draw dimensions label
        let label = "\(Int(rect.width)) x \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .backgroundColor: NSColor.black.withAlphaComponent(0.6),
        ]
        let labelSize = (label as NSString).size(withAttributes: attrs)
        let labelPoint = NSPoint(
            x: rect.midX - labelSize.width / 2,
            y: rect.maxY + 8
        )
        (label as NSString).draw(at: labelPoint, withAttributes: attrs)
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1 | head -20`

**Step 3: Commit**

```bash
git add Sources/JackApp/ScreenRecording/RegionSelectionController.swift
git commit -m "feat(screen-recording): add freeform region selection overlay with shift-snap"
```

---

## Phase 6: Countdown Overlay

### Task 12: Countdown Overlay

**Files:**
- Create: `Sources/JackApp/ScreenRecording/CountdownOverlayController.swift`

**Step 1: Write the controller**

```swift
import AppKit
import SwiftUI

@MainActor
final class CountdownOverlayController {
    private var window: NSWindow?

    func show() async {
        guard let screen = NSScreen.main else { return }

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true

        let hostingView = NSHostingView(rootView: CountdownView())
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        self.window = window

        // Wait for countdown (3 seconds)
        try? await Task.sleep(for: .seconds(3.2))

        window.close()
        self.window = nil
    }
}

private struct CountdownView: View {
    @State private var currentNumber = 3

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)

            Text("\(currentNumber)")
                .font(.system(size: 120, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(radius: 20)
                .scaleEffect(currentNumber > 0 ? 1.0 : 0.5)
                .opacity(currentNumber > 0 ? 1.0 : 0.0)
        }
        .ignoresSafeArea()
        .task {
            for i in stride(from: 3, through: 1, by: -1) {
                currentNumber = i
                try? await Task.sleep(for: .seconds(1))
            }
            currentNumber = 0
        }
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1 | head -20`

**Step 3: Commit**

```bash
git add Sources/JackApp/ScreenRecording/CountdownOverlayController.swift
git commit -m "feat(screen-recording): add 3-2-1 countdown overlay"
```

---

## Phase 7: Metal Rendering Pipeline

### Task 13: Metal Compute Shader

**Files:**
- Create: `Sources/JackApp/ScreenRecording/Shaders/ZoomCursorCompositor.metal`

**Step 1: Write the Metal shader**

```metal
#include <metal_stdlib>
using namespace metal;

// Uniforms passed from CPU
struct CompositorUniforms {
    float2 outputSize;        // Output texture dimensions
    float2 sourceSize;        // Input texture dimensions
    float2 zoomCenter;        // Normalized zoom center (0-1)
    float zoomLevel;          // 1.0 = no zoom, 2.0 = 2x zoom, etc.
    float2 cursorPosition;    // Cursor position in output coords
    float cursorScale;        // 1.0 - 3.0
    float cursorVisible;      // 0 or 1
    float clickHighlightPhase; // 0-1 for click animation (0 = no click)
    float4 clickHighlightColor; // RGBA
    float clickHighlightRadius; // max radius in pixels
};

// Bicubic interpolation weight function (Catmull-Rom)
float catmullRom(float x) {
    float ax = abs(x);
    if (ax < 1.0) {
        return 0.5 * (2.0 + ax * ax * (-5.0 + 3.0 * ax));
    } else if (ax < 2.0) {
        return 0.5 * (4.0 - 8.0 * ax + 5.0 * ax * ax - ax * ax * ax);
    }
    return 0.0;
}

float4 sampleBicubic(texture2d<float, access::sample> tex, float2 uv, float2 texSize) {
    sampler bilinearSampler(filter::linear, address::clamp_to_edge);

    float2 pixelCoord = uv * texSize - 0.5;
    float2 base = floor(pixelCoord);
    float2 frac_part = pixelCoord - base;

    float4 result = float4(0.0);
    float weightSum = 0.0;

    for (int y = -1; y <= 2; y++) {
        for (int x = -1; x <= 2; x++) {
            float2 samplePos = (base + float2(x, y) + 0.5) / texSize;
            float weight = catmullRom(float(x) - frac_part.x) * catmullRom(float(y) - frac_part.y);
            result += tex.sample(bilinearSampler, samplePos) * weight;
            weightSum += weight;
        }
    }

    return result / weightSum;
}

kernel void zoomCursorComposite(
    texture2d<float, access::sample> sourceTexture [[texture(0)]],
    texture2d<float, access::sample> cursorTexture [[texture(1)]],
    texture2d<float, access::write> outputTexture [[texture(2)]],
    constant CompositorUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(uniforms.outputSize.x) || gid.y >= uint(uniforms.outputSize.y)) {
        return;
    }

    float2 outputUV = float2(gid) / uniforms.outputSize;

    // Phase 1: Zoom Transform
    // Map output UV back to source UV based on zoom level and center
    float2 zoomCenter = uniforms.zoomCenter;
    float invZoom = 1.0 / uniforms.zoomLevel;

    float2 sourceUV = zoomCenter + (outputUV - 0.5) * invZoom;

    // Clamp to valid range
    sourceUV = clamp(sourceUV, float2(0.0), float2(1.0));

    // Sample source with bicubic interpolation for quality
    float4 color;
    if (uniforms.zoomLevel > 1.01) {
        color = sampleBicubic(sourceTexture, sourceUV, uniforms.sourceSize);
    } else {
        sampler s(filter::linear, address::clamp_to_edge);
        color = sourceTexture.sample(s, sourceUV);
    }

    // Phase 2: Cursor Overlay
    if (uniforms.cursorVisible > 0.5) {
        float2 cursorPos = uniforms.cursorPosition;
        float cursorSize = 24.0 * uniforms.cursorScale; // Base cursor ~24px
        float2 diff = float2(gid) - cursorPos;
        float dist = length(diff);

        if (dist < cursorSize) {
            sampler cursorSampler(filter::linear, address::clamp_to_edge);
            float2 cursorUV = (diff / cursorSize) * 0.5 + 0.5;
            float4 cursorColor = cursorTexture.sample(cursorSampler, cursorUV);
            // Alpha blend cursor over scene
            color = mix(color, cursorColor, cursorColor.a);
        }
    }

    // Phase 3: Click Highlight
    if (uniforms.clickHighlightPhase > 0.0) {
        float2 clickPos = uniforms.cursorPosition;
        float2 diff = float2(gid) - clickPos;
        float dist = length(diff);

        float currentRadius = uniforms.clickHighlightRadius * uniforms.clickHighlightPhase;
        float fadeOut = 1.0 - uniforms.clickHighlightPhase; // Fade as animation progresses

        if (dist < currentRadius) {
            float radialFade = 1.0 - (dist / currentRadius);
            radialFade = radialFade * radialFade; // Quadratic falloff
            float alpha = uniforms.clickHighlightColor.a * radialFade * fadeOut;
            color = mix(color, uniforms.clickHighlightColor, alpha);
        }
    }

    outputTexture.write(color, gid);
}
```

**Step 2: Verify the shader compiles** (Metal shaders compile at build time when added to target)

**Step 3: Commit**

```bash
git add Sources/JackApp/ScreenRecording/Shaders/ZoomCursorCompositor.metal
git commit -m "feat(screen-recording): add Metal compute shader for zoom and cursor compositing"
```

---

### Task 14: MetalVideoRenderer

**Files:**
- Create: `Sources/JackApp/ScreenRecording/MetalVideoRenderer.swift`

**Step 1: Write the renderer**

```swift
import Foundation
import Metal
import MetalKit
import AVFoundation
import CoreVideo

final class MetalVideoRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    private var uniformsBuffer: MTLBuffer?
    private var cursorTexture: MTLTexture?

    // Uniforms struct matching Metal shader
    struct CompositorUniforms {
        var outputSize: SIMD2<Float>
        var sourceSize: SIMD2<Float>
        var zoomCenter: SIMD2<Float>
        var zoomLevel: Float
        var cursorPosition: SIMD2<Float>
        var cursorScale: Float
        var cursorVisible: Float
        var clickHighlightPhase: Float
        var clickHighlightColor: SIMD4<Float>
        var clickHighlightRadius: Float
        var _padding: Float = 0 // Alignment
    }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "MetalVideoRenderer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No Metal device available"])
        }
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            throw NSError(domain: "MetalVideoRenderer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create command queue"])
        }
        self.commandQueue = queue

        // Load compute shader
        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "zoomCursorComposite") else {
            throw NSError(domain: "MetalVideoRenderer", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to load shader"])
        }

        self.pipelineState = try device.makeComputePipelineState(function: function)
    }

    // MARK: - Render Frame

    func renderFrame(
        sourcePixelBuffer: CVPixelBuffer,
        outputSize: CGSize,
        zoomCenter: CGPoint,
        zoomLevel: Double,
        cursorPosition: CGPoint?,
        cursorScale: Double,
        clickPhase: Double,
        clickColor: SIMD4<Float>,
        clickRadius: Double
    ) -> MTLTexture? {
        // Create source texture from pixel buffer
        guard let sourceTexture = makeTexture(from: sourcePixelBuffer) else { return nil }

        // Create output texture
        let outputDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            mipmapped: false
        )
        outputDesc.usage = [.shaderWrite, .shaderRead]
        guard let outputTexture = device.makeTexture(descriptor: outputDesc) else { return nil }

        // Setup uniforms
        var uniforms = CompositorUniforms(
            outputSize: SIMD2<Float>(Float(outputSize.width), Float(outputSize.height)),
            sourceSize: SIMD2<Float>(Float(sourceTexture.width), Float(sourceTexture.height)),
            zoomCenter: SIMD2<Float>(Float(zoomCenter.x), Float(zoomCenter.y)),
            zoomLevel: Float(zoomLevel),
            cursorPosition: cursorPosition.map { SIMD2<Float>(Float($0.x), Float($0.y)) } ?? .zero,
            cursorScale: Float(cursorScale),
            cursorVisible: cursorPosition != nil ? 1.0 : 0.0,
            clickHighlightPhase: Float(clickPhase),
            clickHighlightColor: clickColor,
            clickHighlightRadius: Float(clickRadius)
        )

        // Encode compute command
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(cursorTexture, index: 1)
        encoder.setTexture(outputTexture, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<CompositorUniforms>.size, index: 0)

        // Dispatch threads
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (Int(outputSize.width) + 15) / 16,
            height: (Int(outputSize.height) + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return outputTexture
    }

    // MARK: - Zoom Interpolation

    /// Calculates smooth zoom level for a given timestamp based on keyframes
    static func interpolateZoom(at time: Double, keyframes: [ZoomKeyframe], rampDuration: Double = 0.3) -> Double {
        var level = 1.0
        for kf in keyframes {
            if time < kf.startTime || time > kf.endTime { continue }

            let easeIn = min(1.0, (time - kf.startTime) / rampDuration)
            let easeOut = min(1.0, (kf.endTime - time) / rampDuration)
            let easedIn = cubicBezierEase(easeIn)
            let easedOut = cubicBezierEase(easeOut)
            let blend = min(easedIn, easedOut)

            level = 1.0 + (kf.zoomLevel - 1.0) * blend
        }
        return level
    }

    /// Cubic bezier ease (0.25, 0.1, 0.25, 1.0) approximation
    private static func cubicBezierEase(_ t: Double) -> Double {
        // Approximate CSS "ease" curve
        let t2 = t * t
        let t3 = t2 * t
        return 3.0 * t2 - 2.0 * t3
    }

    /// Exponential smoothing for cursor trailing
    static func smoothCursorPosition(previous: CGPoint, current: CGPoint, factor: Double = 0.15) -> CGPoint {
        CGPoint(
            x: previous.x + (current.x - previous.x) * factor,
            y: previous.y + (current.y - previous.y) * factor
        )
    }

    // MARK: - Texture Helpers

    private var textureCache: CVMetalTextureCache?

    private func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        if textureCache == nil {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
            textureCache = cache
        }

        guard let cache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else { return nil }

        return CVMetalTextureGetTexture(cvTexture)
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1 | head -30`

**Step 3: Commit**

```bash
git add Sources/JackApp/ScreenRecording/MetalVideoRenderer.swift
git commit -m "feat(screen-recording): add Metal video renderer with zoom and cursor compositing"
```

---

## Phase 8: Video Editor

### Task 15: VideoEditorController

**Files:**
- Create: `Sources/JackApp/ScreenRecording/VideoEditorController.swift`

**Step 1: Write the controller**

```swift
import Foundation
import AVFoundation
import Observation

@Observable
@MainActor
final class VideoEditorController {
    // MARK: - State

    private(set) var session: RecordingSession
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    var currentTime: TimeInterval = 0

    // Edit state
    var cuts: [CutRegion] = []
    var zoomKeyframes: [ZoomKeyframe] = []
    var cursorScale: Double = 1.5
    var clickHighlightEnabled: Bool = true
    var clickHighlightColor: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.3)
    var clickHighlightOpacity: Double = 0.3
    var cursorSmoothingEnabled: Bool = true

    // Audio
    var micVolume: Float = 1.0
    var systemVolume: Float = 1.0
    var micMuted: Bool = false
    var systemMuted: Bool = false

    // Cursor data
    private(set) var cursorData: CursorTrackingData?

    // In/Out points for cutting
    var inPoint: TimeInterval?
    var outPoint: TimeInterval?

    // Undo stack
    private var undoStack: [EditorSnapshot] = []
    private var redoStack: [EditorSnapshot] = []

    // Playback
    private var playbackTask: Task<Void, Never>?

    // MARK: - Init

    init(session: RecordingSession) {
        self.session = session
    }

    func load() async {
        // Load video duration
        let asset = AVURLAsset(url: session.screenVideoURL)
        if let dur = try? await asset.load(.duration) {
            duration = dur.seconds
        }

        // Load cursor data
        if let data = try? Data(contentsOf: session.cursorDataURL),
           let decoded = try? JSONDecoder().decode(CursorTrackingData.self, from: data) {
            cursorData = decoded
        }
    }

    // MARK: - Playback

    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        playbackTask = Task {
            let startTime = currentTime
            let startDate = Date()
            while !Task.isCancelled && currentTime < duration {
                try? await Task.sleep(for: .milliseconds(16)) // ~60fps
                let elapsed = Date().timeIntervalSince(startDate)
                currentTime = min(startTime + elapsed, duration)

                // Skip cut regions
                for cut in cuts {
                    if currentTime >= cut.inPoint && currentTime <= cut.outPoint {
                        currentTime = cut.outPoint
                    }
                }
            }
            isPlaying = false
        }
    }

    func pause() {
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func stepForward() {
        currentTime = min(currentTime + 1.0 / 60.0, duration)
    }

    func stepBackward() {
        currentTime = max(currentTime - 1.0 / 60.0, 0)
    }

    // MARK: - Cutting

    func setInPoint() {
        saveSnapshot()
        inPoint = currentTime
    }

    func setOutPoint() {
        saveSnapshot()
        outPoint = currentTime
    }

    func deleteSelection() {
        guard let inPt = inPoint, let outPt = outPoint, inPt < outPt else { return }
        saveSnapshot()
        cuts.append(CutRegion(id: UUID(), inPoint: inPt, outPoint: outPt))
        inPoint = nil
        outPoint = nil
    }

    // MARK: - Zoom

    func addZoomRegion(start: Double, end: Double, level: Double) {
        saveSnapshot()
        zoomKeyframes.append(ZoomKeyframe(id: UUID(), startTime: start, endTime: end, zoomLevel: level))
    }

    func removeZoomRegion(id: UUID) {
        saveSnapshot()
        zoomKeyframes.removeAll { $0.id == id }
    }

    // MARK: - Cursor at Time

    func cursorPosition(at time: TimeInterval) -> CGPoint? {
        guard let data = cursorData else { return nil }
        // Binary search for closest event
        let events = data.events
        guard !events.isEmpty else { return nil }

        var lo = 0, hi = events.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if events[mid].t < time {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        let event = events[lo]
        return CGPoint(x: event.x, y: event.y)
    }

    func clickAtTime(_ time: TimeInterval, window: TimeInterval = 0.4) -> CursorEvent? {
        guard let data = cursorData else { return nil }
        return data.events.first { $0.click != nil && abs($0.t - time) < window }
    }

    // MARK: - Undo/Redo

    private struct EditorSnapshot {
        let cuts: [CutRegion]
        let zoomKeyframes: [ZoomKeyframe]
        let cursorScale: Double
    }

    private func saveSnapshot() {
        undoStack.append(EditorSnapshot(cuts: cuts, zoomKeyframes: zoomKeyframes, cursorScale: cursorScale))
        redoStack.removeAll()
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(EditorSnapshot(cuts: cuts, zoomKeyframes: zoomKeyframes, cursorScale: cursorScale))
        cuts = snapshot.cuts
        zoomKeyframes = snapshot.zoomKeyframes
        cursorScale = snapshot.cursorScale
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(EditorSnapshot(cuts: cuts, zoomKeyframes: zoomKeyframes, cursorScale: cursorScale))
        cuts = snapshot.cuts
        zoomKeyframes = snapshot.zoomKeyframes
        cursorScale = snapshot.cursorScale
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1 | head -20`

**Step 3: Commit**

```bash
git add Sources/JackApp/ScreenRecording/VideoEditorController.swift
git commit -m "feat(screen-recording): add video editor controller with cut, zoom, and undo"
```

---

### Task 16: Video Editor View (Preview + Toolbar)

**Files:**
- Create: `Sources/JackApp/ScreenRecording/VideoEditorView.swift`

**Context:** Full SwiftUI window with MetalKit preview, timelines, and controls. This is a large view — build it as the main container with sub-views extracted as needed.

**Step 1: Write the main editor view**

This is a large file. Build the top-level layout first, then wire up components in subsequent tasks. Focus on:
- Toolbar (undo/redo/export/done)
- Video preview placeholder (MTKView wrapped via NSViewRepresentable)
- Cursor effects panel
- Placeholder sections for timelines

```swift
import SwiftUI
import MetalKit

struct VideoEditorView: View {
    @Bindable var editor: VideoEditorController
    var onDone: () -> Void
    var onExport: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            editorToolbar

            Divider()

            // Video Preview
            videoPreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Cursor Effects Panel (collapsible)
            cursorEffectsPanel
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            Divider()

            // Timelines
            VStack(spacing: 4) {
                videoTimeline
                zoomTimeline
                audioTracks
            }
            .padding(12)
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color(nsColor: NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)))
        .preferredColorScheme(.dark)
        .onKeyPress(.space) { editor.togglePlayPause(); return .handled }
        .onKeyPress(.leftArrow) { editor.stepBackward(); return .handled }
        .onKeyPress(.rightArrow) { editor.stepForward(); return .handled }
    }

    // MARK: - Toolbar

    private var editorToolbar: some View {
        HStack {
            Button(action: editor.undo) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(true) // TODO: track undo stack emptiness

            Button(action: editor.redo) {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])

            Spacer()

            Button(action: onExport) {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .keyboardShortcut("e", modifiers: .command)
            .buttonStyle(.borderedProminent)

            Button("Done", action: onDone)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Video Preview

    private var videoPreview: some View {
        ZStack {
            // Placeholder - MTKView integration in Task 17
            Rectangle()
                .fill(Color.black)
                .overlay {
                    Text("Preview")
                        .foregroundStyle(.secondary)
                }

            // Play/Pause overlay
            if !editor.isPlaying {
                Button(action: editor.play) {
                    Image(systemName: "play.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                        .padding(20)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
            }

            // Playhead time
            VStack {
                Spacer()
                HStack {
                    Text(formatTime(editor.currentTime))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.black.opacity(0.6)))
                    Spacer()
                    Text(formatTime(editor.duration))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.black.opacity(0.6)))
                }
                .padding(8)
            }
        }
    }

    // MARK: - Cursor Effects Panel

    @State private var showCursorEffects = true

    private var cursorEffectsPanel: some View {
        DisclosureGroup("Cursor Effects", isExpanded: $showCursorEffects) {
            HStack(spacing: 24) {
                HStack {
                    Text("Size:")
                        .foregroundStyle(.secondary)
                    Slider(value: $editor.cursorScale, in: 1.0...3.0, step: 0.25)
                        .frame(width: 150)
                    Text(String(format: "%.1fx", editor.cursorScale))
                        .foregroundStyle(.secondary)
                        .frame(width: 30)
                }

                Toggle("Click Highlight", isOn: $editor.clickHighlightEnabled)

                Toggle("Cursor Smoothing", isOn: $editor.cursorSmoothingEnabled)
            }
        }
    }

    // MARK: - Video Timeline

    private var videoTimeline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Video")
                .font(.caption)
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.05))

                    // Cut regions (shown as gaps)
                    ForEach(editor.cuts) { cut in
                        let x = cut.inPoint / editor.duration * geo.size.width
                        let w = (cut.outPoint - cut.inPoint) / editor.duration * geo.size.width
                        Rectangle()
                            .fill(Color.red.opacity(0.3))
                            .frame(width: w)
                            .offset(x: x)
                    }

                    // In/Out points
                    if let inPt = editor.inPoint {
                        Rectangle()
                            .fill(Color.yellow)
                            .frame(width: 2)
                            .offset(x: inPt / editor.duration * geo.size.width)
                    }
                    if let outPt = editor.outPoint {
                        Rectangle()
                            .fill(Color.yellow)
                            .frame(width: 2)
                            .offset(x: outPt / editor.duration * geo.size.width)
                    }

                    // Playhead
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2)
                        .offset(x: editor.currentTime / max(editor.duration, 0.001) * geo.size.width)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let ratio = value.location.x / geo.size.width
                            editor.currentTime = max(0, min(editor.duration, ratio * editor.duration))
                        }
                )
            }
            .frame(height: 30)
        }
    }

    // MARK: - Zoom Timeline

    private var zoomTimeline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Zoom")
                .font(.caption)
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.03))

                    ForEach(editor.zoomKeyframes) { kf in
                        let x = kf.startTime / editor.duration * geo.size.width
                        let w = (kf.endTime - kf.startTime) / editor.duration * geo.size.width
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.blue.opacity(0.4))
                            .frame(width: max(w, 20))
                            .offset(x: x)
                            .overlay {
                                Text(String(format: "%.1fx", kf.zoomLevel))
                                    .font(.caption2)
                                    .foregroundStyle(.white)
                            }
                    }

                    // Playhead (shared with video timeline)
                    Rectangle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 1)
                        .offset(x: editor.currentTime / max(editor.duration, 0.001) * geo.size.width)
                }
            }
            .frame(height: 24)
        }
    }

    // MARK: - Audio Tracks

    private var audioTracks: some View {
        VStack(alignment: .leading, spacing: 6) {
            audioTrackRow(label: "Mic", volume: $editor.micVolume, muted: $editor.micMuted, icon: "mic.fill")
            audioTrackRow(label: "System", volume: $editor.systemVolume, muted: $editor.systemMuted, icon: "speaker.wave.2.fill")
        }
    }

    private func audioTrackRow(label: String, volume: Binding<Float>, muted: Binding<Bool>, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)

            // Waveform placeholder
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white.opacity(0.05))
                .frame(height: 20)

            Slider(value: volume, in: 0...1)
                .frame(width: 80)

            Button(action: { muted.wrappedValue.toggle() }) {
                Image(systemName: muted.wrappedValue ? "speaker.slash.fill" : "speaker.fill")
                    .foregroundStyle(muted.wrappedValue ? .red : .secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let mins = total / 60
        let secs = total % 60
        let frames = Int((seconds - Double(total)) * 60)
        return String(format: "%02d:%02d.%02d", mins, secs, frames)
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1 | head -30`

**Step 3: Commit**

```bash
git add Sources/JackApp/ScreenRecording/VideoEditorView.swift
git commit -m "feat(screen-recording): add video editor view with timeline and controls"
```

---

### Task 17: MTKView Preview Integration

**Files:**
- Create: `Sources/JackApp/ScreenRecording/MetalPreviewView.swift`

**Context:** NSViewRepresentable wrapping MTKView that renders composited frames from MetalVideoRenderer based on the editor's current playhead position.

**Step 1: Write the NSViewRepresentable**

```swift
import SwiftUI
import MetalKit
import AVFoundation

struct MetalPreviewView: NSViewRepresentable {
    let session: RecordingSession
    @Bindable var editor: VideoEditorController

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        mtkView.delegate = context.coordinator
        return mtkView
    }

    func updateNSView(_ mtkView: MTKView, context: Context) {
        context.coordinator.editor = editor
        mtkView.setNeedsDisplay(mtkView.bounds)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, editor: editor)
    }

    class Coordinator: NSObject, MTKViewDelegate {
        var editor: VideoEditorController
        private let session: RecordingSession
        private var renderer: MetalVideoRenderer?
        private var assetReader: AVAssetReader?
        private var videoOutput: AVAssetReaderTrackOutput?
        private var lastRenderedTime: TimeInterval = -1

        init(session: RecordingSession, editor: VideoEditorController) {
            self.session = session
            self.editor = editor
            super.init()
            self.renderer = try? MetalVideoRenderer()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let renderer,
                  let drawable = view.currentDrawable else { return }

            // Only re-render if time changed
            guard editor.currentTime != lastRenderedTime else { return }
            lastRenderedTime = editor.currentTime

            // Read frame at current time (simplified - full implementation would use
            // AVAssetImageGenerator or seekable AVAssetReader)
            // For now, this is the integration point - the actual frame reading
            // will be refined during implementation
            guard let pixelBuffer = readFrame(at: editor.currentTime) else { return }

            let zoomLevel = MetalVideoRenderer.interpolateZoom(
                at: editor.currentTime,
                keyframes: editor.zoomKeyframes
            )

            let cursorPos = editor.cursorPosition(at: editor.currentTime)
            let clickEvent = editor.clickAtTime(editor.currentTime)

            let outputTexture = renderer.renderFrame(
                sourcePixelBuffer: pixelBuffer,
                outputSize: view.drawableSize,
                zoomCenter: cursorPos ?? CGPoint(x: 0.5, y: 0.5),
                zoomLevel: zoomLevel,
                cursorPosition: cursorPos,
                cursorScale: editor.cursorScale,
                clickPhase: clickEvent != nil ? 0.5 : 0,
                clickColor: SIMD4<Float>(1, 1, 1, Float(editor.clickHighlightOpacity)),
                clickRadius: 40
            )

            // Blit to drawable (simplified)
            if let commandBuffer = renderer.commandQueue.makeCommandBuffer(),
               let blitEncoder = commandBuffer.makeBlitCommandEncoder(),
               let output = outputTexture {
                blitEncoder.copy(from: output, to: drawable.texture)
                blitEncoder.endEncoding()
                commandBuffer.present(drawable)
                commandBuffer.commit()
            }
        }

        private func readFrame(at time: TimeInterval) -> CVPixelBuffer? {
            // Implementation: Use AVAssetImageGenerator for thumbnail frames
            // or AVAssetReader with seek for full-quality frames
            // This will be fleshed out during implementation
            return nil
        }
    }
}
```

Note: The `commandQueue` property on `MetalVideoRenderer` is currently private. During implementation, expose it as `internal` or add a `blitToDrawable` method.

**Step 2: Verify it compiles**

Run: `swift build 2>&1 | head -20`

**Step 3: Commit**

```bash
git add Sources/JackApp/ScreenRecording/MetalPreviewView.swift
git commit -m "feat(screen-recording): add MTKView preview integration for editor"
```

---

## Phase 9: Export Pipeline

### Task 18: ExportService

**Files:**
- Create: `Sources/JackApp/ScreenRecording/ExportService.swift`

**Step 1: Write the export service**

```swift
import Foundation
import AVFoundation

actor ExportService {
    struct ExportConfiguration {
        var codec: VideoCodec
        var quality: ExportQuality
        var resolution: ExportResolution
        var outputURL: URL
    }

    /// Export with Metal rendering applied (zoom, cursor, etc.)
    func exportWithEffects(
        session: RecordingSession,
        editor: VideoEditorController,
        config: ExportConfiguration,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        let renderer = try MetalVideoRenderer()

        let sourceAsset = AVURLAsset(url: session.screenVideoURL)
        let duration = try await sourceAsset.load(.duration)
        let totalSeconds = duration.seconds

        // Setup asset reader
        let reader = try AVAssetReader(asset: sourceAsset)
        guard let videoTrack = try await sourceAsset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "ExportService", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }

        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerSettings)
        reader.add(videoOutput)

        // Setup asset writer
        let writer = try AVAssetWriter(outputURL: config.outputURL, fileType: .mp4)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let outputSize = resolvedSize(natural: naturalSize, resolution: config.resolution)

        let videoSettings = videoWriterSettings(codec: config.codec, quality: config.quality, size: outputSize)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height),
            ]
        )
        writer.add(videoInput)

        // Add audio tracks
        await addAudioTracks(to: writer, session: session, editor: editor)

        // Start reading and writing
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var frameCount = 0

        while let sampleBuffer = videoOutput.copyNextSampleBuffer() {
            let presentationTime = sampleBuffer.presentationTimeStamp.seconds

            // Skip cut regions
            let isCut = await MainActor.run {
                editor.cuts.contains { presentationTime >= $0.inPoint && presentationTime <= $0.outPoint }
            }
            if isCut { continue }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }

            // Get editor state on main actor
            let (zoomKeyframes, cursorScale, cursorPos) = await MainActor.run {
                (editor.zoomKeyframes, editor.cursorScale, editor.cursorPosition(at: presentationTime))
            }

            let zoomLevel = MetalVideoRenderer.interpolateZoom(at: presentationTime, keyframes: zoomKeyframes)

            // Render through Metal
            guard let outputTexture = renderer.renderFrame(
                sourcePixelBuffer: pixelBuffer,
                outputSize: outputSize,
                zoomCenter: cursorPos ?? CGPoint(x: 0.5, y: 0.5),
                zoomLevel: zoomLevel,
                cursorPosition: cursorPos,
                cursorScale: cursorScale,
                clickPhase: 0, // TODO: compute from cursor data
                clickColor: SIMD4<Float>(1, 1, 1, 0.3),
                clickRadius: 40
            ) else { continue }

            // Convert Metal texture back to pixel buffer and append
            // (Implementation detail: create CVPixelBuffer from texture)
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }

            // For now, write the original buffer; Metal texture → CVPixelBuffer conversion
            // will be implemented during the actual build
            adaptor.append(pixelBuffer, withPresentationTime: sampleBuffer.presentationTimeStamp)

            frameCount += 1
            progress(presentationTime / totalSeconds)
        }

        videoInput.markAsFinished()
        await writer.finishWriting()

        progress(1.0)
    }

    // MARK: - Helpers

    private func resolvedSize(natural: CGSize, resolution: ExportResolution) -> CGSize {
        switch resolution {
        case .original: return natural
        case .p1080:
            let aspect = natural.width / natural.height
            return CGSize(width: 1920, height: 1920 / aspect)
        case .p720:
            let aspect = natural.width / natural.height
            return CGSize(width: 1280, height: 1280 / aspect)
        }
    }

    private func videoWriterSettings(codec: VideoCodec, quality: ExportQuality, size: CGSize) -> [String: Any] {
        let codecType: AVVideoCodecType = codec == .h265 ? .hevc : .h264
        let bitrate: Int
        switch quality {
        case .low: bitrate = 2_000_000
        case .medium: bitrate = 5_000_000
        case .high: bitrate = 10_000_000
        case .lossless: bitrate = 50_000_000
        }

        return [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: codec == .h265
                    ? kVTProfileLevel_HEVC_Main_AutoLevel
                    : AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
    }

    private func addAudioTracks(to writer: AVAssetWriter, session: RecordingSession, editor: VideoEditorController) async {
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000,
        ]

        // Mic audio
        let micMuted = await MainActor.run { editor.micMuted }
        if !micMuted && FileManager.default.fileExists(atPath: session.micAudioURL.path) {
            let micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            if writer.canAdd(micInput) { writer.add(micInput) }
        }

        // System audio
        let sysMuted = await MainActor.run { editor.systemMuted }
        if !sysMuted && FileManager.default.fileExists(atPath: session.systemAudioURL.path) {
            let sysInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            if writer.canAdd(sysInput) { writer.add(sysInput) }
        }
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1 | head -30`

**Step 3: Commit**

```bash
git add Sources/JackApp/ScreenRecording/ExportService.swift
git commit -m "feat(screen-recording): add export service with Metal rendering pipeline"
```

---

## Phase 10: App Integration

### Task 19: Sidebar Integration

**Files:**
- Modify: `Sources/JackApp/ContentView.swift`

**Step 1: Add Screen Recording to SettingsSection enum**

In `SettingsSection` enum (~line 384), add a new case:

```swift
case screenRecording  // Add after 'advanced'
```

Add corresponding computed properties:
- `title`: "Screen Recording"
- `subtitle`: "Capture and edit screen recordings"
- `systemImage`: "record.circle"

**Step 2: Add the section view**

In the `sectionView()` switch (~line 39), add:

```swift
case .screenRecording:
    screenRecordingSection
```

**Step 3: Build the section content**

Add a new computed property `screenRecordingSection`:

```swift
private var screenRecordingSection: some View {
    VStack(alignment: .leading, spacing: 16) {
        // Permission status
        if !recordingController.hasScreenPermission {
            settingsCard(title: "Permission Required", subtitle: "Screen Recording access needed") {
                Button("Grant Permission") {
                    Task { await recordingController.refreshPermissions() }
                }
                .buttonStyle(.borderedProminent)
            }
        }

        // Start Recording button
        settingsCard(title: "Recording", subtitle: "Start a new screen recording") {
            Button(action: {
                Task { await recordingController.openSetup() }
                setupWindowController.show(controller: recordingController)
            }) {
                Label("Start Recording", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!recordingController.hasScreenPermission)
        }

        // Default settings
        settingsCard(title: "Defaults", subtitle: "Default recording settings") {
            Picker("Frame Rate", selection: $recordingController.fps) {
                ForEach(RecordingFPS.allCases) { fps in
                    Text(fps.label).tag(fps)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}
```

**Step 4: Wire up the controller**

In `ContentView`, add `recordingController` as a parameter (or environment object) alongside the existing `controller: DictationController`.

**Step 5: Verify it compiles**

Run: `swift build 2>&1 | head -30`

**Step 6: Commit**

```bash
git add Sources/JackApp/ContentView.swift
git commit -m "feat(screen-recording): add Screen Recording sidebar section"
```

---

### Task 20: App Entry Point Integration

**Files:**
- Modify: `Sources/JackApp/JackApp.swift`

**Step 1: Add RecordingSessionController to RootView**

In `RootView` (~line 17), add a `@State` property:

```swift
@State private var recordingController = RecordingSessionController()
```

**Step 2: Pass to ContentView**

Update the ContentView initializer to accept the recording controller.

**Step 3: Add initialization**

In the `.task` modifier, add:

```swift
await recordingController.initialize()
```

**Step 4: Verify it compiles**

Run: `swift build 2>&1 | head -30`

**Step 5: Commit**

```bash
git add Sources/JackApp/JackApp.swift
git commit -m "feat(screen-recording): wire RecordingSessionController into app entry point"
```

---

### Task 21: Onboarding Wizard — Screen Recording Permission Step

**Files:**
- Modify: `Sources/JackApp/OnboardingWizardView.swift`

**Step 1: Add new wizard step**

In `WizardStep` enum (~line 33), add `screenRecordingPermissions` between `permissions` and `shortcut`:

```swift
case screenRecordingPermissions
```

Update `CaseIterable` compliance — the step count increases to 5.

**Step 2: Add the step view**

Create a new view function `screenRecordingPermissionsStep` following the two-column layout pattern from `permissionsStep` (~line 256). Include:
- Left column: screen recording icon + title
- Right column: Screen Recording permission card + Camera permission card
- "Skip for now" link at bottom

**Step 3: Update step routing**

In the step content switch (~line 105), add the new case.

**Step 4: Verify it compiles**

Run: `swift build 2>&1 | head -20`

**Step 5: Commit**

```bash
git add Sources/JackApp/OnboardingWizardView.swift
git commit -m "feat(screen-recording): add optional permissions step to onboarding wizard"
```

---

### Task 22: AppMode Integration in DictationController

**Files:**
- Modify: `Sources/JackApp/DictationController.swift`

**Step 1: Add appMode property**

Near the top of the @Published properties (~line 15), add:

```swift
@Published var appMode: AppMode = .dictation
```

**Step 2: Guard recording against mode**

In `beginRecording()` (~line 678), add a guard:

```swift
guard appMode == .dictation else { return }
```

This ensures dictation doesn't start while in screen recording mode.

**Step 3: Verify it compiles**

Run: `swift build 2>&1 | head -20`

**Step 4: Commit**

```bash
git add Sources/JackApp/DictationController.swift
git commit -m "feat(screen-recording): add AppMode to DictationController for mode separation"
```

---

## Phase 11: Export Dialog & Polish

### Task 23: Export Dialog View

**Files:**
- Create: `Sources/JackApp/ScreenRecording/ExportDialogView.swift`

**Step 1: Write the export dialog**

```swift
import SwiftUI

struct ExportDialogView: View {
    @Bindable var editor: VideoEditorController
    @State private var codec: VideoCodec = .h264
    @State private var quality: ExportQuality = .high
    @State private var resolution: ExportResolution = .original
    @State private var isExporting = false
    @State private var progress: Double = 0
    var onExport: (VideoCodec, ExportQuality, ExportResolution) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Export Recording")
                .font(.headline)

            // Codec
            VStack(alignment: .leading) {
                Text("Codec")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("", selection: $codec) {
                    ForEach(VideoCodec.allCases) { c in
                        Text(c.label).tag(c)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Quality
            VStack(alignment: .leading) {
                Text("Quality")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("", selection: $quality) {
                    ForEach(ExportQuality.allCases) { q in
                        Text(q.label).tag(q)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Resolution
            VStack(alignment: .leading) {
                Text("Resolution")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("", selection: $resolution) {
                    ForEach(ExportResolution.allCases) { r in
                        Text(r.label).tag(r)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Destination
            HStack {
                Text("Save to:")
                    .foregroundStyle(.secondary)
                Text("~/Documents/Jack Recordings/")
                    .font(.system(.caption, design: .monospaced))
            }

            if isExporting {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Actions
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export") {
                    onExport(codec, quality, resolution)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExporting)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1 | head -20`

**Step 3: Commit**

```bash
git add Sources/JackApp/ScreenRecording/ExportDialogView.swift
git commit -m "feat(screen-recording): add export dialog with codec/quality/resolution options"
```

---

### Task 24: Package.swift — Metal Shader Resources

**Files:**
- Modify: `Package.swift`

**Step 1: Ensure Metal files are included**

Metal shaders in SPM need to be in the source directory. Verify the `Resources` processing in Package.swift includes `.metal` files, or that they're in the correct source path. SPM compiles `.metal` files automatically when they're in the target's source directory.

If needed, add explicit resource processing for the Shaders directory.

**Step 2: Verify full build**

Run: `swift build 2>&1 | tail -30`

**Step 3: Commit if changes needed**

```bash
git add Package.swift
git commit -m "chore: ensure Metal shaders compile in SPM build"
```

---

### Task 25: Integration Smoke Test

**Step 1: Full build verification**

Run: `swift build 2>&1`

Fix any compilation errors.

**Step 2: Verify all new files exist**

Expected new files in `Sources/JackApp/ScreenRecording/`:
- `RecordingTypes.swift`
- `ScreenRecordingService.swift`
- `CursorTrackingService.swift`
- `WebcamCaptureService.swift`
- `MicrophoneCaptureService.swift`
- `RecordingSessionController.swift`
- `SetupWindowController.swift`
- `RecordingSetupView.swift`
- `RecordingBubbleController.swift`
- `WebcamOverlayController.swift`
- `RegionSelectionController.swift`
- `CountdownOverlayController.swift`
- `MetalVideoRenderer.swift`
- `VideoEditorController.swift`
- `VideoEditorView.swift`
- `MetalPreviewView.swift`
- `ExportService.swift`
- `ExportDialogView.swift`
- `Shaders/ZoomCursorCompositor.metal`

Modified files:
- `ContentView.swift`
- `JackApp.swift`
- `OnboardingWizardView.swift`
- `DictationController.swift`

**Step 3: Run existing tests**

Run: `swift test 2>&1 | tail -20`

**Step 4: Final commit**

```bash
git add -A
git commit -m "feat(screen-recording): complete initial screen recording implementation"
```

---

## Summary

| Phase | Tasks | Description |
|-------|-------|-------------|
| 1 | 1 | Foundation types & enums |
| 2 | 2-5 | Capture services (cursor, screen, webcam, mic) |
| 3 | 6 | Recording session controller |
| 4 | 7-8 | Setup window (panel + SwiftUI view) |
| 5 | 9-11 | Recording bubble, webcam overlay, region selection |
| 6 | 12 | Countdown overlay |
| 7 | 13-14 | Metal shader + renderer |
| 8 | 15-17 | Video editor (controller, view, MTKView preview) |
| 9 | 18 | Export service |
| 10 | 19-22 | App integration (sidebar, entry point, onboarding, mode) |
| 11 | 23-25 | Export dialog, package config, smoke test |

**Total: 25 tasks across 11 phases**
