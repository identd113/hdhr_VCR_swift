import SwiftUI
import AppKit

// Every duration/stagger value below (both structs in this file) is multiplied by this one
// constant rather than hand-picking new absolute numbers — preserves the exact original
// choreography's proportions (arrive/hold/depart ratios, per-tile stagger spacing) while making
// the whole thing read as a slower or faster effect throughout, instead of just some beats. Went
// 1.0 → 1.7 → 3.5 (too slow, ~8.75s — live feedback was "waaay too fast" at 1.7, then the
// opposite complaint at 3.5) → 2.0, which lands totalDurationMs (below) at ~5s — a quick,
// skippable showcase beat rather than something that overstays its welcome.
// Not private — FirstRunIntroSplashTimingTests references it directly so its regression tests
// don't hardcode a second copy of this literal that could silently drift from the real one.
let introSplashSpeedScale: Double = 2.0

// One-time animated splash shown before FirstRunWizardView's Step 1 (see that file's `.intro`
// Step case) — a fan of 6 "poster" tiles springs out from center, holds, then flies apart past the
// panel's edges before handing off into the real wizard content via the exact same slide mechanism
// Step 1↔2 already use (no second transition system). Skippable at any time, and bypassed entirely
// under Reduce Motion (see FirstRunWizardView's `reduceMotion` guard — this view is never even
// instantiated in that case, not just animated faster).
struct IntroSplashOverlay: View {
    var onFinished: () -> Void

    private static let tileCount = 6
    // Pre-scale duration of each of the finale's 5 *travel* legs — 4 tracing the stage's own
    // perimeter, 1 cutting to dead center. This governs only the lap/arrive phase; the grow phase
    // that follows (see growDurationMs below) is a separate, dedicated animation, not more legs on
    // this same track — see finaleWaypoints()'s own comment for why the two are split. Raised from
    // an initial 140ms — live feedback called that pace "not smooth": five hops across the whole
    // stage in well under a second reads as a frantic dart rather than a deliberate sweep. More time
    // per leg is the actual fix (the curve itself, `CubicKeyframe`, already interpolates smoothly
    // through the chain using neighboring keyframes' velocity — this was purely a pacing problem).
    private static let finaleLegDurationMs: Double = 175
    private static let finaleLegCount = 5
    // Pre-scale duration of a normal (non-finale) tile's single depart leg — named so
    // totalDurationMs (below) can size its buffer off the same number driving the ForEach's
    // `legDurationMs: ... : 550` rather than a second hand-copied literal that could drift from it.
    // Not private — FirstRunIntroSplashTimingTests references it directly.
    static let normalLegDurationMs: Double = 550
    // Pre-scale duration of the grow phase — a single continuous expansion, not staggered legs
    // (see FinaleGrowReveal below). Given real weight of its own (not squeezed into a leftover
    // sliver) since "expanding to cover the window" is the payoff beat the whole effect builds to.
    // Not private — FirstRunIntroSplashTimingTests checks totalDurationMs against it directly.
    static let growDurationMs: Double = 600
    // Every other tile's own depart, staggered across the grow phase (not the finale's perimeter
    // lap — those five stay put and watch it lap the stage first) — ordered by ascending distance
    // from center, closest first, so the expanding circle reads as "reaching" each tile roughly in
    // the order it actually would. See departDelayMs(for:).
    private static let finaleKnockoutOrder: [Int] = [2, 3, 4, 1, 0]

    // When the finale's own lap+arrive-at-center journey finishes and the grow phase takes over —
    // shared by departDelayMs(for:)'s grow-phase stagger and the .task below's growTrigger timer,
    // so both derive from the exact same math rather than two numbers that could drift apart.
    // Not private — FirstRunIntroSplashTimingTests checks totalDurationMs against it directly.
    static let growStartMsPreScale = 1050 + Double(finaleLegCount) * finaleLegDurationMs

