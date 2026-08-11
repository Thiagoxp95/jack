import SwiftUI

// MARK: - TodoViewMode

enum TodoViewMode: String, CaseIterable {
    case list, kanban

    var title: String { self == .list ? "List" : "Kanban" }
    var icon: String { self == .list ? "list.bullet" : "rectangle.split.3x1" }
}

// MARK: - TodosView

struct TodosView: View {
    var controller: TodoListController
    var spaceController: SpaceController
    @State private var viewMode: TodoViewMode = .list
    @State private var showAddTodo = false
    @State private var newTodoTitle = ""
    @State private var expandedTodoId: String?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAddTodo.toggle()
                        if !showAddTodo {
                            newTodoTitle = ""
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .help("Add Todo")

                Spacer()

                Picker("View Mode", selection: $viewMode) {
                    ForEach(TodoViewMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.icon)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Add todo text field
            if showAddTodo {
                HStack(spacing: 8) {
                    TextField("New todo...", text: $newTodoTitle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            submitNewTodo()
                        }

                    Button("Add") {
                        submitNewTodo()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newTodoTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Divider()

            // Content
            switch viewMode {
            case .list:
                TodoListView(
                    controller: controller,
                    spaceController: spaceController,
                    expandedTodoId: $expandedTodoId
                )
            case .kanban:
                TodoKanbanView(
                    controller: controller,
                    spaceController: spaceController
                )
            }
        }
        .task {
            await controller.fetchLists(spaceId: spaceController.currentSpaceId)
            await controller.fetchTodos(spaceId: spaceController.currentSpaceId)
        }
        .onChange(of: spaceController.activeSpace.id) { _, _ in
            Task {
                await controller.fetchLists(spaceId: spaceController.currentSpaceId)
                await controller.fetchTodos(spaceId: spaceController.currentSpaceId)
            }
        }
    }

    private func submitNewTodo() {
        let title = newTodoTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        Task {
            await controller.createTodo(
                title: title,
                spaceId: spaceController.currentSpaceId
            )
            newTodoTitle = ""
            showAddTodo = false
            await controller.fetchTodos(spaceId: spaceController.currentSpaceId)
        }
    }
}

// MARK: - TodoListView

struct TodoListView: View {
    var controller: TodoListController
    var spaceController: SpaceController
    @Binding var expandedTodoId: String?

    var body: some View {
        if controller.isLoading && controller.todos.isEmpty {
            VStack {
                Spacer()
                ProgressView("Loading todos...")
                    .controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if controller.todos.isEmpty {
            ContentUnavailableView {
                Label("No Todos", systemImage: "checklist")
            } description: {
                Text("Create a todo to get started, or use voice dictation with the todo switch key.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    let grouped = groupedTodos()
                    let sortedKeys = grouped.keys.sorted { key1, key2 in
                        // "Uncategorized" goes last
                        if key1 == nil { return false }
                        if key2 == nil { return true }
                        let name1 = listName(for: key1) ?? ""
                        let name2 = listName(for: key2) ?? ""
                        return name1 < name2
                    }

                    ForEach(sortedKeys, id: \.self) { listId in
                        let todos = grouped[listId] ?? []
                        let sectionTitle = listName(for: listId) ?? "Uncategorized"

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                if let listId, let list = controller.lists.first(where: { $0.id == listId }),
                                   let colorName = list.color {
                                    Circle()
                                        .fill(listColor(colorName))
                                        .frame(width: 8, height: 8)
                                }
                                Text(sectionTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text("\(todos.count)")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)

                            ForEach(todos) { todo in
                                TodoRowView(
                                    todo: todo,
                                    isExpanded: expandedTodoId == todo.id,
                                    controller: controller,
                                    spaceController: spaceController,
                                    onToggleExpand: {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            expandedTodoId = expandedTodoId == todo.id ? nil : todo.id
                                        }
                                    }
                                )
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }

    private func groupedTodos() -> [String?: [TodoItem]] {
        Dictionary(grouping: controller.todos) { $0.listId }
    }

    private func listName(for listId: String?) -> String? {
        guard let listId else { return nil }
        return controller.lists.first(where: { $0.id == listId })?.name
    }

    private func listColor(_ name: String) -> Color {
        switch name.lowercased() {
        case "red":    return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green":  return .green
        case "blue":   return .blue
        case "purple": return .purple
        case "pink":   return .pink
        case "teal":   return .teal
        case "indigo": return .indigo
        default:       return .gray
        }
    }
}

// MARK: - TodoRowView

struct TodoRowView: View {
    let todo: TodoItem
    let isExpanded: Bool
    var controller: TodoListController
    var spaceController: SpaceController
    let onToggleExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(spacing: 10) {
                // Checkbox
                Button {
                    let newStatus = todo.status == "done" ? "todo" : "done"
                    Task {
                        await controller.updateTodo(todoId: todo.id, fields: ["status": newStatus])
                        await controller.fetchTodos(spaceId: spaceController.currentSpaceId)
                    }
                } label: {
                    Image(systemName: todo.status == "done" ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(todo.status == "done" ? .green : .secondary)
                }
                .buttonStyle(.plain)

                // Priority dots
                priorityDots

                // Title + Description
                VStack(alignment: .leading, spacing: 2) {
                    Text(todo.title)
                        .font(.body)
                        .strikethrough(todo.status == "done")
                        .foregroundStyle(todo.status == "done" ? .secondary : .primary)
                        .lineLimit(isExpanded ? nil : 2)

                    if !isExpanded, let desc = todo.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Reminder bell
                if let reminders = todo.reminders, !reminders.isEmpty {
                    Image(systemName: "bell.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("Has \(reminders.count) reminder(s)")
                }

                // Due date + time
                if let dueDateText = formattedDueDate {
                    HStack(spacing: 3) {
                        Image(systemName: "calendar")
                            .font(.caption2)
                        Text(dueDateText)
                            .font(.caption2.weight(.medium))
                        if let dueTime = todo.dueTime, !dueTime.isEmpty {
                            Text(dueTime)
                                .font(.caption2.weight(.medium))
                        }
                    }
                    .foregroundStyle(isDueSoon ? .red : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(isDueSoon ? Color.red.opacity(0.1) : Color.secondary.opacity(0.1))
                    )
                }

                // Delete button
                Button(role: .destructive) {
                    Task {
                        await controller.deleteTodo(todoId: todo.id)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onToggleExpand()
            }

            // Expanded detail
            if isExpanded {
                TodoDetailView(
                    todo: todo,
                    controller: controller,
                    spaceController: spaceController
                )
                .padding(.top, 8)
                .padding(.leading, 28)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var priorityDots: some View {
        switch todo.priority {
        case "high":
            HStack(spacing: 2) {
                Circle().fill(.red).frame(width: 5, height: 5)
                Circle().fill(.red).frame(width: 5, height: 5)
                Circle().fill(.red).frame(width: 5, height: 5)
            }
        case "medium":
            HStack(spacing: 2) {
                Circle().fill(.orange).frame(width: 5, height: 5)
                Circle().fill(.orange).frame(width: 5, height: 5)
            }
        case "low":
            Circle().fill(.blue).frame(width: 5, height: 5)
        default:
            EmptyView()
        }
    }

    private var formattedDueDate: String? {
        guard let dueDate = todo.dueDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dueDate) else { return dueDate }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInTomorrow(date) {
            return "Tomorrow"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let display = DateFormatter()
            display.dateFormat = "MMM d"
            return display.string(from: date)
        }
    }

    private var isDueSoon: Bool {
        guard let dueDate = todo.dueDate else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dueDate) else { return false }

        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        return date <= tomorrow
    }
}

// MARK: - TodoDetailView

struct TodoDetailView: View {
    let todo: TodoItem
    var controller: TodoListController
    var spaceController: SpaceController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Description
            if let description = todo.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 12) {
                // Priority picker
                Menu {
                    Button("None") {
                        updateField("priority", value: "none")
                    }
                    Button {
                        updateField("priority", value: "low")
                    } label: {
                        Label("Low", systemImage: "circle.fill")
                    }
                    Button {
                        updateField("priority", value: "medium")
                    } label: {
                        Label("Medium", systemImage: "circle.fill")
                    }
                    Button {
                        updateField("priority", value: "high")
                    } label: {
                        Label("High", systemImage: "circle.fill")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "flag.fill")
                            .font(.caption2)
                            .foregroundStyle(priorityColor)
                        Text(priorityLabel)
                            .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(priorityColor.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)

                // Status picker
                Menu {
                    Button("To Do") {
                        updateField("status", value: "todo")
                    }
                    Button("In Progress") {
                        updateField("status", value: "in_progress")
                    }
                    Button("Done") {
                        updateField("status", value: "done")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: statusIcon)
                            .font(.caption2)
                        Text(statusLabel)
                            .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
            }

            // Due date/time + reminders
            if todo.dueDate != nil || (todo.reminders != nil && !todo.reminders!.isEmpty) {
                HStack(spacing: 12) {
                    if let dueDate = todo.dueDate {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                                .font(.caption2)
                            Text(dueDate)
                                .font(.caption.weight(.medium))
                            if let dueTime = todo.dueTime, !dueTime.isEmpty {
                                Text("at \(dueTime)")
                                    .font(.caption.weight(.medium))
                            }
                        }
                        .foregroundStyle(.secondary)
                    }

                    if let reminders = todo.reminders, !reminders.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "bell.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Text("\(reminders.count) reminder(s)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            // Tags
            if let tags = todo.tags, !tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.1))
                            )
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }

    private func updateField(_ field: String, value: Any) {
        Task {
            await controller.updateTodo(todoId: todo.id, fields: [field: value])
            await controller.fetchTodos(spaceId: spaceController.currentSpaceId)
        }
    }

    private var priorityColor: Color {
        switch todo.priority {
        case "high":   return .red
        case "medium": return .orange
        case "low":    return .blue
        default:       return .gray
        }
    }

    private var priorityLabel: String {
        switch todo.priority {
        case "high":   return "High"
        case "medium": return "Medium"
        case "low":    return "Low"
        default:       return "None"
        }
    }

    private var statusIcon: String {
        switch todo.status {
        case "in_progress": return "arrow.triangle.2.circlepath"
        case "done":        return "checkmark.circle.fill"
        default:            return "circle"
        }
    }

    private var statusLabel: String {
        switch todo.status {
        case "in_progress": return "In Progress"
        case "done":        return "Done"
        default:            return "To Do"
        }
    }
}
