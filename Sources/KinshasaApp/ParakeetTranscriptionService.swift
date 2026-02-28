import AVFoundation
import FluidAudio
import Foundation

extension AsrManager: @retroactive @unchecked Sendable {}

struct ParakeetConfiguration: Sendable {
    var cliPath: String
    var model: String
    var cacheDirectory: String
    var version: AsrModelVersion
}

struct WordTiming: Sendable {
    let word: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Float
}

struct TranscriptionResult: Sendable {
    let text: String
    let backend: String
    let wordTimings: [WordTiming]
}

enum ParakeetTranscriptionError: LocalizedError {
    case modelPreparationFailed(String)
    case missingEngine
    case transcriptionFailed(String)
    case audioTrimFailed(String)

    var errorDescription: String? {
        switch self {
        case let .modelPreparationFailed(details):
            return "Failed to prepare CoreML speech engine: \(details)"
        case .missingEngine:
            return "CoreML speech engine is unavailable."
        case let .transcriptionFailed(details):
            return "CoreML transcription failed: \(details)"
        case let .audioTrimFailed(details):
            return "Failed to prepare tail audio for transcription: \(details)"
        }
    }
}

struct ParakeetTranscriptionService {
    private static let engine = CoreMLParakeetEngine()

    func prepare(configuration: ParakeetConfiguration) async throws {
        try await Self.engine.prepare(configuration: configuration)
    }

    func transcribe(
        audioFileURL: URL,
        configuration: ParakeetConfiguration,
        startSeconds: TimeInterval? = nil,
        backendLabel: String = "CoreML Streaming"
    ) async throws -> TranscriptionResult {
        let (text, wordTimings) = try await Self.engine.transcribe(
            audioFileURL: audioFileURL,
            configuration: configuration,
            startSeconds: startSeconds
        )
        return TranscriptionResult(text: text, backend: backendLabel, wordTimings: wordTimings)
    }

    // Backward-compatible shim; this backend is CoreML-only.
    func transcribeUsingCLI(
        audioFileURL: URL,
        configuration: ParakeetConfiguration,
        backendLabel: String = "CoreML Streaming"
    ) async throws -> TranscriptionResult {
        try await transcribe(
            audioFileURL: audioFileURL,
            configuration: configuration,
            startSeconds: nil,
            backendLabel: backendLabel
        )
    }

    func keepWarm(configuration: ParakeetConfiguration) async throws {
        try await Self.engine.warmup(configuration: configuration)
    }
}

