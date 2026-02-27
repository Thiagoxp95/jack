import ClerkKit
import Foundation

/// Lightweight HTTP client for the Convex HTTP API.
///
/// Bypasses ConvexMobile's Rust bridge entirely — uses `URLSession` with a
/// Clerk JWT. This avoids the deadlock where the Rust bridge needs MainActor
/// for token refresh but MainActor is saturated with subscription callbacks.
enum ConvexHTTPClient {

    enum Error: LocalizedError {
        case notSignedIn
        case noToken
        case httpError(Int, String)
        case invalidResponse(String)
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Not signed in"
            case .noToken: return "Could not get auth token"
            case .httpError(let code, let body): return "HTTP \(code): \(body)"
            case .invalidResponse(let detail): return "Invalid response: \(detail)"
            case .serverError(let msg): return msg
            }
        }
    }

    /// Get a Clerk JWT for the Convex template. Must be called from MainActor
    /// or with a captured session reference.
    @MainActor
    static func getToken() async throws -> String {
        guard let session = Clerk.shared.session else {
            throw Error.notSignedIn
        }
        guard let jwt = try await session.getToken(.init(template: "convex")) else {
            throw Error.noToken
        }
        return jwt
    }

    /// Call a Convex mutation via the HTTP API.
    /// This is `nonisolated` so it can be called from any actor context.
    nonisolated static func mutation(
        function: String,
        args: [String: Any] = [:],
        token: String,
        deploymentUrl: String = AppConfig.convexDeploymentUrl
    ) async throws -> Any {
        try await call(
            endpoint: "mutation",
            function: function,
            args: args,
            token: token,
            deploymentUrl: deploymentUrl
        )
    }

    /// Call a Convex action via the HTTP API.
    nonisolated static func action(
        function: String,
        args: [String: Any] = [:],
        token: String,
        deploymentUrl: String = AppConfig.convexDeploymentUrl
    ) async throws -> Any {
        try await call(
            endpoint: "action",
            function: function,
            args: args,
            token: token,
            deploymentUrl: deploymentUrl
        )
    }

    /// Call a Convex query via the HTTP API.
    /// This is `nonisolated` so it can be called from any actor context.
    nonisolated static func query(
        function: String,
        args: [String: Any] = [:],
        token: String,
        deploymentUrl: String = AppConfig.convexDeploymentUrl
    ) async throws -> Any {
        try await call(
            endpoint: "query",
            function: function,
            args: args,
            token: token,
            deploymentUrl: deploymentUrl
        )
    }

    // MARK: - Private

    private nonisolated static func call(
        endpoint: String,
        function: String,
        args: [String: Any],
        token: String,
        deploymentUrl: String
    ) async throws -> Any {
        let url = URL(string: "\(deploymentUrl)/api/\(endpoint)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "path": function,
            "args": args,
            "format": "json",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

        guard statusCode == 200 else {
            let body = String(data: data.prefix(500), encoding: .utf8) ?? "HTTP \(statusCode)"
            throw Error.httpError(statusCode, body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.invalidResponse("Not a JSON object")
        }

        if let errorMessage = json["errorMessage"] as? String {
            throw Error.serverError(errorMessage)
        }

        return json["value"] as Any
    }
}
