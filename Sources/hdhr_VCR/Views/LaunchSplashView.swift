import SwiftUI
import AppKit

// Launch splash: logo, version, a live "finding your tuner /
// loading the lineup / loading the guide" checklist over slowly drifting cached station logos and posters.
// When startup has finished (never sooner than `minimumSeconds`, never later than `capSeconds`) the card
// fades and the logo flies up to the menu-bar icon and pulses there — "I'm loaded, I live up here".
// Not load-bearing: startup runs exactly as before whether or not this window ever appears. See docs/LaunchSplash.md.

/// The splash's pure decisions — gate, timing, and the checklist text — so they are unit-tested.
enum LaunchSplashPlan {
    static let minimumSeconds: TimeInterval = 3.4
    static let capSeconds: TimeInterval = 9.5

    /// Every launch, a brand-new install included (there it hands off to the setup wizard instead of flying to the
    /// menu-bar icon — the wizard and donation cards slide in instead, see `runCards`).
    static func shouldShow(enabled: Bool, underTests: Bool, reduceMotion: Bool) -> Bool {
        enabled && !underTests && !reduceMotion
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
    /// Whether a donation card may follow the splash (the app's launch asks for it; the Settings preview doesn't). It is
    /// shown only if the nag is due then: `Donation_unlocked` still false.
    let offersDonation: Bool
    /// Called once, when the splash is over — the controller destroys the window, this view and everything it holds.
    let onFinish: () -> Void

    // The wall is the one persistent backdrop; on top of it exactly one card at a time slides in: the splash's own
    // (logo, version, checklist), then — when due — the setup wizard (first run), then the donation card. Without a card
    // after the splash, the logo flies to the menu-bar icon (`flying` → `arrived`); after cards, only the ring pulses there.
    private enum Phase { case showing, flying, arrived }
    private enum Card { case splash, wizard, donation, none }
    @State private var phase: Phase = .showing
    @State private var card: Card = .splash
    @State private var closedCards = 0              // bumped by a hosted card's close action; the flow waits on it
    @State private var assembled = false            // tiles have locked into the window: chrome, logo and text fade in
    @State private var started = Date()
    @State private var tilesReady = false   // the wall isn't drawn until posters are loaded — no placeholder flash
    @State private var tiles: [NSImage] = []
    @State private var window: NSWindow?
    @State private var target = CGPoint.zero        // menu-bar icon centre, in this window's top-left coordinates
    @State private var pulse = false
    @State private var frozen = false               // a card is up: the wall stops animating (no idle CPU/GPU)
    @State private var cardsActive = false          // the window takes input; hidden whenever another app is frontmost
    @State private var wallHasPosters = false       // false → placeholder tiles / cached logos; upgraded once the guide supplies posters
    @State private var ended = false

    private let cardSize = CGSize(width: LaunchCard.width, height: LaunchCard.designHeight)

    /// The panel and everything in it is designed at 520×600 and scaled with the display so it takes about 42 % of the screen's
    /// height (and at most 30 % of its width) — a modest card on the wall, the same proportion on any screen. The wall fills
    /// the screen (its tiles scale with it).
    private func displayScale(_ screen: CGSize) -> CGFloat {
        min(1.6, max(0.5, min(0.42 * screen.height / cardSize.height, 0.30 * screen.width / cardSize.width)))
    }
    /// Each card has its own accent: the splash is the logo's orange, setup is a cool teal, the support card a warm rose.
    private var accent: Color {
        switch card {
        case .wizard:   return Color(red: 0.20, green: 0.72, blue: 0.80)
        case .donation: return Color(red: 0.95, green: 0.34, blue: 0.50)
        default:        return .orange
        }
    }
    private let logoTop: CGFloat = 130                 // logo's top edge below the panel's top
    private let logoSize: CGFloat = 108

    /// Cards enter from the right and leave to the left, one panel width, clipped by the panel — so only one is ever visible.
    private var slide: AnyTransition {
        .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity))
    }

    var body: some View {
        GeometryReader { geo in
            let full = geo.size
            let center = CGPoint(x: full.width / 2, y: full.height / 2)
            let scale = displayScale(full)
            ZStack {
                // No window: the posters themselves are the backdrop. They fly in from every direction and settle into a
                // loose wall (centre posters dimmed) with the splash card on a dark panel that sits in it.
                if tilesReady {
                    MosaicTiles(images: tiles, started: started, screen: full, scale: scale, frozen: frozen)
                        .opacity(phase == .showing ? 1 : 0)
                    // Dimmed a little more while the wizard or donation card sits on the wall, so it reads.
                    Color.black.opacity((card == .wizard || card == .donation) && phase == .showing ? 0.4 : 0)
                        .allowsHitTesting(false)
                }

                // The panel stays put; the cards slide *inside* it, clipped to its edges — splash card out to the left,
                // the next in from the right. One panel, one card at a time (docs/LaunchSplash.md).
                ZStack {
                    if card == .splash {
                        splashCard
                            .frame(width: cardSize.width, height: cardSize.height)
                            .transition(slide)
                    }
                    if card == .wizard {
                        FirstRunWizardView()
                            .environment(\.embeddedCardClose, { closedCards += 1 })
                            .frame(width: cardSize.width, height: cardSize.height)
                            .transition(slide)
                    }
                    if card == .donation {
                        DonationNagView()
                            .environment(\.embeddedCardClose, { closedCards += 1 })
                            .frame(width: cardSize.width, height: cardSize.height)
                            .transition(slide)
                    }
                }
                .frame(width: cardSize.width, height: cardSize.height)
                .blendedLaunchPanel(accent: accent)
                .animation(.easeInOut(duration: 0.55), value: card)
                // The ending: the last panel glides up to the menu-bar icon, shrinking to icon size, while the wall fades away.
                .scaleEffect(phase == .showing ? scale : 24 / cardSize.width)
                .opacity(assembled && phase != .arrived ? 1 : 0)
                .position(phase == .showing ? center : target)

                if phase == .arrived {
                    Circle().stroke(Color.accentColor, lineWidth: 3)
                        .frame(width: 26, height: 26)
                        .scaleEffect(pulse ? 3.2 : 0.8).opacity(pulse ? 0 : 0.9)
                        .position(target)
                }
            }
            .frame(width: full.width, height: full.height)
            .task { await run(in: full) }
        }
        .background(WindowAction(trigger: true) { w in
            window = w
            Self.configure(w)
        })
        .onAppear { if let w = window { Self.configure(w) } }
        // While a card is up the window takes input and must not cover another app you switch to.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if cardsActive { window?.alphaValue = 0; window?.ignoresMouseEvents = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            window?.alphaValue = 1
            window?.ignoresMouseEvents = !cardsActive
        }
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

    /// The splash card's content (logo, title, version, checklist), laid out for the panel's own coordinates.
    private var splashCard: some View {
        ZStack(alignment: .top) {
            chrome
            logo
                .frame(width: logoSize, height: logoSize)
                .position(x: cardSize.width / 2, y: logoTop + logoSize / 2)
        }
    }

    private var chrome: some View {
        VStack(spacing: 6) {
            Color.clear.frame(height: logoTop + logoSize + 6)   // the logo is drawn above, flying out of this spot
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
            .padding(.bottom, 70)
        }
        .foregroundStyle(.white)
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

    /// Borderless, clear, click-through (until a card needs input — see `runCards`), covering the menu-bar screen — a
    /// full-screen canvas the tiles and logo can fly across — and above the menu bar itself so the logo can land on the icon.
    fileprivate static func configure(_ w: NSWindow) {
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
    @MainActor private func loadPosters() async -> (images: [NSImage], real: Bool) {
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
        let posters = await fetchImages(urls)
        if !posters.isEmpty { return (posters, true) }
        return (await ChannelIconCache.shared.sampleCachedImages(limit: want), false)
    }

    /// A poster scaled once, off the main thread, to about twice the size a tile is drawn at — the cache holds full-size art,
    /// and rescaling that every frame for 84 tiles is what made the fly-in drop frames.
    nonisolated private static func shrunk(_ image: NSImage) async -> NSImage {
        final class Box: @unchecked Sendable { let image: NSImage; init(_ i: NSImage) { image = i } }
        let box = Box(image)
        return await Task.detached(priority: .userInitiated) { () -> Box in
            let src = box.image
            let target = CGSize(width: 200, height: 240)                        // ≈ 2× a tile on a 1440×900 screen
            guard src.size.width > target.width * 1.5, src.size.height > target.height * 1.5,
                  let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return box }
            let k = max(target.width / CGFloat(cg.width), target.height / CGFloat(cg.height))
            let w = max(1, Int(CGFloat(cg.width) * k)), h = max(1, Int(CGFloat(cg.height) * k))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return box }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let out = ctx.makeImage() else { return box }
            return Box(NSImage(cgImage: out, size: NSSize(width: w, height: h)))
        }.value.image
    }

    /// Downloads/loads the given poster URLs through the shared icon cache, capped at ~1.5 s overall — whatever has arrived
    /// by then is returned.
    @MainActor private func fetchImages(_ urls: [String]) async -> [NSImage] {
        final class Box: @unchecked Sendable { var images: [Int: NSImage] = [:]; var done = 0 }
        let box = Box()
        for (i, u) in urls.enumerated() {
            Task { @MainActor in
                if let img = await ChannelIconCache.shared.image(for: u) { box.images[i] = await Self.shrunk(img) }
                box.done += 1
            }
        }
        var ticks = 0
        while box.done < urls.count, ticks < 15 { try? await Task.sleep(for: .milliseconds(100)); ticks += 1 }
        return box.images.sorted { $0.key < $1.key }.map(\.value)
    }

    /// A brand-new install has no saved poster list and usually no guide yet when the wall is built, so the wall starts as
    /// placeholder tiles. Once the guide supplies on-air art, swap the real posters in (a slow cross-fade) — the wall is the
    /// backdrop for the setup wizard, so it should end up as show images. Gives up after ~60 s.
    @MainActor private func upgradeToRealPosters() async {
        let want = MosaicTiles.slotCount
        for _ in 0..<120 {
            try? await Task.sleep(for: .milliseconds(500))
            if ended || Task.isCancelled { return }
            let urls = posterURLs()
            guard urls.count >= 8 else { continue }
            let images = await fetchImages(Array(urls.shuffled().prefix(want)))
            guard images.count >= 4, !ended else { continue }
            glog("[Splash] wall upgraded from placeholders to \(images.count) show posters")
            withAnimation(.easeInOut(duration: 0.9)) { tiles = images; wallHasPosters = true }
            UserDefaults.standard.set(Array(urls.prefix(60)), forKey: Self.savedPostersKey)
            return
        }
    }

    /// The splash is over: hand the window back to `LaunchSplashController`, which orders it out and releases it — the
    /// window, this view, its `@State` and the poster images are all freed (nothing stays alive, hidden or animating).
    /// Before 2026-10-15 the splash was a SwiftUI `Window` scene, which `dismiss()` only orders out: its view graph lived on
    /// and the `TimelineView` kept rendering the invisible wall at display rate (~21 % idle CPU, a ~0.6 s main-thread stall
    /// every 10 s). First run: this is only called after the setup wizard is dismissed, so the wall stays as its backdrop.
    @MainActor private func finish() {
        frozen = true
        tilesReady = false
        onFinish()
    }

    @MainActor private func run(in size: CGSize) async {
        defer { ended = true }
        // A re-opened Window scene can keep this view's @State from the previous run (phase stuck at .arrived =
        // invisible), so every run starts from a clean slate — this is what makes "Preview Launch Splash" replayable.
        var reset = Transaction(); reset.disablesAnimations = true
        withTransaction(reset) { phase = .showing; assembled = false; pulse = false; frozen = false; cardsActive = false; card = .splash; closedCards = 0; wallHasPosters = false; ended = false; tiles = []; tilesReady = false }
        let loaded = await loadPosters()
        tiles = loaded.images
        wallHasPosters = loaded.real
        if !loaded.real, state.launchSplashHandsOffToWizard {
            Task { @MainActor in await upgradeToRealPosters() }
        }
        started = Date()                                                       // tiles start flying now
        tilesReady = true
        try? await Task.sleep(for: .milliseconds(Int((MosaicTiles.assembleSeconds + 0.1) * 1000)))
        withAnimation(.easeOut(duration: 0.6)) { assembled = true }
        LaunchSplashController.shared.markFlyInDone()                          // the rest of the app's launch may proceed
        while !LaunchSplashPlan.shouldFinish(elapsed: Date().timeIntervalSince(started), startupDone: !state.isStartingUp) {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
        }
        let fresh = posterURLs()
        if !fresh.isEmpty { UserDefaults.standard.set(Array(fresh.prefix(60)), forKey: Self.savedPostersKey) }
        // Cards after the splash: the setup wizard on a brand-new install, then the donation card if the nag is due. One at a
        // time, each sliding over the previous; the wall stays as the backdrop throughout.
        let wizardDue = state.launchSplashHandsOffToWizard
        if wizardDue || (offersDonation && (demoFirstRunRequested || !state.config.Donation_unlocked)) {
            await runCards(wizardDue: wizardDue, in: size)
            return
        }
        await flyPanelToMenuBar(in: size)
    }
}

