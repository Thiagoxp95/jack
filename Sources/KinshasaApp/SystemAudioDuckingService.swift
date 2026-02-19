import CoreAudio
import Foundation

final class SystemAudioDuckingService {
    private enum DuckingMode {
        case master(original: Float32)
        case channels([(element: UInt32, original: Float32)])
        case appleScript(originalPercent: Int)
    }

    private struct SavedState {
        let deviceID: AudioDeviceID
        let mode: DuckingMode
    }

    private var savedState: SavedState?

    @discardableResult
    func applyDucking(reductionPercent: Double) -> Bool {
        let reduction = max(0, min(100, reductionPercent))
        if reduction == 0 {
            restoreIfNeeded()
            return true
        }

        if savedState == nil {
            savedState = captureCurrentState() ?? captureAppleScriptState()
        }

        guard let savedState else {
            return false
        }

        if apply(savedState: savedState, reductionPercent: reduction) {
            return true
        }

        // Some output devices expose no writable CoreAudio volume; AppleScript usually still works.
        if case .appleScript = savedState.mode {
            return false
        }

        guard let appleScriptState = captureAppleScriptState() else {
            return false
        }

        self.savedState = appleScriptState
        return apply(savedState: appleScriptState, reductionPercent: reduction)
    }

    func restoreIfNeeded() {
        guard let savedState else {
            return
        }

        switch savedState.mode {
        case let .master(original):
            _ = writeVolume(deviceID: savedState.deviceID, element: kAudioObjectPropertyElementMain, value: original)
        case let .channels(channels):
            for channel in channels {
                _ = writeVolume(deviceID: savedState.deviceID, element: channel.element, value: channel.original)
            }
        case let .appleScript(originalPercent):
            _ = setAppleScriptOutputVolume(originalPercent)
        }

        self.savedState = nil
    }

    private func captureCurrentState() -> SavedState? {
        guard let deviceID = defaultOutputDeviceID() else {
            return nil
        }

        let masterElement = kAudioObjectPropertyElementMain
        if hasSettableVolume(deviceID: deviceID, element: masterElement),
           let original = readVolume(deviceID: deviceID, element: masterElement)
        {
            return SavedState(deviceID: deviceID, mode: .master(original: original))
        }

        var channels: [(element: UInt32, original: Float32)] = []
        for element in [UInt32(1), UInt32(2)] {
            guard hasSettableVolume(deviceID: deviceID, element: element),
                  let original = readVolume(deviceID: deviceID, element: element)
            else {
                continue
            }
            channels.append((element: element, original: original))
        }

        guard !channels.isEmpty else {
            return nil
        }

        return SavedState(deviceID: deviceID, mode: .channels(channels))
    }

    private func apply(savedState: SavedState, reductionPercent: Double) -> Bool {
        let factor = Float32(1 - (reductionPercent / 100))
        var changedAnyVolume = false

        switch savedState.mode {
        case let .master(original):
            let target = clamp(original * factor)
            changedAnyVolume = writeVolume(deviceID: savedState.deviceID, element: kAudioObjectPropertyElementMain, value: target)
        case let .channels(channels):
            for channel in channels {
                let target = clamp(channel.original * factor)
                if writeVolume(deviceID: savedState.deviceID, element: channel.element, value: target) {
                    changedAnyVolume = true
                }
            }
        case let .appleScript(originalPercent):
            let target = Int((Double(originalPercent) * (1 - (reductionPercent / 100))).rounded())
            changedAnyVolume = setAppleScriptOutputVolume(max(0, min(100, target)))
        }

        return changedAnyVolume
    }

    private func captureAppleScriptState() -> SavedState? {
        guard let currentVolume = readAppleScriptOutputVolume() else {
            return nil
        }

        return SavedState(deviceID: 0, mode: .appleScript(originalPercent: currentVolume))
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else {
            return nil
        }
        return deviceID
    }

    private func hasSettableVolume(deviceID: AudioDeviceID, element: UInt32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        var isSettable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        return status == noErr && isSettable.boolValue
    }

    private func readVolume(deviceID: AudioDeviceID, element: UInt32) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )

        var value: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )

        guard status == noErr else {
            return nil
        }
        return value
    }

    private func writeVolume(deviceID: AudioDeviceID, element: UInt32, value: Float32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )

        var writeValue = clamp(value)
        let dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            dataSize,
            &writeValue
        )

        return status == noErr
    }

    private func clamp(_ value: Float32) -> Float32 {
        min(max(value, 0), 1)
    }

    private func readAppleScriptOutputVolume() -> Int? {
        let script = "output volume of (get volume settings)"
        guard let result = runAppleScript(script) else {
            return nil
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed)
    }

    private func setAppleScriptOutputVolume(_ percent: Int) -> Bool {
        let clamped = max(0, min(100, percent))
        let script = "set volume output volume \(clamped)"
        return runAppleScript(script) != nil
    }

    private func runAppleScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
