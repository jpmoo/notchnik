//
//  NotchOverlayPanel.swift
//  notch
//

import AppKit

/// Floating panel that sits above normal windows. Allowed to become key so text fields inside (the
/// chrome search inputs) can receive keystrokes; the `.nonactivatingPanel` style mask keeps our app
/// from being promoted to frontmost when this happens, so the user's previous app stays active.
final class NotchOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum NotchOverlayPanelFactory {
    static func makeHostingRoot(_ rootView: NSView) -> NotchOverlayPanel {
        let panel = NotchOverlayPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = rootView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        return panel
    }
}