extension LaunchSplashView {
    /// Shows the wizard (when due) and then the donation card (when due) as cards in this window, each sliding in over
    /// the one before, with the wall as the backdrop. Ends like a normal launch, minus the logo (it left with the splash
    /// card): the wall fades and a ring pulses at the menu-bar icon — "set up, and living up here".
    @MainActor fileprivate func runCards(wizardDue: Bool, in size: CGSize) async {
        state.launchSplashHandsOffToWizard = false     // decided — the app's fallback timer (openLaunchSplashIfNeeded) stands down
        cardsActive = true
        frozen = true                                   // the wall stops animating while a card is open
        LaunchSplashController.shared.settled = true
        if let w = window {                             // the cards take input: key window, above other apps' windows
            w.ignoresMouseEvents = false
            w.level = .modalPanel
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        }
        if wizardDue {
            withAnimation(.easeInOut(duration: 0.55)) { card = .wizard }
            guard await waitForCardClose() else { return }
        }
        if offersDonation, demoFirstRunRequested || !state.config.Donation_unlocked {
            withAnimation(.easeInOut(duration: 0.55)) { card = .donation }
            guard await waitForCardClose() else { return }
        }
        await flyPanelToMenuBar(in: size)
    }

    /// The ending, with or without cards: the last panel (whatever card is in it) glides up to the menu-bar icon, shrinking to
    /// the icon's size, while the wall fades away behind it; then a ring pulses on the icon — "I live up here, that's next".
    @MainActor fileprivate func flyPanelToMenuBar(in size: CGSize) async {
        cardsActive = false
        if let w = window {
            w.ignoresMouseEvents = true
            w.level = .popUpMenu                        // above the menu bar, so the panel can land on the icon
            w.alphaValue = 1
        }
        let item = LaunchSplashPlan.statusItemFrame().frame
        let origin = window?.frame.origin ?? .zero
        let height = window?.frame.height ?? size.height
        target = CGPoint(x: item.midX - origin.x, y: height - (item.midY - origin.y))
        withAnimation(.easeInOut(duration: 0.95)) { phase = .flying }
        try? await Task.sleep(for: .milliseconds(1000))
        phase = .arrived
        withAnimation(.easeOut(duration: 0.7)) { pulse = true }
        try? await Task.sleep(for: .milliseconds(750))
        finish()
    }

