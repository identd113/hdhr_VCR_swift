import SwiftUI

// Static "how it works" map for Recording FEED: watch a recording that's already in progress on
// another Mac, live, without spending a second tuner. Two devices connected by a line — a small dot
// mid-line reads as "something flows between them" — makes that one-to-one hand-off legible at a
// glance without needing real motion (see the body's own comment on why this is deliberately no
// longer animated). Parametrized (icons/badge colors/captions) so it's reusable for any future
// point-to-point "this Mac ↔ one specific other party" explainer, not hardcoded to FEED, though FEED
// — whose "this Mac's recording, that Mac watching it" relationship is genuinely one-to-one — is the
// only user today.
//
// Web LAN and Terminal Guide, the app's other Sharing features, use their own purpose-built
// diagrams instead of a themed copy of this one, because their relationships are shaped differently:
// Web LAN (`WebLANDiagram.swift`) is one Mac serving many different kinds of devices at once, not
// one specific pair, so it fans out to three device icons. Terminal Guide
// (`TerminalTypingDiagram.swift`) isn't a broadcast relationship at all — it's a CLI session — so it
// shows a mock terminal window with a typing command instead of the two-device shape.
//
// Visual convention shared across every use of THIS component: the left side (always "this Mac")
// gets a badge color naming the specific local action happening (e.g. red = recording); the right
// side stays watchNowBlue by default — "whoever's receiving it" reads as one consistent identity.
struct NetworkFlowDiagram: View {
    var leftSystemImage: String = "desktopcomputer"
    var leftBadgeColor: Color
    var leftCaption: String
    var leftCaptionSystemImage: String

    var rightSystemImage: String
    var rightBadgeColor: Color = watchNowBlue
    var rightCaption: String
    var rightCaptionSystemImage: String

    private static let deviceSize: CGFloat = 40
    private static let packetSize: CGFloat = 7

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let midY = geo.size.height / 2
                let leftX = Self.deviceSize / 2 + 2
                let rightX = geo.size.width - Self.deviceSize / 2 - 2
                let lineStartX = leftX + Self.deviceSize / 2 + 6
                let lineEndX = rightX - Self.deviceSize / 2 - 6

                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: lineStartX, y: midY))
                        p.addLine(to: CGPoint(x: lineEndX, y: midY))
                    }
                    .stroke(Color(NSColor.separatorColor), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))

                    // Always the single-frame frozen-mid-flow rendering, never a live TimelineView —
                    // see issues_resolved.md's "First-Run Wizard's Recording FEED step crashed the
                    // app outright" entry. Two attempted fixes first (capping this step's Form
                    // height; switching .animation to .periodic) both failed to stop a real,
                    // repeatable crash: any continuously-redrawing TimelineView hosted inside this
                    // wizard's content-fitted (`height: nil`) window triggers AppKit's own
                    // "needs Update Constraints"/layout-invalidation path every tick, and once that
                    // count exceeds a small fixed AppKit safety limit the process gets hard-
                    // terminated — reproduced deterministically, at the identical window size, three
                    // times in one session, regardless of which TimelineView schedule was used. This
                    // diagram is purely illustrative (`.accessibilityHidden(true)` below) — the
                    // motion was a nice-to-have, not worth an unrecoverable crash. Still communicates
                    // "these two are connected," just without motion, same as the old `reduceMotion`
                    // fallback below used to provide.
                    Circle()
                        .fill(rightBadgeColor)
                        .frame(width: Self.packetSize, height: Self.packetSize)
                        .position(x: (lineStartX + lineEndX) / 2, y: midY)

                    DiagramAnimation.deviceIcon(systemImage: leftSystemImage, size: Self.deviceSize, badgeColor: leftBadgeColor)
                        .position(x: leftX, y: midY)
                    DiagramAnimation.deviceIcon(systemImage: rightSystemImage, size: Self.deviceSize, badgeColor: rightBadgeColor)
                        .position(x: rightX, y: midY)
                }
            }
            .frame(height: 84)

            HStack {
                Label(leftCaption, systemImage: leftCaptionSystemImage)
                    .labelStyle(.titleAndIcon)
                    .font(.caption2).foregroundStyle(leftBadgeColor)
                Spacer()
                Label(rightCaption, systemImage: rightCaptionSystemImage)
                    .font(.caption2).foregroundStyle(rightBadgeColor)
            }
        }
        .accessibilityHidden(true)   // purely decorative — the surrounding text explains the same thing
    }
}
