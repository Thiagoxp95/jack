import ScreenCaptureKit
import SwiftUI

// MARK: - RecordingSetupView

struct RecordingSetupView: View {
    @Bindable var controller: RecordingSessionController
    var onClose: () -> Void

    @State private var isStarting = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sourceSelectionSection
                    audioSection
                    webcamSection
                    optionsSection
                }
                .padding(24)
            }

            Divider()

            actionBar
        }
        .frame(width: 480, height: 520)
        .preferredColorScheme(.dark)
    }

    // MARK: - Source Selection

    @ViewBuilder
    private var sourceSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Source")

            Picker("Capture Source", selection: $controller.sourceType) {
                ForEach(CaptureSourceType.allCases) { type in
                    Text(type.title).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

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
                HStack(spacing: 8) {
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
                Image(systemName: "macwindow")
                    .font(.system(size: 24))
                    .frame(width: 64, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.05))
                    )

                Text(appName)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(width: 64)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? Color.accentColor : Color.clear,
                        lineWidth: 2
                    )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var regionPicker: some View {
        HStack {
            Button("Select Region...") {
                // Region selection is handled externally (overlay)
            }
            .buttonStyle(.bordered)

            if let region = controller.selectedRegion {
                Text("\(Int(region.width)) x \(Int(region.height))")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    // MARK: - Audio Section

    @ViewBuilder
    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Audio")

            Toggle("Record Microphone", isOn: $controller.recordMicrophone)
            Toggle("Record System Audio", isOn: $controller.recordSystemAudio)
        }
    }

    // MARK: - Webcam Section

    @ViewBuilder
    private var webcamSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Webcam")

            Toggle("Enable Webcam", isOn: $controller.enableWebcam)

            if controller.enableWebcam {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Position")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        ForEach(WebcamPosition.allCases) { position in
                            positionButton(position)
                        }
                    }

                    Text("Size")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Picker("Webcam Size", selection: $controller.webcamSize) {
                        ForEach(WebcamSize.allCases) { size in
                            Text(size.label).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.leading, 4)
            }
        }
    }

    @ViewBuilder
    private func positionButton(_ position: WebcamPosition) -> some View {
        let isSelected = controller.webcamPosition == position

        Button {
            controller.webcamPosition = position
        } label: {
            Text(position.label)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            isSelected
                                ? Color.accentColor.opacity(0.3)
                                : Color.white.opacity(0.05)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            isSelected ? Color.accentColor : Color.white.opacity(0.1),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Options Section

    @ViewBuilder
    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Options")

            HStack {
                Text("Frame Rate")
                    .font(.subheadline)

                Spacer()

                Picker("FPS", selection: $controller.fps) {
                    ForEach(RecordingFPS.allCases) { fps in
                        Text(fps.label).tag(fps)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
        }
    }

    // MARK: - Action Bar

    @ViewBuilder
    private var actionBar: some View {
        HStack {
            Button("Cancel") {
                controller.cancelSetup()
                onClose()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button {
                isStarting = true
                onClose()  // Close setup window IMMEDIATELY, before countdown begins
                Task {
                    do {
                        try await controller.startRecording()
                    } catch {
                        // Error is logged in controller
                    }
                    isStarting = false
                }
            } label: {
                if isStarting {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 4)
                } else {
                    Text("Start Recording")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isStarting)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
    }
}
