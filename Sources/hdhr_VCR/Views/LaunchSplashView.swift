import SwiftUI
import AppKit

// Launch splash for returning users (first-run already done): logo, version, a live "finding your tuner /
// loading the lineup / loading the guide" checklist over slowly drifting cached station logos and posters.
// When startup has finished (never sooner than `minimumSeconds`, never later than `capSeconds`) the card
// fades and the logo flies up to the menu-bar icon and pulses there — "I'm loaded, I live up here".
// Not load-bearing: startup runs exactly as before whether or not this window ever appears. See docs/LaunchSplash.md.

/// The splash's pure decisions — gate, timing, and the checklist text — so they are unit-tested.
enum LaunchSplashPlan {
    static let minimumSeconds: TimeInterval = 3.4
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
    @State private var assembled = false            // tiles have locked into the window: chrome, logo and text fade in
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
                // No window: the posters themselves are the backdrop. They fly in from every direction and settle into a
                // loose wall (centre posters dimmed) with the text floating over a soft, edgeless glow.
                MosaicTiles(images: tiles, started: started, screen: geo.size)
                    .opacity(phase == .showing ? 1 : 0)

                RadialGradient(colors: [.black.opacity(0.62), .black.opacity(0)], center: .center,
                               startRadius: 40, endRadius: 270)
                    .frame(width: 600, height: 600)
                    .opacity(phase == .showing && assembled ? 1 : 0)
                    .position(center)
                    .allowsHitTesting(false)

