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

**Redesigned again 2026-08-28** (same day, second pass) — replaced the plain network-status row
with a device-aware `TunerDiscoveryCard` (see its own section below). (That pass also added a
one-time animated `.intro` step; **removed 2026-10-14** — see "Look and first-run hand-off" below.)

**Look changed 2026-10-14**: the `.thickMaterial` panel described above is now the launch splash's own look — see
"Look and first-run hand-off". Everything else about the chrome (20pt rounded corners, faint white border, the drop
shadow, hidden title bar) is unchanged.

**Fixed size**: a 520pt-wide panel (`LaunchCard.width`, shared with the splash and donation cards; was 460 until 2026-10-15) at `FirstRunWizardView.stepHeight` (see below) for every step. `.windowResizability(.contentSize)`
tracks it. Each `Form` also gets `.scrollContentBackground(.hidden)` (lets the panel's own dark backdrop show through
instead of the Form's own opaque grouped-list card, so the two don't read as a card nested inside a panel) and
`.fixedSize(horizontal: false, vertical: true)` (List-backed Forms otherwise claim more vertical space than their rows
need even without an outer fixed height).

**Fixed step height + pinned footer (2026-10-10)**: every step is a fixed `min(600, screen − 80)` pt tall (600 when shown as a launch card; the splash scales the whole card) (`FirstRunWizardView.stepHeight` — a *bounded* frame), the step content sits in a `ScrollView`, and the header and Back/Next row are outside it, so Next can never be pushed off the bottom (Step 1 clipped it on a live Mac; a first attempt with only a `minHeight` made it worse). The window itself is also sized explicitly on every step change (`WindowAction` → `setContentSize` + `center`), because a window AppKit restored at an earlier, shorter frame ignored `.windowResizability(.contentSize)`. The unbounded-ideal-height `ScrollView` that crashed the Recording FEED step is a different shape from this; all seven steps were walked through after the change.