    // Total lifetime before handing off — covers the finale's own depart start (1050ms pre-scale —
    // "how long the fan holds before the finale starts moving"), its 5-leg lap+arrive journey, the
    // grow phase, plus a little buffer so nothing visibly snaps away, all scaled by
    // introSplashSpeedScale together with every duration below. Deliberately does NOT also wait out
    // the last-departing outer tile's own depart leg (departDelayMs(for:) fires it right at the
    // grow phase's end): by then FinaleGrowReveal's own dot has already grown past the 800pt stage
    // diagonal (its circle passes that size well before the grow phase's own end, since coverScale
    // itself is ~5-7×), so every outer tile is already hidden underneath it for the entirety of its
    // own depart leg — padding for a tile no one can see just added a dead, empty-feeling pause at
    // the very end (tried once, reverted after it visibly stalled the handoff).
    //
    // static rather than an instance `let` — it derives entirely from the static constants above,
    // no `self` needed — which also lets FirstRunIntroSplashTimingTests check it directly without
    // constructing a view instance. Not private, for the same reason.
    static let totalDurationMs = Int(
        (growStartMsPreScale + growDurationMs + 150) * introSplashSpeedScale
    )

    private let tiles = FirstRunSplashContent.symbols
    @State private var titleVisible = false
    @State private var growTrigger = 0
    // The finale tile itself stays opaque throughout its own lap+arrive journey (departFades:
    // false, below) so it doesn't flicker away mid-lap — but once it arrives at center and
    // FinaleGrowReveal takes over, it has no further reason to still be on screen. Left visible, it
    // sits at whatever position its own Depart track settled on, which needn't pixel-match
    // FinaleGrowReveal's own independently-computed center closely enough to stay fully hidden
    // behind the now-much-larger reveal — a small sliver of it can peek out at the reveal's edge,
    // reading as a stray "artifact" left over from the lap rather than a clean hand-off. Fading it
    // out the instant growTrigger fires removes it from the picture entirely, regardless of how
    // closely the two positions actually match.
    @State private var finaleTileFaded = false
    // Drives FinaleGrowReveal's own blink, mirroring PosterTileView's blinksBeforeDeparting on the
    // small finale tile — kept here (parent-owned, set once in growTask below) rather than as
    // FinaleGrowReveal's own internal @State/.task(id:) pair, since that view is reconstructed by
    // its enclosing GeometryReader closure on every parent re-render; a plain passed-in Bool can't
    // silently fail to pick up the trigger the way a child-owned task keyed off a prop could.
    @State private var finaleBlinkDim = false
    @State private var finishTask: Task<Void, Never>?
    @State private var growTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            ForEach(0..<Self.tileCount, id: \.self) { i in
                let isFinale = i == Self.tileCount - 1
                PosterTileView(
                    content: tiles[i],
                    size: Self.size(for: i),
                    restOffset: Self.restOffset(i),
                    restRotation: Self.restRotation(i),
                    // A normal tile has exactly one waypoint (its own single quick flight-out); the
                    // finale has five — 4 perimeter corners, 1 cut to center — and never grows on
                    // this track at all (Self.finaleWaypoints()'s own comment covers why growth is a
                    // separate view, not more waypoints here).
                    departWaypoints: isFinale ? Self.finaleWaypoints() : [(delta: Self.flightDelta(i), scale: 1.18)],
                    legDurationMs: isFinale ? Self.finaleLegDurationMs : Self.normalLegDurationMs,
                    // Also unwinds its own rest rotation back to 0° (rather than adding a 0 delta on
                    // top of it, which would leave it rotated) — .rotationEffect/.scaleEffect both
                    // apply *after* .offset in PosterTileView's transform chain, so a still-rotated,
                    // still off-true-center view scaled up hugely would compound whatever residual
                    // offset that rotation implies, the same class of bug finaleCoverScale() exists
                    // to avoid for the offset half of it.
                    flightSpin: isFinale ? -Self.restRotation(i) : Self.flightSpin(i),
                    departFades: !isFinale,
                    blinksBeforeDeparting: isFinale,
                    arriveDelayMs: Int(Double(i * 50) * introSplashSpeedScale),
                    departDelayMs: Self.departDelayMs(for: i)
                )
                // Only ever touches the finale tile (isFinale false → both sides of the ?: are 1 —
                // a no-op) — see finaleTileFaded's own comment for why it fades out here rather than
                // through the tile's own opacity keyframe track.
                .opacity(isFinale && finaleTileFaded ? 0 : 1)
            }

