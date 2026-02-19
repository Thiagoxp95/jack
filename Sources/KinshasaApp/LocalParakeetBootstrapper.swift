import Foundation

actor LocalParakeetBootstrapper {
    private var cachedConfiguration: ParakeetConfiguration?
    private var inFlight: Task<ParakeetConfiguration, Error>?

    func ensureReady(model: String) async throws -> ParakeetConfiguration {
        if let cachedConfiguration {
            return cachedConfiguration
        }

        if let inFlight {
            return try await inFlight.value
        }

        let task = Task.detached(priority: .userInitiated) {
            try Self.bootstrap(model: model)
        }

        inFlight = task

        do {
            let config = try await task.value
            cachedConfiguration = config
            inFlight = nil
            return config
        } catch {
            inFlight = nil
            throw error
        }
    }

    private static func bootstrap(model: String) throws -> ParakeetConfiguration {
        let paths = try PathConfig(model: model)
        try FileManager.default.createDirectory(at: paths.baseDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.cacheDirectory, withIntermediateDirectories: true)

        let uvPath = try ensureUVInstalled()

        if !FileManager.default.isExecutableFile(atPath: paths.venvPythonPath) {
            _ = try runProcess(
                executablePath: uvPath,
                arguments: ["venv", paths.venvDirectory.path, "--python", "3.11"]
            )
        }

        if !isParakeetRuntimeInstalled(paths: paths) {
            _ = try runProcess(
                executablePath: uvPath,
                arguments: ["pip", "install", "--python", paths.venvPythonPath, "--upgrade", "pip"]
            )

            _ = try runProcess(
                executablePath: uvPath,
                arguments: ["pip", "install", "--python", paths.venvPythonPath, "--upgrade", "parakeet-mlx"]
            )
        }

        guard FileManager.default.isExecutableFile(atPath: paths.cliPath) else {
            throw LocalParakeetSetupError.setupFailed("parakeet-mlx executable was not created at \(paths.cliPath).")
        }

        if !FileManager.default.fileExists(atPath: paths.modelCacheMarker.path) {
            try predownloadModel(paths: paths)
        }

        return ParakeetConfiguration(
            cliPath: paths.cliPath,
            model: model,
            cacheDirectory: paths.cacheDirectory.path
        )
    }

    private static func isParakeetRuntimeInstalled(paths: PathConfig) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: paths.cliPath),
              FileManager.default.isExecutableFile(atPath: paths.venvPythonPath)
        else {
            return false
        }

        do {
            _ = try runProcess(
                executablePath: paths.venvPythonPath,
                arguments: ["-c", "import parakeet_mlx"]
            )
            return true
        } catch {
            return false
        }
    }

    private static func predownloadModel(paths: PathConfig) throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-bootstrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let sampleWavPath = tempDirectory.appendingPathComponent("silence.wav")
        try writeSilenceWav(to: sampleWavPath, durationSeconds: 1)

        _ = try runProcess(
            executablePath: paths.cliPath,
            arguments: [
                "--model", paths.model,
                "--cache-dir", paths.cacheDirectory.path,
                "--output-format", "txt",
                "--output-template", "{filename}",
                "--output-dir", tempDirectory.path,
                sampleWavPath.path,
            ]
        )
    }

    private static func ensureUVInstalled() throws -> String {
        if let uv = findExecutable(named: "uv") {
            return uv
        }

        if let brew = findExecutable(named: "brew") {
            _ = try runProcess(executablePath: brew, arguments: ["install", "uv"])
            if let uv = findExecutable(named: "uv") {
                return uv
            }
        }

        if FileManager.default.isExecutableFile(atPath: "/usr/bin/curl") {
            _ = try runProcess(
                executablePath: "/bin/sh",
                arguments: ["-c", "curl -LsSf https://astral.sh/uv/install.sh | sh"]
            )

            if let uv = findExecutable(named: "uv") {
                return uv
            }
        }

        throw LocalParakeetSetupError.setupFailed("Unable to install uv automatically.")
    }

    private static func findExecutable(named name: String) -> String? {
        let fm = FileManager.default

        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathCandidates = pathEnv
            .split(separator: ":")
            .map(String.init)
            .map { "\($0)/\(name)" }

        let fixedCandidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(NSHomeDirectory())/.local/bin/\(name)",
        ]

        for candidate in pathCandidates + fixedCandidates {
            let expanded = (candidate as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }

        return nil
    }

    private struct PathConfig {
        let model: String
        let baseDirectory: URL
        let venvDirectory: URL
        let cacheDirectory: URL
        let modelCacheMarker: URL
        let cliPath: String
        let venvPythonPath: String

        init(model: String) throws {
            self.model = model

            guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw LocalParakeetSetupError.setupFailed("Unable to resolve Application Support directory.")
            }

            baseDirectory = appSupport
                .appendingPathComponent("KinshasaApp", isDirectory: true)
                .appendingPathComponent("parakeet", isDirectory: true)

            venvDirectory = baseDirectory.appendingPathComponent("venv", isDirectory: true)
            cacheDirectory = baseDirectory.appendingPathComponent("cache", isDirectory: true)

            let modelMarker = "models--\(model.replacingOccurrences(of: "/", with: "--"))"
            modelCacheMarker = cacheDirectory.appendingPathComponent(modelMarker, isDirectory: true)

            cliPath = venvDirectory
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("parakeet-mlx")
                .path

            venvPythonPath = venvDirectory
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("python")
                .path
        }
    }

    private static func runProcess(executablePath: String, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

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

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw LocalParakeetSetupError.setupFailed("Failed to launch process: \(error.localizedDescription)")
        }

        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let details = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                : stderr.trimmingCharacters(in: .whitespacesAndNewlines)

            throw LocalParakeetSetupError.setupFailed(
                "Command failed (\(process.terminationStatus)): \(executablePath) \(arguments.joined(separator: " "))\n\(details)"
            )
        }

        return ProcessResult(stdout: stdout, stderr: stderr)
    }

    private struct ProcessResult {
        let stdout: String
        let stderr: String
    }

    private static func writeSilenceWav(to url: URL, durationSeconds: Int) throws {
        let sampleRate = 16_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = Int(bitsPerSample / 8)
        let sampleCount = sampleRate * durationSeconds
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

        try wav.write(to: url)
    }
}

enum LocalParakeetSetupError: LocalizedError {
    case setupFailed(String)

    var errorDescription: String? {
        switch self {
        case let .setupFailed(message):
            return message
        }
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
