import SwiftUI
import AppKit

// One-time animated splash shown before FirstRunWizardView's Step 1 (see that file's `.intro`
// Step case) — a fan of 6 "poster" tiles springs out from center, holds, then flies apart past the
// panel's edges before handing off into the real wizard content via the exact same slide mechanism
// Step 1↔2 already use (no second transition system). Skippable at any time, and bypassed entirely
// under Reduce Motion (see FirstRunWizardView's `reduceMotion` guard — this view is never even
// instantiated in that case, not just animated faster).
struct IntroSplashOverlay: View {
    @EnvironmentObject var state: AppState
    var onFinished: () -> Void

    private let tileCount = 6
    // Total lifetime before handing off — covers the last tile's depart start (1050 + 5*60 = 1350ms)
    // plus its own 550ms flight-out duration, plus a little buffer so nothing visibly snaps away.
    private let totalDurationMs = 2100

    @State private var tiles: [SplashTileContent] = FirstRunSplashContent.placeholderSet()
    @State private var titleVisible = false
    @State private var collectTask: Task<Void, Never>?
    @State private var finishTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            // titleBlock is listed FIRST so the tile fan (added next) draws in front of it —
            // ZStack layers later children on top, and the title is meant to read as sitting
            // underneath/behind the fanned tiles during the Hold beat, not overlapping in front
            // of the two center posters.
            titleBlock

            ForEach(0..<tileCount, id: \.self) { i in
                PosterTileView(
                    content: tiles[i],
                    restOffset: Self.restOffset(i),
                    restRotation: Self.restRotation(i),
                    flightDelta: Self.flightDelta(i),
                    flightSpin: Self.flightSpin(i),
                    arriveDelayMs: i * 50,
                    departDelayMs: 1050 + i * 60
                )
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button("Skip") {
                        collectTask?.cancel()
                        finishTask?.cancel()
                        onFinished()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("wizard-skip-intro")
                    .help("Skip the intro animation")
                    .padding(14)
                }
            }
        }
        .transition(.opacity)
        .task {
            withAnimation(.easeOut(duration: 0.35)) { titleVisible = true }
            // Real content collection races the visual sequence, not blocking it — see
            // FirstRunSplashContent.collect's own comment for the bounded-wait cascade.
            collectTask = Task {
                let real = await FirstRunSplashContent.collect(state: state, count: tileCount)
                guard !Task.isCancelled else { return }
                tiles = real
            }
            finishTask = Task {
                try? await Task.sleep(for: .milliseconds(totalDurationMs))
                guard !Task.isCancelled else { return }
                onFinished()
            }
        }
        .onDisappear {
            collectTask?.cancel()
            finishTask?.cancel()
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 6) {
            if let icon = appIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
            }
            Text("Welcome to hdhrVCRplus").font(.title3).bold()
            Text("Let's get your HDHomeRun set up.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .opacity(titleVisible ? 1 : 0)
        .offset(y: titleVisible ? 0 : 8)
    }

    // MARK: - Generative fan layout (6 tiles, evenly spread -14°…+14°, two-row depth stagger)

    private static func restRotation(_ i: Int) -> Double { -14 + Double(i) * (28.0 / 5) }

    private static func restOffset(_ i: Int) -> CGSize {
        CGSize(width: (Double(i) - 2.5) * 92, height: i.isMultiple(of: 2) ? -20 : 24)
    }

    // Radial "fly off the stage" vector from each tile's own rest slot — normalized to a fixed
    // 520pt magnitude so every slot clears the 640×480 intro stage before fading, regardless of
    // how close to center that slot's rest position happens to be.
    private static func flightDelta(_ i: Int) -> CGSize {
        let rest = restOffset(i)
        let dx = rest.width, dy = rest.height - 40
        let mag = (dx * dx + dy * dy).squareRoot()
        guard mag > 0 else { return CGSize(width: 0, height: -520) }
        let k = 520 / mag
        return CGSize(width: dx * k, height: dy * k)
    }

    // Spin direction matches each tile's horizontal fan side, so the departure reads as an
    // extension of the arrival fan rather than a random spin.
    private static func flightSpin(_ i: Int) -> Double {
        restOffset(i).width < 0 ? -35 : 35
    }
}

// MARK: - PosterTileView

