import ClerkKit
import SwiftUI

/// A macOS sign-in form with email/password fields.
///
/// Calls `Clerk.shared.auth.signInWithPassword` and invokes `onSignedIn`
/// when sign-in completes. Offers a sheet to switch to ``SignUpView``.
struct SignInView: View {
    var onSignedIn: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var showSignUp = false

    var body: some View {
        VStack(spacing: 24) {
            // Logo / Title
            VStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)
                Text("Actionfy")
                    .font(.title.bold())
            }
            .padding(.bottom, 8)

            // Fields
            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .disableAutocorrection(true)

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
            }

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
                    signIn()
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Sign In")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(email.isEmpty || password.isEmpty || isLoading)

                Button("Create an account") {
                    showSignUp = true
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
        .padding(32)
        .frame(width: 360)
        .sheet(isPresented: $showSignUp) {
            SignUpView(onSignedUp: {
                showSignUp = false
                onSignedIn()
            })
        }
    }

    // MARK: - Actions

    private func signIn() {
        isLoading = true
        errorMessage = nil

        Task { @MainActor in
            defer { isLoading = false }
            do {
                let result = try await Clerk.shared.auth.signInWithPassword(
                    identifier: email,
                    password: password
                )
                if result.status == .complete {
                    onSignedIn()
                } else {
                    errorMessage = "Sign-in requires additional steps (status: \(result.status.rawValue))."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
