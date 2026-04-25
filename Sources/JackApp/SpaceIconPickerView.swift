import AppKit
import SwiftUI

/// Floating popover for picking a space icon — categorized SF Symbols grid
/// plus a button that opens the native macOS emoji picker.
struct SpaceIconPickerView: View {
    var spaceController: SpaceController

    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.fixed(32), spacing: 4), count: 8)

    var body: some View {
        VStack(spacing: 0) {
            // Hidden emoji receiver
            EmojiReceiverView { emoji in
                spaceController.setIcon(.emoji(emoji), for: spaceController.activeSpace)
            }
            .frame(width: 1, height: 1)
            .clipped()

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                TextField("Search icons...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.04))

            Divider()

            // Icons grid
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if searchText.isEmpty {
                        // Show categories
                        ForEach(SpaceIcon.categories) { category in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(category.label)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 2)

                                LazyVGrid(columns: columns, spacing: 4) {
                                    ForEach(category.icons, id: \.serialized) { icon in
                                        iconButton(icon)
                                    }
                                }
                            }
                        }
                    } else {
                        // Filtered flat list
                        let filtered = SpaceIcon.presetSymbols.filter { icon in
                            if case .symbol(let name) = icon {
                                return name.localizedCaseInsensitiveContains(searchText)
                            }
                            return false
                        }

                        if filtered.isEmpty {
                            Text("No matching icons")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                        } else {
                            LazyVGrid(columns: columns, spacing: 4) {
                                ForEach(filtered, id: \.serialized) { icon in
                                    iconButton(icon)
                                }
                            }
                        }
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 300)

            Divider()

            // Emoji button
            HStack {
                Button {
                    openEmojiPicker()
                } label: {
                    Label("Emoji Picker", systemImage: "face.smiling")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                // Show current emoji if set
                if case .emoji(let e) = spaceController.activeSpaceIcon {
                    Text(e)
                        .font(.title3)
                        .padding(.leading, 4)
                }

                Spacer()
            }
            .padding(10)
        }
        .frame(width: 300)
    }

    @ViewBuilder
    private func iconButton(_ icon: SpaceIcon) -> some View {
        let isSelected = spaceController.activeSpaceIcon == icon
        let accentColor = spaceController.activeSpaceColor.color

        Button {
            spaceController.setIcon(icon, for: spaceController.activeSpace)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? accentColor.opacity(0.2) : Color.primary.opacity(0.04))
                    .frame(width: 32, height: 32)

                if case .symbol(let name) = icon {
                    Image(systemName: name)
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? accentColor : .secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .help(symbolName(icon))
    }

    private func symbolName(_ icon: SpaceIcon) -> String {
        if case .symbol(let name) = icon { return name }
        return ""
    }

    /// Open the native macOS Character Viewer (emoji picker).
    /// Characters typed while it's open go to the key window's first responder,
    /// which is the hidden emoji text field we focus below.
    private func openEmojiPicker() {
        // Bring up the system emoji picker
        NSApp.orderFrontCharacterPalette(nil)
        // Focus the hidden field to receive emoji input
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let window = NSApp.keyWindow {
                // Find our EmojiReceiver field and make it first responder
                if let receiver = findEmojiReceiver(in: window.contentView) {
                    window.makeFirstResponder(receiver)
                }
            }
        }
    }

    private func findEmojiReceiver(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view is EmojiReceiverTextField { return view }
        for sub in view.subviews {
            if let found = findEmojiReceiver(in: sub) { return found }
        }
        return nil
    }
}

// MARK: - EmojiReceiverTextField

/// Hidden NSTextField that receives emoji input from the Character Viewer.
final class EmojiReceiverTextField: NSTextField {
    var onEmoji: ((String) -> Void)?

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        let text = stringValue
        if !text.isEmpty {
            // Take the first character/grapheme cluster
            let emoji = String(text.prefix(1))
            onEmoji?(emoji)
            stringValue = ""
        }
    }
}

/// SwiftUI wrapper for the hidden emoji receiver.
struct EmojiReceiverView: NSViewRepresentable {
    var onEmoji: (String) -> Void

    func makeNSView(context: Context) -> EmojiReceiverTextField {
        let field = EmojiReceiverTextField()
        field.onEmoji = onEmoji
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.font = .systemFont(ofSize: 1)
        field.alphaValue = 0.01
        field.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        return field
    }

    func updateNSView(_ nsView: EmojiReceiverTextField, context: Context) {
        nsView.onEmoji = onEmoji
    }
}
