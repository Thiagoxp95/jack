import SwiftUI

struct TodoConfirmationView: View {
    let todo: CreatedTodoInfo
    let onOK: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Todo Created")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            // Title
            Text(todo.title)
                .font(.body.weight(.semibold))
                .lineLimit(2)

            // Metadata rows
            VStack(alignment: .leading, spacing: 4) {
                if let dueDate = todo.dueDate {
                    metadataRow(icon: "calendar", text: formatDueDate(dueDate, time: todo.dueTime))
                }

                if todo.reminderCount > 0 {
                    metadataRow(icon: "bell.fill", text: "\(todo.reminderCount) reminder(s)")
                }

                metadataRow(icon: "flag.fill", text: todo.priority.capitalized)

                if let tags = todo.tags, !tags.isEmpty {
                    metadataRow(icon: "tag.fill", text: tags.joined(separator: ", "))
                }

                if let listName = todo.listName {
                    metadataRow(icon: "list.bullet", text: listName)
                } else {
                    metadataRow(icon: "list.bullet", text: "Uncategorized")
                }

                if let desc = todo.description, !desc.isEmpty {
                    metadataRow(icon: "text.alignleft", text: desc)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Buttons
            HStack {
                Spacer()
                Button("Edit") { onEdit() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("OK") { onOK() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }

    private func metadataRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .frame(width: 14)
                .foregroundStyle(.orange)
            Text(text)
        }
    }

    private func formatDueDate(_ date: String, time: String?) -> String {
        let today = DateFormatter.yyyyMMdd.string(from: Date())
        let prefix = date == today ? "Today" : date
        if let time {
            return "\(prefix) \(time)"
        }
        return prefix
    }
}

private extension DateFormatter {
    static let yyyyMMdd: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
