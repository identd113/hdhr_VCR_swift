import SwiftUI

// Cyclic-progress helper for the first-run "how it works" diagrams. Only TerminalTypingDiagram's cursor blink still uses it:
// the other diagrams are static (a continuously redrawing TimelineView inside the wizard's content-fitted window crashed).
enum DiagramAnimation {
    // 0..<1 progress around a repeating cycle.
    static func progress(_ date: Date, cycleSeconds: Double) -> Double {
        let t = date.timeIntervalSinceReferenceDate / cycleSeconds
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
