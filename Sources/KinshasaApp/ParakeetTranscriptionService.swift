import Foundation

struct ParakeetConfiguration: Sendable {
    var cliPath: String
    var model: String
    var cacheDirectory: String
}

struct TranscriptionResult: Sendable {
    let text: String
    let backend: String
}

enum ParakeetTranscriptionError: LocalizedError {
    case cliNotFound(path: String)
    case workerScriptMissing
    case workerProtocol(String)
    case processLaunchFailed(String)
    case transcriptionFailed(exitCode: Int32, details: String)
    case transcriptMissing(path: String, details: String)

    var errorDescription: String? {
        switch self {
        case let .cliNotFound(path):
            return "Local Parakeet runtime is not ready at: \(path). Please wait for automatic setup to finish."
        case .workerScriptMissing:
            return "Bundled Parakeet worker script is missing from app resources."
        case let .workerProtocol(details):
            return "Parakeet worker communication failed: \(details)"
        case let .processLaunchFailed(message):
            return "Failed to launch local Parakeet CLI: \(message)"
        case let .transcriptionFailed(exitCode, details):
            return "Parakeet local transcription failed (exit \(exitCode)): \(details)"
        case let .transcriptMissing(path, details):
            return "Transcription finished, but no output text file was found at: \(path). \(details)"
        }
    }
}

struct ParakeetTranscriptionService {
    private static let worker = ParakeetWorker()

    func prepare(configuration: ParakeetConfiguration) async throws {
        try await Self.worker.prepare(configuration: configuration)
    }

    func transcribe(audioFileURL: URL, configuration: ParakeetConfiguration) async throws -> TranscriptionResult {
        do {
            let text = try await Self.worker.transcribe(audioFileURL: audioFileURL, configuration: configuration)
            return TranscriptionResult(text: text, backend: "Persistent Worker")
        } catch {
            do {
                try await Self.worker.reset(configuration: configuration)
                let recoveredText = try await Self.worker.transcribe(audioFileURL: audioFileURL, configuration: configuration)
                return TranscriptionResult(text: recoveredText, backend: "Persistent Worker (recovered)")
            } catch {
                let text = try await Task.detached(priority: .userInitiated) {
                    try Self.transcribeBlocking(audioFileURL: audioFileURL, configuration: configuration)
                }.value
                return TranscriptionResult(text: text, backend: "CLI Fallback")
            }
        }
    }

    func keepWarm(configuration: ParakeetConfiguration) async throws {
        try await Self.worker.warmup(configuration: configuration)
    }

