import SwiftUI

/// A form to create a new space via Convex.
struct CreateSpaceView: View {
    var spaceController: SpaceController?
    var onCreated: (Space) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var spaceName = ""
    @State private var selectedColor: SpaceColor = .blue
    @State private var selectedIcon: SpaceIcon = .defaultTeam
    @State private var showIconPicker = false
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 20) {
            // Header icon — reflects selection
            VStack(spacing: 8) {
                spaceIconView(selectedIcon, size: 32)
                    .foregroundStyle(selectedColor.color)
                    .frame(width: 56, height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(selectedColor.color.opacity(0.15))
                    )
                Text("New Space")
                    .font(.title2.bold())
            }

            // Name field
            TextField("Space name", text: $spaceName)
                .textFieldStyle(.roundedBorder)

            // Color & icon pickers (only when spaceController is available)
            if spaceController != nil {
                // Color picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Color")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        ForEach(SpaceColor.allCases) { sc in
                            Button {
                                selectedColor = sc
                            } label: {
                                Circle()
                                    .fill(sc.color)
                                    .frame(width: 22, height: 22)
                                    .overlay {
                                        if selectedColor == sc {
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

                // Icon picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Icon")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Button {
                        showIconPicker.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            spaceIconView(selectedIcon, size: 16)
                                .foregroundStyle(selectedColor.color)
                                .frame(width: 32, height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(.quaternary)
                                )
                            Text("Choose icon")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showIconPicker, arrowEdge: .trailing) {
                        iconPickerContent
                    }
                }
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
                .tint(selectedColor.color)
                .controlSize(.large)
                .disabled(spaceName.isEmpty || isLoading)

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
        .padding(32)
        .frame(width: 380)
    }

    /// Inline icon picker grid (shown in popover).
    private var iconPickerContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(SpaceIcon.categories) { category in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(category.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 2)

                        LazyVGrid(
                            columns: Array(repeating: GridItem(.fixed(32), spacing: 4), count: 8),
                            spacing: 4
                        ) {
                            ForEach(category.icons, id: \.serialized) { icon in
                                let isSelected = selectedIcon == icon
                                Button {
                                    selectedIcon = icon
                                } label: {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(
                                                isSelected
                                                    ? selectedColor.color.opacity(0.2)
                                                    : Color.primary.opacity(0.04)
                                            )
                                            .frame(width: 32, height: 32)

                                        if case .symbol(let name) = icon {
                                            Image(systemName: name)
                                                .font(.system(size: 14))
                                                .foregroundStyle(
                                                    isSelected ? selectedColor.color : .secondary
                                                )
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(10)
        }
        .frame(width: 300, height: 320)
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

    // MARK: - Actions

    private func create() {
        isLoading = true
        errorMessage = nil

        Task { @MainActor in
            defer { isLoading = false }
            do {
                guard let spaceController else {
                    errorMessage = "Space controller not available"
                    return
                }

                let spaceId = try await spaceController.createSpace(name: spaceName)

                // Apply chosen color and icon to the new space
                let newSpace = Space(id: spaceId, name: spaceName, isPersonal: false)
                spaceController.setColor(selectedColor, for: newSpace)
                spaceController.setIcon(selectedIcon, for: newSpace)

                onCreated(newSpace)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
