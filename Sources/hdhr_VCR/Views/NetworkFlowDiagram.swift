import SwiftUI

// Animated "how it works" map for a LAN-facing feature — two devices connected by a line, with
// signal rings broadcasting from the left (this Mac) device and small packets flowing along the
// line to the right one. Purely illustrative (no real network activity of its own). Parametrized
// so every first-run wizard "Sharing" step (Recording FEED, Enable Sharing, Terminal Guide) can
// reuse the same animation engine with its own icons/colors/captions rather than each hand-rolling
// a near-identical view — see FirstRunWizardView.swift's three call sites.
//
// Visual convention shared across every use: the left side (always "this Mac") gets a badge color
// naming the specific local action happening (e.g. red = recording, green = serving on the LAN);
// the right side stays watchNowBlue by default — "whoever's receiving it" reads as one consistent
// identity regardless of which feature is being explained.
struct NetworkFlowDiagram: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    // Two packets/rings per side, offset by half a cycle, so the line/device never sits empty
    // between beats — reads as a continuous flow rather than a single pulse repeating with a gap.
    private static let packetCycleSeconds: Double = 1.6
    private static let rippleCycleSeconds: Double = 1.8
    private static let phaseOffsets: [Double] = [0, 0.5]

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

                    if reduceMotion {
                        // A single frame frozen mid-flow rather than no diagram at all — still
                        // communicates "these two are connected," just without motion.
                        Circle()
                            .fill(rightBadgeColor)
                            .frame(width: Self.packetSize, height: Self.packetSize)
                            .position(x: (lineStartX + lineEndX) / 2, y: midY)
                    } else {
                        TimelineView(.animation) { timeline in
                            ForEach(Self.phaseOffsets, id: \.self) { offset in
                                rippleRing(date: timeline.date, phaseOffset: offset)
                                    .position(x: leftX, y: midY)
                            }
                            ForEach(Self.phaseOffsets, id: \.self) { offset in
                                packetDot(date: timeline.date, phaseOffset: offset,
                                          startX: lineStartX, endX: lineEndX)
                                    .position(
                                        x: Self.packetX(timeline.date, phaseOffset: offset, startX: lineStartX, endX: lineEndX),
                                        y: midY)
                            }
                        }
                    }

                    deviceIcon(systemImage: leftSystemImage, badgeColor: leftBadgeColor)
                        .position(x: leftX, y: midY)
                    deviceIcon(systemImage: rightSystemImage, badgeColor: rightBadgeColor)
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

    // MARK: - Devices

    @ViewBuilder
    private func deviceIcon(systemImage: String, badgeColor: Color) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: systemImage)
                .font(.system(size: Self.deviceSize * 0.62))
                .foregroundStyle(Color(NSColor.labelColor))
                .frame(width: Self.deviceSize, height: Self.deviceSize)
            Circle()
                .fill(badgeColor)
                .frame(width: 11, height: 11)
                .overlay(Circle().strokeBorder(Color(NSColor.windowBackgroundColor), lineWidth: 1.5))
                .offset(x: 3, y: -2)
        }
    }

    // MARK: - Animation math

    // 0...1 progress around one cycle, offset so multiple instances (phaseOffsets) stay evenly
    // spaced along the same line instead of bunching up.
    private static func progress(_ date: Date, cycleSeconds: Double, phaseOffset: Double) -> Double {
        let t = date.timeIntervalSinceReferenceDate / cycleSeconds + phaseOffset
        return t.truncatingRemainder(dividingBy: 1)
    }

    private static func packetX(_ date: Date, phaseOffset: Double, startX: CGFloat, endX: CGFloat) -> CGFloat {
        let t = progress(date, cycleSeconds: packetCycleSeconds, phaseOffset: phaseOffset)
        return startX + (endX - startX) * CGFloat(t)
    }

    // Fades in/out over the first and last 15% of the line so a packet doesn't pop in/out abruptly
    // right at each device's own edge.
    private static func packetOpacity(_ t: Double) -> Double {
        let fadeWidth = 0.15
        if t < fadeWidth { return t / fadeWidth }
        if t > 1 - fadeWidth { return (1 - t) / fadeWidth }
        return 1
    }

    @ViewBuilder
    private func packetDot(date: Date, phaseOffset: Double, startX: CGFloat, endX: CGFloat) -> some View {
        let t = Self.progress(date, cycleSeconds: Self.packetCycleSeconds, phaseOffset: phaseOffset)
        Circle()
            .fill(rightBadgeColor)
            .frame(width: Self.packetSize, height: Self.packetSize)
            .opacity(Self.packetOpacity(t))
    }

    // Expanding, fading ring centered on the left ("this Mac") device — same "broadcasting outward"
    // language SettingsView's About-tab SignalRing already uses for the app icon's own pulse effect.
    @ViewBuilder
    private func rippleRing(date: Date, phaseOffset: Double) -> some View {
        let t = Self.progress(date, cycleSeconds: Self.rippleCycleSeconds, phaseOffset: phaseOffset)
        Circle()
            .stroke(leftBadgeColor.opacity(0.5 * (1 - t)), lineWidth: 2)
            .frame(width: Self.deviceSize, height: Self.deviceSize)
            .scaleEffect(1 + CGFloat(t) * 1.6)
    }
}
