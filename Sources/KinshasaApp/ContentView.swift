import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Voice to Text")
                    .font(.title2.weight(.semibold))

                Text("Press \(controller.invocationKeyDisplayName) to dictate globally. Grant Input Monitoring, Accessibility, and Microphone on first run.")
                    .foregroundStyle(.secondary)

                Picker("Shortcut Mode", selection: $controller.mode) {
                    ForEach(ShortcutMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                GroupBox("Audio Ducking") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Lower system output volume while recording", isOn: $controller.duckingEnabled)

                        HStack(spacing: 10) {
                            Text("Lower By")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: $controller.duckingAmountPercent, in: 0 ... 90, step: 5)
                                .disabled(!controller.duckingEnabled)
                            Text(controller.duckingAmountText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 42, alignment: .trailing)
                        }

                        Text("Volume is restored automatically when recording stops.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Model Warmth") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Keep model warm in background", isOn: $controller.keepModelWarmEnabled)

                        Toggle("Only while plugged in", isOn: $controller.keepModelWarmOnlyOnPower)
                            .disabled(!controller.keepModelWarmEnabled)

                        LabeledContent("Warm Status", value: controller.keepModelWarmStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("Runs a lightweight warmup about every 45 seconds while idle.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Invocation Key") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Current Key", value: controller.invocationKeyDisplayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        LabeledContent("Active Model", value: controller.activeModelText)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        LabeledContent("Last Transcription", value: controller.lastLatencyText)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        LabeledContent("Backend", value: controller.lastBackendText)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Button(controller.isCapturingInvocationKey ? "Listening for key..." : "Change Invocation Key") {
                                controller.startInvocationKeyCapture()
                            }
                            .disabled(controller.isCapturingInvocationKey)

                            if controller.isCapturingInvocationKey {
                                Button("Cancel") {
                                    controller.cancelInvocationKeyCapture()
                                }
                            }
                        }

                        if controller.isCapturingInvocationKey {
                            Text("Press any physical key now. Left and right modifier keys are distinct.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Permissions & Shortcut Health") {
                    VStack(alignment: .leading, spacing: 10) {
                        permissionRow(
                            title: "Keyboard (Input Monitoring)",
                            granted: controller.keyboardMonitoringGranted,
                            detail: "Required for global invocation shortcut"
                        )

                        permissionRow(
                            title: "Accessibility",
                            granted: controller.accessibilityGranted,
                            detail: "Required for auto-paste into focused app"
                        )

                        permissionRow(
                            title: "Microphone",
                            granted: controller.microphoneGranted,
                            detail: "Required for recording your voice"
                        )

                        LabeledContent("Shortcut Signal", value: controller.lastShortcutSignalText)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        LabeledContent("Current App", value: controller.currentAppIdentityText)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(controller.currentAppPathText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)

                        if controller.isPreparingModel {
                            ProgressView("Preparing local model...")
                                .controlSize(.small)
                        }

                        HStack(spacing: 10) {
                            Button("Request Keyboard Prompt") {
                                controller.requestKeyboardPrompt()
                            }

                            Button("Prompt Permissions") {
                                Task {
                                    await controller.refreshPermissions(prompt: true)
                                }
                            }

                            Button("Re-check Permissions") {
                                Task {
                                    await controller.refreshPermissions(prompt: false)
                                }
                            }
                        }

                        HStack(spacing: 10) {
                            Button("Reveal This App in Finder") {
                                controller.revealCurrentAppInFinder()
                            }
                            .buttonStyle(.bordered)

                            Button("Open Input Monitoring") {
                                controller.openInputMonitoringSettings()
                            }
                            .buttonStyle(.bordered)

                            Button("Open Accessibility") {
                                controller.openAccessibilitySettings()
                            }
                            .buttonStyle(.bordered)

                            Button("Open Microphone") {
                                controller.openMicrophoneSettings()
                            }
                            .buttonStyle(.bordered)
                        }
                        .font(.caption)

                        Text("After granting Input Monitoring, quit and reopen the app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if !controller.keyboardMonitoringGranted {
                            Text("If no pop-up appears: Open Input Monitoring -> click + -> add the exact app shown above -> reopen app -> Re-check Permissions.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 10) {
                    Button("Start Listening") {
                        controller.startFromUI()
                    }
                    .disabled(controller.isRecording || controller.isTranscribing || controller.isPreparingModel)

                    Button("Stop & Transcribe") {
                        controller.stopFromUI()
                    }
                    .disabled(!controller.isRecording)

                    Button("Toggle") {
                        controller.toggleFromUI()
                    }
                    .disabled(controller.isTranscribing || controller.isPreparingModel)
                }

                LabeledContent("Status", value: controller.statusText)

                GroupBox("Last Transcript") {
                    ScrollView {
                        Text(controller.lastTranscript.isEmpty ? "No transcript yet." : controller.lastTranscript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.vertical, 4)
                    }
                    .frame(minHeight: 120)
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .scrollIndicators(.visible)
    }

    private func permissionRow(title: String, granted: Bool, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle()
                    .fill(granted ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(granted ? "Granted" : "Missing")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(granted ? .green : .orange)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(.clear)
                    .frame(width: 8, height: 8)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
