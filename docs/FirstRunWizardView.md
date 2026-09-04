# FirstRunWizardView.swift — First-Run Setup Wizard

## Visual Appearance

### Overall window
**Redesigned 2026-08-28** — the original version was a bare `VStack`/`Form` in a fixed 480×460
frame with no material/corner treatment at all: it looked like an undressed Settings dialog
floating with hard square corners, not a "floating panel" despite the doc's original claim. It now
actually shares `DonationNagView`'s exact chrome, not just the same *intent*: `.background(.thickMaterial)`,
`.clipShape(RoundedRectangle(cornerRadius: 20))`, a faint white `.strokeBorder` overlay, and the
same drop shadow (`.shadow(color: .black.opacity(0.4), radius: 28, y: 14)`) — hidden title bar
(traffic lights only, no title text), same as before.

**Redesigned again 2026-08-28** (same day, second pass) — added a third `Step` case, `.intro`, for
a one-time animated splash (see "Intro Splash" below), and replaced the plain network-status row
with a device-aware `TunerDiscoveryCard` (see its own section below).

**Width/height are step-dependent**: normally width only is fixed (460pt), height follows content
(the old fixed 460 height left a dead gray gap below Step 1's rows once the Form's own list
background was accounted for). During `.intro` the frame grows to a fixed 640×480 "stage"
(`.frame(width: step == .intro ? 640 : 460, height: step == .intro ? 480 : nil)`) so the splash's
tiles have real room to fan out and fly off before the panel shrinks back down on hand-off — this
resize is animated inside the same `withAnimation` transaction as the `step` change, the identical
mechanism `goNext()`/`goBack()` already use for the width-only case. `.windowResizability(.contentSize)`
tracks whichever size is currently requested. Each `Form` also gets
`.scrollContentBackground(.hidden)` (lets the panel's own `.thickMaterial` show through instead of
the Form's own opaque grouped-list card, so the two don't read as a card nested inside a panel) and
`.fixedSize(horizontal: false, vertical: true)` (List-backed Forms otherwise claim more vertical
space than their rows need even without an outer fixed height).

**Header band**: the app icon (`appIconImage`, `Sources/hdhr_VCR/AppIcon.swift` — the same
global already used by `DonationNagView`/`SettingsView`/the menu bar icon) at 36×36 in a rounded
rect, next to "Welcome to hdhrVCRplus" (`.headline`) and a one-line subtitle, giving the window the
same "unmistakably this app's own chrome" identity `DonationNagView`'s header comment already
argues for. The step-progress dots sit directly below this, inside the same header `VStack` — 5
small 8pt circles, filled accent-color = current step, hollow gray = other steps (same visual
pattern as `AddShowView`'s step indicator). **Not rendered during `.intro`** (`if step != .intro`
around both the header and the bottom nav bar) — the splash has no header/nav chrome of its own,
just its own Skip control (see below).

