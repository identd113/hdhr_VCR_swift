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
argues for. The step-progress dots sit directly below this, inside the same header `VStack` — 2
small 8pt circles, filled accent-color = current step, hollow gray = other step (same visual
pattern as `AddShowView`'s step indicator). **Not rendered during `.intro`** (`if step != .intro`
around both the header and the bottom nav bar) — the splash has no header/nav chrome of its own,
just its own Skip control (see below).

**Finish-flourish glow**: the header icon sits in a `ZStack` with a `RadialGradient` circle behind
it, driven by a `keyframeAnimator(initialValue: FinishGlowValues(), trigger: finishGlowTrigger)` —
same visual language as `DonationNagView`'s own appear-glow, reused here on *completion* instead.
Unlike `DonationNagView`'s plain appear→fade Bool, this needs to rest *hidden* both before and
after the flourish (nothing should show behind the icon while the user is still on Step 1/2) with a
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
`.overlay` attached after the panel's `.shadow(...)` (not inside the clipped `VStack`) —
`.overlay` content is unclipped by default, so tiles can fly past the panel's own rounded-rect
edges within the 640×480 stage set up for `.intro` (see "Overall window" above).

**Layout**: 6 tiles (78×110pt, 2:3 poster aspect, 10pt corner radius) in a generative fan —
evenly spread -14°…+14° rotation, x-offsets centered across ~550pt, alternating ±20/24pt vertical
offset for a two-row depth read. Each tile's "flight" vector is its own rest-offset direction
normalized to a fixed 520pt magnitude, so every slot clears the stage regardless of how close to
center it starts.

**Choreography** (~2.1s total, per-tile staggered):
1. **Arrive** (0–~50–300ms, staggered `i×50ms`) — springs from center (scale 0.4, opacity 0) out to
   its rest offset/rotation. Response tuned to 0.3 (down from an initial 0.42/0.5) after live
   screenshots showed the heavier-damped spring still visibly mid-transit past the intended arrive
   beat — tightened to settle in the same beat as the faster opacity/scale tracks.
2. **Hold** — tiles sit fanned out; title ("Welcome to hdhrVCRplus" + subtitle) fades/slides in
   underneath during this window.
3. **Depart** (starting 1050ms, staggered `i×60ms`, same order as arrival) — each tile flies out
   along its own vector with an added ±35° spin (matching its fan side), fading to 0 opacity.
4. Overlay fades out as `step` changes underneath (the `.transition(.opacity)` on
   `IntroSplashOverlay` itself, riding the same `withAnimation` as the hand-off).

