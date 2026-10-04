import SwiftUI
import AppKit

/// An NSMenuItem that runs a closure — lets a context menu be built imperatively with plain AppKit.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

/// A transparent overlay that shows a native NSMenu on right-click, built fresh at click time.
///
/// Why not SwiftUI's `.contextMenu`: a SwiftUI context menu is rebuilt whenever the view it belongs
/// to re-evaluates, and the player window observes `VLCBridge` (publishes every stats tick, ~3s)
/// and the whole `AppState` — so an open menu visibly reloaded every few seconds (found live
/// 2026-10-03, the PiP "Channel" submenu). An `NSMenu` handed to `popUpContextMenu` is a snapshot
/// that SwiftUI never touches.
///
/// Only right-clicks (and ctrl-clicks) are claimed in `hitTest`, so every other click, drag and
/// hover reaches the SwiftUI views underneath.
struct NativeContextMenuHost: NSViewRepresentable {
    /// Called on the main actor at right-click time; return nil to show no menu.
    let makeMenu: @MainActor () -> NSMenu?

    func makeNSView(context: Context) -> HostView {
        let v = HostView()
        v.makeMenu = makeMenu
        return v
    }

    func updateNSView(_ nsView: HostView, context: Context) { nsView.makeMenu = makeMenu }

    final class HostView: NSView {
        var makeMenu: (@MainActor () -> NSMenu?)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent else { return nil }
            let isContextClick = e.type == .rightMouseDown
                || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))
            return isContextClick ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let menu = makeMenu?() else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        override func mouseDown(with event: NSEvent) {
            // ctrl-click is the other macOS spelling of a right-click.
            if event.modifierFlags.contains(.control) { rightMouseDown(with: event) } else { super.mouseDown(with: event) }
        }
    }
}
