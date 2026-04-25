import SwiftUI

// MARK: - TodoKanbanView

struct TodoKanbanView: View {
    var controller: TodoListController
    var spaceController: SpaceController

    var body: some View {
        HStack(spacing: 0) {
            KanbanColumn(
                title: "To Do",
                status: "todo",
                todos: todosForStatus("todo"),
                controller: controller,
                spaceController: spaceController
            )

            Divider()

            KanbanColumn(
                title: "In Progress",
                status: "in_progress",
                todos: todosForStatus("in_progress"),
                controller: controller,
                spaceController: spaceController
            )

            Divider()

            KanbanColumn(
                title: "Done",
                status: "done",
                todos: todosForStatus("done"),
                controller: controller,
                spaceController: spaceController
            )
        }
    }

    /// Filter and sort todos by status, then by priority (high first) and due date.
    private func todosForStatus(_ status: String) -> [ConvexTodo] {
        controller.todos
            .filter { $0.status == status }
            .sorted { a, b in
                let priorityA = priorityOrder(a.priority)
                let priorityB = priorityOrder(b.priority)
                if priorityA != priorityB {
                    return priorityA < priorityB
                }
                // Sort by due date — items with due dates come first, earlier dates first
                switch (a.dueDate, b.dueDate) {
                case (nil, nil):   return a.createdAt > b.createdAt
                case (nil, _):     return false
                case (_, nil):     return true
                case (let da?, let db?): return da < db
                }
            }
    }

    /// Lower number = higher priority (sorts first).
    private func priorityOrder(_ priority: String) -> Int {
        switch priority {
        case "high":   return 0
        case "medium": return 1
        case "low":    return 2
        default:       return 3
        }
    }
}

// MARK: - KanbanColumn

struct KanbanColumn: View {
    let title: String
    let status: String
    let todos: [ConvexTodo]
    var controller: TodoListController
    var spaceController: SpaceController

    var body: some View {
        VStack(spacing: 0) {
            // Column header
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text("\(todos.count)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.1))
                    )
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Cards
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(todos) { todo in
                        KanbanCard(
                            todo: todo,
                            controller: controller,
                            spaceController: spaceController
                        )
                    }
                }
                .padding(8)
            }
            .onDrop(of: [.text], isTargeted: nil) { providers in
                handleDrop(providers: providers)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.02))
    }

    private var statusColor: Color {
        switch status {
        case "todo":        return .blue
        case "in_progress": return .orange
        case "done":        return .green
        default:            return .gray
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.text", options: nil) { item, _ in
                guard let data = item as? Data,
                      let todoId = String(data: data, encoding: .utf8)
                else { return }

                Task { @MainActor in
                    await controller.updateTodo(todoId: todoId, fields: ["status": status])
                    await controller.fetchTodos(spaceId: spaceController.currentSpaceId)
                }
            }
        }
        return true
    }
}

// MARK: - KanbanCard

struct KanbanCard: View {
    let todo: ConvexTodo
    var controller: TodoListController
    var spaceController: SpaceController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title + Description
            VStack(alignment: .leading, spacing: 3) {
                Text(todo.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let desc = todo.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack(spacing: 8) {
                // Priority badge
                if todo.priority != "none" {
                    HStack(spacing: 3) {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 9))
                        Text(priorityLabel)
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(priorityColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(priorityColor.opacity(0.1))
                    )
                }

                Spacer()

                // Due date
                if let dueDateText = formattedDueDate {
                    Text(dueDateText)
                        .font(.caption2)
                        .foregroundStyle(isDueSoon ? .red : .secondary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 2, x: 0, y: 1)
        .onDrag {
            NSItemProvider(object: todo.id as NSString)
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