    private static func transcribeBlocking(audioFileURL: URL, configuration: ParakeetConfiguration) throws -> String {
        let fm = FileManager.default

        let cliPath = (configuration.cliPath as NSString).expandingTildeInPath
        guard fm.isExecutableFile(atPath: cliPath) else {
            throw ParakeetTranscriptionError.cliNotFound(path: cliPath)
        }

        let outputDir = fm.temporaryDirectory.appendingPathComponent("parakeet-output-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        defer {
            try? fm.removeItem(at: outputDir)
        }

        var arguments = [
            "--model", configuration.model,
            "--output-format", "txt",
            "--output-template", "{filename}",
            "--output-dir", outputDir.path,
        ]

        let trimmedCacheDirectory = configuration.cacheDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCacheDirectory.isEmpty {
            let cachePath = (trimmedCacheDirectory as NSString).expandingTildeInPath
            try fm.createDirectory(atPath: cachePath, withIntermediateDirectories: true)
            arguments.append(contentsOf: ["--cache-dir", cachePath])
        }

        arguments.append(audioFileURL.path)

        let result = try runProcess(executablePath: cliPath, arguments: arguments)

        guard result.exitCode == 0 else {
            let details = result.stderr.isEmpty ? result.stdout : result.stderr
            throw ParakeetTranscriptionError.transcriptionFailed(
                exitCode: result.exitCode,
                details: details.isEmpty ? "No error output from CLI" : details
            )
        }

        return try transcriptText(
            from: outputDir,
            expectedStem: audioFileURL.deletingPathExtension().lastPathComponent,
            processStdout: result.stdout,
            processStderr: result.stderr
        )
    }

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private static func runProcess(executablePath: String, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ParakeetTranscriptionError.processLaunchFailed(error.localizedDescription)
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private static func transcriptText(
        from outputDir: URL,
        expectedStem: String,
        processStdout: String,
        processStderr: String
    ) throws -> String {
        let fm = FileManager.default
        let expectedURL = outputDir
            .appendingPathComponent(expectedStem)
            .appendingPathExtension("txt")

        if let text = readTrimmedText(at: expectedURL) {
            return text
        }

        let directoryFiles = (try? fm.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)) ?? []
        let textFiles = directoryFiles.filter { $0.pathExtension.lowercased() == "txt" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        if let bestMatch = textFiles.first(where: { $0.deletingPathExtension().lastPathComponent.contains(expectedStem) }) ?? textFiles.first,
           let text = readTrimmedText(at: bestMatch)
        {
            return text
        }

        if let stdoutTranscript = normalizedPotentialTranscript(processStdout), !stdoutTranscript.isEmpty {
            return stdoutTranscript
        }

        let fileList = directoryFiles.map(\.lastPathComponent).sorted().joined(separator: ", ")
        let stderrSnippet = processStderr.isEmpty ? "No stderr output." : "stderr: \(processStderr)"
        throw ParakeetTranscriptionError.transcriptMissing(
            path: expectedURL.path,
            details: "Output dir files: [\(fileList)]. \(stderrSnippet)"
        )
    }

    private static func readTrimmedText(at fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func normalizedPotentialTranscript(_ stdout: String) -> String? {
        guard !stdout.isEmpty else {
            return nil
        }

        let cleaned = stdout
            .split(separator: "\n")
            .map(String.init)
            .filter { line in
                let lower = line.lowercased()
                return !lower.contains("transcription complete") && !lower.contains("outputs saved in")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? nil : cleaned
    }
}

private actor ParakeetWorker {
    private var workerState: WorkerState?
    private var nextRequestID = 1
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func prepare(configuration: ParakeetConfiguration) throws {
        _ = try ensureWorker(configuration: configuration)
    }

    func transcribe(audioFileURL: URL, configuration: ParakeetConfiguration) throws -> String {
        let state = try ensureWorker(configuration: configuration)
        let requestID = nextRequestID
        nextRequestID += 1

        let request = WorkerRequest(id: requestID, command: "transcribe", audioPath: audioFileURL.path)
        let encoded = try encoder.encode(request)
        try writeLine(encoded, to: state.stdin)

        while true {
            let message = try readMessage(from: state.stdout)
            switch message.type {
            case "result":
                guard message.id == requestID else {
                    continue
                }
                return (message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            case "error":
                guard message.id == nil || message.id == requestID else {
                    continue
                }
                throw ParakeetTranscriptionError.transcriptionFailed(
                    exitCode: 1,
                    details: message.message ?? "Unknown worker error."
                )
            case "fatal":
                throw ParakeetTranscriptionError.transcriptionFailed(
                    exitCode: 1,
                    details: message.message ?? "Worker failed while preparing model."
                )
            case "ready", "bye":
                continue
            default:
                continue
            }
        }
    }

    func warmup(configuration: ParakeetConfiguration) throws {
        let state = try ensureWorker(configuration: configuration)
        let requestID = nextRequestID
        nextRequestID += 1

        let request = WorkerRequest(id: requestID, command: "warmup", audioPath: "")
        let encoded = try encoder.encode(request)
        try writeLine(encoded, to: state.stdin)

        while true {
            let message = try readMessage(from: state.stdout)
            switch message.type {
            case "warmed":
                guard message.id == requestID else {
                    continue
                }
                return
            case "error":
                guard message.id == nil || message.id == requestID else {
                    continue
                }
                throw ParakeetTranscriptionError.transcriptionFailed(
                    exitCode: 1,
                    details: message.message ?? "Unknown worker warmup error."
                )
            case "fatal":
                throw ParakeetTranscriptionError.transcriptionFailed(
                    exitCode: 1,
                    details: message.message ?? "Worker failed while warming."
                )
            case "ready", "bye":
                continue
            default:
                continue
            }
        }
    }

    func reset(configuration: ParakeetConfiguration) throws {
        stopWorkerIfNeeded()
        _ = try ensureWorker(configuration: configuration)
    }

    private func ensureWorker(configuration: ParakeetConfiguration) throws -> WorkerState {
        if let workerState,
           workerState.matches(configuration: configuration),
           workerState.process.isRunning
        {
            return workerState
        }

        stopWorkerIfNeeded()
        let newWorker = try startWorker(configuration: configuration)
        workerState = newWorker
        return newWorker
    }

    private func startWorker(configuration: ParakeetConfiguration) throws -> WorkerState {
        let fm = FileManager.default
        let cliPath = (configuration.cliPath as NSString).expandingTildeInPath
        guard fm.isExecutableFile(atPath: cliPath) else {
            throw ParakeetTranscriptionError.cliNotFound(path: cliPath)
        }

        let binDir = URL(fileURLWithPath: cliPath).deletingLastPathComponent()
        let pythonPath = binDir.appendingPathComponent("python").path
        guard fm.isExecutableFile(atPath: pythonPath) else {
            throw ParakeetTranscriptionError.cliNotFound(path: pythonPath)
        }

        guard let scriptURL = Bundle.module.url(forResource: "parakeet_worker", withExtension: "py") else {
            throw ParakeetTranscriptionError.workerScriptMissing
        }

        let cachePath = (configuration.cacheDirectory as NSString).expandingTildeInPath
        if !cachePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try fm.createDirectory(atPath: cachePath, withIntermediateDirectories: true)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [
            scriptURL.path,
            "--model", configuration.model,
            "--cache-dir", cachePath,
        ]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [
            env["PATH"],
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.local/bin",
        ]
        .compactMap { $0 }
        .joined(separator: ":")
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ParakeetTranscriptionError.processLaunchFailed(error.localizedDescription)
        }

        let state = WorkerState(
            process: process,
            stdin: stdinPipe.fileHandleForWriting,
            stdout: stdoutPipe.fileHandleForReading,
            stderr: stderrPipe.fileHandleForReading,
            configuration: configuration
        )

        while true {
            let readyMessage = try readMessage(from: state.stdout)
            switch readyMessage.type {
            case "ready":
                return state
            case "fatal", "error":
                let errorText = readyMessage.message ?? readPipeTail(state.stderr)
                stopWorker(state: state)
                throw ParakeetTranscriptionError.workerProtocol("Worker failed to initialize. \(errorText)")
            default:
                continue
            }
        }
    }

    private func stopWorkerIfNeeded() {
        guard let state = workerState else {
            return
        }

        stopWorker(state: state)
        workerState = nil
    }

    private func stopWorker(state: WorkerState) {
        if state.process.isRunning {
            let shutdownRequest = WorkerRequest(id: 0, command: "shutdown", audioPath: "")
            if let data = try? encoder.encode(shutdownRequest) {
                try? writeLine(data, to: state.stdin)
            }
            state.process.terminate()
        }

        try? state.stdin.close()
        try? state.stdout.close()
        try? state.stderr.close()
    }

    private func writeLine(_ data: Data, to handle: FileHandle) throws {
        var payload = data
        payload.append(0x0A)
        do {
            try handle.write(contentsOf: payload)
        } catch {
            stopWorkerIfNeeded()
            throw ParakeetTranscriptionError.workerProtocol("Failed to send request to worker: \(error.localizedDescription)")
        }
    }

    private func readMessage(from handle: FileHandle) throws -> WorkerMessage {
        var skippedNoiseLineCount = 0

        while true {
            let rawLine = try readLine(from: handle)
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !line.isEmpty else {
                continue
            }

            guard let data = line.data(using: .utf8) else {
                skippedNoiseLineCount += 1
                if skippedNoiseLineCount >= 40 {
                    throw ParakeetTranscriptionError.workerProtocol("Worker emitted repeated non-UTF8 output.")
                }
                continue
            }

            if let message = try? decoder.decode(WorkerMessage.self, from: data) {
                return message
            }

            skippedNoiseLineCount += 1
            if skippedNoiseLineCount >= 40 {
                throw ParakeetTranscriptionError.workerProtocol("Too many unexpected worker lines. Last line: \(line)")
            }
        }
    }

    private func readLine(from handle: FileHandle) throws -> String {
        var buffer = Data()

        while true {
            guard let chunk = try handle.read(upToCount: 1), !chunk.isEmpty else {
                let stderrTail = workerState.map { readPipeTail($0.stderr) } ?? "No stderr."
                stopWorkerIfNeeded()
                throw ParakeetTranscriptionError.workerProtocol("Worker exited unexpectedly. \(stderrTail)")
            }

            if chunk[0] == 0x0A {
                break
            }

            buffer.append(chunk)
        }

        return String(data: buffer, encoding: .utf8) ?? ""
    }

    private func readPipeTail(_ handle: FileHandle) -> String {
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else {
            return "No stderr."
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "No stderr."
        }

        return "stderr: \(trimmed)"
    }
}

private struct WorkerState {
    let process: Process
    let stdin: FileHandle
    let stdout: FileHandle
    let stderr: FileHandle
    let configuration: ParakeetConfiguration

    func matches(configuration: ParakeetConfiguration) -> Bool {
        normalized(configuration.cliPath) == normalized(self.configuration.cliPath)
            && configuration.model == self.configuration.model
            && normalized(configuration.cacheDirectory) == normalized(self.configuration.cacheDirectory)
    }

    private func normalized(_ path: String) -> String {
        (path as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct WorkerRequest: Encodable {
    let id: Int
    let command: String
    let audioPath: String

    enum CodingKeys: String, CodingKey {
        case id
        case command
        case audioPath = "audio_path"
    }
}

private struct WorkerMessage: Decodable {
    let type: String
    let id: Int?
    let text: String?
    let message: String?
}