            // The grow/cover finale, as a wholly separate view from the tile fan above — deliberately
            // never touched by any .offset and only ever animated via .scaleEffect, so it has no
            // offset for that scale to compound with in the first place (the same "offset then scale
            // magnifies any residual offset" class of bug finaleCoverScale() already documents — this
            // fixes it by construction instead of by careful calibration, after the finale tile's own
            // multi-leg Depart track turned out to still hit it despite settling its own delta at
            // "true center": that delta is itself a large nonzero value up until the last instant,
            // and it's that in-flight value — not the net position relative to Arrive — that its own
            // scaleEffect actually compounds with, so it drifted off center anyway). Explicitly
            // centered via GeometryReader + .position rather than trusting ZStack's own default
            // per-child centering — belt-and-suspenders: this is the one element that absolutely
            // must land on the stage's exact geometric center, so its centering shouldn't depend on
            // how any sibling's own (unrelated) offset happens to interact with ZStack's layout pass.
            GeometryReader { geo in
                FinaleGrowReveal(
                    content: tiles[Self.tileCount - 1],
                    restSize: Self.size(for: Self.tileCount - 1),
                    coverScale: Self.finaleCoverScale(),
                    growDurationMs: Self.growDurationMs,
                    trigger: growTrigger,
                    blinkDim: finaleBlinkDim
                )
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }

