import SwiftUI

/// Modal sheet for managing space appearance (color, icon) and members.
struct SpaceSettingsSheet: View {
    var spaceController: SpaceController

    @Environment(\.dismiss) private var dismiss

    @State private var showIconPicker = false
    @State private var showDeleteConfirmation = false
    @State private var spaceToDelete: Space?
    @State private var isDeletingSpace = false
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Space Settings")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Current space header
                    HStack(spacing: 12) {
                        spaceIconView(spaceController.activeSpaceIcon, size: 24)
                            .foregroundStyle(spaceController.activeSpaceColor.color)
                            .frame(width: 40, height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(spaceController.activeSpaceColor.color.opacity(0.15))
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spaceController.activeSpace.name)
                                .font(.headline)
                            Text(
                                spaceController.activeSpace.isPersonal
                                    ? "Your personal space"
                                    : "Team space"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    // Color picker
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Color")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 6) {
                            ForEach(SpaceColor.allCases) { sc in
                                Button {
                                    spaceController.setColor(sc, for: spaceController.activeSpace)
                                } label: {
                                    Circle()
                                        .fill(sc.color)
                                        .frame(width: 24, height: 24)
                                        .overlay {
                                            if spaceController.activeSpaceColor == sc {
                                                Image(systemName: "checkmark")
                                                    .font(.caption2.weight(.bold))
                                                    .foregroundStyle(.white)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Icon picker (not for personal space)
                    if !spaceController.activeSpace.isPersonal {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Icon")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Button {
                                showIconPicker = true
                            } label: {
                                spaceIconView(spaceController.activeSpaceIcon, size: 18)
                                    .foregroundStyle(spaceController.activeSpaceColor.color)
                                    .frame(width: 36, height: 36)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(.quaternary)
                                    )
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showIconPicker, arrowEdge: .trailing) {
                                SpaceIconPickerView(spaceController: spaceController)
                            }
                        }
                    }

                    // Members for team spaces
                    if !spaceController.activeSpace.isPersonal {
                        Divider()
                        SpaceMembersView(
                            spaceId: spaceController.activeSpace.id,
                            spaceController: spaceController
                        )
                    }

                    // Manage spaces — delete option for team spaces
                    let teamSpaces = spaceController.availableSpaces.filter { !$0.isPersonal }
                    if !teamSpaces.isEmpty {
                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Manage Spaces")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            ForEach(teamSpaces) { space in
                                HStack(spacing: 8) {
                                    spaceIconView(spaceController.icon(for: space), size: 14)
                                        .foregroundStyle(spaceController.color(for: space).color)
                                    Text(space.name)
                                        .font(.callout)
                                    Spacer()
                                    Button(role: .destructive) {
                                        spaceToDelete = space
                                        showDeleteConfirmation = true
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .padding(.vertical, 2)
                            }

                            if let error = deleteError {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .font(.caption)
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 440, height: 500)
        .alert(
            "Delete Space?",
            isPresented: $showDeleteConfirmation,
            presenting: spaceToDelete
        ) { space in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                isDeletingSpace = true
                deleteError = nil
                Task {
                    do {
                        try await spaceController.deleteSpace(space)
                    } catch {
                        deleteError = error.localizedDescription
                    }
                    isDeletingSpace = false
                    spaceToDelete = nil
                }
            }
        } message: { space in
            Text(
                "All recordings, notes, and other content in \"\(space.name)\" will be permanently deleted. This action cannot be undone."
            )
        }
        .task {
            await spaceController.refreshSpaces()
        }
    }

    @ViewBuilder
    private func spaceIconView(_ icon: SpaceIcon, size: CGFloat) -> some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size))
        case .emoji(let char):
            Text(char)
                .font(.system(size: size))
        }
    }
}
