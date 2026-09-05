import Foundation

// Shared date-driven cyclic-progress math for the app's small "how it works" first-run wizard
// diagrams (NetworkFlowDiagram, WebLANDiagram, TerminalTypingDiagram) — each drives its own visual
// elements off a TimelineView's Date independently, but the underlying "where am I in a repeating
// cycle" and "fade in/out near the edges" math is identical regardless of what's actually animating.
// Factored out after NetworkFlowDiagram and WebLANDiagram's copies of both functions drifted to
// exactly the same code living in two places.
enum DiagramAnimation {
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
}
