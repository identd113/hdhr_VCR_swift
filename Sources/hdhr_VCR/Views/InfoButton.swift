import SwiftUI

struct InfoButton: View {
    let text: String
    // What the help is about ("Port"), so VoiceOver says "More information about Port" instead of a bare
    // "More information" repeated for every row. nil keeps the generic label.
    let about: String?
    @State private var isPresented = false
    init(_ text: String, about: String? = nil) { self.text = text; self.about = about }
    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()   // no blue focus square when a window opens with this the first control (the scan window's "The airwaves" (i))
        .padding(2)
        .contentShape(Rectangle())
        .help("Show help")
        .accessibilityLabel(about.map { "More information about \($0)" } ?? "More information")
        .accessibilityHint(text)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            // Explicit foreground rather than relying on .popover's own default Text color —
            // reported blank (unreadable) in dark mode: NSPopover's content view doesn't reliably
            // pick up the presenting window's appearance in every configuration this app runs in
            // (a MenuBarExtra-hosted app, or a window with .preferredColorScheme(.dark) applied
            // regardless of the system's own appearance). Deliberately does NOT also add an
            // explicit `.background` — an earlier attempt at that (`.background(.regularMaterial)`)
            // broke the popover's own automatic content-size calculation instead, ballooning it
            // into a mostly-empty box hundreds of points tall; `.popover`'s default background
            // already adapts correctly on its own, it was only the text color that needed pinning.
            //
            // `.frame(width:)` — a FIXED width, not `maxWidth` — for the same "don't break the
            // size calculation" reason: a flexible `maxWidth` frame has no determinate width until
            // something else constrains it, and a popover's content has no real parent to supply
            // one, so NSHostingController's preferredContentSize negotiation gets an ambiguous
            // answer and falls back to an oversized box again — reported live as "the tooltip
            // window is very large and the text is shifted to the bottom" (the actual, much
            // smaller text ends up bottom-anchored inside that oversized fallback box). A fixed
            // width gives `.fixedSize(horizontal: false, vertical: true)` below a single concrete
            // width to measure the ideal *height* against, which is what actually lets the
            // popover size itself tightly around the real content.
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .padding(12)
                .frame(width: 280)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