                chrome.frame(width: cardSize.width, height: cardSize.height)
                    .opacity(phase == .showing && assembled ? 1 : 0)
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
                    .opacity(phase == .arrived ? 0 : (assembled ? 1 : 0))
                    .position(phase == .showing ? logoHome : target)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .task { await run(in: geo.size) }
        }
        .background(WindowAction(trigger: true) { w in
            window = w
            Self.configure(w)
        })
        .onAppear { if let w = window { Self.configure(w) } }
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

    /// The text over the finished wall — no panel, just a shadow to keep it legible over the posters.
    private var chrome: some View {
        VStack(spacing: 6) {
            Color.clear.frame(height: 40 + logoSize + 6)   // the logo is drawn above, flying out of this spot
            Text("hdhrVCRplus").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Version \(versionText)").font(.callout).foregroundStyle(.white.opacity(0.8))
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(stages) { s in
                    HStack(spacing: 8) {
                        Image(systemName: s.done ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(s.done ? Color.green : Color.white.opacity(0.7))
                        Text(s.label).font(.callout)
                    }
                }
            }
            .padding(.bottom, 26)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.9), radius: 6, y: 1)
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

    /// Borderless, clear, click-through, covering the menu-bar screen — a full-screen canvas the tiles and logo can fly
    /// across — and above the menu bar itself so the logo can land on the icon.
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

    private static let savedPostersKey = "launchSplashPosterURLs"

    /// Poster art of what's on air now across our tuners (the guide restored from disk is usually ready within a moment).
    @MainActor private func posterURLs() -> [String] {
        var seen = Set<String>(), out: [String] = []
        for d in state.recordableDevices {
            for (_, entry) in state.onAirNow(for: d) {
                if let u = entry.ImageURL, !u.isEmpty, seen.insert(u).inserted { out.append(u) }
            }
        }
        return out
    }

    /// The show posters for the wall. Last launch's list is on hand instantly (and the images are on disk), so the
    /// splash never waits for the guide; fresh on-air posters are added if the guide is up within ~1 s. Fetches are
    /// capped at ~1.5 s overall — whatever has arrived by then is used. No posters at all → cached station logos.
    @MainActor private func loadPosters() async -> [NSImage] {
        let want = MosaicTiles.slotCount
        let saved = UserDefaults.standard.stringArray(forKey: Self.savedPostersKey) ?? []
        var fresh = posterURLs()
        var waited = 0
        while fresh.count < want, saved.count < want, waited < 10, state.isStartingUp {   // brand-new install of this feature
            try? await Task.sleep(for: .milliseconds(100)); waited += 1
            fresh = posterURLs()
        }
        var urls = Array((fresh.shuffled() + saved.shuffled()).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(want))
        urls.shuffle()
        final class Box: @unchecked Sendable { var images: [Int: NSImage] = [:]; var done = 0 }
        let box = Box()
        for (i, u) in urls.enumerated() {
            Task { @MainActor in
                if let img = await ChannelIconCache.shared.image(for: u) { box.images[i] = img }
                box.done += 1
            }
        }
        var ticks = 0
        while box.done < urls.count, ticks < 15 { try? await Task.sleep(for: .milliseconds(100)); ticks += 1 }
        let posters = box.images.sorted { $0.key < $1.key }.map(\.value)
        if !posters.isEmpty { return posters }
        return await ChannelIconCache.shared.sampleCachedImages(limit: want)
    }

    @MainActor private func run(in size: CGSize) async {
        // A re-opened Window scene can keep this view's @State from the previous run (phase stuck at .arrived =
        // invisible), so every run starts from a clean slate — this is what makes "Preview Launch Splash" replayable.
        var reset = Transaction(); reset.disablesAnimations = true
        withTransaction(reset) { phase = .showing; assembled = false; pulse = false; tiles = [] }
        tiles = await loadPosters()
        started = Date()                                                       // tiles start flying now
        try? await Task.sleep(for: .milliseconds(Int((MosaicTiles.assembleSeconds + 0.1) * 1000)))
        withAnimation(.easeOut(duration: 0.6)) { assembled = true }
        while !LaunchSplashPlan.shouldFinish(elapsed: Date().timeIntervalSince(started), startupDone: !state.isStartingUp) {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
        }
        let fresh = posterURLs()
        if !fresh.isEmpty { UserDefaults.standard.set(Array(fresh.prefix(60)), forKey: Self.savedPostersKey) }
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

/// Cached logos/posters flying in from random points just off the screen's edges and locking into a 7×4 grid the size
/// of the card. Position is a pure function of time since `started`, so it always animates (no state to fall behind),
/// and once seated each tile keeps a faint bob so the wall stays alive. Fewer images than slots → they repeat;
/// none cached → the app's placeholder mark fills the wall.
private struct MosaicTiles: View {
    static let cols = 10, rows = 5
    static let wall = CGSize(width: 860, height: 520)
    static var slotCount: Int { cols * rows }
    static let assembleSeconds: Double = 1.6
    private static let flightSeconds: Double = 0.9

    let images: [NSImage]
    let started: Date
    let screen: CGSize

    /// Deterministic 0…1 jitter per tile and salt — stable across frames without storing state.
    private static func rnd(_ i: Int, _ salt: Int) -> Double {
        let x = sin(Double(i * 127 + salt * 311) * 12.9898) * 43758.5453
        return x - x.rounded(.down)
    }

    /// Anywhere on a ring just outside the screen — every angle, not just four sides.
    private func start(_ i: Int) -> CGPoint {
        let angle = Self.rnd(i, 1) * 2 * .pi
        let r = hypot(screen.width, screen.height) / 2 + 120 + 160 * Self.rnd(i, 2)
        return CGPoint(x: screen.width / 2 + CGFloat(cos(angle)) * r, y: screen.height / 2 + CGFloat(sin(angle)) * r)
    }

    var body: some View {
        let wall = Self.wall
        let slotW = wall.width / CGFloat(Self.cols), slotH = wall.height / CGFloat(Self.rows)
        let origin = CGPoint(x: (screen.width - wall.width) / 2, y: (screen.height - wall.height) / 2)
        TimelineView(.animation) { ctx in
            let elapsed = ctx.date.timeIntervalSince(started)
            ZStack {
                ForEach(0..<Self.slotCount, id: \.self) { i in
                    let delay = (Self.assembleSeconds - Self.flightSeconds) * Self.rnd(i, 3)
                    let raw = min(1, max(0, (elapsed - delay) / Self.flightSeconds))
                    let e = 1 - pow(1 - raw, 3)                                        // ease-out: fast in, gentle landing
                    let jx = (Self.rnd(i, 5) - 0.5) * 10, jy = (Self.rnd(i, 6) - 0.5) * 10
                    let seat = CGPoint(x: origin.x + (CGFloat(i % Self.cols) + 0.5) * slotW + CGFloat(jx),
                                       y: origin.y + (CGFloat(i / Self.cols) + 0.5) * slotH + CGFloat(jy))
                    let from = start(i)
                    let bob = raw >= 1 ? CGFloat(sin(elapsed * 1.3 + Double(i))) * 1.5 : 0
                    // Posters near the middle sit back so the text reads; the rim stays bright.
                    let dx = (seat.x - screen.width / 2) / (wall.width / 2), dy = (seat.y - screen.height / 2) / (wall.height / 2)
                    let dim = 0.45 + 0.55 * min(1, Double(hypot(dx, dy)))
                    tile(i, size: CGSize(width: slotW * 1.12, height: slotH * 1.12))
                        .rotationEffect(.degrees((1 - e) * (Self.rnd(i, 4) - 0.5) * 700 + (Self.rnd(i, 7) - 0.5) * 10 * e))
                        .scaleEffect(0.55 + 0.45 * e)
                        .opacity(raw > 0 ? dim : 0)
                        .position(x: from.x + (seat.x - from.x) * e, y: from.y + (seat.y - from.y) * e + bob)
                }
            }
        }
    }

    @ViewBuilder private func tile(_ i: Int, size: CGSize) -> some View {
        let img: NSImage? = images.isEmpty ? nil : images[i % images.count]
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(white: 0.16))
            // Posters fill their slot edge to edge; the placeholder mark (no art cached) sits inset.
            if let img {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: stationLogoPlaceholder).resizable().aspectRatio(contentMode: .fit).padding(14)
            }
        }
        .frame(width: size.width - 3, height: size.height - 3)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }
}
