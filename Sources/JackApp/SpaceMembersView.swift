import SwiftUI

/// Shows space members and an invite row.
///
/// Designed to be embedded inside a `settingsCard` — no extra padding,
/// headers, or chrome. Matches the flat caption/secondary style used
/// throughout the app.
struct SpaceMembersView: View {
    let spaceId: String
    var spaceController: SpaceController

    @State private var members: [SpaceController.SpaceMember] = []
    @State private var pendingInvitations: [SpaceController.SpacePendingInvitation] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    // Invite form state
    @State private var inviteEmail = ""
    @State private var isInviting = false
    @State private var inviteSuccessMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Invite row
            VStack(alignment: .leading, spacing: 6) {
                Text("Invite")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    TextField("Email address", text: $inviteEmail)
                        .textFieldStyle(.plain)
                        .textContentType(.emailAddress)
                        .font(.caption)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.quaternary)
                        )

                    Button {
                        invite()
                    } label: {
                        if isInviting {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Text("Send")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(inviteEmail.isEmpty || isInviting)
                }

                if let msg = inviteSuccessMessage {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            // Members
            VStack(alignment: .leading, spacing: 6) {
                Text("Members")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if isLoading {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading...")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else if members.isEmpty {
                    Text("No members.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(members) { member in
                        HStack(spacing: 8) {
                            // Avatar circle with initials
                            Circle()
                                .fill(.quaternary)
                                .frame(width: 24, height: 24)
                                .overlay {
                                    Text(initials(member))
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }

                            VStack(alignment: .leading, spacing: 0) {
                                Text(memberDisplayName(member))
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                Text(member.email)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text(member.role)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(.quaternary)
                                )
                        }
                        .padding(.vertical, 2)
                    }
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            // Pending invitations
            if !pendingInvitations.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pending Invitations")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(pendingInvitations) { invitation in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(.quaternary)
                                .frame(width: 24, height: 24)
                                .overlay {
                                    Image(systemName: "envelope.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }

                            Text(invitation.email)
                                .font(.caption)
                                .lineLimit(1)

                            Spacer()

                            Text("pending")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(.orange.opacity(0.15))
                                )
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .task { await loadMembers() }
    }

    // MARK: - Actions

    private func loadMembers() async {
        isLoading = true
        defer { isLoading = false }
        do {
            members = try await spaceController.fetchMembers(spaceId: spaceId)
            pendingInvitations = try await spaceController.fetchPendingInvitationsForSpace(spaceId: spaceId)
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
                try await spaceController.inviteToSpace(spaceId: spaceId, email: inviteEmail)
                inviteSuccessMessage = "Invitation sent to \(inviteEmail)"
                inviteEmail = ""
                await loadMembers()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Helpers

    private func memberDisplayName(_ member: SpaceController.SpaceMember) -> String {
        let first = member.firstName ?? ""
        let last = member.lastName ?? ""
        let full = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? member.email : full
    }

    private func initials(_ member: SpaceController.SpaceMember) -> String {
        let first = member.firstName?.prefix(1) ?? ""
        let last = member.lastName?.prefix(1) ?? ""
        let result = "\(first)\(last)"
        return result.isEmpty ? "?" : result.uppercased()
    }
}
