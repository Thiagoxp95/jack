import SwiftUI

extension Notification.Name {
    static let todoSheetCommitInput = Notification.Name("todoSheetCommitInput")
}

struct TodoSideSheetView: View {
    @Bindable var sheetState: TodoSideSheetState
    @Bindable var todoListController: TodoListController
    var spaceController: SpaceController

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider().opacity(0.3)

            if sheetState.isCreating {
                createInputView
                Divider().opacity(0.3)
            }

            todoListView

            Divider().opacity(0.3)
            keyboardHintsView
        }
        .background(
            RoundedRectangle(cornerRadius: 0)
                .fill(.ultraThinMaterial)
        )
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            spaceIconView(spaceController.activeSpaceIcon, size: 14)
                .foregroundStyle(spaceController.activeSpaceColor.color)

            Text(spaceController.activeSpace.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Spacer()

            if spaceController.availableSpaces.count > 1 {
                Text("\u{2190} Tab \u{2192}")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Create Input

    private var createInputView: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            TextField("New todo...", text: $sheetState.editText, onCommit: {
                NotificationCenter.default.post(name: .todoSheetCommitInput, object: nil)
            })
            .textFieldStyle(.plain)
            .font(.system(size: 13))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05))
    }

    // MARK: - Todo List

    private var todoListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if todoListController.isLoading && todoListController.todos.isEmpty {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else if todoListController.todos.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "checklist")
                                .font(.system(size: 24))
                                .foregroundStyle(.tertiary)
                            Text("No todos")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text("Press N to create one")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        ForEach(Array(todoListController.todos.enumerated()), id: \.element.id) { index, todo in
                            todoRow(todo: todo, index: index)
                                .id(todo.id)
                        }
                    }
                }
            }
            .onChange(of: sheetState.selectedIndex) { _, newIndex in
                if newIndex < todoListController.todos.count {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(todoListController.todos[newIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Todo Row

    private func todoRow(todo: ConvexTodo, index: Int) -> some View {
        let isSelected = index == sheetState.selectedIndex
        let isDone = todo.status == "done"

        return HStack(spacing: 10) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isDone ? .green : .secondary)

            if sheetState.isEditing && isSelected {
                TextField("Edit todo...", text: $sheetState.editText, onCommit: {
                    NotificationCenter.default.post(name: .todoSheetCommitInput, object: nil)
                })
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            } else {
                Text(todo.title)
                    .font(.system(size: 13))
                    .strikethrough(isDone)
                    .foregroundStyle(isDone ? .secondary : .primary)
                    .lineLimit(2)
            }

            Spacer()

            if let dueDate = todo.dueDate {
                Text(formatShortDate(dueDate))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            priorityDot(todo.priority)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? spaceController.activeSpaceColor.color.opacity(0.15) : .clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
    }

    private func priorityDot(_ priority: String) -> some View {
        Circle()
            .fill(priorityColor(priority))
            .frame(width: 6, height: 6)
    }

    private func priorityColor(_ priority: String) -> Color {
        switch priority {
        case "high": return .red
        case "medium": return .orange
        case "low": return .blue
        default: return .gray.opacity(0.4)
        }
    }

    // MARK: - Keyboard Hints

    private var keyboardHintsView: some View {
        VStack(spacing: 2) {
            HStack(spacing: 12) {
                hintPill("\u{2191}\u{2193}", "Navigate")
                hintPill("\u{23CE}", "Done")
                hintPill("\u{232B}", "Delete")
            }
            HStack(spacing: 12) {
                hintPill("N", "New")
                hintPill("E", "Edit")
                hintPill("P", "Priority")
            }
            HStack(spacing: 12) {
                hintPill("Tab", "Space")
                hintPill("Esc", "Close")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func hintPill(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.white.opacity(0.1))
                )
            Text(label)
                .font(.system(size: 9))
        }
        .foregroundStyle(.tertiary)
    }

    // MARK: - Helpers

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

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private func formatShortDate(_ dateString: String) -> String {
        guard let date = Self.isoDateFormatter.date(from: dateString) else { return dateString }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInTomorrow(date) {
            return "Tmrw"
        } else {
            return Self.shortDateFormatter.string(from: date)
        }
    }
}