**Finish-flourish glow**: the header icon sits in a `ZStack` with a `RadialGradient` circle behind
it, driven by a `keyframeAnimator(initialValue: FinishGlowValues(), trigger: finishGlowTrigger)` —
same visual language as `DonationNagView`'s own appear-glow, reused here on *completion* instead.
Unlike `DonationNagView`'s plain appear→fade Bool, this needs to rest *hidden* both before and
after the flourish (nothing should show behind the icon while the user is still on any earlier step) with a
visible pulse in between — a two-state `withAnimation` toggle can't do that (it can only rest at
one of its two endpoints), so it's a keyframe pulse instead: `FinishGlowValues`' own `initialValue`
is hidden (scale 0.7, opacity 0), and pressing Finish increments `finishGlowTrigger`, popping the
glow to scale 1.3 while opacity ramps 0→0.9→0 over 0.35s, alongside the Finish button's label
morphing to a checkmark (`finishButton`, `.transition(.scale.combined(with: .opacity))`, 0.18s).
`dismiss()` fires after a separate 380ms delay (`finish()`'s `finishTask`) — long enough to see the
flourish, short enough not to feel like a stall. `.onExitCommand`/the red-close-button still call
`dismiss()` directly and immediately regardless of this pending task, and `finish()` itself no-ops
on a double-click during the delay (`guard !hasFinished else { return }`). Because the animator's
rest state is always its own `initialValue`, there's nothing to reset in `resetForFreshRun()` for a
"Reset First-Run Setup" replay — an earlier boolean-based version of this got that wrong (stayed
"flourished"/hidden across a reset instead of resting at the pre-flourish visible pulse state).

**Step content slides horizontally** — Next moves the new screen in from the right while the old
one exits to the left; Back mirrors it. This is a real content transition
(`.move(edge:).combined(with: .opacity)`, 0.25s ease-in-out), distinct from `AddShowView`'s
window-frame-only animation (that view has no content transition at all). Each screen carries a
distinct `.id(Step.X)` — without it SwiftUI may just diff the two similarly-shaped `Form`s in
place instead of treating the swap as an insert/remove pair, and the transition would silently
never fire. **The intro splash's hand-off reuses this exact mechanism** — `finishIntro()` calls the
same `withAnimation(.easeInOut(duration: 0.25)) { step = .recordingDefaults }` shape as `goNext()`,
so the splash-to-Step-1 transition rides the one slide/frame-resize system the wizard already has,
not a second bespoke one.

Escape, the red close button, or clicking Finish all count as "dismissed" — this is a one-time
onboarding flow, not a resumable/cancelable form. Only Finish commits the field values; closing any
other way just marks the wizard as seen and discards whatever was typed. This applies during
`.intro` too — Escape/red-close-button work identically mid-splash (`.onExitCommand`/the window's
close button are independent of `step`).

### Intro Splash (`Views/FirstRunIntroSplash.swift`)
A one-time animated splash, entered deliberately right after `.onAppear`/reset (never the resting
default for `step` — see "Steps" below) and skipped entirely under **Reduce Motion**
(`@Environment(\.accessibilityReduceMotion)`) — a different code path, not a faster version of the
same one; `IntroSplashOverlay` is never even instantiated in that case. Lives in a **second**
`.overlay` attached after the panel's `.shadow(...)` (not inside the clipped `VStack`) — `.overlay`
content is unclipped by default, so `IntroSplashOverlay`'s own body applies its own
`.frame(width: 640, height: 480).clipped()` (matching the exact stage size `FirstRunWizardView`
sizes its panel to during `.intro`) rather than relying on the ambient overlay behavior — a hard
guarantee that every tile's motion, including the finale's own multi-leg journey below, stays
inside the actual window bounds instead of potentially rendering past its edge. (An earlier version
of this splash relied on the unclipped overlay to let tiles fly *past* the panel edge on purpose;
that reasoning no longer applies now that clipping is explicit — see "Depart" below for why.)

**Layout**: 6 tiles, each its own size (`IntroSplashOverlay.size(for:)` — a hand-picked spread from
90×126 to 134×184, not a uniform size for all six — a fixed size read as too grid-like for a "fan of
loose tiles" effect; sized up from an earlier, smaller 66×92–92×128 spread once live feedback said
the glyphs read as too small) in a generative fan — evenly spread -20°…+20° rotation, x-offsets
centered across ~600pt, alternating ±20/24pt vertical offset for a two-row depth read. Each glyph
renders with **no background card** — an earlier version filled each tile with its own
orange/red/amber gradient behind the glyph (see "Tile content" below); that background is gone, the
glyph itself now carries the gradient as a foreground fill plus a soft drop shadow for depth, so
there's no rounded-rect "card" outline at all, just the floating icon. Each of the five non-finale
tiles' "flight" vector is its own rest-offset direction normalized to a fixed 600pt magnitude, so
every slot clears the stage regardless of how close to center it starts. The title ("Welcome to
hdhrVCRplus" + subtitle) is pinned near the top of the 640×480 stage (`-160` offset), well clear of
the fan's own vertical band — an earlier version centered both the fan and the title, and the fan's
vertical range genuinely overlapped and obscured the text.

**Record tile prominence**: the finale (record, `⏺`) tile is deliberately the largest of the six
from the moment it arrives (134×184 vs. the other five's smaller sizes) and is the only one with a
soft red radial glow rendered behind its glyph (`PosterTileView.tileContent`, gated on
`blinksBeforeDeparting`) — both read *before* its own blink/sweep/grow kicks in, so it's already the
visual focal point during the Hold beat, not just once it starts moving. Its glyph is also rendered
larger than the other five (66pt vs. 46pt).

**Idle motion during Hold**: the five non-finale tiles weren't previously animated at all between
their own Arrive settling and Depart firing — dead-still for most of the sequence. Each now floats a
small continuous ±7pt vertical bob (`PosterTileView.idleBobOffset`, `.easeInOut(...).repeatForever`)
starting the moment its own Arrive settles, composed the same way `isBlinking`/`blinkDim` is — a
plain state-driven modifier stacked on top of the keyframe animators' own offset, not folded into
either track. The finale tile doesn't bob; its own blink pulse is its Hold-phase motion.

**Choreography** (~5s total at the current `introSplashSpeedScale` of 2.0, per-tile staggered —
every duration/stagger number in this section is the *pre-scale* baseline the file's own comments
document, all multiplied by that one constant rather than hand-tuned independently; see "Pacing"
below for the full history of that constant):
1. **Arrive** (0–~50–300ms pre-scale, staggered `i×50ms`) — springs from center (scale 0.4, opacity
   0) out to its rest offset/rotation. Response tuned to 0.3 pre-scale (down from an initial
   0.42/0.5) after live screenshots showed the heavier-damped spring still visibly mid-transit past
   the intended arrive beat — tightened to settle in the same beat as the faster opacity/scale
   tracks. `dampingRatio` on the x/y/rotation springs is `0.56` (down from `0.68`) for a livelier,
   more visible overshoot-and-settle rather than a heavily-damped glide.
2. **Hold** — tiles sit fanned out; title fades/slides in above them. The finale (record) tile
   additionally blinks — a repeating opacity pulse (0.35s pre-scale half-cycle,
   `.repeatForever(autoreverses: true)`) layered on as a plain, separately-driven modifier rather
   than folded into either keyframe animator, so it can free-run independently of their one-shot
   tracks. Started the moment its own Arrive settles and **never turned off** — it keeps blinking
   straight through its whole journey below too (a real recording light doesn't stop blinking just
   because the shot is moving).
3. **Depart** — the five non-finale tiles each fly out along their own vector with an added ±35°
   spin (matching their fan side), growing slightly (1.18×) while fading to 0 opacity, over a single
   550ms-pre-scale leg, same as before (their own flight vector is now clipped at the stage edge by
   the `.clipped()` in "Intro Splash" above, but each tile has already faded to 0 opacity well before
   reaching it — see `flightDelta`'s magnitude vs. the opacity track's own timing).

   The **finale tile** (last in `FirstRunSplashContent.symbols`, the record glyph) does something
   different — a **5-leg travel journey, then a hand-off to a separate grow view**, not a single
   grow-in-place and not more waypoints appended to its own Depart track. Legs 1–4 **lap the stage's
   own perimeter** (`IntroSplashOverlay.finalePerimeterPoints()` — bottom-right → top-right →
   top-left → bottom-left, inset from the true 640×480 half-extents so the tile stays fully inside
   the stage for the whole lap), leg 5 **cuts to dead center**. Scale stays at `1.0` throughout — this
   track never grows. Each leg takes `finaleLegDurationMs` (`175ms` pre-scale, raised from an initial
   `140ms` — that pace read as a frantic dart across the stage rather than a deliberate sweep; the
   curve itself already interpolates smoothly through the chain, this was purely a pacing fix) — the
   travel journey is `5×175=875ms` pre-scale. Once leg 5 completes, `IntroSplashOverlay`'s own
   `growTask` fires `growTrigger`, which does two things at once: `FinaleGrowReveal` (below)
   cross-fades in and starts growing, and the original finale `PosterTileView` fades out
   (`finaleTileFaded`, `0.15s` pre-scale `easeOut` — deliberately matched to `FinaleGrowReveal`'s own
   fade-in duration below rather than picked independently, so the old tile finishes vanishing at the
   same moment the new one finishes appearing, an even crossfade instead of a gap or a double-expose)
   — it's served its purpose (being the thing that visibly laps the stage) and has no reason to keep
   existing once the grow view takes over; left on screen, its own settled position needn't
   pixel-match `FinaleGrowReveal`'s independently-computed center closely enough to stay fully hidden
   behind the now-much-larger reveal, and a sliver of it peeking out past the reveal's edge read as a
   stray "artifact" rather than a clean hand-off (live feedback after the perimeter-lap redesign first
   shipped) — fading it out unconditionally removes it from the picture regardless of how closely the
   two positions actually match, rather than chasing ever-tighter position parity.

   **`FinaleGrowReveal` is a deliberately separate view, not more Depart waypoints on the finale
   tile** — the previous version of this redesign tried exactly that (append 2 more waypoints to the
   same Depart track, growing to `finaleCoverScale()` at a delta that exactly cancels the finale's own
   rest offset, i.e. "true center") and it was a real bug, not just an aesthetic miss, live feedback:
   "the record icon keeps moving out of the screen" / "finishing at the bottom of the window."
   `.rotationEffect`/`.scaleEffect` apply *after* `.offset` in `PosterTileView`'s transform chain, so
   its own `scaleEffect` compounds with whatever that track's *in-flight* offset value is at the
   moment scale ramps up — and that value is a large nonzero number (the delta needed to reach center
   from the tile's own rest position) for the entire grow phase, regardless of what it nets out to
   relative to Arrive. The huge scale factor magnifies that in-flight value, dragging the growth
   toward one side instead of expanding evenly. `FinaleGrowReveal` sidesteps the whole bug class by
   construction: it's a plain view that never has `.offset` applied to it at all (nothing for its own
   `scaleEffect` to compound with), explicitly centered via `GeometryReader` + `.position` rather than
   relying on implicit ZStack per-child centering, so it grows radially symmetric from the stage's
   true center regardless of where the finale tile's own Depart track happens to land. It renders the
   same content (glow circle + `⏺` glyph, same rest size as the finale tile) so the cross-fade reads
   as one continuous object continuing to grow, not a visible swap between two views. Its own
   `growDurationMs` (`600ms` pre-scale) is a single `CubicKeyframe` scale ramp to `finaleCoverScale()`,
   with opacity ramping in over its first quarter. **Every non-finale tile's own depart is staggered
   across this grow phase**, not the finale's perimeter lap — `IntroSplashOverlay.finaleKnockoutOrder`,
   `[2, 3, 4, 1, 0]` (ascending distance from center) — so the five tiles hold their fanned pose while
   the record tile laps the stage, then get "pushed out" one by one, roughly in the order the
   expanding circle would actually reach them. The finale itself starts its own travel at 1050ms
   pre-scale — unrelated to the shape of its journey, just "how long the fan holds before the finale
   starts moving."

   **`finaleCoverScale()` is calibrated per-tile-size, not a flat guessed multiplier — a flat `14×`
   was tried first and was a real bug, not just an aesthetic miss**: at `14×`, an 82pt-wide tile
   becomes 1148pt wide — nearly double the 640pt-wide intro *window* — so the excess rendered past the
   actual window edge (now caught by the explicit `.clipped()` in "Intro Splash" above regardless).
   `max(640/width, 480/height) × 1.15` is what covering (not just containing) the stage actually
   requires — whichever dimension needs more scale to reach the stage size gates the result, the other
   overshoots safely.
4. Overlay fades out as `step` changes underneath (the `.transition(.opacity)` on
   `IntroSplashOverlay` itself, riding the same `withAnimation` as the hand-off) — by this point the
   grown record circle already fills the visible stage, so the fade reads as "cut from red to the
   real UI," not a tile disappearing.

**Pacing**: `introSplashSpeedScale` (file-scope `private let` in `FirstRunIntroSplash.swift`,
currently `2.0`) multiplies every duration and per-tile stagger value in both `IntroSplashOverlay`
and `PosterTileView` — arrive/depart spring `response`s, the scale/opacity keyframe durations, the
title fade, `arriveDelayMs`/`departDelayMs`, and `totalDurationMs` all move together, so the
choreography's own proportions (how much of the sequence is Arrive vs. Hold vs. Depart, how far
apart each tile's stagger lands relative to the whole) stay exactly as designed — only the overall
speed changes. History: `1.0` (original) → `1.7` (live viewing: fan arriving and already flying
apart again before it read as considered, not a blip) → `3.5` (~8.75s total — the opposite
complaint, "waaay too fast" at 1.7, overcorrected into feeling long) → `2.0` (~5.35s total — the
current setting, landing between the two). `totalDurationMs` itself is
`(growStartMsPreScale + growDurationMs + 150) * scale`, where `growStartMsPreScale =
1050 + finaleLegCount * finaleLegDurationMs` (1050 = hold time, `finaleLegCount * finaleLegDurationMs`
= the finale's 5-leg travel journey) — so the finale's travel journey and `FinaleGrowReveal`'s own
grow phase both always have room to finish before the hand-off fires regardless of `scale`.
`finaleLegDurationMs` is `175ms` pre-scale (5 legs = `875ms` — raised from an initial `140ms`/`700ms`
total, live feedback: "not smooth," the perimeter lap read as a frantic dart at that pace) and
`growDurationMs` is `600ms` pre-scale, split out this way — rather than one number for a combined
single track — specifically so each phase (lap+arrive vs. grow) can be tuned independently now that
they're genuinely separate animations (`FinaleGrowReveal` is its own view, not more waypoints on the
finale tile's own track —
see "Depart" above for why that split exists).

**Known follow-up: still a work in progress.** This has already been through several rounds of live
feedback (card removal, icon sizing, record-tile prominence, idle motion, pacing, the finale's
perimeter-lap-then-center-grow path replacing its original off-center sweep, splitting the grow phase
into its own `FinaleGrowReveal` view after the sweep-based grow still drifted off-center, fading the
original finale tile out once `FinaleGrowReveal` takes over so it doesn't leave a stray artifact
poking out from behind it) — treat any of the specific numbers above as tunable, not settled, if a
future pass gets more feedback.

**Composition model** — two independent `keyframeAnimator`s per tile (Arrive, Depart), extending
`StarburstBadge.swift`'s own documented rule (stacked `scaleEffect`s multiply, stacked
`rotationEffect`s add) to `.offset` (adds) and `.opacity` (multiplies): `PosterTileDepartValues`
starts neutral (0 offset, 0° rotation, ×1 scale, ×1 opacity) and contributes nothing until its own
trigger fires, exactly like `StarburstBadge`'s celebration track staying neutral until tapped. Both
value types are file-scope (`@KeyframesBuilder` type inference requirement, same as
`StarburstBadge`'s own note) with a nested-`AnimatablePair` `animatableData` — the same technique
`StarburstBadge` uses for 2 properties, extended here to 5 (x, y, rotation, scale, opacity). The
finale tile's different depart *target values* (grow instead of fly-fade, no spin) are supplied by
the caller (`IntroSplashOverlay`, via `departScale`/`departFades`/`departDurationScale` params) —
the keyframe track *shapes* themselves are shared unchanged between all six tiles.

**Tile content — fixed set of six stylized Unicode Media Control glyphs**
(`FirstRunSplashContent.symbols`: `⏯` `⏪` `⏩` `⏹` `⏏` `⏺`, each its own orange/red/amber-family
gradient applied as the glyph's own foreground fill (not a background card, see "Layout" above),
rendered as plain `Text` — not an SF Symbol — via `PosterTileView.tileContent`). No network
dependency and nothing to race against the visual choreography. A deliberate nostalgic
callback to the original AppleScript-era hdhr_VCR, which rendered exactly these Unicode Media
Control block glyphs (U+23E9–U+23FA) as plain text too (an AppleScript UI's normal way of drawing an
icon at all, no custom asset needed) — real, single-codepoint transport-control symbols, each
already its own self-contained "framed" glyph, rather than an earlier attempt at approximating one
(e.g. `◀◀`, two plain triangle characters) by doubling up unrelated characters. The last symbol in
the array (`⏺`, record) is the finale tile by convention — `IntroSplashOverlay` always treats index
`tileCount - 1` as the one that blinks-then-grows instead of flying away, so reordering this array
moves which glyph gets that treatment.

**Superseded**: an earlier version tried real show-poster art instead (`state.guideByDevice`'s
`ImageURL` fields, falling back through a channel-logo tier, then a generated gradient+SF-Symbol
placeholder as a last resort) — removed because the network fetch reliably lost the race against
the tiles' own arrive animation in practice (fetches ran one at a time per tile slot, easily adding
up to longer than the whole splash's visible lifetime even when the guide already had real posters
loaded), so the *placeholder* tier was what actually rendered on real runs, not real art —
indistinguishable from "random art" to anyone watching, which is exactly the live feedback that
prompted dropping the whole cascade for the fixed glyph set above instead of trying to fix the race.

**Skip**: an always-visible `.plain`/`.tertiary` "Skip" button, bottom-trailing, `.help("Skip the
intro animation")` + `accessibilityIdentifier("wizard-skip-intro")` — confirmed reachable via System
Events by `.help` text (not `name`/`description`, which come back empty for this button — same
finding `WindowNavigationTests.swift` already documents for other wizard controls). Tapping it
performs the same hand-off immediately, mid-animation regardless of which phase any tile (including
the finale) is in.

**Replay**: double-clicking the app-icon logo in any non-intro step's own header (`FirstRunWizardView.header`,
`accessibilityIdentifier("wizard-header-logo-replay-intro")`) calls `replayIntro()` — the same
`withAnimation { step = .intro }` `playIntroIfNeeded()` uses, but without that function's own
`!hasPlayedIntro` guard, since this is an explicit, repeatable request rather than the one-time
automatic entry that guard exists to gate. Still respects Reduce Motion (a no-op there, same as
every other path into `.intro`). `hasPlayedIntro` itself is left untouched by this, so a later
automatic reopen (Settings → Maintenance → "Reset First-Run Setup", which calls
`resetForFreshRun()` separately) still behaves exactly as documented under "Reset from Settings"
below.

### Step 1 — Recording Defaults
**Tuner discovery card** (`Views/TunerDiscoveryCard.swift`, top of Step 1, own `Section`) —
device-aware replacement for the original plain network-status row. Four states:
- **Checking**: an antenna glyph (`antenna.radiowaves.left.and.right`) pulsing via the native SF
  Symbols `.symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: true)`
  effect — chosen over a hand-rolled radar-ping animation because it's a built-in macOS effect
  (zero animation code to maintain) and is thematically exact.
- **Found (single device)**: green checkmark with a spring "pop" (same spring family as
  `StarburstBadge`'s own pop-in), plus a `.caption.monospaced()` identity line —
  `"HDHR-XXXXXXXX · N tuners · M channels ready"` — using the app's established
  `"HDHR-\(deviceId.uppercased())"` device-label convention (same one `WebServer.swift`'s device
  bar and the web guide's offline-device warning already use). The tuner-count and channel-count
  clauses are each independently omitted when not yet known (`nil TunerCount`, or no lineup fetched
  for that device yet) — never rendered as a false "0".
- **Found (multiple devices)**: headline becomes "N HDHomeRun devices found"; a compact per-device
  list replaces the single identity line — each row reuses the exact same `identityLine(for:)`
  helper the single-device case uses (`"● HDHR-XXXXXXXX · N tuners · M channels ready"`, the
  channel-count clause included whenever known), not a shortened two-part format — not a card grid
  either, since Step 1's `Form` is already vertically tight and a grid there would overpower the
  actual recording-defaults content.
- **Not found**: unchanged copy/behavior (the "Open Privacy Settings" button below) — deliberately
  no new animation on this state; whimsy belongs in progress/success states, not failure states.

`checkNetworkAccessIfNeeded()` itself (the actual discovery/confirmation logic feeding this card via
`discoveryStatus`, a presentational computed property) is unchanged from before this redesign — see
"Local Network permission" below.

**Background art prefetch during the splash** (`prefetchIntroArtIfNeeded()`, its own `.task`
alongside `checkNetworkAccessIfNeeded()`'s) — while the intro splash is on screen, the wizard also
warms `ChannelIconCache` for a handful of channels' current-show posters (`GuideEntry.ImageURL`),
favorite channels first — channel *logos* aren't fetched by this function itself; any logo warming
that happens is `AppState.performFetchAllGuides()`'s own unrelated `prefetchChannelIcons(_:)` call
(not favorite-first, and only reached if `fetchAllGuides()` actually runs below). Doesn't run its
own device-discovery scan
(`checkNetworkAccessIfNeeded()`'s is already doing that concurrently, from a separate `.task`) — it
briefly polls `state.devices` (200ms × up to 20, ~4s ceiling, comfortably inside the ~5.35s splash)
waiting for either that function or `AppState`'s own launch-time `startup()` to populate it, then
loads lineups (`ensureLineupLoaded(for:)` — a no-op if already loaded) and, only if some device's
guide isn't already loaded, `fetchAllGuides()`. Channel selection and favorite-first ordering reuse
`state.onAirNow(for:)` (`.prefix(10)`, capping this at "a few posters," not the whole on-air
lineup) rather than reimplementing that sort — the same lookup `/api/now.json` and the menu's own
"on now" list already use, whose own sort already puts `channel.isFavorite` first (ties broken by
channel number). This isn't just reuse for its own sake: an earlier version of this function read
`GuideChannel.Guide` directly off `state.guideByDevice` to find each channel's current program, and
that field is never actually populated there — the per-program data lives only in `GuideStore`'s own
separate per-channel/time-range index, reached through `guideEntries(deviceId:channelNum:)` (which is
exactly what `onAirNow` calls internally) — so that version silently warmed nothing on every real
device despite running without error. Purely best-effort with no UI binding — nothing in this view
displays the result, so a slow network or an empty lineup just means less got warmed, never an error
state; the
payoff is instant
posters whichever screen the user reaches once the wizard hands off (Watch Now, the guide,
etc.), not anything visible during the splash itself.

Save folder (`NSOpenPanel` picker, same control shape as `SettingsView`'s Recording tab), default
transcode profile, min free disk (GB), and failure threshold — each with an `InfoButton` popover
explaining what it does. This wizard and `SettingsView`'s Recording section now share these four
rows via one view, `RecordingDefaultsFields` (`Views/RecordingDefaultsFields.swift`) — no separate
doc for it since it has no independent visual identity beyond what's described here and in
`docs/SettingsView.md`'s Recording section.

### Step 2 — Web LAN
A purpose-built animated diagram (`WebLANDiagram`, `Views/WebLANDiagram.swift` — see its own
section below) — this Mac fanning out to three different device icons — above a short explanation
and one `Toggle`, **Enable Web LAN**. See "Steps" below for the config-commit details.

### Step 3 — Terminal Guide
A second, genuinely different animated diagram (`TerminalTypingDiagram`,
`Views/TerminalTypingDiagram.swift` — see its own section below): a mock terminal window typing a
command, not another instance of Web LAN's own broadcast-fan visual. **Split into its own step
2026-09-04** — an earlier version put Web LAN and Terminal Guide on one combined screen (gating
Terminal Guide's toggle right there, since it's meaningless without Web LAN on first); live
feedback was that stacked together the two diagrams read as the same graphic twice. Now sequential
instead: Web LAN's decision is already made by the time this step is reached, so the gating
(`Toggle` `.disabled(!sharingEnabled)`, label suffixed `" (Requires Web LAN)"` when Web LAN is
off) still works correctly across the step boundary — both bools are the same wizard-lifetime
`@State`, just read from a later step now instead of the same screen. See "Steps" below for the
config-commit details.

### Step 4 — Recording FEED
An animated diagram (`NetworkFlowDiagram`) showing two devices connected by a line — signal rings
broadcasting from the recording Mac, small packets flowing along the line to the watching one —
above two short paragraphs of plain-language explanation and one `Toggle`. See "Steps" below for
the config-commit details.

### Step 5 — Notification Timing
Up Next / Recording Soon lead-time minutes, same `Stepper` controls and warning banner (shown when
the recording alert would fire at or after Up Next) as `SettingsView`'s Notifications tab.

**Nav bar** (bottom): Back (steps 2–5, `.plain` style, `.secondary` foreground — a quiet
secondary action) and Next/Finish, right-aligned, Next/Finish `.borderedProminent` (Finish only on
the last step). A `Divider` above (`opacity(0.5)`, same softened-divider treatment used below the
header, so the dividers read as subtle separators against the material background rather than harsh
full-contrast lines).

## Intent

A first-launch-only setup flow covering the handful of settings worth deciding before using the
app: where recordings are saved and how, how much notice you get before one starts, and — since
2026-09-04 — every LAN-facing feature this app's Settings groups under its "Web LAN" section
(Enable Web LAN, Terminal Guide, Recording FEED), each its own step, since each is now off by
default and worth a one-time explanation of what it actually does before a first-time user goes
looking for it in Settings. Everything else (Discord, Guide) is still left for `SettingsView` —
this wizard covers "what's off by default and needs a plain-English explanation," not a full
onboarding tour of every setting in the app.

Every field defaults to the **current** config value (`loadCurrentValuesIfNeeded()`, called from
`.onAppear`), not a hardcoded factory default — re-running the wizard later via the reset button
(see "Reset from Settings" below) shows what's actually configured, not `AppConfig`'s factory
defaults.

---

## Steps

```swift
enum Step: Int { case intro, recordingDefaults, webLAN, terminalGuide, recordingRelay, notificationTiming }
```

Navigation (`goNext()`/`goBack()`) walks a single `orderedSteps` array
(`[.recordingDefaults, .webLAN, .terminalGuide, .recordingRelay, .notificationTiming]`) by index
rather than a per-step ternary chain — added when a 3rd non-`.recordingDefaults` step made the
original 3-way ternary ambiguous; a plain ordered list is the one place to edit for any future
reorder/insert/removal instead of a scattered set of hand-kept `step == .X ? .Y : .Z` conditions.

`.intro` is **never the resting default** (`@State private var step: Step = .recordingDefaults`) —
it's entered deliberately via `playIntroIfNeeded()`, called from both `.onAppear` and the
`onChange` reset block (see "Reset from Settings" below), guarded by `hasPlayedIntro` so it plays
exactly once per fresh wizard-open. This keeps every "step starts at `.recordingDefaults`"
assumption elsewhere (sizing, header, nav bar visibility) true by default, and means a Reduce
Motion user never instantiates `IntroSplashOverlay` at all rather than seeing a faster version of it.

### Step 1 — Recording Defaults
Binds to local `@State` throughout, including the save folder (`saveFolder`) — deliberately
**not** `@AppStorage`, unlike `SettingsView`'s live-bound `defaultSaveDirectory`: every field on
this screen only takes effect on Finish, so Choose…/Reset have to stay in local state too, or
they'd persist immediately even if the user backs out via Escape. `loadCurrentValuesIfNeeded()`
reads the current value from the same `"defaultSaveDirectory"` `UserDefaults` key `AddShowView`
and `SettingsView` already use (falling back to `Hdhr_setup_folder`, matching
`AppState.defaultSaveDir`'s own chain minus the final `localFallbackDir` step — an empty result
here just means "use the default," same as everywhere else); `finish()` writes it back to that
same key. Transcode/min-disk/fail-threshold commit to `state.config.Default_transcode` /
`.Min_disk_free_gb` / `.Fail_count_setting` on Finish the same way.

### Step 2 — Web LAN
Covers `Web_server_enabled` ("Enable Web LAN," the LAN web server) on its own screen — one local
`@State sharingEnabled` bool (default `false`, mirroring `AppConfig`'s own default), introduced by
`WebLANDiagram()` (see its own section below) and a short paragraph.

`finish()` commits it to `state.config.Web_server_enabled` and, if it changed, calls
`state.setupWebServer()` immediately — the same changed-value-gated pattern `SettingsView.save()`
already uses, so Web LAN actually starts serving the moment this wizard closes rather than waiting
for the next unrelated settings save.

### Step 3 — Terminal Guide
Covers `Terminal_guide_enabled` ("Enable Terminal Guide") on its own screen, one step after Web
LAN — **not combined with it on one screen**, unlike an earlier version of this step (see the
summary section above for why: two `NetworkFlowDiagram` instances stacked together read as visually
redundant). The dependency is still enforced exactly as before, just across the step boundary
instead of within one screen: local `@State terminalGuideEnabled`'s `Toggle` is
`.disabled(!sharingEnabled)` and its label suffixed `" (Requires Web LAN)"` while `sharingEnabled`
is off — the same `sharingEnabled` bool Step 2 set, still in scope since both are plain
wizard-lifetime `@State`, not per-screen state. Because the toggle is SwiftUI-`.disabled` whenever
`sharingEnabled` is false, the wizard can never actually produce the (recoverable, but meaningless)
state of Terminal Guide on with Web LAN off *while moving forward through the wizard normally* —
though going back to Step 2, turning Web LAN off after having already turned Terminal Guide on
earlier, then returning here without touching the now-disabled Terminal Guide toggle, leaves
`terminalGuideEnabled` at its prior `true` value: accepted, not a bug, matching
`SettingsView.sharingView`'s own identical precedent (its Terminal Guide toggle doesn't force-reset
either — see `docs/SettingsView.md`, "Turning this off has no security effect").

`finish()` commits it to `state.config.Terminal_guide_enabled` — no follow-up action needed (unlike
Web LAN, nothing has to be started/stopped for this flag; it's just read passively by `hdhr_guide`
and `/api/guide.json`).

### `WebLANDiagram` (`Views/WebLANDiagram.swift`)
Purpose-built for Step 2, not a themed instance of `NetworkFlowDiagram` — added 2026-09-04
alongside the step split above, replacing an earlier version that palette-swapped
`NetworkFlowDiagram`'s own two-device shape. Web LAN's real relationship (one Mac serving many
different *kinds* of devices) is genuinely different from Recording FEED's (one Mac connecting to
one specific other Mac), so this fans out instead: "this Mac" on the left (green badge, ripple
rings — same broadcasting language `NetworkFlowDiagram`/`SignalRing` use) connects via three
separate dashed lines to three device icons on the right (`desktopcomputer`/`ipad`/`iphone`,
`watchNowBlue`), each receiving its own small traveling packet at a staggered phase offset (0,
0.33, 0.66 of the packet cycle) so the three arrivals read as a continuous fan-out rhythm rather
than three lines pulsing in lockstep. Respects Reduce Motion (freezes to three static dots, one per
line) and is `.accessibilityHidden(true)`, same conventions as every other diagram here.

### `TerminalTypingDiagram` (`Views/TerminalTypingDiagram.swift`)
Purpose-built for Step 3 — deliberately NOT another `NetworkFlowDiagram`/`WebLANDiagram` instance,
since Terminal Guide isn't really a "this Mac broadcasting to a receiver" relationship the way the
other two Sharing features are; it's a CLI session, so this shows that directly. A mock terminal
window (hardcoded dark chrome — not theme-adaptive, deliberately, the same way a screenshot of
another app's own UI wouldn't re-theme itself — with three decorative traffic-light dots) types out
`$ hdhr_guide` character by character, holds with a blinking cursor, then resets and repeats.
Respects Reduce Motion (freezes on the fully-typed line with cursor showing) and is
`.accessibilityHidden(true)`, same conventions as every other diagram here.

### Step 4 — Recording FEED
Leads with `NetworkFlowDiagram(...)` (see its own section below), then a short plain-language
explanation of the virtual-tuner relay (`docs/VirtualTunerService.md`) — what it is and what it
can't do — then one `Toggle` bound to local `@State relayEnabled` (default `false`, mirroring
`state.config.Virtual_tuner_relay_enabled`'s own default). Same commit-on-Finish pattern
as every other field here: `finish()` writes it to `state.config.Virtual_tuner_relay_enabled` and,
if it changed, calls `state.updateVirtualTunerPresence()` directly so a recording already in
progress (only realistically possible via a mid-session reset from Settings → Maintenance) reflects
the new setting immediately rather than waiting for that recording to end. `SettingsView`'s own
Web LAN → Recording FEED toggle is the same setting, same wording, reachable any time after this
wizard closes — this screen exists purely so a first-time user sees the explanation once, unprompted.

### `NetworkFlowDiagram` (`Views/NetworkFlowDiagram.swift`)
Self-contained animated view, parametrized (icons/badge colors/captions) so it's reusable for any
future point-to-point "this Mac ↔ one specific other party" explainer — currently used only by
Step 4, Recording FEED, whose "this Mac's recording, that Mac watching it" relationship is
genuinely one-to-one (Web LAN and Terminal Guide moved to their own purpose-built diagrams above,
see those sections for why). Two SF Symbols (`desktopcomputer` on both sides for FEED — another
Mac, not a generic device) connected by a dashed line, drawn in a `GeometryReader` so it scales to
whatever width its container gives it. A single `TimelineView(.animation)` drives two independent,
looping effects, each run twice at a half-cycle phase offset so the line/device never sits visibly
empty between beats:
- **Ripple rings** — expanding, fading circles centered on the left ("this Mac") device, colored by
  `leftBadgeColor` (red for "Recording") — the same "broadcasting outward" language `SettingsView`'s
  About-tab `SignalRing` already uses for the app icon's own pulse effect.
- **Packets** — small dots traveling along the line from the left device to the right one, colored
  by `rightBadgeColor` (`watchNowBlue` by default — "whoever's receiving it"), fading in/out over
  the first/last 15% of the line so they don't pop at either device's edge.

Both cycle lengths (1.6s packets, 1.8s rings) are independent named constants, not tied to each
other or to any other animation in the app. Respects Reduce Motion — freezes to one static dot
at the line's midpoint instead of animating (still shows the two devices are connected, just
without motion), the same "different code path, not a faster version" convention the Intro Splash
above uses. Marked `.accessibilityHidden(true)`: purely decorative, and the diagram says nothing
the surrounding prose doesn't already say in words — a screen reader user isn't missing content by
skipping it.

### Step 5 — Notification Timing
Binds to local `@State` (`upNextMinutes`, `recordingSoonMinutes`). Committed to
`state.config.Notify_upnext` / `.Notify_recording` on Finish.

## Slide transition mechanism

```swift
private var slideTransition: AnyTransition {
    goingForward
        ? .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                       removal:   .move(edge: .leading).combined(with: .opacity))
        : .asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                       removal:   .move(edge: .trailing).combined(with: .opacity))
}
```

`goingForward` is a local `@State` bool set immediately before the `withAnimation` block that
changes `step`, in the same button action — both mutations land in the same animation transaction,
so the transition the next render picks up already reflects the direction that button implies
(Next → forward/right-to-left exit, Back → mirrored). This is genuinely new code — `AddShowView`
has no equivalent; its own step swap only animates the outer window frame size, not content.

## Auto-open-on-launch + donation-nag suppression

`hdhr_VCRApp.swift` opens this window automatically once, on a fresh install (or after an upgrade
from a version predating `AppConfig.First_run_wizard_shown`), via the same
launch-guard-flag-plus-`.onAppear` pattern the donation nag already uses (see
`docs/DonationNagView.md`) — a local `@State private var launchFirstRunWizardShown` checked before
`launchDonationNagShown`, so a genuinely first launch shows this wizard first.

**The launch-time check reads a synchronous config peek, not `appState.config`** — same reasoning
as the Dock-icon-visibility logic a few lines above it in `hdhr_VCRApp.init()`: `AppState`'s real
config load happens inside an unawaited `Task { await startup() }`, so `appState.config` can still
read `AppConfig()`'s bare defaults at the exact moment the launch `.onAppear` fires, even for a
returning user whose real persisted `First_run_wizard_shown` is `true` — which would reopen the
wizard on every single launch for them, not just once. `init()` already computes a synchronous
`ConfigManager().load()?.config` peek for the Dock icon decision; a `@State private var
needsFirstRunWizard: Bool`, set from that same peek (`!(cfg?.First_run_wizard_shown ?? false)`),
is what `openFirstRunWizardIfNeeded()`'s guard actually reads — never the live `appState.config`
value at launch time.

The donation nag is suppressed until this wizard is dismissed: `openDonationNagIfNeeded()` gained a
leading `guard !needsFirstRunWizard else { return }` (same race-free flag, not `appState.config`
directly, for the same reason), and a
`.onChange(of: appState.config.First_run_wizard_shown)` re-checks the nag the moment this wizard's
flag flips true (mirroring the existing `pendingDonationNagTrigger` re-check after a show is
added) — this `onChange` fires well after launch, so `appState.config` is reliably loaded by then;
it also flips `needsFirstRunWizard` back to `false` so that flag stays in sync for any later call.
The two windows never compete for focus on a brand-new install, and the nag still appears right
after the wizard closes (if not `Donation_unlocked`).

## Reset from Settings

Settings → Maintenance → "Reset First-Run Setup" (`docs/SettingsView.md`'s Maintenance section)
clears `First_run_wizard_shown` and calls `openWindow(id: "first-run-wizard")` immediately, in one
action — matching every other Maintenance button's "run now, report a status string" shape. Two
genuinely different reopen scenarios both need to reset the wizard's `@State`, and are handled by
two different call sites (calling `resetForFreshRun()` twice in some edge case is harmless):

- **Wizard still open/visible in the background** when Reset is clicked: `openWindow(id:)` on an
  already-open single-instance `Window` scene just refocuses it without re-running `.onAppear`
  (`hdhr_VCRApp.swift`'s own comment on this) — caught by
  `.onChange(of: state.config.First_run_wizard_shown)`, which fires on the observed `true → false`
  transition.
- **Wizard was fully closed** (Escape, red close button) before Reset is clicked: **this Window's
  `@State` persists across even a full close** — reopening later still refires `.onAppear` (a
  genuine close→open transition), but with *stale* flags from the previous run, not
  freshly-initialized ones (confirmed empirically while building the intro splash: an early version
  relied on `.onChange` alone and silently skipped replaying the splash on every reopen after a full
  close, since by the time the reopened view attaches, `First_run_wizard_shown` is already `false`
  and there's no further transition for `.onChange` to observe — `.onAppear` fires instead, with
  `hasPlayedIntro` still `true` from before). `.onAppear` now separately checks
  `!state.config.First_run_wizard_shown` itself and calls the same `resetForFreshRun()` if so — that
  boolean is the reliable "this appearance needs a fresh run" signal for *both* a genuine first
  launch and this reopen-after-full-close case, independent of which lifecycle callback actually
  fires.

`resetForFreshRun()` clears `hasLoadedInitialValues`/`hasFinished`/`hasCheckedNetwork`/
`hasPlayedIntro` and resets `step` to `.recordingDefaults` in one place, shared by both call sites —
so a reset (via either path) always replays the intro splash and shows fresh values, not stale ones.

## Key Functions

| Function | Purpose |
|---|---|
| `loadCurrentValuesIfNeeded()` | Reads current `AppConfig` values into local `@State`, once per window lifetime (or again after a reset — see above) |
| `resetForFreshRun()` | Clears all the "has this run once already" flags + resets `step`; called from both `.onAppear` and the `onChange` reset block — see "Reset from Settings" |
| `playIntroIfNeeded()` | Enters `.intro` once per fresh run, unless Reduce Motion is on |
| `finishIntro()` | The splash's hand-off — same `withAnimation`/target shape as `goNext()` |
| `goNext()` / `goBack()` | Sets `goingForward` and animates `step` in one action |
| `finish()` | Commits all fields to `state.config`, sets `First_run_wizard_shown = true`, saves, triggers the finish-flourish, dismisses after a 380ms delay |
| `chooseFolder()` | `NSOpenPanel` directory picker, same shape as `SettingsView.chooseFolder()` |
| `TunerDiscoveryCard`'s `discoveryStatus` (on `FirstRunWizardView`) | Derives the card's device-aware `TunerDiscoveryStatus` from the existing checking/confirmed/notFound tri-state + `state.devices`/`state.lineups` |
| `prefetchIntroArtIfNeeded()` | Warms `ChannelIconCache` for a few channels' current-show posters (favorites first) while the intro splash plays — see "Background art prefetch during the splash" under Step 1 |
| `FirstRunSplashContent.symbols` | The fixed six-glyph tile content set — see "Tile content" above |

## What Still Needs Doing

- [ ] No skip-to-Settings shortcut — a user who wants to change something not covered here (e.g.
      Discord) has to finish the wizard first, then separately open Settings.
- [x] The intro splash's tile-choreography numeric values (spring response/damping, per-tile
      stagger, beat durations) were a first tuning pass, confirmed to look right via live
      screenshots during development but not further refined — real user feedback ("it goes by
      very fast") confirmed it needed one: `introSplashSpeedScale` now retimes the whole thing
      uniformly (see "Pacing" above) rather than the relative proportions themselves needing
      redesign.
- [ ] `TunerDiscoveryCard`'s multiple-devices state was verified by inspection and via a single
      real device's `.foundSingle` path live (`HDHR-105404BE · 2 tuners · 112 channels ready`,
      confirmed via screenshot) — the `.foundMultiple` list rendering has not been device-tested
      live (would need a second physical/virtual HDHomeRun on the test network).
- [ ] `wizard-skip-intro`'s accessibility identifier + `.help()` text were confirmed reachable via a
      manual System Events probe during development, but `WindowNavigationTests.swift` itself
      hasn't been extended with an automated check for it yet.
