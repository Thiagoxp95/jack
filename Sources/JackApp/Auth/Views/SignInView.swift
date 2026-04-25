import ClerkKit
import SwiftUI

/// A macOS sign-in view with Google OAuth.
///
/// Uses `Clerk.shared.auth.signInWithOAuth(provider: .google)` which opens
/// a system browser sheet via `ASWebAuthenticationSession`.
struct SignInView: View {
    var onSignedIn: () -> Void

    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 24) {
            // Logo / Title
            VStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)
                Text("Jack")
                    .font(.title.bold())
                Text("Sign in to get started")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)

            // Error
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }

            // Google Sign In
            Button {
                signInWithGoogle()
            } label: {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "globe")
                        Text("Continue with Google")
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isLoading)
        }
        .padding(32)
        .frame(width: 360)
    }

    // MARK: - Actions

    private func signInWithGoogle() {
        isLoading = true
        errorMessage = nil

        Task { @MainActor in
            defer { isLoading = false }
            do {
                let result = try await Clerk.shared.auth.signInWithOAuth(
                    provider: .google,
                    prefersEphemeralWebBrowserSession: false
                )
                switch result {
                case .signIn(let signIn) where signIn.status == .complete:
                    onSignedIn()
                case .signUp(let signUp) where signUp.status == .complete:
                    onSignedIn()
                default:
                    // Session should auto-activate; check clerk.session
                    if Clerk.shared.session != nil {
                        onSignedIn()
                    }
                }
            } catch {
                if !error.isCancellation {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private extension Error {
    var isCancellation: Bool {
        let nsError = self as NSError
        // ASWebAuthenticationSession cancellation
        return nsError.domain == "com.apple.AuthenticationServices.WebAuthenticationSession"
            && nsError.code == 1
    }
}