// A single flying tile. Two independent keyframeAnimators — Arrive and Depart — stacked on the
// same content, extending StarburstBadge.swift's own documented composition rule (stacked
// scaleEffect multiplies, stacked rotationEffect adds) to offset (adds) and opacity (multiplies):
// PosterTileDepartValues starts at (0,0,0°,scale 1,opacity 1) — neutral, contributing nothing —
// until its own trigger fires, exactly like StarburstBadge's celebration track stays neutral until
// tapped. This lets Arrive settle into its rest pose and Depart layer a second, independent motion
// on top without either animator needing to know about the other's state.
private struct PosterTileView: View {
    let content: SplashTileContent
    let restOffset: CGSize
    let restRotation: Double
    let flightDelta: CGSize
    let flightSpin: Double
    let arriveDelayMs: Int
    let departDelayMs: Int

    @State private var arriveTrigger = 0
    @State private var departTrigger = 0

    var body: some View {
        tileContent
            .frame(width: 78, height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            .keyframeAnimator(initialValue: PosterTileArriveValues(), trigger: arriveTrigger) { view, v in
                view.offset(x: v.x, y: v.y)
                    .rotationEffect(.degrees(v.rotation))
                    .scaleEffect(v.scale)
                    .opacity(v.opacity)
            } keyframes: { _ in
                // response tightened from an initial 0.42/0.5 — at that setting the x/y/rotation
                // springs (heavily damped, no overshoot) were still visibly mid-transit well past
                // the intended ~350ms arrive beat (confirmed via live screenshots showing tiles
                // still clustered near center at that point, despite scale/opacity — both driven
                // by faster tracks — already having finished). Matched closer to scale's own
                // already-snappy 0.3 response so all four properties settle in the same beat.
                KeyframeTrack(\.x) { SpringKeyframe(restOffset.width, spring: Spring(response: 0.3, dampingRatio: 0.68)) }
                KeyframeTrack(\.y) { SpringKeyframe(restOffset.height, spring: Spring(response: 0.3, dampingRatio: 0.68)) }
                KeyframeTrack(\.rotation) { SpringKeyframe(restRotation, spring: Spring(response: 0.32, dampingRatio: 0.68)) }
                KeyframeTrack(\.scale) {
                    LinearKeyframe(CGFloat(1.05), duration: 0.16)
                    SpringKeyframe(CGFloat(1.0), spring: Spring(response: 0.3, dampingRatio: 0.55))
                }
                KeyframeTrack(\.opacity) { LinearKeyframe(1.0, duration: 0.18) }
            }
            .keyframeAnimator(initialValue: PosterTileDepartValues(), trigger: departTrigger) { view, v in
                view.offset(x: v.x, y: v.y)
                    .rotationEffect(.degrees(v.rotation))
                    .scaleEffect(v.scale)
                    .opacity(v.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.x) { CubicKeyframe(flightDelta.width, duration: 0.55) }
                KeyframeTrack(\.y) { CubicKeyframe(flightDelta.height, duration: 0.55) }
                KeyframeTrack(\.rotation) { CubicKeyframe(flightSpin, duration: 0.55) }
                KeyframeTrack(\.scale) { CubicKeyframe(CGFloat(1.18), duration: 0.3) }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1.0, duration: 0.28)
                    LinearKeyframe(0.0, duration: 0.27)
                }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(arriveDelayMs))
                guard !Task.isCancelled else { return }
                arriveTrigger += 1
                try? await Task.sleep(for: .milliseconds(departDelayMs - arriveDelayMs))
                guard !Task.isCancelled else { return }
                departTrigger += 1
            }
    }

    @ViewBuilder private var tileContent: some View {
        switch content {
        case .image(let nsImage):
            Image(nsImage: nsImage).resizable().aspectRatio(contentMode: .fill)
        case .placeholder(let spec):
            ZStack {
                LinearGradient(colors: spec.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: spec.symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

// File-scope per StarburstBadge.swift's own note: @KeyframesBuilder type inference fails on a
// type nested inside the view. Flat stored properties + a nested-AnimatablePair animatableData —
// the same technique StarburstBadge uses for 2 properties, extended here to 5.
private struct PosterTileArriveValues: Animatable {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rotation: Double = 0
    var scale: CGFloat = 0.4
    var opacity: Double = 0

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<Double, AnimatablePair<CGFloat, Double>>> {
        get { AnimatablePair(AnimatablePair(x, y), AnimatablePair(rotation, AnimatablePair(scale, opacity))) }
        set {
            x = newValue.first.first
            y = newValue.first.second
            rotation = newValue.second.first
            scale = newValue.second.second.first
            opacity = newValue.second.second.second
        }
    }
}

// Deltas, not absolute values — starts at (0,0,0°,scale 1×,opacity 1×), i.e. neutral, so stacking
// this on top of the (by-then-settled) Arrive animator contributes nothing until departTrigger fires.
private struct PosterTileDepartValues: Animatable {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rotation: Double = 0
    var scale: CGFloat = 1
    var opacity: Double = 1

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<Double, AnimatablePair<CGFloat, Double>>> {
        get { AnimatablePair(AnimatablePair(x, y), AnimatablePair(rotation, AnimatablePair(scale, opacity))) }
        set {
            x = newValue.first.first
            y = newValue.first.second
            rotation = newValue.second.first
            scale = newValue.second.second.first
            opacity = newValue.second.second.second
        }
    }
}

// MARK: - Tile content sourcing

enum SplashTileContent {
    case image(NSImage)
    case placeholder(PlaceholderSpec)
}

struct PlaceholderSpec {
    let symbol: String
    let colors: [Color]
}

// Namespaced rather than free functions — this is purely splash-tile content sourcing, kept
// separate from IntroSplashOverlay's own layout/choreography math above.
enum FirstRunSplashContent {
    // 6 distinct symbol/gradient pairs, all within the app's existing orange/red/amber accent
    // family (DonationNagView's own header comment argues for this over generic system blue) —
    // varied enough that an all-placeholder run still reads as a designed icon set, not filler.
    private static let placeholders: [PlaceholderSpec] = [
        PlaceholderSpec(symbol: "tv.fill", colors: [.orange, .red]),
        PlaceholderSpec(symbol: "film.fill", colors: [.red, .orange]),
        PlaceholderSpec(symbol: "sparkles", colors: [.orange, .yellow]),
        PlaceholderSpec(symbol: "antenna.radiowaves.left.and.right", colors: [.red.opacity(0.85), .orange.opacity(0.85)]),
        PlaceholderSpec(symbol: "play.tv.fill", colors: [.orange.opacity(0.85), .red.opacity(0.85)]),
        PlaceholderSpec(symbol: "star.fill", colors: [.yellow, .orange]),
    ]

    static func placeholderSet() -> [SplashTileContent] {
        placeholders.map { .placeholder($0) }
    }

    // Decisive hybrid cascade per tile slot: real show poster → channel logo → generated
    // placeholder. Runs off the main sequence's own timing — see IntroSplashOverlay.task, which
    // races this against the visual choreography rather than waiting on it.
    @MainActor
    static func collect(state: AppState, count: Int) async -> [SplashTileContent] {
        func posterURLPool() -> [String] {
            Array(Set(
                state.guideByDevice.values.flatMap { $0 }.flatMap { $0.Guide ?? [] }
                    .compactMap { $0.ImageURL }.filter { !$0.isEmpty }
            ))
        }

        var posterURLs = posterURLPool()
        if posterURLs.count < count {
            // True-first-launch case: guide/EPG data (posters) very likely doesn't exist yet.
            // ensureGuideLoaded(for:) is synchronous/fire-and-forget (see AppState.swift), so this
            // polls for it to land rather than awaiting completion directly — bounded to ~900ms so
            // the splash never visibly stalls waiting on the network.
            let deadline = Date().addingTimeInterval(0.9)
            var kicked = false
            while Date() < deadline, posterURLs.count < count {
                if !kicked, let first = state.devices.first {
                    state.ensureGuideLoaded(for: first.DeviceID)
                    kicked = true
                }
                try? await Task.sleep(for: .milliseconds(100))
                posterURLs = posterURLPool()
            }
        }

        var posterPool = posterURLs.shuffled()
        var logoPool = Array(state.channelImageURLs.values.filter { !$0.isEmpty }).shuffled()

        var slots: [SplashTileContent] = []
        for i in 0..<count {
            if let url = posterPool.popLast(), let img = await ChannelIconCache.shared.image(for: url) {
                slots.append(.image(img))
            } else if let url = logoPool.popLast(), let img = await ChannelIconCache.shared.image(for: url) {
                slots.append(.image(img))
            } else {
                slots.append(.placeholder(placeholders[i % placeholders.count]))
            }
        }
        return slots
    }
}
