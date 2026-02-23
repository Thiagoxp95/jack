import AVFoundation
import CoreMedia
import ScreenCaptureKit
import SwiftUI

// MARK: - RecordingSetupView

struct RecordingSetupView: View {
    @Bindable var controller: RecordingSessionController
    var onClose: () -> Void

    @State private var isStarting = false
    @State private var micLevel: Float = 0
    @State private var micMonitor: MicLevelMonitor?
    @State private var previewWebcam: WebcamCaptureService?
    @State private var webcamReady = false

    var body: some View {
        VStack(spacing: 0) {
            webcamPreviewSection
                .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    deviceSection
                    sourceSection
                    optionsSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }

            Divider()
                .overlay(SetupColors.divider)

            actionBar
        }
        .frame(width: 420, height: 580)
        .background(SetupColors.background)
        .onAppear { startPreviews() }
        .onDisappear { stopPreviews() }
        .onChange(of: controller.recordWebcam) { _, on in
            if on { startWebcamPreview() } else { stopWebcamPreview() }
        }
        .onChange(of: controller.selectedCameraDeviceID) { _, _ in
            restartWebcamPreview()
        }
        .onChange(of: controller.recordMicrophone) { _, on in
            if on { restartMicMonitor() } else { stopMicMonitor() }
        }
        .onChange(of: controller.selectedMicDeviceID) { _, _ in
            restartMicMonitor()
        }
    }

    // MARK: - Webcam Preview

    @ViewBuilder
    private var webcamPreviewSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(SetupColors.previewWell)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(SetupColors.subtleStroke, lineWidth: 1)
                )
                .frame(height: 180)

            if controller.recordWebcam {
                if webcamReady, let svc = previewWebcam {
                    CameraPreviewCircle(service: svc)
                        .frame(width: 120, height: 120)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(
                                    LinearGradient(
                                        colors: [Color(hex: 0x5E5CE6), Color(hex: 0x007AFF)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 3
                                )
                        )
                        .shadow(color: Color(hex: 0x5E5CE6).opacity(0.3), radius: 12)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 120, height: 120)
                        .overlay(
                            Circle()
                                .stroke(SetupColors.subtleStroke, lineWidth: 2)
                        )
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("Camera Off")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Device Section

    @ViewBuilder
    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Microphone
            setupCard {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(SetupColors.accentGradient)
                            .frame(width: 32, height: 32)
                        Image(systemName: "mic.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Microphone")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Toggle("", isOn: $controller.recordMicrophone)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                        }

                        if controller.recordMicrophone {
                            micDevicePicker
                            micLevelBar
                        }
                    }
                }
            }

            // Camera
            setupCard {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(SetupColors.accentGradient)
                            .frame(width: 32, height: 32)
                        Image(systemName: "video.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Camera")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Toggle("", isOn: $controller.recordWebcam)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                        }

                        if controller.recordWebcam {
                            cameraDevicePicker

                            HStack(spacing: 8) {
                                Text("Size")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Slider(
                                    value: $controller.webcamDiameter,
                                    in: WebcamDefaults.minDiameter...WebcamDefaults.maxDiameter,
                                    step: 10
                                )
                                .controlSize(.small)
                                Text("\(Int(controller.webcamDiameter))px")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .trailing)
                            }
                        }
                    }
                }
            }

            // System audio
            setupCard {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(SetupColors.accentGradient)
                            .frame(width: 32, height: 32)
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    Text("System Audio")
                        .font(.system(size: 13, weight: .semibold))

                    Spacer()

                    Toggle("", isOn: $controller.recordSystemAudio)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }
        }
    }

    @ViewBuilder
    private var micDevicePicker: some View {
        let devices = controller.availableMicDevices
        if !devices.isEmpty {
            Picker("", selection: $controller.selectedMicDeviceID) {
                Text("Default").tag(nil as String?)
                ForEach(devices, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(device.uniqueID as String?)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var micLevelBar: some View {
        HStack(spacing: 3) {
            ForEach(0..<20, id: \.self) { i in
                let threshold = Float(i) / 20.0
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor(for: i))
                    .frame(height: 6)
                    .opacity(micLevel > threshold ? 1.0 : 0.15)
            }
        }
        .animation(.easeOut(duration: 0.08), value: micLevel)
    }

    private func barColor(for index: Int) -> Color {
        let ratio = Float(index) / 20.0
        if ratio < 0.6 {
            return Color(hex: 0x34D399)
        } else if ratio < 0.8 {
            return Color(hex: 0xFBBF24)
        } else {
            return Color(hex: 0xEF4444)
        }
    }

    @ViewBuilder
    private var cameraDevicePicker: some View {
        let cameras = controller.availableCameras
        if !cameras.isEmpty {
            Picker("", selection: $controller.selectedCameraDeviceID) {
                Text("Default").tag(nil as String?)
                ForEach(cameras, id: \.uniqueID) { camera in
                    Text(camera.localizedName).tag(camera.uniqueID as String?)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    // MARK: - Source Section

    @ViewBuilder
    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What to record")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(CaptureSourceType.allCases) { type in
                    sourceButton(type)
                }
            }

            switch controller.sourceType {
            case .screen:
                screenPicker
            case .window:
                windowPicker
            case .region:
                regionPicker
            }
        }
    }

    @ViewBuilder
    private func sourceButton(_ type: CaptureSourceType) -> some View {
        let isSelected = controller.sourceType == type
        Button {
            controller.sourceType = type
        } label: {
            HStack(spacing: 6) {
                Image(systemName: type.iconName)
                    .font(.system(size: 11, weight: .medium))
                Text(type.title)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(SetupColors.accentGradient) : AnyShapeStyle(SetupColors.subtleFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.clear : SetupColors.subtleStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var screenPicker: some View {
        if controller.availableDisplays.isEmpty {
            Text("No displays found")
                .foregroundStyle(.secondary)
                .font(.caption)
        } else {
            Picker("Display", selection: $controller.selectedDisplayIndex) {
                ForEach(
                    Array(controller.availableDisplays.enumerated()),
                    id: \.offset
                ) { index, display in
                    Text("Display \(index + 1) (\(display.width)x\(display.height))")
                        .tag(index)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var windowPicker: some View {
        if controller.availableWindows.isEmpty {
            Text("No windows available")
                .foregroundStyle(.secondary)
                .font(.caption)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(controller.availableWindows, id: \.windowID) { window in
                        windowThumbnailButton(window)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func windowThumbnailButton(_ window: SCWindow) -> some View {
        let isSelected = controller.selectedWindowID == window.windowID
        let appName = window.owningApplication?.applicationName ?? "Unknown"

        Button {
            controller.selectedWindowID = window.windowID
        } label: {
            VStack(spacing: 4) {
                if let icon = appIcon(for: window) {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 32, height: 32)
                        .frame(width: 56, height: 40)
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: 20))
                        .frame(width: 56, height: 40)
                }

                Text(appName)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(width: 56)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color(hex: 0x5E5CE6).opacity(0.2) : SetupColors.subtleFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isSelected ? Color(hex: 0x5E5CE6) : SetupColors.subtleStroke,
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func appIcon(for window: SCWindow) -> NSImage? {
        guard let bundleID = window.owningApplication?.bundleIdentifier else { return nil }

        // Try running apps first (faster)
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let icon = app.icon
        {
            return icon
        }

        // Fallback to workspace
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }

        return nil
    }

    @ViewBuilder
    private var regionPicker: some View {
        HStack {
            Button("Select Region...") {
                // Region selection handled externally
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if let region = controller.selectedRegion {
                Text("\(Int(region.width)) x \(Int(region.height))")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    // MARK: - Options Section

    @ViewBuilder
    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quality")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(RecordingFPS.allCases) { fpsOption in
                    fpsButton(fpsOption)
                }
            }
        }
    }

    @ViewBuilder
    private func fpsButton(_ fpsOption: RecordingFPS) -> some View {
        let isSelected = controller.fps == fpsOption
        Button {
            controller.fps = fpsOption
        } label: {
            Text(fpsOption.label)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Color.primary.opacity(0.12) : SetupColors.subtleFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.primary.opacity(0.15) : SetupColors.subtleStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Action Bar

    @ViewBuilder
    private var actionBar: some View {
        HStack {
            Button {
                stopPreviews()
                controller.cancelSetup()
                onClose()
            } label: {
                Text("Cancel")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button {
                isStarting = true
                stopPreviews()
                onClose()
                Task {
                    do {
                        try await controller.startRecording()
                    } catch {
                        // Error logged in controller
                    }
                    isStarting = false
                }
            } label: {
                HStack(spacing: 6) {
                    if isStarting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 8, height: 8)
                        Text("Start Recording")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: 0xEF4444), Color(hex: 0xDC2626)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .shadow(color: Color(hex: 0xEF4444).opacity(0.3), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .disabled(isStarting)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func setupCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SetupColors.subtleFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(SetupColors.subtleStroke, lineWidth: 1)
        )
    }

    // MARK: - Preview Management

    private func startPreviews() {
        if controller.recordMicrophone {
            startMicMonitor()
        }
        if controller.recordWebcam {
            startWebcamPreview()
        }
    }

    private func stopPreviews() {
        stopMicMonitor()
        stopWebcamPreview()
    }

    private func startMicMonitor() {
        guard micMonitor == nil else { return }
        let monitor = MicLevelMonitor { level in
            self.micLevel = level
        }
        monitor.start(deviceID: controller.selectedMicDeviceID)
        micMonitor = monitor
    }

    private func stopMicMonitor() {
        micMonitor?.stop()
        micMonitor = nil
        micLevel = 0
    }

    private func restartMicMonitor() {
        stopMicMonitor()
        if controller.recordMicrophone {
            startMicMonitor()
        }
    }

    private func startWebcamPreview() {
        guard previewWebcam == nil else { return }
        webcamReady = false
        let svc = WebcamCaptureService()
        do {
            let selectedCamera: AVCaptureDevice?
            if let camID = controller.selectedCameraDeviceID {
                selectedCamera = controller.availableCameras.first { $0.uniqueID == camID }
            } else {
                selectedCamera = nil
            }
            try svc.start(device: selectedCamera)
            previewWebcam = svc
            // Small delay to let the capture session fully spin up
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.webcamReady = true
            }
        } catch {
            // Camera preview unavailable
        }
    }

    private func stopWebcamPreview() {
        webcamReady = false
        if let svc = previewWebcam {
            previewWebcam = nil
            // No file recording on the preview, so stop() just calls stopRunning
            Task { await svc.stop() }
        }
    }

    private func restartWebcamPreview() {
        stopWebcamPreview()
        if controller.recordWebcam {
            startWebcamPreview()
        }
    }
}

// MARK: - Camera Preview (NSViewRepresentable)

/// Hosts an AVCaptureVideoPreviewLayer from a WebcamCaptureService in SwiftUI.
struct CameraPreviewCircle: NSViewRepresentable {
    let service: WebcamCaptureService

    final class LayerHostView: NSView {
        override func layout() {
            super.layout()
            // Keep the preview layer sized to the view
            layer?.sublayers?.forEach { $0.frame = bounds }
        }
    }

    func makeNSView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.wantsLayer = true

        if let previewLayer = service.previewLayer {
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.frame = view.bounds
            view.layer?.addSublayer(previewLayer)
        }

        return view
    }

    func updateNSView(_ nsView: LayerHostView, context: Context) {
        // Re-attach if the preview layer was recreated (e.g. camera change)
        if let previewLayer = service.previewLayer,
           previewLayer.superlayer !== nsView.layer
        {
            nsView.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
            previewLayer.videoGravity = .resizeAspectFill
            nsView.layer?.addSublayer(previewLayer)
        }
        nsView.layer?.sublayers?.forEach { $0.frame = nsView.bounds }
    }
}

// MARK: - Mic Level Monitor

/// Uses AVCaptureSession with a specific audio device to meter input levels.
/// Supports targeting a specific microphone (unlike AVAudioRecorder which
/// always uses the system default).
@MainActor
final class MicLevelMonitor: NSObject, @unchecked Sendable {
    private var session: AVCaptureSession?
    private var timer: Timer?
    private let onLevel: @MainActor (Float) -> Void

    /// Latest level written from the capture callback, read from the polling timer.
    /// Protected by `levelLock`, accessed from both the capture queue and main thread.
    private let levelLock = NSLock()
    nonisolated(unsafe) private var latestLevel: Float = 0

    init(onLevel: @MainActor @escaping (Float) -> Void) {
        self.onLevel = onLevel
        super.init()
    }

    func start(deviceID: String? = nil) {
        stop()

        // Find the requested device
        let device: AVCaptureDevice?
        if let id = deviceID {
            device = MicrophoneCaptureService.availableInputDevices.first { $0.uniqueID == id }
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }
        guard let dev = device else { return }

        let captureSession = AVCaptureSession()

        guard let input = try? AVCaptureDeviceInput(device: dev),
              captureSession.canAddInput(input)
        else { return }
        captureSession.addInput(input)

        let output = AVCaptureAudioDataOutput()
        let queue = DispatchQueue(label: "com.actionfy.mic-level", qos: .userInteractive)
        output.setSampleBufferDelegate(self, queue: queue)

        guard captureSession.canAddOutput(output) else { return }
        captureSession.addOutput(output)

        captureSession.startRunning()
        self.session = captureSession

        // Poll the latest level on the main thread at ~20 Hz
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let level: Float
            self.levelLock.lock()
            level = self.latestLevel
            self.levelLock.unlock()
            Task { @MainActor [weak self] in
                self?.onLevel(level)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        session?.stopRunning()
        session = nil
    }
}

extension MicLevelMonitor: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        else { return }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0,
            lengthAtOffsetOut: nil, totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let data = dataPointer, length > 0 else { return }

        let rms: Float

        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { return }
            let samples = UnsafeRawPointer(data).assumingMemoryBound(to: Float.self)
            var sum: Float = 0
            for i in 0..<count { sum += samples[i] * samples[i] }
            rms = sqrt(sum / Float(count))
        } else if asbd.mBitsPerChannel == 16 {
            let count = length / MemoryLayout<Int16>.size
            guard count > 0 else { return }
            let samples = UnsafeRawPointer(data).assumingMemoryBound(to: Int16.self)
            var sum: Float = 0
            for i in 0..<count {
                let f = Float(samples[i]) / 32768.0
                sum += f * f
            }
            rms = sqrt(sum / Float(count))
        } else {
            return
        }

        let db = 20 * log10(max(rms, 1e-6))
        let normalized = min(max((db + 50) / 50, 0), 1)
        let curved = pow(normalized, 0.72)
        let level = curved < 0.01 ? Float(0) : curved

        levelLock.lock()
        latestLevel = level
        levelLock.unlock()
    }
}

// MARK: - Setup Colors (system-adaptive, matches WizardColors)

private enum SetupColors {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let subtleFill = Color.primary.opacity(0.05)
    static let subtleStroke = Color.primary.opacity(0.08)
    static let divider = Color.primary.opacity(0.08)

    // Webcam preview well — slightly tinted, adapts to appearance
    static let previewWell = Color(nsColor: .controlBackgroundColor)

    static let accentGradient = LinearGradient(
        colors: [Color(hex: 0x5E5CE6), Color(hex: 0x007AFF)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Color hex extension

extension Color {
    init(hex: UInt, opacity: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
