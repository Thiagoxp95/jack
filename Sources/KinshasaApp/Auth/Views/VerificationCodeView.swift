import ClerkKit
import SwiftUI

/// A macOS view for entering a 6-digit email verification code.
///
/// Presented as a sheet from ``SignUpView`` when email verification is
/// required to complete sign-up.
struct VerificationCodeView: View {
    let signUp: SignUp
    var onVerified: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
                Text("Verify Your Email")
                    .font(.title2.bold())
                Text("We sent a verification code to\n\(signUp.emailAddress ?? "your email")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Code input
            TextField("Verification code", text: $code)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .font(.title3.monospaced())

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
                    verify()
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Verify")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(code.count < 6 || isLoading)

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

    private func verify() {
        isLoading = true
        errorMessage = nil

        Task { @MainActor in
            defer { isLoading = false }
            do {
                let result = try await signUp.verifyEmailCode(code)
                if result.status == .complete {
                    onVerified()
                } else {
                    errorMessage = "Verification incomplete (status: \(result.status.rawValue))."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
