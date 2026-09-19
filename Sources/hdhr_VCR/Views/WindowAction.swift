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
// constant (e.g. `true`) for an action that only ever needs to run once (like setting a window
// level), or a real changing value (e.g. a wizard's current step) to scope reapplication to
// specific changes. `action` always runs once via `makeNSView`; `updateNSView` re-runs it only
// when `trigger` actually changes since the last call (tracked in `Coordinator`), not on every
// unrelated SwiftUI re-render — found live 2026-09-18: FirstRunWizardView's `trigger: step` usage
// re-centered the window on *any* re-render (moving a Stepper, clicking a button), not just a
// step change, since the original version fired `action` unconditionally from `updateNSView`.
struct WindowAction<Trigger: Equatable>: NSViewRepresentable {
    var trigger: Trigger
    let action: (NSWindow) -> Void

    final class Coordinator {
        var lastTrigger: Trigger
        init(trigger: Trigger) { lastTrigger = trigger }
    }

    func makeCoordinator() -> Coordinator { Coordinator(trigger: trigger) }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { action(w) } }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard context.coordinator.lastTrigger != trigger else { return }
        context.coordinator.lastTrigger = trigger
        DispatchQueue.main.async { if let w = nsView.window { action(w) } }
    }
}
