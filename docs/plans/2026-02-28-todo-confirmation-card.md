# Todo Confirmation Card Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Show a floating confirmation card after dictation creates a todo, displaying full parsed details with OK (auto-dismiss 3s) and Edit (opens floating editor) actions.

**Architecture:** New `TodoConfirmationController` manages an NSPanel hosting SwiftUI views (confirmation card + editor). `processAndCreate` is changed to return full parsed data. `DictationController.syncTodoToConvex()` parses the response and calls the confirmation controller.

**Tech Stack:** SwiftUI views hosted in NSPanel, Convex backend action return value change.

---

### Task 1: Change processAndCreate to return full parsed todo data

**Files:**
- Modify: `convex/todos.ts:654-672`

**Step 1: Change the return value**

Replace the final section of `processAndCreate` (lines 654-672) from:

```typescript
    const todoId = await ctx.runMutation(internal.todos.insertFromAction, {
      userId: user._id,
      spaceId: args.spaceId,
      title: parsed.title,
      description: parsed.description,
      status: "todo" as const,
      priority: parsed.priority,
      listId: listId as any,
      tags: parsed.tags,
      dueDate: parsed.dueDate,
      dueTime: parsed.dueTime,
      reminders,
      rawTranscription: args.rawText,
      createdAt: Date.now(),
    });

    return todoId;
```

With:

```typescript
    const createdAt = Date.now();
    const todoId = await ctx.runMutation(internal.todos.insertFromAction, {
      userId: user._id,
      spaceId: args.spaceId,
      title: parsed.title,
      description: parsed.description,
      status: "todo" as const,
      priority: parsed.priority,
      listId: listId as any,
      tags: parsed.tags,
      dueDate: parsed.dueDate,
      dueTime: parsed.dueTime,
      reminders,
      rawTranscription: args.rawText,
      createdAt,
    });

    return JSON.stringify({
      id: todoId,
      title: parsed.title,
      description: parsed.description,
      dueDate: parsed.dueDate,
      dueTime: parsed.dueTime,
      priority: parsed.priority,
      tags: parsed.tags,
      reminders: reminders?.map((r) => ({ at: r.at })),
      listName: parsed.listName,
    });
```

**Step 2: Deploy**

Run: `npx convex deploy --yes`
Expected: Successful deployment.

**Step 3: Commit**

```bash
git add convex/todos.ts
git commit -m "feat: return full parsed data from processAndCreate"
```

---

### Task 2: Create TodoConfirmationController (NSPanel management)

**Files:**
- Create: `Sources/JackApp/TodoConfirmationController.swift`

**Step 1: Create the controller**

This controller manages the floating NSPanel, show/hide lifecycle, auto-dismiss timer, and hosts the SwiftUI views.

```swift
import AppKit
import SwiftUI

/// Data model for a newly created todo, passed from processAndCreate response.
struct CreatedTodoInfo {
    let id: String
    let title: String
    let description: String?
    let dueDate: String?
    let dueTime: String?
    let priority: String
    let tags: [String]?
    let reminderCount: Int
    let listName: String?
}

@MainActor
final class TodoConfirmationController {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var isEditing = false
    private let bottomOffset: CGFloat = 48
    private let cardWidth: CGFloat = 320

    // Callback for when user saves an edit — caller wires this to Convex mutation.
    var onSave: ((CreatedTodoInfo, _ updates: [String: Any]) async -> Void)?

    func show(todo: CreatedTodoInfo) {
        dismissTask?.cancel()
        isEditing = false

        let panel = ensurePanel()
        let hostingView = NSHostingView(
            rootView: TodoConfirmationView(
                todo: todo,
                onOK: { [weak self] in self?.hide() },
                onEdit: { [weak self] in self?.enterEditMode(todo: todo) }
            )
        )
        panel.contentView = hostingView

        let size = NSSize(width: cardWidth, height: 200)
        resize(panel, size: size)
        positionPanel(panel, size: size)

        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 1
        }

        startAutoDismiss()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        dismissTask?.cancel()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel?.alphaValue = 1
        })
    }

    // MARK: - Private

    private func enterEditMode(todo: CreatedTodoInfo) {
        isEditing = true
        dismissTask?.cancel()

        guard let panel else { return }
        let hostingView = NSHostingView(
            rootView: TodoEditView(
                todo: todo,
                onCancel: { [weak self] in self?.hide() },
                onSave: { [weak self] updates in
                    guard let self else { return }
                    await self.onSave?(todo, updates)
                    self.hide()
                }
            )
        )
        panel.contentView = hostingView

        let size = NSSize(width: cardWidth, height: 360)
        resize(panel, size: size)
        positionPanel(panel, size: size)
    }

    private func startAutoDismiss() {
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.hide() }
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: cardWidth, height: 200)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false

        self.panel = panel
        return panel
    }

    private func resize(_ panel: NSPanel, size: NSSize) {
        let frame = NSRect(origin: panel.frame.origin, size: size)
        panel.setFrame(frame, display: true)
    }

    private func positionPanel(_ panel: NSPanel, size: NSSize) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        let x = round(visibleFrame.midX - size.width / 2)
        let y = round(visibleFrame.origin.y + bottomOffset)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
```

**Step 2: Commit**