            // Drawn AFTER the tile fan (on top), and pinned near the top of the stage rather than
            // vertically centered like the fan — an earlier version centered both, and the fan's
            // own vertical band (tile height ± the two-row stagger) directly overlapped the title
            // text, genuinely obscuring it. The offset above is the real fix (no spatial overlap to
            // begin with); drawing on top is a belt-and-suspenders backup, not the only guard.
            titleBlock

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button("Skip") {
                        growTask?.cancel()
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
        // Hard-clip to the exact 640×480 stage FirstRunWizardView sizes its panel to during
        // `.intro` — the enclosing `.overlay` (see that file's own comment) is unclipped by
        // default, so without this any tile motion that overshoots the stage bounds (a bug, not a
        // feature — the finale's old off-center growth used to do exactly this) would render past
        // the actual window edge instead of being caught. Every waypoint below is already
        // calibrated to stay inside these bounds on its own; this is the backstop, not the fix.
        .frame(width: 640, height: 480)
        .clipped()
        .transition(.opacity)
        .task {
            withAnimation(.easeOut(duration: 0.35 * introSplashSpeedScale)) { titleVisible = true }
            growTask = Task {
                try? await Task.sleep(for: .milliseconds(Int(Self.growStartMsPreScale * introSplashSpeedScale)))
                guard !Task.isCancelled else { return }
                growTrigger += 1
                // Plain state change, not a keyframeAnimator trigger, so it needs its own
                // withAnimation to fade rather than cut — FinaleGrowReveal's own cross-fade-in
                // (its keyframes' own opacity track) runs independently of this ambient animation.
                // Duration matched exactly to that fade-in (growDurationMs's own first-quarter ramp,
                // 0.15s pre-scale) rather than picked separately, so the old tile finishes vanishing
                // at the same moment the new one finishes appearing — an even crossfade instead of
                // two mismatched fades that either gap (old gone too soon) or double-expose (old
                // lingers past the new one's own fade-in).
                withAnimation(.easeOut(duration: 0.15 * introSplashSpeedScale)) {
                    finaleTileFaded = true
                }
                // Continues the finale tile's own "recording light" blink into the grow/hold phase
                // — a real recording light doesn't stop blinking just because the shot is zooming
                // in. A separate withAnimation call (different duration than the crossfade above,
                // and repeatForever besides) — each only touches the one @State var it sets, so
                // stacking the two in the same scope doesn't interfere with either.
                withAnimation(.easeInOut(duration: 0.35 * introSplashSpeedScale).repeatForever(autoreverses: true)) {
                    finaleBlinkDim = true
                }
            }
            finishTask = Task {
                try? await Task.sleep(for: .milliseconds(Self.totalDurationMs))
                guard !Task.isCancelled else { return }
                onFinished()
            }
        }
        .onDisappear {
            growTask?.cancel()
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
        // -160 clears the fan's own vertical band (tile height up to 128pt, plus the ±20/24pt
        // two-row stagger, centered on the 480pt-tall stage) entirely — the +8 on top of that is
        // the existing "settles down into place" entrance nudge, unrelated to this positioning fix.
        .offset(y: -160 + (titleVisible ? 0 : 8))
    }

    // MARK: - Generative fan layout (6 tiles, evenly spread -14°…+14°, two-row depth stagger)

    // Varied per tile (was a uniform 78×110 for all six) — a fixed size read as too uniform/grid-like
    // for a "fan of loose tiles" effect; hand-picked spread rather than a formula, same reasoning
    // restOffset's own two-row stagger already uses a fixed alternation instead of a computed curve.
    // Sized up from the original 66–92pt-wide set (icons read as too small at that scale) and the
    // last slot (the record/finale tile) is deliberately the largest of the six even before its own
    // finale grow kicks in — this is the tile the whole effect is building toward, so it should
    // already read as "the important one" during the hold, not just once it starts sweeping.
    private static func size(for i: Int) -> CGSize {
        let sizes: [CGSize] = [
            CGSize(width: 96, height: 134),
            CGSize(width: 120, height: 166),
            CGSize(width: 90, height: 126),
            CGSize(width: 126, height: 174),
            CGSize(width: 104, height: 144),
            CGSize(width: 134, height: 184),
        ]
        return sizes[i % sizes.count]
    }

    private static func restRotation(_ i: Int) -> Double { -20 + Double(i) * (40.0 / 5) }

    private static func restOffset(_ i: Int) -> CGSize {
        CGSize(width: (Double(i) - 2.5) * 100, height: i.isMultiple(of: 2) ? -20 : 24)
    }

    // Radial "fly off the stage" vector from each tile's own rest slot — normalized to a fixed
    // 600pt magnitude so every slot clears the 640×480 intro stage before fading, regardless of
    // how close to center that slot's rest position happens to be. (Raised from 520 for a more
    // energetic, longer-throw exit now that the whole effect runs faster overall.)
    private static func flightDelta(_ i: Int) -> CGSize {
        let rest = restOffset(i)
        let dx = rest.width, dy = rest.height - 40
        let mag = (dx * dx + dy * dy).squareRoot()
        guard mag > 0 else { return CGSize(width: 0, height: -600) }
        let k = 600 / mag
        return CGSize(width: dx * k, height: dy * k)
    }

    // Spin direction matches each tile's horizontal fan side, so the departure reads as an
    // extension of the arrival fan rather than a random spin.
    private static func flightSpin(_ i: Int) -> Double {
        restOffset(i).width < 0 ? -35 : 35
    }

    // MARK: - Finale (record tile) journey

    // How large the finale tile needs to grow, calibrated to its own rest size, to cover the
    // 640×480 intro stage plus a 15% bleed past the edges — not a flat guessed multiplier. A flat
    // 14× was tried first and was a real bug, not just an aesthetic miss: .rotationEffect/
    // .scaleEffect apply *after* .offset in PosterTileView's transform chain, so any residual
    // offset left over from the journey's own math gets magnified by the scale factor too — at
    // 14×, an 82pt-wide tile becomes 1148pt wide, nearly double the 640pt-wide *window* (which
    // doesn't grow to accommodate it), so the excess just rendered past the actual window edge,
    // invisible — the literal "out of frame" bug this calibration fixes. max(...) of the two
    // dimension ratios is what covering (not just containing) the stage actually requires.
    private static func finaleCoverScale() -> CGFloat {
        let s = size(for: tileCount - 1)
        return max(640 / s.width, 480 / s.height) * 1.15
    }

    // Four points tracing the stage's own inner edge — inset from the true 640×480 half-extents
    // (320×240) by more than the finale tile's own half-size (67×92 at rest) so the tile stays
    // fully inside the stage for the whole lap, before it ever starts growing. Ordered starting
    // from the corner nearest the finale's own rest position (bottom-right, since rest is on the
    // fan's right edge) so the first leg is a short hop, not a jump clear across the stage, then
    // proceeds around the perimeter (up the right side, across the top, down the left) rather than
    // jumping between opposite corners.
    private static func finalePerimeterPoints() -> [CGSize] {
        let hx: CGFloat = 235
        let hy: CGFloat = 125
        return [
            CGSize(width: hx, height: hy),    // bottom-right
            CGSize(width: hx, height: -hy),   // top-right
            CGSize(width: -hx, height: -hy),  // top-left
            CGSize(width: -hx, height: hy),   // bottom-left
        ]
    }

    // The finale's 5-leg *travel* path: laps the stage's own perimeter (4 corners), then cuts to
    // dead center — "around the edge, then to the middle." Scale stays at 1.0 the whole time; the
    // grow-to-cover payoff is a deliberately separate view (FinaleGrowReveal below), not more
    // waypoints appended to this same track. That split exists because appending growth here was
    // tried first and was a real bug, not just an aesthetic miss: even with the last waypoint's
    // delta set to exactly cancel the finale's own rest offset (i.e. "true center"), that delta is
    // still a large nonzero value for the whole grow phase — and .rotationEffect/.scaleEffect apply
    // *after* .offset in PosterTileView's transform chain, so its own scaleEffect compounds with
    // that in-flight offset value regardless of what position it nets out to relative to Arrive —
    // magnifying it into a large, visibly off-center drift (reported live as "the record icon keeps
    // moving out of the screen" / "finishing at the bottom of the window"). A view that never has
    // .offset applied to it at all — FinaleGrowReveal sits at the ZStack's own natural center by
    // construction — has no residual offset for its scaleEffect to compound with, sidestepping the
    // whole bug class instead of trying to calibrate around it again. Deltas here are relative to
    // the finale's own rest position, matching PosterTileDepartValues' own "delta on top of the
    // Arrive-settled pose" semantics.
    private static func finaleWaypoints() -> [(delta: CGSize, scale: CGFloat)] {
        let recordRest = restOffset(tileCount - 1)
        let centerDelta = CGSize(width: -recordRest.width, height: -recordRest.height)
        var stops: [(delta: CGSize, scale: CGFloat)] = finalePerimeterPoints().map { corner in
            (CGSize(width: corner.width - recordRest.width, height: corner.height - recordRest.height), 1.0)
        }
        stops.append((centerDelta, 1.0))
        return stops
    }

    // Every other tile departs during the grow phase (once the finale has reached dead center and
    // FinaleGrowReveal has taken over), not during its perimeter lap — they hold their fanned pose
    // while the record tile laps the stage, then get "pushed out" one by one as it expands from the
    // middle. Staggered evenly across the grow phase in finaleKnockoutOrder (ascending distance from
    // center) rather than an independent per-tile timer, so the order roughly matches the sequence
    // the expanding circle would actually reach each one in. The finale itself always departs at
    // 1050ms pre-scale — "how long the fan holds before the finale starts moving," independent of
    // what its own journey looks like afterward.
    private static func departDelayMs(for i: Int) -> Int {
        let ms: Double
        if i == tileCount - 1 {
            ms = 1050
        } else {
            let step = finaleKnockoutOrder.firstIndex(of: i) ?? 0
            ms = growStartMsPreScale + (Double(step + 1) / Double(finaleKnockoutOrder.count)) * growDurationMs
        }
        return Int(ms * introSplashSpeedScale)
    }
}

// MARK: - FinaleGrowReveal

// The "expand to cover the window" payoff — a plain, unmoved ZStack child (see finaleWaypoints()'s
// own comment for why growth lives here rather than as more Depart waypoints on the finale tile
// itself). Sitting at the ZStack's own natural center with no .offset ever applied means its
// .scaleEffect has no residual offset to compound with, so it grows symmetrically from true stage
// center by construction, not by calibration. Rendered on top of (after, in the ZStack) the tile
// fan, at the finale tile's own rest size and matching content, so the moment it fades in as the
// finale tile finishes arriving at center reads as one continuous object continuing to grow, not a
// visible swap between two different views.
private struct FinaleGrowReveal: View {
    let content: VCRSymbolSpec
    let restSize: CGSize
    let coverScale: CGFloat
    let growDurationMs: Double
    let trigger: Int
    // Set (with its own repeatForever animation) by the parent's growTask, not owned here — see
    // IntroSplashOverlay.finaleBlinkDim's own comment for why.
    let blinkDim: Bool

