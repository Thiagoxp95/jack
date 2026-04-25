import FluidAudio
import Foundation

actor LocalParakeetBootstrapper {
    private var cachedConfiguration: ParakeetConfiguration?
    private var inFlight: Task<ParakeetConfiguration, Error>?

    func ensureReady(model: String) async throws -> ParakeetConfiguration {
        if let cachedConfiguration, cachedConfiguration.model == Self.resolvedModelIdentifier(forInput: model) {
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
        let version = resolvedModelVersion(forInput: model)
        let modelIdentifier = resolvedModelIdentifier(for: version)
        let cacheDirectory = AsrModels.defaultCacheDirectory(for: version)

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        return ParakeetConfiguration(
            cliPath: "coreml://fluidaudio",
            model: modelIdentifier,
            cacheDirectory: cacheDirectory.path,
            version: version
        )
    }

    private static func resolvedModelVersion(forInput model: String) -> AsrModelVersion {
        let normalized = model.lowercased()
        if normalized.contains("v3") || normalized.contains("multilingual") {
            return .v3
        }
        return .v2
    }

    private static func resolvedModelIdentifier(for version: AsrModelVersion) -> String {
        switch version {
        case .v2:
            return "FluidInference/parakeet-tdt-0.6b-v2-coreml"
        case .v3:
            return "FluidInference/parakeet-tdt-0.6b-v3-coreml"
        }
    }

    private static func resolvedModelIdentifier(forInput model: String) -> String {
        resolvedModelIdentifier(for: resolvedModelVersion(forInput: model))
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
