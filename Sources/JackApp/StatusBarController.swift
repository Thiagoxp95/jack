import AppKit
import SwiftUI

/// Manages the persistent menu bar status item with quick actions.
@MainActor
final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var visibilityObserver: Any?

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            let icon = loadMenuBarIcon()
            icon.isTemplate = false
            button.image = icon
            button.toolTip = "Jack"
        }

        item.menu = buildMenu()
        statusItem = item

        visibilityObserver = NotificationCenter.default.addObserver(
            forName: .statusBarVisibilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let visible = notification.userInfo?["visible"] as? Bool ?? true
            Task { @MainActor in
                if visible {
                    self?.show()
                } else {
                    self?.hide()
                }
            }
        }
    }

    func show() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let icon = loadMenuBarIcon()
            icon.isTemplate = false
            button.image = icon
            button.toolTip = "Jack"
        }
        item.menu = buildMenu()
        statusItem = item
    }

    func hide() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    // MARK: - Icon

    private func loadMenuBarIcon() -> NSImage {
        // Look for the bundled resource first, fall back to a system symbol.
        if let img = Bundle.main.image(forResource: "MenuBarIcon") {
            img.size = NSSize(width: 22, height: 22)
            return img
        }
        return NSImage(systemSymbolName: "command", accessibilityDescription: "Jack")!
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Quick actions
        let todoSheetItem = NSMenuItem(title: "Todo Side Sheet", action: #selector(toggleTodoSheet), keyEquivalent: "")
        todoSheetItem.target = self
        todoSheetItem.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: nil)
        menu.addItem(todoSheetItem)

        let recordItem = NSMenuItem(title: "Start Screen Recording", action: #selector(startRecording), keyEquivalent: "r")
        recordItem.keyEquivalentModifierMask = [.command, .shift]
        recordItem.target = self
        recordItem.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        menu.addItem(recordItem)

        menu.addItem(.separator())

        // Navigation
        let overviewItem = NSMenuItem(title: "Overview", action: #selector(showOverview), keyEquivalent: ",")
        overviewItem.keyEquivalentModifierMask = [.command]
        overviewItem.target = self
        overviewItem.image = NSImage(systemSymbolName: "rectangle.grid.1x2", accessibilityDescription: nil)
        menu.addItem(overviewItem)

        let notesItem = NSMenuItem(title: "Notes", action: #selector(showNotes), keyEquivalent: "")
        notesItem.target = self
        notesItem.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)
        menu.addItem(notesItem)

        let todosItem = NSMenuItem(title: "Todos", action: #selector(showTodos), keyEquivalent: "")
        todosItem.target = self
        todosItem.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: nil)
        menu.addItem(todosItem)

        let recordingsItem = NSMenuItem(title: "Screen Recording", action: #selector(showScreenRecording), keyEquivalent: "")
        recordingsItem.target = self
        recordingsItem.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        menu.addItem(recordingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Jack", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Actions

    @objc func toggleTodoSheet() {
        TodoSideSheetController.shared.toggle()
    }

    @objc private func startRecording() {
        activateMainWindow()
        NotificationCenter.default.post(
            name: .showSection,
            object: nil,
            userInfo: ["section": "screenRecording"]
        )
    }

    @objc private func showOverview() {
        navigateToSection("overview")
    }

    @objc private func showNotes() {
        navigateToSection("notes")
    }

    @objc private func showTodos() {
        navigateToSection("todos")
    }

    @objc private func showScreenRecording() {
        navigateToSection("screenRecording")
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func navigateToSection(_ section: String) {
        activateMainWindow()
        NotificationCenter.default.post(
            name: .showSection,
            object: nil,
            userInfo: ["section": section]
        )
    }

    private func activateMainWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // If no window is visible, open a new one
            NSApp.activate()
        }
    }
}