    var body: some View {
        // The record dot itself, drawn as a real vector Circle rather than the ⏺ Unicode glyph it
        // replaces — that glyph has no outline-font design in the system font stack and silently
        // falls back to Apple Color Emoji, a fixed-resolution BITMAP font (~160px native per
        // glyph): no requested point size adds real detail past that ceiling, so scaling it up to
        // cover the stage just magnified the same small bitmap — the actual source of the
        // pixelation a bigger font size alone couldn't fix (confirmed live: raising the requested
        // size to 66×coverScale made no visible difference). A Circle is pure vector geometry,
        // crisp under scaleEffect at any factor. Deliberately has no ambient glow of its own the
        // way the small finale tile does (PosterTileView's blinksBeforeDeparting branch) — a glow
        // circle scaled up alongside a dot already covering most of the 640×480 stage read as flat
        // red wash filling the screen ("too much glare"), not a halo around anything.
        Circle()
            .fill(LinearGradient(colors: content.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: restSize.width * 0.85, height: restSize.width * 0.85)
            .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
            .frame(width: restSize.width, height: restSize.height)
            // Multiplies (stacks) with the keyframeAnimator's own opacity track below, same
            // composition rule PosterTileView's identical blink modifier uses.
            .opacity(blinkDim ? 0.4 : 1.0)
            .keyframeAnimator(initialValue: FinaleGrowValues(), trigger: trigger) { view, v in
                view.scaleEffect(v.scale).opacity(v.opacity)
            } keyframes: { _ in
                let duration = growDurationMs / 1000 * introSplashSpeedScale
                KeyframeTrack(\.scale) { CubicKeyframe(coverScale, duration: duration) }
                // Opacity ramps in over the first quarter — a hard cut from 0→1 at trigger would be
                // a visible pop; a real cross-fade against the finale tile it's continuing from.
                KeyframeTrack(\.opacity) { LinearKeyframe(1.0, duration: duration * 0.25) }
            }
    }
}

// File-scope per StarburstBadge.swift's own note: @KeyframesBuilder type inference fails on a type
// nested inside the view. Starts fully transparent (opacity 0) at scale 1.0 — the same size the
// finale tile itself settles at — so it renders as an invisible, identically-sized stand-in until
// growTrigger fires, then cross-fades in and grows as one continuous motion.
private struct FinaleGrowValues: Animatable {
    var scale: CGFloat = 1.0
    var opacity: Double = 0

