import ClerkKit
import SwiftUI

/// Shows organization details, members list, and an invite section.
///
/// Uses the Clerk iOS SDK's ``Organization/getMemberships()`` and
/// ``Organization/inviteMember(emailAddress:role:)`` methods.
struct OrganizationSettingsView: View {
    let organization: Organization

    @State private var members: [OrganizationMembership] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    // Invite form state
    @State private var inviteEmail = ""
    @State private var inviteRole = "org:member"
    @State private var isInviting = false
    @State private var inviteSuccessMessage: String?

    private let roleOptions = [
        ("org:admin", "Admin"),
        ("org:member", "Member"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            headerSection

            Divider()

            // Invite section
            inviteSection

            Divider()

            // Members list
            membersSection
        }
        .padding(24)
        .frame(minWidth: 400, minHeight: 320)
        .task { await loadMembers() }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "building.2.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(organization.name)
                    .font(.title3.bold())
                if let count = organization.membersCount {
                    Text("\(count) member\(count == 1 ? "" : "s")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Invite Member")
                .font(.headline)

            HStack(spacing: 8) {
                TextField("Email address", text: $inviteEmail)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)

                Picker("Role", selection: $inviteRole) {
                    ForEach(roleOptions, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)

                Button {
                    invite()
                } label: {
                    if isInviting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Invite")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(inviteEmail.isEmpty || isInviting)
            }

            if let inviteSuccessMessage {
                Text(inviteSuccessMessage)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Members")
                .font(.headline)

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else if members.isEmpty {
                Text("No members found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                List(members) { membership in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(memberDisplayName(membership))
                                .font(.body)
                            if let identifier = membership.publicUserData?.identifier {
                                Text(identifier)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(membership.roleName)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 80, maxHeight: 260)
            }

            // Error
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
    }

    // MARK: - Actions

    private func loadMembers() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await organization.getMemberships()
            members = response.data
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func invite() {
        isInviting = true
        inviteSuccessMessage = nil

        Task { @MainActor in
            defer { isInviting = false }
            do {
                _ = try await organization.inviteMember(
                    emailAddress: inviteEmail,
                    role: inviteRole
                )
                inviteSuccessMessage = "Invitation sent to \(inviteEmail)"
                inviteEmail = ""
                // Reload members to reflect changes
                await loadMembers()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Helpers

    private func memberDisplayName(_ membership: OrganizationMembership) -> String {
        let first = membership.publicUserData?.firstName ?? ""
        let last = membership.publicUserData?.lastName ?? ""
        let full = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
        return full.isEmpty
            ? (membership.publicUserData?.identifier ?? "Unknown")
            : full
    }
}
