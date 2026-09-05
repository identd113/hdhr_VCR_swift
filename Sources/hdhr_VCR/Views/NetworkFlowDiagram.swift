import SwiftUI

// Animated "how it works" map for a point-to-point LAN-facing feature — two devices connected by a
// line, with signal rings broadcasting from the left (this Mac) device and small packets flowing
// along the line to the right one. Purely illustrative (no real network activity of its own).
// Parametrized (icons/badge colors/captions) so it's reusable wherever the app wants this exact
// "this Mac ↔ one specific other party" shape, rather than hardcoded to any one feature — currently
// only Recording FEED (FirstRunWizardView's Recording FEED step), whose "this Mac's recording,
// that Mac watching it" relationship is genuinely one-to-one.
//
// Sibling diagrams for the app's other Sharing features deliberately do NOT reuse this component:
// added 2026-09-04 after live feedback that Web LAN's earlier version — a straight palette-swap of
// this same one-to-one shape — read as visually redundant stacked next to a similar diagram on the
// same wizard screen. Web LAN (`WebLANDiagram.swift`) is a genuinely different relationship — one
// Mac serving many different kinds of devices, not one specific pair — so it fans out to three
// device icons instead. Terminal Guide (`TerminalTypingDiagram.swift`) isn't a broadcast
// relationship at all — it's a CLI session — so it abandons the two-device shape entirely for a
// mock terminal window with a typing command.
//
// Visual convention shared across every use of THIS component: the left side (always "this Mac")
// gets a badge color naming the specific local action happening (e.g. red = recording); the right
// side stays watchNowBlue by default — "whoever's receiving it" reads as one consistent identity.
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
    private static let frameInterval: Double = 1.0 / 30.0

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
                        // Matched to the actual visual cadence (smooth-looking continuous motion
                        // tops out well below display refresh rate) rather than firing on every
                        // frame via .animation, which redraws 2-4x more often than needed for a
                        // purely decorative diagram.
                        TimelineView(.periodic(from: .now, by: Self.frameInterval)) { timeline in
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

    private static func packetX(_ date: Date, phaseOffset: Double, startX: CGFloat, endX: CGFloat) -> CGFloat {
        let t = DiagramAnimation.progress(date, cycleSeconds: packetCycleSeconds, phaseOffset: phaseOffset)
        return startX + (endX - startX) * CGFloat(t)
    }

    @ViewBuilder
    private func packetDot(date: Date, phaseOffset: Double, startX: CGFloat, endX: CGFloat) -> some View {
        let t = DiagramAnimation.progress(date, cycleSeconds: Self.packetCycleSeconds, phaseOffset: phaseOffset)
        Circle()
            .fill(rightBadgeColor)
            .frame(width: Self.packetSize, height: Self.packetSize)
            .opacity(DiagramAnimation.edgeFadeOpacity(t))
    }

    // Expanding, fading ring centered on the left ("this Mac") device — same "broadcasting outward"
    // language SettingsView's About-tab SignalRing already uses for the app icon's own pulse effect.
    @ViewBuilder
    private func rippleRing(date: Date, phaseOffset: Double) -> some View {
        let t = DiagramAnimation.progress(date, cycleSeconds: Self.rippleCycleSeconds, phaseOffset: phaseOffset)
        Circle()
            .stroke(leftBadgeColor.opacity(0.5 * (1 - t)), lineWidth: 2)
            .frame(width: Self.deviceSize, height: Self.deviceSize)
            .scaleEffect(1 + CGFloat(t) * 1.6)
    }
}
