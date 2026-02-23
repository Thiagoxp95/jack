import ClerkKit
import SwiftUI

/// Shows the current user's organizations and lets them pick one.
///
/// When an organization is selected, the view calls
/// `Clerk.shared.auth.setActive(sessionId:organizationId:)` and invokes the
/// callback. A button to create a new organization is included.
struct OrganizationPickerView: View {
    var onOrganizationSelected: (Organization) -> Void

    @State private var memberships: [OrganizationMembership] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showCreateOrg = false

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 4) {
                Text("Select Organization")
                    .font(.title2.bold())
                Text("Choose the workspace you want to use")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if memberships.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "building.2")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No organizations yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List(memberships) { membership in
                    Button {
                        selectOrganization(membership.organization)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(membership.organization.name)
                                    .font(.body.weight(.medium))
                                Text(membership.roleName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
                .frame(minHeight: 120, maxHeight: 260)
            }

            // Error
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            // Actions
            Button {
                showCreateOrg = true
            } label: {
                Label("Create Organization", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(32)
        .frame(width: 380)
        .task { await loadMemberships() }
        .sheet(isPresented: $showCreateOrg) {
            CreateOrganizationView { org in
                showCreateOrg = false
                onOrganizationSelected(org)
            }
        }
    }

    // MARK: - Private

    private func loadMemberships() async {
        isLoading = true
        defer { isLoading = false }

        // Read from user's organizationMemberships (already loaded by Clerk)
        if let userMemberships = Clerk.shared.user?.organizationMemberships {
            memberships = userMemberships
        }
    }

    private func selectOrganization(_ org: Organization) {
        guard let sessionId = Clerk.shared.session?.id else {
            errorMessage = "No active session."
            return
        }

        Task { @MainActor in
            do {
                try await Clerk.shared.auth.setActive(
                    sessionId: sessionId,
                    organizationId: org.id
                )
                onOrganizationSelected(org)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
