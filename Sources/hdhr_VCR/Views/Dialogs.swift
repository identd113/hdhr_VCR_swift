import AppKit

/// Non-blocking dialogs — the replacement for `NSAlert.runModal()` / `NSOpenPanel.runModal()`.
///
/// `runModal()` parks the main thread in its own event loop until the user answers. Everything that
/// runs on the main actor stops with it: the web server's request handlers (the guide, SSE, other
/// Macs' FEED viewers), the idle loop, recording start/stop. These helpers keep the main thread
/// free: an alert is a sheet on the frontmost app window, or — with no window open (a menu-bar app
/// often has none) — a small floating alert window; a file picker is a sheet or a non-modal panel.
///
/// Answer with `await Dialogs.present(alert)` (same `.alertFirstButtonReturn…` values `runModal()`
/// returned) or fire-and-forget with `Dialogs.show(alert)`. Pickers: `Dialogs.choose(panel) { url in … }`.
/// Not for launch-time prompts that must finish before the app starts (see `AppRelocator`).
@MainActor
enum Dialogs {
    /// Standalone alert windows currently on screen, retained until answered.
    private static var standalone: [ObjectIdentifier: StandaloneAlert] = [:]

    /// The window a sheet should hang off: the key window, else any visible, keyable app window.
    static func hostWindow() -> NSWindow? {
        if let key = NSApp.keyWindow, key.isVisible, !key.isSheet { return key }
        return NSApp.windows.first { $0.isVisible && !$0.isSheet && $0.canBecomeKey && !($0 is NSPanel) }
    }

    /// Shows `alert` without blocking and returns the user's choice (`.alertFirstButtonReturn` …).
    @discardableResult
    static func present(_ alert: NSAlert, on window: NSWindow? = nil) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            show(alert, on: window) { continuation.resume(returning: $0) }
        }
    }

    /// Shows `alert` without blocking; `completion` receives the choice (default: ignore it).
    static func show(_ alert: NSAlert, on window: NSWindow? = nil,
                     completion: @escaping (NSApplication.ModalResponse) -> Void = { _ in }) {
        // One sheet per window: a second request while one is up gets its own floating window.
        if let host = window ?? hostWindow(), host.attachedSheet == nil {
            alert.beginSheetModal(for: host, completionHandler: completion)
            return
        }
        let box = StandaloneAlert(alert: alert, completion: completion)
        standalone[ObjectIdentifier(box)] = box
        box.present()
    }

    /// Shows a file/folder picker without blocking; `completion` gets the chosen URL, or nil if cancelled.
    static func choose(_ panel: NSSavePanel, on window: NSWindow? = nil, completion: @escaping (URL?) -> Void) {
        if let host = window ?? hostWindow(), host.attachedSheet == nil {
            panel.beginSheetModal(for: host) { completion($0 == .OK ? panel.url : nil) }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            panel.begin { completion($0 == .OK ? panel.url : nil) }
        }
    }

    fileprivate static func finished(_ box: StandaloneAlert) {
        standalone.removeValue(forKey: ObjectIdentifier(box))
    }
}

/// An `NSAlert` shown as an ordinary, non-modal floating window (its buttons rewired to report the
/// choice) for when there is no app window to hang a sheet off.
@MainActor
private final class StandaloneAlert: NSObject {
    private let alert: NSAlert
    private var completion: ((NSApplication.ModalResponse) -> Void)?

    init(alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        self.alert = alert
        self.completion = completion
        super.init()
        for button in alert.buttons {
            button.target = self
            button.action = #selector(buttonClicked(_:))
        }
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        // NSAlert only lays out (hides its unused template buttons and the suppression checkbox) when
        // it is run or begun as a sheet; showing alert.window directly without this leaves two blank
        // buttons and a "<Do not show this message again>" checkbox on screen.
        alert.layout()
        let window = alert.window
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        let index = alert.buttons.firstIndex(of: sender) ?? 0
        let response = NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
        alert.window.orderOut(nil)
        let done = completion
        completion = nil
        Dialogs.finished(self)
        done?(response)
    }
}
