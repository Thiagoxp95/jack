import SwiftUI

struct TodoEditView: View {
    let todo: CreatedTodoInfo
    let onCancel: () -> Void
    let onSave: (TodoEditUpdates) async -> Void

    @State private var title: String
    @State private var dueDate: String
    @State private var dueTime: String
    @State private var priority: String
    @State private var tags: String
    @State private var isSaving = false

    init(
        todo: CreatedTodoInfo,
        onCancel: @escaping () -> Void,
        onSave: @escaping (TodoEditUpdates) async -> Void
    ) {
        self.todo = todo
        self.onCancel = onCancel
        self.onSave = onSave
        _title = State(initialValue: todo.title)
        _dueDate = State(initialValue: todo.dueDate ?? "")
        _dueTime = State(initialValue: todo.dueTime ?? "")
        _priority = State(initialValue: todo.priority)
        _tags = State(initialValue: todo.tags?.joined(separator: ", ") ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            Text("Edit Todo")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            // Fields
            VStack(alignment: .leading, spacing: 8) {
                fieldRow(label: "Title") {
                    TextField("Title", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                fieldRow(label: "Due Date") {
                    TextField("yyyy-MM-dd", text: $dueDate)
                        .textFieldStyle(.roundedBorder)
                }

                fieldRow(label: "Due Time") {
                    TextField("HH:mm", text: $dueTime)
                        .textFieldStyle(.roundedBorder)
                }

                fieldRow(label: "Priority") {
                    Picker("", selection: $priority) {
                        Text("None").tag("none")
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                    }
                    .pickerStyle(.segmented)
                }

                fieldRow(label: "Tags") {
                    TextField("tag1, tag2", text: $tags)
                        .textFieldStyle(.roundedBorder)
                }
            }

            // Buttons
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    isSaving = true
                    Task {
                        let parsedTags = tags.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        let updates = TodoEditUpdates(
                            title: title,
                            priority: priority,
                            dueDate: dueDate.isEmpty ? nil : dueDate,
                            dueTime: dueTime.isEmpty ? nil : dueTime,
                            tags: parsedTags.isEmpty ? nil : parsedTags
                        )
                        await onSave(updates)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(title.isEmpty || isSaving)
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

    private func fieldRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            content()
        }
    }
}
