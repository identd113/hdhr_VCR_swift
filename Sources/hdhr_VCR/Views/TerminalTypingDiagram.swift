import SwiftUI

// Animated "how it works" map for Terminal Guide — a standalone mock terminal window with a
// command typing itself out and a blinking cursor, looping. Deliberately NOT another instance of
// the network-flow diagrams (NetworkFlowDiagram/WebLANDiagram) other Sharing features use — added
// 2026-09-04 after live feedback that a palette-swapped copy of the same "two devices, flowing
// packets" shape read as visually redundant next to Web LAN's own diagram. Terminal Guide isn't
// really "this Mac broadcasting to a receiver" the way Web LAN/Recording FEED are — it's a CLI
// session — so this shows that directly instead of forcing it into the same broadcast metaphor.
//
// Hardcoded dark chrome (not theme-adaptive) is deliberate: this is a small cameo of what an actual
// terminal window looks like, which is conventionally dark regardless of the host app's own
// light/dark mode — same reasoning a screenshot of another app's own UI wouldn't re-theme itself.
struct TerminalTypingDiagram: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let command = "hdhr_guide"
    private static let typeSecondsPerChar: Double = 0.09
    private static let holdSeconds: Double = 1.4
    private static let blinkCycleSeconds: Double = 0.9
    private static var typeDuration: Double { Double(command.count) * typeSecondsPerChar }
    private static var cycleSeconds: Double { typeDuration + holdSeconds + 0.4 }

    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black)
                .overlay(alignment: .topLeading) {
                    // Three traffic-light dots — purely decorative chrome establishing "this is a
                    // terminal window," not real controls (no tap targets, matches this whole
                    // diagram's accessibilityHidden below).
                    HStack(spacing: 6) {
                        Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 9, height: 9)
                        Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 9, height: 9)
                        Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.35)).frame(width: 9, height: 9)
                    }
                    .padding(.leading, 10)
                    .padding(.top, 9)
                }
                .overlay(alignment: .leading) {
                    if reduceMotion {
                        // Static, fully-typed frame — still shows what the window contains, just
                        // no motion. Same convention the other two Sharing diagrams use.
                        promptLine(typedCount: Self.command.count, cursorOn: true)
                            .padding(.leading, 12)
                    } else {
                        TimelineView(.animation) { timeline in
                            let t = Self.progress(timeline.date)
                            let typedCount = Self.typedCharCount(for: t)
                            let cursorOn = Self.cursorBlinkOn(timeline.date)
                            promptLine(typedCount: typedCount, cursorOn: cursorOn)
                        }
                        .padding(.leading, 12)
                    }
                }
                .frame(height: 84)

            HStack {
                Label("Terminal", systemImage: "terminal")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2).foregroundStyle(Color(NSColor.systemGreen))
                Spacer()
                Label("hdhr_guide", systemImage: "checkmark.circle")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)   // purely decorative — the surrounding text explains the same thing
    }

    @ViewBuilder
    private func promptLine(typedCount: Int, cursorOn: Bool) -> some View {
        let typed = String(Self.command.prefix(typedCount))
        (Text("$ ").foregroundColor(.white.opacity(0.5))
            + Text(typed).foregroundColor(Color(red: 0.4, green: 0.95, blue: 0.5))
            + Text(cursorOn ? "▌" : " ").foregroundColor(Color(red: 0.4, green: 0.95, blue: 0.5)))
            .font(.system(.callout, design: .monospaced))
    }

    // 0...1 progress through one full type→hold→reset cycle.
    private static func progress(_ date: Date) -> Double {
        (date.timeIntervalSinceReferenceDate).truncatingRemainder(dividingBy: cycleSeconds)
    }

    private static func typedCharCount(for elapsedInCycle: Double) -> Int {
        guard elapsedInCycle < typeDuration else { return command.count }
        return Int(elapsedInCycle / typeSecondsPerChar)
    }

    private static func cursorBlinkOn(_ date: Date) -> Bool {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: blinkCycleSeconds)
        return t < blinkCycleSeconds / 2
    }
}
