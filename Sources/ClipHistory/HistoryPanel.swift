import AppKit
import SwiftUI

final class HistoryPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var hidesOnResignKey = true

    init(rootView: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
            // Non-activating: the app the user came from stays frontmost, so the synthetic Cmd+V lands there.
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: rootView.ignoresSafeArea())
    }

    override var canBecomeKey: Bool { true }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            setFrameOrigin(NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.midY - frame.height / 2 + visible.height * 0.08
            ))
        }
        makeKeyAndOrderFront(nil)
    }

    override func resignKey() {
        super.resignKey()
        if hidesOnResignKey { orderOut(nil) }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !event.modifierFlags.contains(.command), onKey?(event) == true { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        if onKey?(event) == true { return true }

        // An accessory app has no Edit menu, so the standard text shortcuts need manual routing.
        let action: Selector? = switch event.charactersIgnoringModifiers {
        case "v": #selector(NSText.paste(_:))
        case "c": #selector(NSText.copy(_:))
        case "x": #selector(NSText.cut(_:))
        case "a": #selector(NSText.selectAll(_:))
        default: nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
