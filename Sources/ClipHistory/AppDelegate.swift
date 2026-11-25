import AppKit
import Carbon.HIToolbox
import ClipHistoryCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: Store!
    private var monitor: ClipboardMonitor!
    private var model: HistoryModel!
    private var panel: HistoryPanel!
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let support = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("ClipHistory")
            let images = support.appendingPathComponent("images")
            try FileManager.default.createDirectory(
                at: images, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
            store = try Store(path: support.appendingPathComponent("history.sqlite").path)
            monitor = ClipboardMonitor(store: store, imagesDirectory: images)
        } catch {
            fatal("ClipHistory cannot open its database.", detail: "\(error)")
        }

        model = HistoryModel(store: store)
        model.onPaste = { [weak self] in self?.paste($0) }
        model.onClose = { [weak self] in self?.panel.orderOut(nil) }

        panel = HistoryPanel(rootView: HistoryView(model: model))
        panel.onKey = { [weak self] in self?.model.handleKey($0) ?? false }

        monitor.onCapture = { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.model.reload(keepSelection: true)
        }
        monitor.start()

        hotKey = HotKey(keyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey) { [weak self] in
            self?.togglePanel()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "list.clipboard", accessibilityDescription: "ClipHistory"
        )
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if hotKey == nil {
            alert("ClipHistory cannot register ⇧⌘V.", detail: "Another app uses this shortcut. Open the history from the menu bar icon.")
        }
        // The prompt appears only while the permission is missing.
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let count = (try? store.count()) ?? 0
        menu.addItem(withTitle: "\(count) items in history", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let open = menu.addItem(withTitle: "Open History", action: #selector(togglePanel), keyEquivalent: "v")
        open.keyEquivalentModifierMask = [.command, .shift]

        let pause = menu.addItem(withTitle: "Pause Capture", action: #selector(togglePause), keyEquivalent: "")
        pause.state = monitor.isPaused ? .on : .off

        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off

        if !AXIsProcessTrusted() {
            menu.addItem(withTitle: "Grant Accessibility Access for Paste…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete Last 15 Minutes", action: #selector(deleteRecent), keyEquivalent: "")
        menu.addItem(withTitle: "Clear History…", action: #selector(clearHistory), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ClipHistory", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            model.prepareForDisplay()
            panel.show()
        }
    }

    @objc private func togglePause() {
        monitor.isPaused.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("ClipHistory cannot change the login item.", detail: "\(error.localizedDescription)")
        }
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    @objc private func deleteRecent() {
        _ = try? store.deleteSince(Date().addingTimeInterval(-15 * 60))
    }

    @objc private func clearHistory() {
        let confirm = NSAlert()
        confirm.messageText = "Clear the clipboard history?"
        confirm.informativeText = "This deletes every item that is not pinned. You cannot undo this."
        confirm.addButton(withTitle: "Clear")
        confirm.addButton(withTitle: "Cancel")
        confirm.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        if confirm.runModal() == .alertFirstButtonReturn {
            _ = try? store.clear()
        }
    }

    private func paste(_ item: ClipItem) {
        guard writeToPasteboard(item) else {
            NSSound.beep()
            return
        }
        monitor.markCurrentContentsAsSeen()
        try? store.touch(id: item.id)
        panel.orderOut(nil)

        // Without the Accessibility permission the item is on the clipboard, and the user pastes it.
        guard AXIsProcessTrusted() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let source = CGEventSource(stateID: .combinedSessionState)
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: keyDown)
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    private func writeToPasteboard(_ item: ClipItem) -> Bool {
        let pasteboard = NSPasteboard.general
        switch item.kind {
        case .text:
            guard let text = try? store.fullText(id: item.id) else { return false }
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        case .image:
            guard let path = item.imagePath, let image = NSImage(contentsOfFile: path) else { return false }
            pasteboard.clearContents()
            return pasteboard.writeObjects([image])
        case .file:
            guard let text = try? store.fullText(id: item.id) else { return false }
            let urls = text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) as NSURL }
            pasteboard.clearContents()
            return pasteboard.writeObjects(urls)
        }
    }

    private func alert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func fatal(_ message: String, detail: String) -> Never {
        alert(message, detail: detail)
        exit(1)
    }
}
