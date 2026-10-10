import SwiftUI
import AppKit

// Launch splash for returning users (first-run already done): logo, version, a live "finding your tuner /
// loading the lineup / loading the guide" checklist over slowly drifting cached station logos and posters.
// When startup has finished (never sooner than `minimumSeconds`, never later than `capSeconds`) the card
// fades and the logo flies up to the menu-bar icon and pulses there — "I'm loaded, I live up here".
// Not load-bearing: startup runs exactly as before whether or not this window ever appears. See docs/LaunchSplash.md.

/// The splash's pure decisions — gate, timing, and the checklist text — so they are unit-tested.
enum LaunchSplashPlan {
    static let minimumSeconds: TimeInterval = 2.6
    static let capSeconds: TimeInterval = 7.0

    static func shouldShow(firstRunDone: Bool, enabled: Bool, underTests: Bool, reduceMotion: Bool) -> Bool {
        firstRunDone && enabled && !underTests && !reduceMotion
    }

    /// Long enough to read, short enough not to nag: wait for startup, but never under the minimum or past the cap.
    static func shouldFinish(elapsed: TimeInterval, startupDone: Bool) -> Bool {
        elapsed >= capSeconds || (elapsed >= minimumSeconds && startupDone)
    }

    struct Stage: Equatable, Identifiable {
        var id: String { label }
        let label: String
        let done: Bool
    }

    /// Tuner → lineup → guide, each flipping to a check mark as `AppState` publishes it.
    static func stages(tunerName: String?, tunerCount: Int, channelCount: Int, guideLoaded: Bool,
                       startupDone: Bool) -> [Stage] {
        let tuner: Stage
        if let tunerName {
            tuner = Stage(label: "\(tunerName) · \(tunerCount) tuner\(tunerCount == 1 ? "" : "s")", done: true)
        } else {
            tuner = Stage(label: startupDone ? "No tuner found" : "Looking for your tuner…", done: false)
        }
        let lineup = channelCount > 0
            ? Stage(label: "\(channelCount) channels", done: true)
            : Stage(label: "Loading the channel lineup…", done: false)
        let guide = guideLoaded
            ? Stage(label: "Guide ready", done: true)
            : Stage(label: "Loading the guide…", done: false)
        return [tuner, lineup, guide]
    }

    /// Where the menu-bar icon is, in screen coordinates (y up). Our own status item's window is found by class
    /// name (private AppKit type, so a loose match); falls back to the top-right of the menu-bar screen.
    @MainActor static func statusItemFrame() -> (frame: NSRect, found: Bool) {
        if let w = NSApp.windows.first(where: {
            String(describing: type(of: $0)).contains("StatusBar") && $0.isVisible && $0.frame.height < 60 && $0.frame.width > 4
        }) { return (w.frame, true) }
        let s = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return (NSRect(x: s.maxX - 180, y: s.maxY - 24, width: 24, height: 24), false)
    }
}