    /// Waits until the card on screen closes itself (Finish, Escape, Not now, a valid code). False if the splash was
    /// cancelled meanwhile.
    @MainActor private func waitForCardClose() async -> Bool {
        let before = closedCards
        while closedCards == before {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return false }
        }
        return true
    }
}

/// Cached logos/posters flying in from random points just off the screen's edges and locking into a 12×7 grid (`designWall`, scaled with the launch panel).
/// Position is a pure function of time since `started`, so it always animates (no state to fall behind),
/// and once seated each tile keeps a faint bob so the wall stays alive. Fewer images than slots → they repeat;
/// none cached → the app's placeholder mark fills the wall.
private struct MosaicTiles: View {
    static let cols = 12, rows = 7
    /// The wall is designed at 1100×760 around the 520×600 launch panel (`LaunchCard`) and scaled by the same factor as the
    /// panel, so the two always keep their proportions to each other and to the display.
    static let designWall = CGSize(width: 1100, height: 760)
    static var slotCount: Int { cols * rows }
    static let assembleSeconds: Double = 1.6
    private static let flightSeconds: Double = 0.9

    let images: [NSImage]
    let started: Date
    let screen: CGSize
    let scale: CGFloat                               // the display scale shared with the launch panel
    /// True once the wall is seated and only serving as a backdrop: the timeline stops, so it costs nothing while idle.
    var frozen: Bool = false

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
        let wall = CGSize(width: Self.designWall.width * scale, height: Self.designWall.height * scale)
        let slotW = wall.width / CGFloat(Self.cols), slotH = wall.height / CGFloat(Self.rows)
        let origin = CGPoint(x: (screen.width - wall.width) / 2, y: (screen.height - wall.height) / 2)
        TimelineView(.animation(paused: frozen)) { ctx in
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
    }
}

