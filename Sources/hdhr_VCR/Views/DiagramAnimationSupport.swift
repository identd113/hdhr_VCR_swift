import SwiftUI

// Shared date-driven cyclic-progress math for the app's small "how it works" first-run wizard
// diagrams. NetworkFlowDiagram/WebLANDiagram no longer animate at all (see NetworkFlowDiagram's own
// doc comment — a continuously-redrawing TimelineView hosted inside the wizard's content-fitted
// window caused a real, repeatable crash, fixed 2026-09-12 by removing the motion entirely); `progress`
// is kept because TerminalTypingDiagram (a plain `.periodic` TimelineView, not `.animation`, and not
// hosted in a way that ever reproduced the crash) still uses it for its typing-cursor blink cadence.
enum DiagramAnimation {
    // 0..<1 progress around a repeating cycle, offset so multiple phase-staggered instances stay
    // evenly spaced instead of bunching up.
    static func progress(_ date: Date, cycleSeconds: Double, phaseOffset: Double = 0) -> Double {
        let t = date.timeIntervalSinceReferenceDate / cycleSeconds + phaseOffset
        return t.truncatingRemainder(dividingBy: 1)
    }

    // Device icon with a small colored status badge in the top-trailing corner — the shape both
    // diagrams use for "this Mac."
    @ViewBuilder
    static func deviceIcon(systemImage: String, size: CGFloat, badgeColor: Color) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.62))
                .foregroundStyle(Color(NSColor.labelColor))
                .frame(width: size, height: size)
            Circle()
                .fill(badgeColor)
                .frame(width: 11, height: 11)
                .overlay(Circle().strokeBorder(Color(NSColor.windowBackgroundColor), lineWidth: 1.5))
                .offset(x: 3, y: -2)
        }
    }
}