private actor CoreMLParakeetEngine {
    nonisolated(unsafe) private var asrManager: AsrManager?
    private var activeConfigurationKey: String?
    private var warmedConfigurationKeys: Set<String> = []
    private var warmupAudioURL: URL?

    func prepare(configuration: ParakeetConfiguration) async throws {
        let key = configurationKey(configuration)
        _ = try await ensureManager(configuration: configuration)

        guard !warmedConfigurationKeys.contains(key) else {
            return
        }

        try await warmup(configuration: configuration)
        warmedConfigurationKeys.insert(key)
    }

    func transcribe(
        audioFileURL: URL,
        configuration: ParakeetConfiguration,
        startSeconds: TimeInterval?
    ) async throws -> (String, [WordTiming]) {
        let manager = try await ensureManager(configuration: configuration)
        let trimmedStart = max(0, startSeconds ?? 0)

        var temporaryTailURL: URL?
        let targetURL: URL

        if trimmedStart > 0 {
            guard let clippedURL = try clipAudioIfNeeded(sourceURL: audioFileURL, startSeconds: trimmedStart) else {
                return ("", [])
            }
            targetURL = clippedURL
            temporaryTailURL = clippedURL
        } else {
            targetURL = audioFileURL
        }

        defer {
            if let temporaryTailURL {
                try? FileManager.default.removeItem(at: temporaryTailURL)
            }
        }

        do {
            let result = try await manager.transcribeStreaming(targetURL, source: .microphone)
            let wordTimings: [WordTiming] = (result.tokenTimings ?? []).map { timing in
                WordTiming(
                    word: timing.token,
                    startTime: timing.startTime,
                    endTime: timing.endTime,
                    confidence: timing.confidence
                )
            }
            return (result.text.trimmingCharacters(in: .whitespacesAndNewlines), wordTimings)
        } catch {
            throw ParakeetTranscriptionError.transcriptionFailed(error.localizedDescription)
        }
    }

    func warmup(configuration: ParakeetConfiguration) async throws {
        let manager = try await ensureManager(configuration: configuration)
        let warmupURL = try makeWarmupAudioURL()

        do {
            _ = try await manager.transcribeStreaming(warmupURL, source: .microphone)
        } catch {
            throw ParakeetTranscriptionError.transcriptionFailed(error.localizedDescription)
        }
    }

    private func ensureManager(configuration: ParakeetConfiguration) async throws -> AsrManager {
        let key = configurationKey(configuration)
        if let asrManager, activeConfigurationKey == key {
            return asrManager
        }

        do {
            let cacheURL = URL(fileURLWithPath: configuration.cacheDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

            let models = try await AsrModels.downloadAndLoad(
                to: cacheURL,
                configuration: AsrModels.defaultConfiguration(),
                version: configuration.version
            )

            let manager = AsrManager(
                config: ASRConfig(
                    sampleRate: 16_000,
                    tdtConfig: .default,
                    streamingEnabled: true,
                    streamingThreshold: 1
                )
            )
            try await manager.initialize(models: models)

            asrManager = manager
            activeConfigurationKey = key
            return manager
        } catch {
            throw ParakeetTranscriptionError.modelPreparationFailed(error.localizedDescription)
        }
    }

    private func clipAudioIfNeeded(sourceURL: URL, startSeconds: TimeInterval) throws -> URL? {
        do {
            let inputFile = try AVAudioFile(forReading: sourceURL)
            let inputFormat = inputFile.processingFormat
            let startFrame = AVAudioFramePosition(startSeconds * inputFormat.sampleRate)

            guard startFrame < inputFile.length else {
                return nil
            }

            inputFile.framePosition = max(0, startFrame)

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("coreml-tail-\(UUID().uuidString)")
                .appendingPathExtension("wav")

            let outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: inputFile.fileFormat.settings,
                commonFormat: inputFormat.commonFormat,
                interleaved: inputFormat.isInterleaved
            )

            let chunkSize: AVAudioFrameCount = 4_096
            guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: chunkSize) else {
                throw ParakeetTranscriptionError.audioTrimFailed("Unable to allocate audio buffer.")
            }

            while inputFile.framePosition < inputFile.length {
                let remaining = inputFile.length - inputFile.framePosition
                let framesToRead = AVAudioFrameCount(min(Int64(chunkSize), remaining))
                try inputFile.read(into: buffer, frameCount: framesToRead)
                guard buffer.frameLength > 0 else {
                    break
                }
                try outputFile.write(from: buffer)
            }

            return outputURL
        } catch let error as ParakeetTranscriptionError {
            throw error
        } catch {
            throw ParakeetTranscriptionError.audioTrimFailed(error.localizedDescription)
        }
    }

    private func makeWarmupAudioURL() throws -> URL {
        if let warmupAudioURL {
            return warmupAudioURL
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("coreml-warmup-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let sampleRate = 16_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = Int(bitsPerSample / 8)
        let seconds = 1
        let sampleCount = sampleRate * seconds
        let dataSize = sampleCount * Int(channels) * bytesPerSample

        var wav = Data()
        wav.reserveCapacity(44 + dataSize)

        wav.append("RIFF".data(using: .ascii)!)
        wav.appendUInt32LE(UInt32(36 + dataSize))
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        wav.appendUInt32LE(16)
        wav.appendUInt16LE(1)
        wav.appendUInt16LE(channels)
        wav.appendUInt32LE(UInt32(sampleRate))
        wav.appendUInt32LE(UInt32(sampleRate * Int(channels) * bytesPerSample))
        wav.appendUInt16LE(UInt16(Int(channels) * bytesPerSample))
        wav.appendUInt16LE(bitsPerSample)
        wav.append("data".data(using: .ascii)!)
        wav.appendUInt32LE(UInt32(dataSize))
        wav.append(Data(repeating: 0, count: dataSize))

        try wav.write(to: outputURL)
        warmupAudioURL = outputURL
        return outputURL
    }

    private func configurationKey(_ configuration: ParakeetConfiguration) -> String {
        "\(configuration.model)|\(configuration.cacheDirectory)|\(configuration.version)"
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