/// A borderless window can't become key by default; the wizard's text fields and the donation code field need it to.
private final class SplashWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns the launch splash's window. The splash is not a SwiftUI `Window` scene: a scene's window is only ever ordered out,
/// never destroyed, so a finished splash would sit in memory (and keep animating) for the life of the app. Here the window
/// is created when the splash plays and destroyed when it ends — `release()` drops the hosting view, which frees the
/// SwiftUI graph, its `@State` and the poster images. A replay (Settings → Maintenance → Preview Launch Splash) builds a
/// fresh one. Never stacks: playing while one is already up just brings it forward.
@MainActor
final class LaunchSplashController {
    static let shared = LaunchSplashController()
    private var window: NSWindow?
    var isPlaying: Bool { window != nil }
    /// True once the splash's busy animation is over (a card is up and the wall is frozen) or the splash is gone — the point
    /// after which heavy MainActor work (the web guide's page rebuild) no longer costs visible frames.
    var settled = true
    /// Launch work that can wait (disk sweeps, update check, tuner discovery, the guide's JSON calls) holds until the splash has
    /// finished assembling. False only between `expectSplash()` (the app's init, when a splash is going to play) and then.
    private(set) var flyInDone = true
    func expectSplash() { flyInDone = false }
    func markFlyInDone() { flyInDone = true }
    func waitForFlyIn(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !flyInDone, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// Heavy launch work calls this first so it doesn't land in the middle of the poster fly-in. Returns at once when no splash
    /// is playing; never waits longer than `timeout`.
    func waitUntilSettled(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while isPlaying, !settled, Date() < deadline { try? await Task.sleep(for: .milliseconds(200)) }
    }

    /// `offersDonation`: the app's launch passes true (the donation card follows if the nag is due); the preview, false.
    func play(state: AppState, offersDonation: Bool) {
        if let window { window.orderFrontRegardless(); return }
        settled = false
        let screen = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = SplashWindow(contentRect: screen, styleMask: [.borderless], backing: .buffered, defer: false)
        w.title = "hdhrVCRplus"
        w.isReleasedWhenClosed = false
        LaunchSplashView.configure(w)
        let root = LaunchSplashView(offersDonation: offersDonation, onFinish: { [weak self] in self?.release() })
            .environmentObject(state)
        w.contentView = NSHostingView(rootView: root)
        window = w
        w.orderFrontRegardless()
    }

    func release() {
        guard let w = window else { return }
        window = nil
        settled = true
        flyInDone = true
        w.orderOut(nil)
        w.contentView = nil
    }
}
