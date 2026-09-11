import SwiftUI

// Animated "how it works" map for Web LAN: this Mac's guide and live/recorded shows, reachable from
// any browser or device already on your home network — no separate app or account needed. Purpose-
// built rather than reusing NetworkFlowDiagram's two-node shape, because Web LAN's relationship is
// genuinely different from Recording FEED's: one Mac serving many different *kinds* of devices at
// once, not one Mac connecting to one specific other Mac — so this fans out to three distinct device
// icons instead of a single clean line to a single icon.
struct WebLANDiagram: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let deviceSize: CGFloat = 40
    private static let receiverSize: CGFloat = 22
    private static let packetSize: CGFloat = 6
    private static let packetCycleSeconds: Double = 1.8
    private static let rippleCycleSeconds: Double = 1.8
    private static let frameInterval: Double = 1.0 / 30.0
    // Three receivers, evenly staggered across the packet cycle — reads as a continuous fan-out
    // rhythm rather than three lines all pulsing in lockstep.
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

                    if reduceMotion {
                        // One frame frozen mid-flow, same "still shows the shape, just no motion"
                        // convention NetworkFlowDiagram's own Reduce Motion fallback uses.
                        ForEach(Self.receivers, id: \.systemImage) { receiver in
                            Circle()
                                .fill(watchNowBlue)
                                .frame(width: Self.packetSize, height: Self.packetSize)
                                .position(x: (branchX + rightEdgeX) / 2, y: midY + receiver.yOffset / 2)
                        }
                    } else {
                        // .animation + DiagramAnimation.snappedDate, not .periodic — see
                        // NetworkFlowDiagram's matching comment and ISSUES.md's entry (2026-09-11).
                        TimelineView(.animation) { timeline in
                            let date = DiagramAnimation.snappedDate(timeline.date, interval: Self.frameInterval)
                            ForEach(Self.receivers, id: \.systemImage) { receiver in
                                DiagramAnimation.packetDot(date: date, cycleSeconds: Self.packetCycleSeconds,
                                                            phaseOffset: receiver.phaseOffset, size: Self.packetSize, color: watchNowBlue,
                                                            startX: branchX, endX: rightEdgeX - Self.receiverSize / 2 - 4,
                                                            startY: midY, endY: midY + receiver.yOffset)
                            }
                            DiagramAnimation.rippleRing(date: date, cycleSeconds: Self.rippleCycleSeconds,
                                                         phaseOffset: 0, size: Self.deviceSize, color: Color(NSColor.systemGreen))
                                .position(x: leftX, y: midY)
                            DiagramAnimation.rippleRing(date: date, cycleSeconds: Self.rippleCycleSeconds,
                                                         phaseOffset: 0.5, size: Self.deviceSize, color: Color(NSColor.systemGreen))
                                .position(x: leftX, y: midY)
                        }
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
