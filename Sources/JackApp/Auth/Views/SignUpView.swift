import ClerkKit
import SwiftUI

/// A macOS sign-up form with name, email, and password fields.
///
/// After creating the account, if the sign-up status indicates missing
/// requirements (e.g. email verification), a ``VerificationCodeView`` sheet
/// is presented automatically.
struct SignUpView: View {
    var onSignedUp: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var pendingSignUp: SignUp?

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)
                Text("Create Account")
                    .font(.title.bold())
            }
            .padding(.bottom, 8)

            // Fields
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    TextField("First name", text: $firstName)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.givenName)

                    TextField("Last name", text: $lastName)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.familyName)
                }

                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .disableAutocorrection(true)

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.newPassword)
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
                    createAccount()
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Create Account")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(email.isEmpty || password.isEmpty || isLoading)

                Button("Already have an account? Sign in") {
                    dismiss()
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
        .padding(32)
        .frame(width: 400)
        .sheet(item: $pendingSignUp) { signUp in
            VerificationCodeView(signUp: signUp) {
                pendingSignUp = nil
                onSignedUp()
            }
        }
    }

    // MARK: - Actions

    private func createAccount() {
        isLoading = true
        errorMessage = nil

        Task { @MainActor in
            defer { isLoading = false }
            do {
                let signUp = try await Clerk.shared.auth.signUp(
                    emailAddress: email,
                    password: password,
                    firstName: firstName.isEmpty ? nil : firstName,
                    lastName: lastName.isEmpty ? nil : lastName
                )

                if signUp.status == .complete {
                    onSignedUp()
                } else if signUp.status == .missingRequirements,
                          signUp.unverifiedFields.contains(.emailAddress) {
                    // Need to verify email -- send verification code
                    let updatedSignUp = try await signUp.sendEmailCode()
                    pendingSignUp = updatedSignUp
                } else {
                    errorMessage = "Sign-up requires additional steps (status: \(signUp.status.rawValue))."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Identifiable conformance for sheet presentation

extension SignUp: @retroactive Identifiable {}