    var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(scale, opacity) }
        set { scale = newValue.first; opacity = newValue.second }
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
    let content: VCRSymbolSpec
    let size: CGSize
    let restOffset: CGSize
    let restRotation: Double
    // One or more (delta, scale) stops the Depart phase travels through in sequence — a normal
    // tile has exactly one (its single quick flight-out, unchanged from before); the finale has
    // five, one per tile it visits on its sweep (IntroSplashOverlay.finaleWaypoints()). Deltas are
    // relative to restOffset, matching PosterTileDepartValues' own "delta on top of the
    // Arrive-settled pose" semantics.
    let departWaypoints: [(delta: CGSize, scale: CGFloat)]
    // Pre-scale duration of EACH leg above, applied uniformly — 550ms for a normal tile's
    // one-and-only leg (unchanged from before), 175ms for the finale's five (its whole journey is
    // 5×175=875ms pre-scale, close to a normal tile's single leg × the old finale duration
    // multiplier this replaced, just spent visiting five stops instead of growing in place at one).
    let legDurationMs: Double
    let flightSpin: Double
    // Whether the depart phase fades to 0 opacity — true for a normal tile flying off, false for
    // the finale (record) tile, which stays fully opaque throughout its whole journey so it reads
    // as "taking over the screen," not "flying away like the rest."
    let departFades: Bool
    // Only the finale (record) tile: pulses opacity in a repeating loop from the moment its own
    // arrive settles, continuing straight through its depart/grow (never turned off — a genuine
    // recording light doesn't stop blinking just because the shot is zooming in) — a "recording"
    // indicator, not just a static icon like the other five.
    let blinksBeforeDeparting: Bool
    let arriveDelayMs: Int
    let departDelayMs: Int