**Header band**: the app icon (`appIconImage`, `Sources/hdhr_VCR/AppIcon.swift` — the same
global already used by `DonationNagView`/`SettingsView`/the menu bar icon) at `headerIconSize` (44pt) in a rounded
rect, next to "Welcome to hdhrVCRplus" (20pt bold `.rounded`) and a one-line subtitle, giving the window the
same "unmistakably this app's own chrome" identity `DonationNagView`'s header comment already
argues for. The step-progress dots sit directly below this, inside the same header `VStack` — one
8pt circle per entry of `orderedSteps` (6 or 7 depending on `FEED_feature_enabled`), filled accent-color = current step, hollow gray = other steps (same visual
pattern as `AddShowView`'s step indicator).

**Finish-flourish glow**: the header icon sits in a `ZStack` with a `RadialGradient` circle behind
it, driven by a `keyframeAnimator(initialValue: FinishGlowValues(), trigger: finishGlowTrigger)` —
same visual language as `DonationNagView`'s own appear-glow, reused here on *completion* instead.
Unlike `DonationNagView`'s plain appear→fade Bool, this needs to rest *hidden* both before and
after the flourish (nothing should show behind the icon while the user is still on any earlier step) with a
visible pulse in between — a two-state `withAnimation` toggle can't do that (it can only rest at
one of its two endpoints), so it's a keyframe pulse instead: `FinishGlowValues`' own `initialValue`
is hidden (scale 0.7, opacity 0), and pressing Finish increments `finishGlowTrigger`, popping the
glow to scale 1.3 while opacity ramps 0→0.9→0 over 0.35s, alongside the Finish button's label
morphing to a checkmark (`finishButton`, `.transition(.scale.combined(with: .opacity))`, 0.18s; the checkmark carries `.accessibilityLabel("Finished")`). With Reduce Motion on, the glow is skipped and the checkmark just fades in.
`dismiss()` fires after a separate 380ms delay (`finish()`'s `finishTask`) — long enough to see the
flourish, short enough not to feel like a stall. `.onExitCommand`/the red-close-button still call
`dismiss()` directly and immediately regardless of this pending task, and `finish()` itself no-ops
on a double-click during the delay (`guard !hasFinished else { return }`). Because the animator's
rest state is always its own `initialValue`, there's nothing to reset in `resetForFreshRun()` for a
"Reset First-Run Setup" replay — an earlier boolean-based version of this got that wrong (stayed
"flourished"/hidden across a reset instead of resting at the pre-flourish visible pulse state).

**Step content slides horizontally** — Next moves the new screen in from the right while the old
one exits to the left; Back mirrors it. This is a real content transition
(`.move(edge:).combined(with: .opacity)`, 0.25s ease-in-out; with Reduce Motion on it is a 0.15s cross-fade instead), distinct from `AddShowView`'s
window-frame-only animation (that view has no content transition at all). Each screen carries a
distinct `.id(Step.X)` — without it SwiftUI may just diff the two similarly-shaped `Form`s in
place instead of treating the swap as an insert/remove pair, and the transition would silently
never fire.

Escape, the red close button, or clicking Finish all count as "dismissed" — this is a one-time
onboarding flow, not a resumable/cancelable form. Only Finish commits the field values; closing any
other way just marks the wizard as seen and discards whatever was typed.

### Look and first-run hand-off
**The `.intro` step and `Views/FirstRunIntroSplash.swift` (the six-glyph tile animation, its Skip button, the
double-click-the-logo replay and the art prefetch that fed it) were removed 2026-10-14**: a new install already gets the
launch splash, and two different opening animations in a row read as two unrelated things. The wizard now opens at
Step 1 and shares the splash's look instead.

**Look** (same family as `LaunchSplashView`; see `docs/LaunchSplash.md`): always dark (`.preferredColorScheme(.dark)` on the
scene plus `.environment(\.colorScheme, .dark)` on the panel, whatever the Appearance setting says), a near-black
`CardBackdrop` in `Views/EmbeddedCard.swift` (formerly the wizard's private `WizardBackdrop`; `Color(white: 0.075)`, a soft orange `RadialGradient` from the top-left logo corner, a foot vignette)
instead of `.thickMaterial`, the app logo at `headerIconSize` (44pt) with the splash's soft shadow and rounded corners,
the title in the splash's `.rounded` bold face ("Welcome to hdhrVCRplus", 20pt) with the subtitle at white 0.8. The window
itself is made clear (`isOpaque = false`, `backgroundColor = .clear`, system shadow) in the same `WindowAction` that
sizes and centres it, so the rounded panel floats rather than sitting on a rectangle. (As a launch card inside the splash it draws no panel of its own — the splash's persistent, blended panel is behind it.)

**First-run hand-off** (new install only; rewritten 2026-10-15): `hdhr_VCRApp` no longer opens the wizard at launch when the
splash is going to run. The wizard is shown as a **card inside the splash's own window** (`LaunchSplashView.runCards`): the splash's
card (logo, version, checklist) slides out to the left, the wizard slides in from the right over the same poster wall (dimmed 40 % over the wall's own area only, so the rest of the screen isn't darkened,
frozen), and when the wizard closes the next card (the donation card, if due) slides in the same way — exactly one card visible at a
time. The view reads `\.embeddedCardClose` (`Views/EmbeddedCard.swift`): when set it calls that instead of `dismiss()` (Finish,
Escape) and skips its `WindowAction` block (size/centre/clear background — the splash window is not its to configure).
`AppState.launchSplashHandsOffToWizard` (set just before the splash opens) tells the splash to host it. After the card slides in the splash grows the panel to 100 % scale and fades the wall (`LaunchSplashView.settledFull`, docs/LaunchSplash.md "Settling to full size"). The logo-glide into the
header icon and `firstRunWizardEntrance` were removed with this change. Full sequence: `docs/LaunchSplash.md`. If the splash never
runs (Reduce Motion, "Show launch splash" off, tests) the wizard opens directly at launch in its own window as before; so does
Settings → Maintenance → "Reset First-Run Setup" (no splash, normal window level).

### Step 1 — Recording Defaults
**Tuner discovery card** (`Views/TunerDiscoveryCard.swift`, top of Step 1, own `Section`) —
device-aware replacement for the original plain network-status row. Four states:
- **Checking**: an antenna glyph (`antenna.radiowaves.left.and.right`) pulsing via the native SF
  Symbols `.symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: !reduceMotion)`
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
- **Not found**: unchanged copy plus a `.bordered` "Check Again" button (`wizard-tuner-check-again`, via `TunerDiscoveryCard.onCheckAgain`) beside "Open Privacy Settings" — it resets `hasCheckedNetwork`, sets the card back to Checking and re-runs `checkNetworkAccessIfNeeded(force: true)` (a full rediscovery even if Local Network access was already confirmed) — deliberately
  no new animation on this state; whimsy belongs in progress/success states, not failure states.

`checkNetworkAccessIfNeeded()` itself (the actual discovery/confirmation logic feeding this card via
`discoveryStatus`, a presentational computed property) is unchanged from before this redesign — see
"Local Network permission" below.
<!-- DOC-DRIFT: no "Local Network permission" section exists anywhere in this file — the sentence
above points at one. Flagging rather than guessing the intended target; find/restore or retarget
the cross-reference. -->

Save folder (`NSOpenPanel` picker, same control shape as `SettingsView`'s Recording tab), default
transcode profile, min free disk (GB), failure threshold, and Time Machine exclusion mode
(off/per-recording/per-show-folder — added 2026-09-27) — each with an `InfoButton` popover
explaining what it does. This wizard and `SettingsView`'s Recording section now share these rows
via one view, `RecordingDefaultsFields` (`Views/RecordingDefaultsFields.swift`) — no separate
doc for it since it has no independent visual identity beyond what's described here and in
`docs/SettingsView.md`'s Recording section.

### Step 3 — VLC Required, added 2026-09-12
Explains that hdhrVCRplus uses VLC's own playback engine for every watching feature (live TV,
in-progress recordings, a remote FEED session) — recording itself never needs VLC, only watching
does. Added the same day the external "Open in VLC" feature (`Watch_in_VLC` config setting,
`AppState.watchInVLC`/`watchRecordingInVLC`) was removed entirely — that removal didn't reduce the
VLC dependency at all, since the in-app player itself dynamically loads libvlc from an installed
VLC.app; every watch-triggering surface elsewhere (`MenuContent`, `WatchNowView`, `SettingsView`'s
FEED transcode picker) already dims/labels itself `" (Requires VLC)"` via
`VLCBridge.shared.isAvailable`/`gatedLabel` when VLC is missing, so this step makes that requirement
visible up front rather than a new user discovering it only once they click a dimmed button later.

A live status row (`checkmark.circle.fill`/`exclamationmark.triangle.fill`, green/orange) reflects
`VLCBridge.locateApp() != nil`, re-checked in `.onAppear` (fires every time this step becomes
visible, not just once at wizard launch), whenever the app is re-activated (`NSApplication.didBecomeActiveNotification` — `AppState.checkVLCHotInstall` only posts a relaunch notification, it never touches this step's `vlcInstalled`) and via a `.bordered` "Check Again" button — the realistic flow is
land here, see "not installed," switch away to install it, come back and re-check before moving on.
When not installed, offers one of two install paths depending on `homebrewInstalled`
(`FileManager.fileExists` on `/opt/homebrew/bin/brew` or `/usr/local/bin/brew`, no `Process()`
spawn needed just to check):
- **Homebrew detected**: a "Copy Install Command & Open Terminal" button (`installVLCViaHomebrew()`) copies
  `brew install --cask vlc` to the clipboard and opens Terminal.app via
  `NSWorkspace.shared.open(_:)` (the same technique `SettingsView.openInTerminal` already uses for
  the Terminal Guide feature) — deliberately **not** `Process()` or AppleScript/System-Events
  keystroke simulation to type or run it automatically. A brew-install UI existed once and was
  removed entirely (2026-08-19, `docs/MAS_COMPLIANCE.md`) specifically because spawning `brew` via
  `Process()` is forbidden under Mac App Store sandboxing; typing the command into Terminal via
  System Events would reopen the same class of problem via the Apple Events automation entitlement
  instead — copy-and-paste needs neither. Shows a one-line confirmation ("Command copied — switch
  to Terminal, paste (⌘V), and press Return.") after clicking.
- **No Homebrew**: a "Download VLC" button opens `videolan.org`'s own macOS download page in the
  default browser instead.

Either way, a closing note explains that coming back to the app after installing is what matters —
`AppState.checkVLCHotInstall()` (fires on `didBecomeActiveNotification`, already existed before this
step) detects the fresh install automatically and prompts a relaunch, which is what actually loads
libvlc into the running process. This step has no config of its own to persist — no
`loadCurrentValuesIfNeeded()`/`finish()` involvement, unlike every other step's `@State` fields.

### Step 4 — Web LAN
A purpose-built animated diagram (`WebLANDiagram`, `Views/WebLANDiagram.swift` — see its own
section below) — this Mac fanning out to three different device icons — above a short explanation
and one `Toggle`, **Enable Web LAN**. See "Steps" below for the config-commit details.

### Step 5 — Terminal Guide
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

### Step 6 — Recording FEED (Beta)
**Visible by default as of v2.5.0** — `orderedSteps` (see "Steps" below) includes `.recordingRelay`
whenever `state.config.FEED_feature_enabled` is `true` (default as of v2.5.0, config-file only —
see `docs/VirtualTunerService.md`'s top note); was hidden from 2026-09-10 until then, and a
first-run user during that window never saw this step at all. Nothing about the screen itself
changed either way.

An animated diagram (`NetworkFlowDiagram`) showing two devices connected by a line — signal rings
broadcasting from the recording Mac, small packets flowing along the line to the watching one —
above two short paragraphs of plain-language explanation and one `Toggle`. The headline and both
the screen's own body text and the toggle's `InfoButton` carry a "(Beta)"/beta-caveat callout,
added 2026-09-07 — the playback-hiccups and CC-track-switching parts of that original caveat are
resolved (CC confirmed working 2026-09-13), but audio track switching on the watching Mac is still
an open, unconfirmed question — see `ISSUES.md`. See "Steps" below for the config-commit details.

### Step 7 — Notification Timing
Up Next / Recording Soon lead-time minutes, same `Stepper` controls and warning banner (shown when
the recording alert would fire at or after Up Next) as `SettingsView`'s Notifications tab.

**Return key**: Next and Finish carry `.keyboardShortcut(.defaultAction)`, so Return advances (Escape still closes the wizard without a confirmation).

**Nav bar** (bottom): Back (every step but the first, `.bordered` — changed 2026-10-15 from a quiet plain-text button so it stays obvious
on the dark launch card) and Next/Finish, right-aligned, Next/Finish `.borderedProminent` (Finish only on
the last step). A `Divider` above (`opacity(0.5)`, same softened-divider treatment used below the
header, so the dividers read as subtle separators against the material background rather than harsh
full-contrast lines).

## Intent

A first-launch-only setup flow covering the handful of settings worth deciding before using the
app: where recordings are saved and how, how much notice you get before one starts, and — since
2026-09-04 — every LAN-facing feature this app's Settings groups under its "Sharing" tab (Enable
Web LAN, Terminal Guide, Recording FEED), each its own step, since each is now off by default and
worth a one-time explanation of what it actually does before a first-time user goes looking for it
in Settings. Since 2026-09-12, also a hard requirement rather than a Settings feature: VLC.app must
be installed for any watching feature to work at all, so Step 3 explains that plainly and offers an
install path (Homebrew or a direct download) before a first-time user hits a dimmed, unexplained
"Watch" button somewhere later. Everything else (Discord, Guide) is still left for `SettingsView` —
this wizard covers "what's off by default (or a hard external dependency) and needs a plain-English
explanation," not a full onboarding tour of every setting in the app.

Every field defaults to the **current** config value (`loadCurrentValuesIfNeeded()`, called from
`.onAppear`), not a hardcoded factory default — re-running the wizard later via the reset button
(see "Reset from Settings" below) shows what's actually configured, not `AppConfig`'s factory
defaults.

---

## Steps

```swift
enum Step: Int, CaseIterable { case recordingDefaults, airChannels, vlcRequired, webLAN, terminalGuide, recordingRelay, notificationTiming }
```

Navigation (`goNext()`/`goBack()`) walks a single `orderedSteps` — an **instance** computed
property (not a static array), so it can conditionally drop `.recordingRelay` when
`FEED_feature_enabled` is off (no longer the default as of v2.5.0). **Derived from `Step.allCases`
with an opt-*out* filter,
not a hand-typed literal array, as of 2026-09-11** (`Step` gained `CaseIterable` the same commit):
`Step.allCases.filter { switch $0 { case .recordingRelay:
config.FEED_feature_enabled; default: true } }` — `.recordingRelay` conditional on the flag, everything else
included by default. Replaces an earlier hand-typed array (`[.recordingDefaults, .webLAN,
.terminalGuide, .recordingRelay, .notificationTiming]` / without `.recordingRelay`) that itself had
replaced a 3-way ternary chain — that array shape reintroduced the same drift class one level up:
a new `Step` case compiled cleanly (the rendering `switch`/`stepTitle` are both exhaustive) but
could silently drop out of Next/Back navigation, the progress dots, and the VoiceOver step count if
this array wasn't separately remembered, mirroring the 2026-09-05 VoiceOver "Step N of X" fix's own
drift class one layer down. Deriving from `allCases` with an opt-out filter means a new case is
now included by default unless explicitly excluded — the safer failure mode.

The wizard always starts at `.recordingDefaults` (`@State private var step: Step = .recordingDefaults`).

### Step 1 — Recording Defaults
Binds to local `@State` throughout, including the save folder (`saveFolder`) — deliberately
**not** `@AppStorage`, unlike `SettingsView`'s live-bound `defaultSaveDirectory`: every field on
this screen only takes effect on Finish, so Choose…/Reset have to stay in local state too, or
they'd persist immediately even if the user backs out via Escape. `loadCurrentValuesIfNeeded()`
reads the current value from the same `"defaultSaveDirectory"` `UserDefaults` key `AddShowView`
and `SettingsView` already use (falling back to `Hdhr_setup_folder`, matching
`AppState.defaultSaveDir`'s own chain minus the final `localFallbackDir` step — an empty result
here just means "use the default," same as everywhere else); `finish()` writes it back to that
same key. Transcode/min-disk/fail-threshold/Time-Machine-mode commit to `state.config.Default_transcode` /
`.Min_disk_free_gb` / `.Fail_count_setting` / `.TimeMachine_exclude_mode` on Finish the same way.

### Step 3 — VLC Required
No `@State` field commits anywhere in `finish()` — `vlcInstalled`/`vlcInstallCopyFeedback` are
purely live-check/UI-feedback state, re-derived from `VLCBridge.locateApp()` on `.onAppear` and the
"Check Again" button, not settings. The only side effects a user can trigger on this screen
(clipboard write, opening Terminal.app or a browser) are fire-and-forget, nothing this wizard's own
save logic needs to know about.

### Step 4 — Web LAN
Covers `Web_server_enabled` ("Enable Web LAN," the LAN web server) on its own screen — one local
`@State sharingEnabled` bool (default `false`, mirroring `AppConfig`'s own default), introduced by
`WebLANDiagram()` (see its own section below) and a short paragraph.

`finish()` commits it to `state.config.Web_server_enabled` and, if it changed, calls
`state.setupWebServer()` immediately — the same changed-value-gated pattern `SettingsView.save()`
already uses, so Web LAN actually starts serving the moment this wizard closes rather than waiting
for the next unrelated settings save.

### Step 5 — Terminal Guide
Covers `Terminal_guide_enabled` ("Enable Terminal Guide") on its own screen, one step after Web
LAN — **not combined with it on one screen**, unlike an earlier version of this step (see the
summary section above for why: two `NetworkFlowDiagram` instances stacked together read as visually
redundant). The dependency is still enforced exactly as before, just across the step boundary
instead of within one screen: local `@State terminalGuideEnabled`'s `Toggle` is
`.disabled(!sharingEnabled)` and its label suffixed `" (Requires Web LAN)"` while `sharingEnabled`
is off — the same `sharingEnabled` bool Step 4 set, still in scope since both are plain
wizard-lifetime `@State`, not per-screen state. Because the toggle is SwiftUI-`.disabled` whenever
`sharingEnabled` is false, the wizard can never actually produce the (recoverable, but meaningless)
state of Terminal Guide on with Web LAN off *while moving forward through the wizard normally* —
though going back to Step 4, turning Web LAN off after having already turned Terminal Guide on
earlier, then returning here without touching the now-disabled Terminal Guide toggle, leaves
`terminalGuideEnabled` at its prior `true` value: accepted, not a bug, matching
`SettingsView.sharingView`'s own identical precedent (its Terminal Guide toggle doesn't force-reset
either — see `docs/SettingsView.md`, "Turning this off has no security effect").

`finish()` commits it to `state.config.Terminal_guide_enabled` as `terminalGuideEnabled && sharingEnabled` (so the stale-`true` case above is not saved) — no follow-up action needed (unlike
Web LAN, nothing has to be started/stopped for this flag; it's just read passively by `hdhr_guide`
and `/api/guide.json`).

### `WebLANDiagram` (`Views/WebLANDiagram.swift`)
Purpose-built for Step 4, not a themed instance of `NetworkFlowDiagram` — added 2026-09-04
alongside the step split above, replacing an earlier version that palette-swapped
`NetworkFlowDiagram`'s own two-device shape. Web LAN's real relationship (one Mac serving many
different *kinds* of devices) is genuinely different from Recording FEED's (one Mac connecting to
one specific other Mac), so this fans out instead: "this Mac" on the left (green badge, ripple
rings — same broadcasting language `NetworkFlowDiagram` uses) connects via three
separate dashed lines to three device icons on the right (`desktopcomputer`/`ipad`/`iphone`,
`watchNowBlue`), each receiving its own small traveling packet at a staggered phase offset (0,
0.33, 0.66 of the packet cycle) so the three arrivals read as a continuous fan-out rhythm rather
than three lines pulsing in lockstep. Respects Reduce Motion (freezes to three static dots, one per
line) and is `.accessibilityHidden(true)`, same conventions as every other diagram here.

### `TerminalTypingDiagram` (`Views/TerminalTypingDiagram.swift`)
Purpose-built for Step 5 — deliberately NOT another `NetworkFlowDiagram`/`WebLANDiagram` instance,
since Terminal Guide isn't really a "this Mac broadcasting to a receiver" relationship the way the
other two Sharing features are; it's a CLI session, so this shows that directly. A mock terminal
window (hardcoded dark chrome — not theme-adaptive, deliberately, the same way a screenshot of
another app's own UI wouldn't re-theme itself — with three decorative traffic-light dots) types out
`$ hdhr_guide` character by character, holds with a blinking cursor, then resets and repeats.
Respects Reduce Motion (freezes on the fully-typed line with cursor showing) and is
`.accessibilityHidden(true)`, same conventions as every other diagram here.

### Step 6 — Recording FEED (Beta)
Leads with `NetworkFlowDiagram(...)` (see its own section below), then a short plain-language
explanation of the virtual-tuner relay (`docs/VirtualTunerService.md`) — what it is and what it
can't do — then one `Toggle` bound to local `@State relayEnabled` (default `false`, mirroring
`state.config.Virtual_tuner_relay_enabled`'s own default). Same commit-on-Finish pattern
as every other field here: `finish()` writes it to `state.config.Virtual_tuner_relay_enabled` and,
if it changed, calls `state.updateVirtualTunerPresence()` directly so a recording already in
progress (only realistically possible via a mid-session reset from Settings → Maintenance) reflects
the new setting immediately rather than waiting for that recording to end. `SettingsView`'s own
Sharing → Recording FEED toggle is the same setting, same wording, reachable any time after this
wizard closes — this screen exists purely so a first-time user sees the explanation once, unprompted.

### `NetworkFlowDiagram` (`Views/NetworkFlowDiagram.swift`)
Self-contained animated view, parametrized (icons/badge colors/captions) so it's reusable for any
future point-to-point "this Mac ↔ one specific other party" explainer — currently used only by
Step 6, Recording FEED, whose "this Mac's recording, that Mac watching it" relationship is
genuinely one-to-one (Web LAN and Terminal Guide moved to their own purpose-built diagrams above,
see those sections for why). Two SF Symbols (`desktopcomputer` on both sides for FEED — another
Mac, not a generic device) connected by a dashed line, drawn in a `GeometryReader` so it scales to
whatever width its container gives it. A single `TimelineView(.animation)` drives two independent,
looping effects, each run twice at a half-cycle phase offset so the line/device never sits visibly
empty between beats:
- **Ripple rings** — expanding, fading circles centered on the left ("this Mac") device, colored by
  `leftBadgeColor` (red for "Recording") — the same "broadcasting outward" language `NetworkFlowDiagram` uses.
- **Packets** — small dots traveling along the line from the left device to the right one, colored
  by `rightBadgeColor` (`watchNowBlue` by default — "whoever's receiving it"), fading in/out over
  the first/last 15% of the line so they don't pop at either device's edge.

Both cycle lengths (1.6s packets, 1.8s rings) are independent named constants, not tied to each
other or to any other animation in the app. Respects Reduce Motion — freezes to one static dot
at the line's midpoint instead of animating (still shows the two devices are connected, just
without motion), the same "different code path, not a faster version" convention the launch splash uses. Marked `.accessibilityHidden(true)`: purely decorative, and the diagram says nothing
the surrounding prose doesn't already say in words — a screen reader user isn't missing content by
skipping it.

### Step 7 — Notification Timing
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
  freshly-initialized ones (an early version relied on `.onChange` alone and silently skipped the reset on every reopen after a
  full close, since by the time the reopened view attaches, `First_run_wizard_shown` is already
  `false` and there's no further transition for `.onChange` to observe — `.onAppear` fires instead,
  with the other "has run once" flags still set from before). `.onAppear` now separately checks
  `!state.config.First_run_wizard_shown` itself and calls the same `resetForFreshRun()` if so — that
  boolean is the reliable "this appearance needs a fresh run" signal for *both* a genuine first
  launch and this reopen-after-full-close case, independent of which lifecycle callback actually
  fires.

`resetForFreshRun()` clears `hasLoadedInitialValues`/`hasFinished`/`hasCheckedNetwork` and resets `step`
to `.recordingDefaults` in one place, shared by both call sites — so a reset (via either path) shows
fresh values, not stale ones.

## Key Functions

| Function | Purpose |
|---|---|
| `loadCurrentValuesIfNeeded()` | Reads current `AppConfig` values into local `@State`, once per window lifetime (or again after a reset — see above) |
| `resetForFreshRun()` | Clears all the "has this run once already" flags + resets `step`; called from both `.onAppear` and the `onChange` reset block — see "Reset from Settings" |
| `goNext()` / `goBack()` | Sets `goingForward` and animates `step` in one action |
| `finish()` | Commits all fields to `state.config`, sets `First_run_wizard_shown = true`, saves, triggers the finish-flourish, dismisses after a 380ms delay |
| `chooseFolder()` | `NSOpenPanel` directory picker, same shape as `SettingsView.chooseFolder()` |
| `TunerDiscoveryCard`'s `discoveryStatus` (on `FirstRunWizardView`) | Derives the card's device-aware `TunerDiscoveryStatus` from the existing checking/confirmed/notFound tri-state + `state.devices`/`state.lineups` |

## What Still Needs Doing

- [ ] No skip-to-Settings shortcut — a user who wants to change something not covered here (e.g.
      Discord) has to finish the wizard first, then separately open Settings.
- [ ] `TunerDiscoveryCard`'s multiple-devices state was verified by inspection and via a single
      real device's `.foundSingle` path live (`HDHR-105404BE · 2 tuners · 112 channels ready`,
      confirmed via screenshot) — the `.foundMultiple` list rendering has not been device-tested
      live (would need a second physical/virtual HDHomeRun on the test network).


## Step "Channels from the Air" (added 2026-10-21, right after Recording Defaults)
`Step.airChannels` (`airChannelsScreen`, title "Channels from the Air"): a short explanation (a cheap backup channel list read from what stations broadcast; about
**2026-10-24:** the step needs no permission switch: it is only the channel scan. A caption points to Settings → Over the Air for using the air for guide data (a separate choice).
three minutes; idle tuners only and it steps aside for a recording or a viewer; the air guide is only ever used if no other guide is available; it refreshes itself
once a day at the picked time) and `AirChannelsCard` (`Views/AirChannelsCard.swift`): **Scan the air for channels** (`wizard-air-scan`) starts a lineup-only
OTA scan *without opening the scan window* (`startOTAScan(lineupOnly:, showWindow: false)`: the wizard shows the progress itself); while it runs, a bar with
"N of 49 RF channels · M stations · K channels" and Cancel (`wizard-air-progress`, `wizard-air-cancel`, plus the "stepped aside" note if the scan yields); afterwards
"Found 18 stations with 118 channels." (`wizard-air-found`) or "No stations found" with an antenna hint (`wizard-air-none`), and "Scan again". With no tuner found yet the
card says so (`wizard-air-no-tuner`). Below the button (and under the found/none result) a caption line `AirLastScanLines` says "Channel list: last scanned Oct 21, 7:42 PM", "never scanned" or "scanning now…" (`ota-last-lineup`). Below the card, one **Rescan the channel list** picker (`wizard-air-schedule`: Never / Daily at HH:00, default 03:00) sets `OTA_lineup_hour` on Finish. Only the channel list is scheduled; the guide from the air is scanned only after a guide failure (prompt, Discord message, automatic start after an hour — docs/OTAGuide.md), and a full scan always reads the channel list first, then the guide. Entirely optional and non-blocking: Next works at any time, the scan keeps running in the background, and nothing is saved by Finish.
Skipping it still ends up with a list: `AppState.startScheduledOTALineupRefreshIfDue` runs the same scan daily at the chosen hour.
(The step dots and "Step N of M" labels derive from `orderedSteps`. Step order: 1 Recording Defaults, 2 Channels from the Air, 3 VLC, 4 Web LAN, 5 Terminal Guide, 6 Recording FEED (only while `FEED_feature_enabled`), 7 Notification Timing; the numbered sections above were renumbered to match.)
