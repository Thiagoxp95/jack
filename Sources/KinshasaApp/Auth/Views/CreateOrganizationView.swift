import ClerkKit
import SwiftUI

/// A form to create a new Clerk organization.
///
/// The ClerkKit iOS SDK does not expose a top-level `createOrganization`
/// method, so this view makes a direct HTTP POST to the Clerk Frontend API.
struct CreateOrganizationView: View {
    var onCreated: (Organization) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var orgName = ""
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "building.2.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
                Text("New Organization")
                    .font(.title2.bold())
            }

            // Name field
            TextField("Organization name", text: $orgName)
                .textFieldStyle(.roundedBorder)

            // Error
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }

            // Actions
            VStack(spacing: 12) {
                Button {
                    create()
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Create")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(orgName.isEmpty || isLoading)

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
        .padding(32)
        .frame(width: 340)
    }

    // MARK: - Actions

    /// Creates an organization via the Clerk Frontend API.
    ///
    /// The SDK does not provide a public `createOrganization` helper, so we
    /// derive the Frontend API base URL from the publishable key (same logic
    /// the SDK itself uses) and POST directly.
    private func create() {
        isLoading = true
        errorMessage = nil

        Task { @MainActor in
            defer { isLoading = false }
            do {
                let org = try await createOrganizationViaAPI(name: orgName)
                // Refresh the client so the new org appears on
                // Clerk.shared.user?.organizationMemberships
                _ = try? await Clerk.shared.refreshClient()
                onCreated(org)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Derives the frontend API URL from the publishable key, obtains a
    /// session token, and POSTs to `/v1/organizations`.
    private func createOrganizationViaAPI(name: String) async throws -> Organization {
        // 1. Derive Frontend API base URL from publishable key.
        let pk = Clerk.shared.publishableKey
        let prefix = pk.hasPrefix("pk_live_") ? "pk_live_" : "pk_test_"
        let encoded = String(pk.dropFirst(prefix.count))

        guard let data = Data(base64Encoded: padBase64(encoded)),
              let decoded = String(data: data, encoding: .utf8) else {
            throw CreateOrgError.badKey
        }
        // The decoded value ends with a `$` -- drop it.
        let host = decoded.hasSuffix("$") ? String(decoded.dropLast()) : decoded
        let baseURL = "https://\(host)"

        // 2. Get session token.
        guard let token = try await Clerk.shared.auth.getToken() else {
            throw CreateOrgError.noToken
        }

        // 3. POST /v1/organizations
        guard let url = URL(string: "\(baseURL)/v1/organizations") else {
            throw CreateOrgError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["name": name])

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw CreateOrgError.apiError(body)
        }

        // The response wraps the org in a `response` field when using the
        // client API, but the organizations endpoint returns the object directly.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        // Clerk may return the org directly or wrapped -- try direct first.
        if let org = try? decoder.decode(Organization.self, from: responseData) {
            return org
        }
        // Fallback: wrapped in `{ "response": ... }` like other client endpoints.
        struct Wrapper: Decodable { let response: Organization }
        return try decoder.decode(Wrapper.self, from: responseData).response
    }

    /// Pads a base-64 string to a multiple of 4 characters.
    private func padBase64(_ str: String) -> String {
        let remainder = str.count % 4
        guard remainder != 0 else { return str }
        return str + String(repeating: "=", count: 4 - remainder)
    }
}

// MARK: - Errors

private enum CreateOrgError: LocalizedError {
    case badKey
    case noToken
    case badURL
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .badKey: "Unable to decode publishable key."
        case .noToken: "No active session token."
        case .badURL: "Invalid API URL."
        case .apiError(let body): "API error: \(body)"
        }
    }
}