struct LaunchSplashView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case showing, flying, arrived }
    @State private var phase: Phase = .showing
    @State private var started = Date()
    @State private var tiles: [NSImage] = []
    @State private var window: NSWindow?
    @State private var target = CGPoint.zero        // menu-bar icon centre, in this window's top-left coordinates
    @State private var pulse = false

    private let cardSize = CGSize(width: 520, height: 340)
    private let logoSize: CGFloat = 108

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let logoHome = CGPoint(x: center.x, y: center.y - cardSize.height / 2 + 40 + logoSize / 2)
            ZStack {
                card.frame(width: cardSize.width, height: cardSize.height)
                    .opacity(phase == .showing ? 1 : 0)
                    .position(center)

                if phase == .arrived {
                    Circle().stroke(Color.accentColor, lineWidth: 3)
                        .frame(width: 26, height: 26)
                        .scaleEffect(pulse ? 3.2 : 0.8).opacity(pulse ? 0 : 0.9)
                        .position(target)
                }

                logo
                    .frame(width: logoSize, height: logoSize)
                    .scaleEffect(phase == .showing ? 1 : 20 / logoSize)
                    .opacity(phase == .arrived ? 0 : 1)
                    .position(phase == .showing ? logoHome : target)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .task { await run(in: geo.size) }
        }
        .background(WindowAction(trigger: true) { w in
            window = w
            Self.configure(w)
        })
    }

    private var logo: some View {
        Group {
            if let icon = appIconImage {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).cornerRadius(22)
            } else {
                Image(systemName: "tv").resizable().aspectRatio(contentMode: .fit).foregroundStyle(.secondary)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .accessibilityHidden(true)
    }

    private var card: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.thickMaterial)
            DriftingTiles(images: tiles)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(colors: [.black.opacity(0.10), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
            VStack(spacing: 6) {
                Color.clear.frame(height: 40 + logoSize + 6)   // the logo is drawn above, flying out of this spot
                Text("hdhrVCRplus").font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Version \(versionText)").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(stages) { s in
                        HStack(spacing: 8) {
                            Image(systemName: s.done ? "checkmark.circle.fill" : "circle.dotted")
                                .foregroundStyle(s.done ? Color.green : Color.secondary)
                            Text(s.label).font(.callout)
                        }
                    }
                }
                .padding(.bottom, 26)
            }
            RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("hdhrVCRplus \(versionText) is starting")
    }

    private var versionText: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? appVersion
    }

    private var stages: [LaunchSplashPlan.Stage] {
        let real = state.recordableDevices
        let tuners = real.reduce(0) { $0 + ($1.TunerCount ?? 1) }
        let channels = real.reduce(0) { $0 + (state.lineups[$1.DeviceID]?.count ?? 0) }
        return LaunchSplashPlan.stages(
            tunerName: real.first.map { $0.FriendlyName ?? $0.DeviceID }, tunerCount: tuners,
            channelCount: channels, guideLoaded: state.guideByDevice.values.contains { !$0.isEmpty },
            startupDone: !state.isStartingUp)
    }

    /// Borderless, clear, click-through, covering the menu-bar screen — a full-screen canvas the logo can fly across —
    /// and above the menu bar itself so it can land on the icon.
    private static func configure(_ w: NSWindow) {
        w.styleMask = [.borderless, .fullSizeContentView]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .popUpMenu
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if let s = NSScreen.screens.first { w.setFrame(s.frame, display: true) }
    }

    @MainActor private func run(in size: CGSize) async {
        started = Date()
        tiles = await ChannelIconCache.shared.sampleCachedImages(limit: 16)
        while !LaunchSplashPlan.shouldFinish(elapsed: Date().timeIntervalSince(started), startupDone: !state.isStartingUp) {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
        }
        // Where to land, in the window's own top-left coordinates.
        let item = LaunchSplashPlan.statusItemFrame().frame
        let origin = window?.frame.origin ?? .zero
        let height = window?.frame.height ?? size.height
        target = CGPoint(x: item.midX - origin.x, y: height - (item.midY - origin.y))
        withAnimation(.easeInOut(duration: 0.85)) { phase = .flying }
        try? await Task.sleep(for: .milliseconds(900))
        phase = .arrived
        withAnimation(.easeOut(duration: 0.7)) { pulse = true }
        try? await Task.sleep(for: .milliseconds(750))
        dismiss()
    }
}

/// Cached logos/posters drifting slowly behind the card. Falls back to nothing when the cache is empty.
private struct DriftingTiles: View {
    let images: [NSImage]

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                        let fi = Double(i)
                        let w = 54 + CGFloat((i * 37) % 30)
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: w, height: w * 1.25)
                            .cornerRadius(6)
                            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                            .opacity(0.5)
                            .rotationEffect(.degrees(sin(t * 0.3 + fi) * 8))
                            .position(x: geo.size.width * (0.08 + 0.84 * ((fi * 0.382).truncatingRemainder(dividingBy: 1)))
                                        + CGFloat(sin(t * 0.25 + fi * 1.7)) * 18,
                                      y: geo.size.height * (0.1 + 0.8 * ((fi * 0.7548).truncatingRemainder(dividingBy: 1)))
                                        + CGFloat(cos(t * 0.2 + fi * 2.3)) * 16)
                    }
                }
            }
        }
    }
}