    @State private var arriveTrigger = 0
    @State private var departTrigger = 0
    @State private var isBlinking = false
    @State private var blinkDim = false
    // Idle float during the hold, for the five non-finale tiles only (the finale already has its
    // own continuous motion via isBlinking, and is about to sweep across the whole stage anyway) —
    // without this the tiles were dead-still for the entire gap between arriving and departing,
    // reading as a static poster rather than "more motion." A plain state-driven offset, same
    // composition approach as isBlinking/blinkDim: stacks additively on top of the Arrive/Depart
    // keyframe tracks' own offsets without either animator needing to know about it.
    @State private var idleBobOffset: CGFloat = 0

    var body: some View {
        tileContent
            .frame(width: size.width, height: size.height)
            // Blink is a plain, separately-driven opacity modifier — not folded into either
            // keyframeAnimator below — so it can free-run its own repeatForever loop independently
            // of the one-shot Arrive/Depart tracks; stacking multiplies with their own opacity
            // values (StarburstBadge.swift's same composition rule), so it dims the tile without
            // fighting either animator for ownership of the same property.
            .opacity(isBlinking && blinkDim ? 0.4 : 1.0)
            .offset(y: idleBobOffset)
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
                // dampingRatio lowered from 0.68 to 0.56 (x/y/rotation) for a livelier, more visible
                // overshoot-and-settle on arrival instead of a heavily-damped glide — more motion to
                // catch the eye during the brief arrive beat.
                KeyframeTrack(\.x) { SpringKeyframe(restOffset.width, spring: Spring(response: 0.3 * introSplashSpeedScale, dampingRatio: 0.56)) }
                KeyframeTrack(\.y) { SpringKeyframe(restOffset.height, spring: Spring(response: 0.3 * introSplashSpeedScale, dampingRatio: 0.56)) }
                KeyframeTrack(\.rotation) { SpringKeyframe(restRotation, spring: Spring(response: 0.32 * introSplashSpeedScale, dampingRatio: 0.56)) }
                KeyframeTrack(\.scale) {
                    LinearKeyframe(CGFloat(1.05), duration: 0.16 * introSplashSpeedScale)
                    SpringKeyframe(CGFloat(1.0), spring: Spring(response: 0.3 * introSplashSpeedScale, dampingRatio: 0.55))
                }
                KeyframeTrack(\.opacity) { LinearKeyframe(1.0, duration: 0.18 * introSplashSpeedScale) }
            }
            .keyframeAnimator(initialValue: PosterTileDepartValues(), trigger: departTrigger) { view, v in
                view.offset(x: v.x, y: v.y)
                    .rotationEffect(.degrees(v.rotation))
                    .scaleEffect(v.scale)
                    .opacity(v.opacity)
            } keyframes: { _ in
                // One CubicKeyframe per waypoint, same leg duration each — a normal tile's single
                // waypoint degenerates to exactly its old one-shot flight-out; the finale's five
                // waypoints chain into one continuous multi-stop journey (SwiftUI's keyframe
                // tracks play each entry back to back automatically once departTrigger fires).
                let legDuration = legDurationMs / 1000 * introSplashSpeedScale
                let totalDuration = legDuration * Double(departWaypoints.count)
                KeyframeTrack(\.x) {
                    for wp in departWaypoints { CubicKeyframe(wp.delta.width, duration: legDuration) }
                }
                KeyframeTrack(\.y) {
                    for wp in departWaypoints { CubicKeyframe(wp.delta.height, duration: legDuration) }
                }
                KeyframeTrack(\.scale) {
                    for wp in departWaypoints { CubicKeyframe(wp.scale, duration: legDuration) }
                }
                // Rotation and opacity aren't part of the multi-stop path — a single target spanning
                // the whole journey (totalDuration) unwinds/fades once, smoothly, rather than
                // stepping at every waypoint.
                KeyframeTrack(\.rotation) { CubicKeyframe(flightSpin, duration: totalDuration) }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1.0, duration: totalDuration * 0.5)
                    LinearKeyframe(departFades ? 0.0 : 1.0, duration: totalDuration * 0.5)
                }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(arriveDelayMs))
                guard !Task.isCancelled else { return }
                arriveTrigger += 1
                if blinksBeforeDeparting {
                    isBlinking = true
                    withAnimation(.easeInOut(duration: 0.35 * introSplashSpeedScale).repeatForever(autoreverses: true)) {
                        blinkDim = true
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.5 * introSplashSpeedScale).repeatForever(autoreverses: true)) {
                        idleBobOffset = -7
                    }
                }
                try? await Task.sleep(for: .milliseconds(departDelayMs - arriveDelayMs))
                guard !Task.isCancelled else { return }
                departTrigger += 1
            }
    }

    // Plain Unicode glyph, not an SF Symbol — deliberately, see FirstRunSplashContent's own
    // comment on why this is a nostalgic callback, not just a convenient icon source. No card/tile
    // background behind it (an earlier version boxed every glyph in its own gradient-filled rounded
    // rect — "against an orange card" — which read as clutter at this icon size); the glyph floats
    // free, colored via its own gradient foreground instead of a background fill, with just a soft
    // drop shadow for depth. The finale (record) tile gets one extra thing none of the other five
    // do — a soft red glow behind it — so it already reads as "the important one" during the hold,
    // not just once its own sweep/grow kicks in.
    private var tileContent: some View {
        ZStack {
            if blinksBeforeDeparting {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.red.opacity(0.5), .red.opacity(0)],
                            center: .center, startRadius: 2, endRadius: size.width * 0.7
                        )
                    )
                    .frame(width: size.width * 1.5, height: size.width * 1.5)
            }
            Text(content.symbol)
                .font(.system(size: blinksBeforeDeparting ? 66 : 46, weight: .heavy, design: .rounded))
                .foregroundStyle(LinearGradient(colors: content.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
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

// MARK: - Tile content

struct VCRSymbolSpec {
    let symbol: String
    let colors: [Color]
}

// Namespaced rather than a free constant — kept separate from IntroSplashOverlay's own
// layout/choreography math above, the same reasoning that split them before.
//
// A deliberate nostalgic callback to the original AppleScript-era hdhr_VCR, which rendered
// exactly these Unicode Media Control glyphs (U+23E9–U+23FA — each one its own self-contained,
// pre-"framed" symbol, unlike doubling up plain triangle characters like "◀◀" to approximate a
// rewind icon, which an early version of this splash did before switching to the real ones below)
// as plain text — no custom icon assets, an AppleScript UI's normal way of drawing an icon at all —
// not a modern substitute for that, a direct reference to it. Also a straight simplification over
// what this used to do: an earlier version tried to show real show-poster art here, fetched from
// the loaded guide, but the network fetch reliably lost the race against the tiles' own arrive
// animation (sequential per-tile awaits could easily take longer than the whole splash's visible
// lifetime), so real art was never actually seen in practice — what showed instead was the
// *fallback* placeholder set every single time, indistinguishable from "random art" to anyone
// watching. This has no network dependency and nothing to race, so what's specified here is
// exactly what always renders. Last in the array by convention — IntroSplashOverlay treats index
// tileCount-1 as the finale (blinks, then grows to fill the stage instead of flying off) — is the
// record glyph, the one moment this whole effect is building toward.
enum FirstRunSplashContent {
    static let symbols: [VCRSymbolSpec] = [
        VCRSymbolSpec(symbol: "⏯", colors: [.orange, .red]),
        VCRSymbolSpec(symbol: "⏪", colors: [.orange, .yellow]),
        VCRSymbolSpec(symbol: "⏩", colors: [.yellow, .orange]),
        VCRSymbolSpec(symbol: "⏹", colors: [.red, .orange]),
        VCRSymbolSpec(symbol: "⏏", colors: [.orange.opacity(0.85), .red.opacity(0.85)]),
        VCRSymbolSpec(symbol: "⏺", colors: [.red, .red.opacity(0.6)]),
    ]
}
