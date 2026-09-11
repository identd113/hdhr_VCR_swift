import SwiftUI

// Shared date-driven cyclic-progress math for the app's small "how it works" first-run wizard
// diagrams (NetworkFlowDiagram, WebLANDiagram, TerminalTypingDiagram) — each drives its own visual
// elements off a TimelineView's Date independently, but the underlying "where am I in a repeating
// cycle" and "fade in/out near the edges" math is identical regardless of what's actually animating.
// Factored out after NetworkFlowDiagram and WebLANDiagram's copies of both functions drifted to
// exactly the same code living in two places.
enum DiagramAnimation {
    // Rounds `date` down to the nearest `interval`-sized bucket — lets a caller drive its
    // TimelineView off `.animation` (which SwiftUI suspends automatically when the view isn't
    // actually being displayed, e.g. the wizard window backgrounded or the Mac idle) while still
    // only recomputing/redrawing at the throttled cadence `.periodic(by: interval)` used to provide
    // directly. `.animation` alone fires on every display refresh (2-4x more often than needed for
    // these purely decorative diagrams, per NetworkFlowDiagram/WebLANDiagram's own original
    // reasoning for choosing `.periodic`); passing this snapped Date into progress(_:cycleSeconds:)
    // instead of the raw one means repeated calls within the same bucket compute identical values,
    // so the extra redraws between buckets are no-ops rather than real work — gets both properties
    // `.periodic` and `.animation` each only had one of. Added 2026-09-11, see ISSUES.md's entry.
    static func snappedDate(_ date: Date, interval: Double) -> Date {
        guard interval > 0 else { return date }
        let t = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / interval).rounded(.down) * interval)
    }

    // 0..<1 progress around a repeating cycle, offset so multiple phase-staggered instances (e.g.
    // two packets on the same line) stay evenly spaced instead of bunching up.
    static func progress(_ date: Date, cycleSeconds: Double, phaseOffset: Double = 0) -> Double {
        let t = date.timeIntervalSinceReferenceDate / cycleSeconds + phaseOffset
        return t.truncatingRemainder(dividingBy: 1)
    }

    // Fades in/out over the first/last `fadeWidth` fraction of a 0...1 progress value, so a moving
    // element doesn't pop in/out abruptly right at its start/end point.
    static func edgeFadeOpacity(_ t: Double, fadeWidth: Double = 0.15) -> Double {
        if t < fadeWidth { return t / fadeWidth }
        if t > 1 - fadeWidth { return (1 - t) / fadeWidth }
        return 1
    }

    // Self-positioning moving dot along a line from (startX,startY) to (endX,endY), fading in/out
    // near each end. `startY == endY` collapses to a purely horizontal line (NetworkFlowDiagram's
    // shape); a real diagonal (WebLANDiagram's fan-out to three receivers) just passes different Y
    // endpoints. Added 2026-09-11 — previously two near-identical private copies (one of which also
    // didn't self-position, requiring a separate public `packetX` the other didn't need) living in
    // NetworkFlowDiagram.swift/WebLANDiagram.swift, the exact duplication `c1b9a90`'s own commit
    // message flagged this file's timing-math extraction as not fully closing. See ISSUES.md.
    @ViewBuilder
    static func packetDot(date: Date, cycleSeconds: Double, phaseOffset: Double, size: CGFloat, color: Color,
                           startX: CGFloat, endX: CGFloat, startY: CGFloat, endY: CGFloat) -> some View {
        let t = progress(date, cycleSeconds: cycleSeconds, phaseOffset: phaseOffset)
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(edgeFadeOpacity(t))
            .position(x: startX + (endX - startX) * CGFloat(t), y: startY + (endY - startY) * CGFloat(t))
    }

    // Expanding, fading ring — the "broadcasting outward" pulse effect centered on a device's own
    // position (positioned by the caller, same as SettingsView's About-tab SignalRing pulse).
    @ViewBuilder
    static func rippleRing(date: Date, cycleSeconds: Double, phaseOffset: Double, size: CGFloat, color: Color) -> some View {
        let t = progress(date, cycleSeconds: cycleSeconds, phaseOffset: phaseOffset)
        Circle()
            .stroke(color.opacity(0.5 * (1 - t)), lineWidth: 2)
            .frame(width: size, height: size)
            .scaleEffect(1 + CGFloat(t) * 1.6)
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