**Composition model** — two independent `keyframeAnimator`s per tile (Arrive, Depart), extending
`StarburstBadge.swift`'s own documented rule (stacked `scaleEffect`s multiply, stacked
`rotationEffect`s add) to `.offset` (adds) and `.opacity` (multiplies): `PosterTileDepartValues`
starts neutral (0 offset, 0° rotation, ×1 scale, ×1 opacity) and contributes nothing until its own
trigger fires, exactly like `StarburstBadge`'s celebration track staying neutral until tapped. Both
value types are file-scope (`@KeyframesBuilder` type inference requirement, same as
`StarburstBadge`'s own note) with a nested-`AnimatablePair` `animatableData` — the same technique
`StarburstBadge` uses for 2 properties, extended here to 5 (x, y, rotation, scale, opacity).

**Tile content — hybrid cascade, verified live against real device/guide data**:
1. Real show posters already loaded (`state.guideByDevice`'s `GuideChannel.Guide` entries'
   `ImageURL`) — used immediately if ≥6 already exist (the common case on a "Reset First-Run Setup"
   replay of an already-working install).
2. Otherwise (the true-first-launch case, where guide/EPG data is very unlikely to exist yet —
   `AppState.startup()` only calls `fetchAllGuides()` after a full discovery pass, racing well
   behind the wizard's near-instant launch): polls up to ~900ms for `state.devices` to populate,
   calls `state.ensureGuideLoaded(for:)` once (synchronous/fire-and-forget, not awaitable — see that
   function's own signature) on the first found device, and re-polls for the remainder of the
   budget.
3. Per tile slot independently: pooled poster URL → pooled `state.channelImageURLs` channel-logo
   URL → generated placeholder (one of 6 orange/red/amber-family gradient + SF Symbol pairs, so an
   all-placeholder run still reads as a designed icon set). Both image tiers resolve via
   `ChannelIconCache.shared.image(for:)` — reused deliberately as a generic URL→NSImage cache
   despite its "channel icon" name, rather than writing a second image loader.

**Skip**: an always-visible `.plain`/`.tertiary` "Skip" button, bottom-trailing, `.help("Skip the
intro animation")` + `accessibilityIdentifier("wizard-skip-intro")` — confirmed reachable via System
Events by `.help` text (not `name`/`description`, which come back empty for this button — same
finding `WindowNavigationTests.swift` already documents for other wizard controls). Tapping it
cancels the in-flight content-collection task and performs the same hand-off immediately.

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
  list (`● HDHR-XXXXXXXX · N tuners`) replaces the single identity line — not a card grid, since
  Step 1's `Form` is already vertically tight and a grid there would overpower the actual
  recording-defaults content.
- **Not found**: unchanged copy/behavior (the "Open Privacy Settings" button below) — deliberately
  no new animation on this state; whimsy belongs in progress/success states, not failure states.

`checkNetworkAccessIfNeeded()` itself (the actual discovery/confirmation logic feeding this card via
`discoveryStatus`, a presentational computed property) is unchanged from before this redesign — see
"Local Network permission" below.

Save folder (`NSOpenPanel` picker, same control shape as `SettingsView`'s Recording tab), default
transcode profile, min free disk (GB), and failure threshold — each with an `InfoButton` popover
explaining what it does. This wizard and `SettingsView`'s Recording section now share these four
rows via one view, `RecordingDefaultsFields` (`Views/RecordingDefaultsFields.swift`) — no separate
doc for it since it has no independent visual identity beyond what's described here and in
`docs/SettingsView.md`'s Recording section.

### Step 2 — Notification Timing
Up Next / Recording Soon lead-time minutes, same `Stepper` controls and warning banner (shown when
the recording alert would fire at or after Up Next) as `SettingsView`'s Notifications tab.

**Nav bar** (bottom): Back (step 2 only, `.plain` style, `.secondary` foreground — a quiet
secondary action) and Next/Finish, right-aligned, Next/Finish `.borderedProminent`. A `Divider`
above (`opacity(0.5)`, same softened-divider treatment used below the header, so the dividers read
as subtle separators against the material background rather than harsh full-contrast lines).

## Intent

A first-launch-only setup flow covering the handful of settings worth deciding before using the
app: where recordings are saved and how, and how much notice you get before one starts. Everything
else (Discord, Guide, Sharing) is left for `SettingsView` — this wizard is deliberately narrow, not
a full onboarding tour.

Every field defaults to the **current** config value (`loadCurrentValuesIfNeeded()`, called from
`.onAppear`), not a hardcoded factory default — re-running the wizard later via the reset button
(see "Reset from Settings" below) shows what's actually configured, not `AppConfig`'s factory
defaults.

---

## Steps

```swift
enum Step: Int { case intro, recordingDefaults, notificationTiming }
```

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

### Step 2 — Notification Timing
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
| `FirstRunSplashContent.collect(state:count:)` | The splash's hybrid poster→logo→placeholder tile-content cascade |

## What Still Needs Doing

- [ ] No skip-to-Settings shortcut — a user who wants to change something not covered here (e.g.
      Discord) has to finish the wizard first, then separately open Settings.
- [ ] The intro splash's tile-choreography numeric values (spring response/damping, per-tile
      stagger, beat durations) are a first tuning pass, confirmed to look right via live screenshots
      during development but not further refined — a candidate for another pass if it ever feels
      off in practice.
- [ ] `TunerDiscoveryCard`'s multiple-devices state was verified by inspection and via a single
      real device's `.foundSingle` path live (`HDHR-105404BE · 2 tuners · 112 channels ready`,
      confirmed via screenshot) — the `.foundMultiple` list rendering has not been device-tested
      live (would need a second physical/virtual HDHomeRun on the test network).
- [ ] `wizard-skip-intro`'s accessibility identifier + `.help()` text were confirmed reachable via a
      manual System Events probe during development, but `WindowNavigationTests.swift` itself
      hasn't been extended with an automated check for it yet.