```bash
git add Sources/JackApp/TodoConfirmationController.swift
git commit -m "feat: add TodoConfirmationController with NSPanel management"
```

---

### Task 3: Create TodoConfirmationView (SwiftUI card)

**Files:**
- Create: `Sources/JackApp/TodoConfirmationView.swift`

**Step 1: Create the confirmation view**

```swift
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
        // Check if date is today
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
```

**Step 2: Commit**

```bash
git add Sources/JackApp/TodoConfirmationView.swift
git commit -m "feat: add TodoConfirmationView SwiftUI card"
```

---

### Task 4: Create TodoEditView (SwiftUI floating editor)

**Files:**
- Create: `Sources/JackApp/TodoEditView.swift`

**Step 1: Create the editor view**

```swift
import SwiftUI

struct TodoEditView: View {
    let todo: CreatedTodoInfo
    let onCancel: () -> Void
    let onSave: ([String: Any]) async -> Void

    @State private var title: String
    @State private var dueDate: String
    @State private var dueTime: String
    @State private var priority: String
    @State private var tags: String
    @State private var isSaving = false

    init(
        todo: CreatedTodoInfo,
        onCancel: @escaping () -> Void,
        onSave: @escaping ([String: Any]) async -> Void
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
                        var updates: [String: Any] = ["title": title, "priority": priority]
                        if !dueDate.isEmpty { updates["dueDate"] = dueDate }
                        if !dueTime.isEmpty { updates["dueTime"] = dueTime }
                        let parsedTags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        if !parsedTags.isEmpty { updates["tags"] = parsedTags }
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
```

**Step 2: Commit**

```bash
git add Sources/JackApp/TodoEditView.swift
git commit -m "feat: add TodoEditView SwiftUI floating editor"
```

---

### Task 5: Wire everything together in DictationController

**Files:**
- Modify: `Sources/JackApp/DictationController.swift:253` (add property)
- Modify: `Sources/JackApp/DictationController.swift:1529-1549` (parse response, show card)

**Step 1: Add the confirmation controller property**

At line 253 (next to the existing `bubble` property), add:

```swift
    private let todoConfirmation = TodoConfirmationController()
```

**Step 2: Update syncTodoToConvex to parse response and show card**

Replace the current `syncTodoToConvex` method (lines 1529-1549) with:

```swift
    private func syncTodoToConvex(text: String) async {
        do {
            let token = try await ConvexHTTPClient.getToken()
            var args: [String: Any] = [
                "rawText": text,
                "timezone": TimeZone.current.identifier,
            ]
            if let spaceId = spaceController?.currentSpaceId {
                args["spaceId"] = spaceId
            }
            let result = try await ConvexHTTPClient.action(
                function: "todos:processAndCreate",
                args: args,
                token: token
            )
            lastTodoSavedAt = Date()

            // Parse the returned JSON and show confirmation card
            if let jsonString = result as? String,
               let data = jsonString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                let info = CreatedTodoInfo(
                    id: json["id"] as? String ?? "",
                    title: json["title"] as? String ?? text,
                    description: json["description"] as? String,
                    dueDate: json["dueDate"] as? String,
                    dueTime: json["dueTime"] as? String,
                    priority: json["priority"] as? String ?? "none",
                    tags: json["tags"] as? [String],
                    reminderCount: (json["reminders"] as? [[String: Any]])?.count ?? 0,
                    listName: json["listName"] as? String
                )
                showTodoConfirmation(info)
            }

            statusText = "Todo created."
        } catch {
            handleError("Could not create todo. \(error.localizedDescription)")
        }
    }

    private func showTodoConfirmation(_ todo: CreatedTodoInfo) {
        todoConfirmation.onSave = { [weak self] todo, updates in
            await self?.saveTodoEdit(todoId: todo.id, updates: updates)
        }
        todoConfirmation.show(todo: todo)
    }

    private func saveTodoEdit(todoId: String, updates: [String: Any]) async {
        do {
            let token = try await ConvexHTTPClient.getToken()
            var args: [String: Any] = updates
            args["todoId"] = todoId
            _ = try await ConvexHTTPClient.mutation(
                function: "todos:update",
                args: args,
                token: token
            )
            lastTodoSavedAt = Date()
        } catch {
            NSLog("[DictationController] Failed to update todo: %@", String(describing: error))
        }
    }
```

**Step 3: Commit**

```bash
git add Sources/JackApp/DictationController.swift
git commit -m "feat: wire todo confirmation card into dictation flow"
```

---

### Task 6: Deploy backend and build

**Step 1: Deploy Convex**

Run: `npx convex deploy --yes`
Expected: Successful deployment.

**Step 2: Build the Swift app**

Run: `swift build` or use `Scripts/compile_and_run.sh`
Expected: Clean build, no errors.

**Step 3: Test end-to-end**

1. Activate dictation, switch to todo mode, say "buy groceries tomorrow at 5pm remind me 10 minutes before"
2. After transcription, the confirmation card should appear bottom-center showing title, due date, time, reminder, priority
3. Wait 3 seconds — card should fade out
4. Repeat and press OK — card should dismiss immediately
5. Repeat and press Edit — editor should appear with editable fields
6. Change the title, press Save — todo should update in the list

**Step 4: Commit**

```bash
git commit -m "feat: todo confirmation card - complete implementation"
```
