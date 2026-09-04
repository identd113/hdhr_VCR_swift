import SwiftUI

// Animated "how it works" map for Web LAN, purpose-built rather than reusing NetworkFlowDiagram's
// two-node shape (added 2026-09-04, replacing an earlier version that palette-swapped the same
// diagram FEED uses — live feedback was that stacked side by side on one screen they read as the
// same graphic twice). Web LAN is a genuinely different relationship than FEED's: one Mac serving
// many different *kinds* of devices at once, not one Mac connecting to one specific other Mac — so
// this fans out to three distinct device icons instead of a single clean line to a single icon.
struct WebLANDiagram: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let deviceSize: CGFloat = 40
    private static let receiverSize: CGFloat = 22
    private static let packetSize: CGFloat = 6
    private static let packetCycleSeconds: Double = 1.8
    private static let rippleCycleSeconds: Double = 1.8
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
                        TimelineView(.animation) { timeline in
                            ForEach(Self.receivers, id: \.systemImage) { receiver in
                                packetDot(date: timeline.date, phaseOffset: receiver.phaseOffset,
                                          startX: branchX, endX: rightEdgeX - Self.receiverSize / 2 - 4,
                                          startY: midY, endY: midY + receiver.yOffset)
                            }
                            rippleRing(date: timeline.date, phaseOffset: 0)
                                .position(x: leftX, y: midY)
                            rippleRing(date: timeline.date, phaseOffset: 0.5)
                                .position(x: leftX, y: midY)
                        }
                    }

                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: Self.deviceSize * 0.62))
                            .foregroundStyle(Color(NSColor.labelColor))
                            .frame(width: Self.deviceSize, height: Self.deviceSize)
                        Circle()
                            .fill(Color(NSColor.systemGreen))
                            .frame(width: 11, height: 11)
                            .overlay(Circle().strokeBorder(Color(NSColor.windowBackgroundColor), lineWidth: 1.5))
                            .offset(x: 3, y: -2)
                    }
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

    private static func progress(_ date: Date, cycleSeconds: Double, phaseOffset: Double) -> Double {
        let t = date.timeIntervalSinceReferenceDate / cycleSeconds + phaseOffset
        return t.truncatingRemainder(dividingBy: 1)
    }

    private static func packetOpacity(_ t: Double) -> Double {
        let fadeWidth = 0.15
        if t < fadeWidth { return t / fadeWidth }
        if t > 1 - fadeWidth { return (1 - t) / fadeWidth }
        return 1
    }

    @ViewBuilder
    private func packetDot(date: Date, phaseOffset: Double, startX: CGFloat, endX: CGFloat, startY: CGFloat, endY: CGFloat) -> some View {
        let t = Self.progress(date, cycleSeconds: Self.packetCycleSeconds, phaseOffset: phaseOffset)
        Circle()
            .fill(watchNowBlue)
            .frame(width: Self.packetSize, height: Self.packetSize)
            .opacity(Self.packetOpacity(t))
            .position(x: startX + (endX - startX) * CGFloat(t), y: startY + (endY - startY) * CGFloat(t))
    }

    @ViewBuilder
    private func rippleRing(date: Date, phaseOffset: Double) -> some View {
        let t = Self.progress(date, cycleSeconds: Self.rippleCycleSeconds, phaseOffset: phaseOffset)
        Circle()
            .stroke(Color(NSColor.systemGreen).opacity(0.5 * (1 - t)), lineWidth: 2)
            .frame(width: Self.deviceSize, height: Self.deviceSize)
            .scaleEffect(1 + CGFloat(t) * 1.6)
    }
}
