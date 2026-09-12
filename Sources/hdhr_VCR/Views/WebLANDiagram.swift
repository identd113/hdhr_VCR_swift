import SwiftUI

// Static "how it works" map for Web LAN: this Mac's guide and live/recorded shows, reachable from
// any browser or device already on your home network — no separate app or account needed. Purpose-
// built rather than reusing NetworkFlowDiagram's two-node shape, because Web LAN's relationship is
// genuinely different from Recording FEED's: one Mac serving many different *kinds* of devices at
// once, not one Mac connecting to one specific other Mac — so this fans out to three distinct device
// icons instead of a single clean line to a single icon.
struct WebLANDiagram: View {
    private static let deviceSize: CGFloat = 40
    private static let receiverSize: CGFloat = 22
    private static let packetSize: CGFloat = 6
    // Three receivers, staggered left-to-right — reads as a fan-out shape even without motion.
    private static let receivers: [(systemImage: String, phaseOffset: Double, yOffset: CGFloat)] = [
        ("desktopcomputer", 0.0,  -24),
        ("ipad",            0.33,  0),
        ("iphone",          0.66,  24),
    ]

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let midY = geo.size.height / 2
                let leftX = Self.deviceSize / 2 + 2
                let branchX = leftX + Self.deviceSize / 2 + 14
                let rightEdgeX = geo.size.width - Self.receiverSize / 2 - 2

                ZStack {
                    ForEach(Self.receivers, id: \.systemImage) { receiver in
                        Path { p in
                            p.move(to: CGPoint(x: branchX, y: midY))
                            p.addLine(to: CGPoint(x: rightEdgeX - Self.receiverSize / 2 - 4, y: midY + receiver.yOffset))
                        }
                        .stroke(Color(NSColor.separatorColor), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    }

                    // Always the single-frame frozen-mid-flow rendering, never a live TimelineView —
                    // see issues_resolved.md's "First-Run Wizard's Recording FEED step crashed the
                    // app outright" entry (feature/recording-feed branch): a continuously-redrawing
                    // TimelineView(.animation) hosted inside this wizard's content-fitted window
                    // triggers a real, repeatable AppKit crash ("needs another Update Constraints in
                    // Window pass..."). That entry caught it on NetworkFlowDiagram (the FEED step,
                    // gated behind a flag and unreachable in this release); this diagram uses the
                    // identical TimelineView(.animation) shape in a wizard step with no such gate —
                    // Web LAN is shown to every user — so it carries the same crash risk even though
                    // it hasn't been directly observed live yet.
                    ForEach(Self.receivers, id: \.systemImage) { receiver in
                        Circle()
                            .fill(watchNowBlue)
                            .frame(width: Self.packetSize, height: Self.packetSize)
                            .position(x: (branchX + rightEdgeX) / 2, y: midY + receiver.yOffset / 2)
                    }

                    DiagramAnimation.deviceIcon(systemImage: "desktopcomputer", size: Self.deviceSize, badgeColor: Color(NSColor.systemGreen))
                        .position(x: leftX, y: midY)

                    ForEach(Self.receivers, id: \.systemImage) { receiver in
                        Image(systemName: receiver.systemImage)
                            .font(.system(size: Self.receiverSize * 0.72))
                            .foregroundStyle(watchNowBlue)
                            .frame(width: Self.receiverSize, height: Self.receiverSize)
                            .position(x: rightEdgeX, y: midY + receiver.yOffset)
                    }
                }
            }
            .frame(height: 84)

            HStack {
                Label("Web LAN", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2).foregroundStyle(Color(NSColor.systemGreen))
                Spacer()
                Label("Any device", systemImage: "checkmark.circle")
                    .font(.caption2).foregroundStyle(watchNowBlue)
            }
        }
        .accessibilityHidden(true)   // purely decorative — the surrounding text explains the same thing
    }
}
