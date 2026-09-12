import SwiftUI
import AppKit

// Generic bridge from SwiftUI to the hosting NSWindow, for one-off AppKit-only window setup that
// has no SwiftUI-level API — floating window level (DonationNagView), explicit re-centering
// (FirstRunWizardView). Extracted 2026-09-12 from two near-identical private
// NSViewRepresentable+DispatchQueue.main.async types that had each independently reinvented this
// same ~10-line idiom (DonationNagView's old FloatingWindowLevelSetter, FirstRunWizardView's old
// WindowRecenterer) — a third view needing window access now has one obvious place to reuse
// instead of writing a third copy.
//
// `trigger` is whatever value should cause `action` to reapply on a SwiftUI re-render — pass a
// constant (e.g. `true`) for an action that's cheap/idempotent to reapply on every render (like
// setting a window level), or a real changing value (e.g. a wizard's current step) to scope
// reapplication to specific changes. Either way `action` also always re-runs in `updateNSView`,
// not just once in `makeNSView` — for the constant-trigger case this widens FloatingWindowLevelSetter's
// original once-only behavior slightly, accepted since re-setting `.level` on every render is free.
struct WindowAction<Trigger: Equatable>: NSViewRepresentable {
    var trigger: Trigger
    let action: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { action(w) } }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let w = nsView.window { action(w) } }
    }
}
