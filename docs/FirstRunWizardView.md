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

**Width only is fixed (460pt)** — height is deliberately *not* declared, so the window sizes to
its content's own ideal height instead of stretching a shorter step's `Form` to fill an
arbitrary, too-tall frame (the old fixed 460 height left a large dead gray gap below Step 1's four
rows once the Form's own list background was accounted for — confirmed via a live screenshot
during the redesign, not just inferred from code). In practice `.windowResizability(.contentSize)`
measures once at window presentation against whichever step renders first, so the window still
effectively holds one height across the Next/Back transition (Step 2 has fewer rows than Step 1,
so it shows a bit of extra bottom space when reached) — a content-driven version of the original
"never resizes between them" property, not a hardcoded guess. Each `Form` also gets
`.scrollContentBackground(.hidden)` (lets the panel's own `.thickMaterial` show through instead of
the Form's own opaque grouped-list card, so the two don't read as a card nested inside a panel) and
`.fixedSize(horizontal: false, vertical: true)` (List-backed Forms otherwise claim more vertical
space than their rows need even without an outer fixed height).

**Header band** (new): the app icon (`appIconImage`, `Sources/hdhr_VCR/AppIcon.swift` — the same
global already used by `DonationNagView`/`SettingsView`/the menu bar icon) at 36×36 in a rounded
rect, next to "Welcome to hdhrVCRplus" (`.headline`) and a one-line subtitle, giving the window the
same "unmistakably this app's own chrome" identity `DonationNagView`'s header comment already
argues for — the old version had no branding/identification at all. The step-progress dots sit
directly below this, inside the same header `VStack` — still 2 small 8pt circles, filled
accent-color = current step, hollow gray = other step (same visual pattern as `AddShowView`'s step
indicator), just with real padding around them now instead of being crammed directly under the
traffic lights.

**Step content slides horizontally** — Next moves the new screen in from the right while the old
one exits to the left; Back mirrors it. This is a real content transition
(`.move(edge:).combined(with: .opacity)`, 0.25s ease-in-out), distinct from `AddShowView`'s
window-frame-only animation (that view has no content transition at all). Each screen carries a
distinct `.id(Step.X)` — without it SwiftUI may just diff the two similarly-shaped `Form`s in
place instead of treating the swap as an insert/remove pair, and the transition would silently
never fire.

Escape, the red close button, or clicking Finish all count as "dismissed" — this is a one-time
onboarding flow, not a resumable/cancelable form. Only Finish commits the field values; closing any
other way just marks the wizard as seen and discards whatever was typed.

### Step 1 — Recording Defaults
**Network status row** (new 2026-08-28, top of Step 1, own `Section`): a status line —
`ProgressView` "Looking for your HDHomeRun tuner…" while checking, green
`checkmark.circle.fill` "Tuner found on your network" once confirmed, or orange
`exclamationmark.triangle.fill` "No tuner found yet" with an "Open Privacy Settings" button if
nothing was found. Exists because `AppState`'s own launch-time discovery
(`hdhr_VCRApp`'s `Task{startup()}`) already runs — and already triggers macOS's one-time Local
Network permission alert — completely uncoordinated with anything on screen; a user could miss a
dialog that appeared and vanished before this wizard even rendered. `checkNetworkAccessIfNeeded()`
(`.task` on the wizard's outer body, guarded by `hasCheckedNetwork` so it runs once per wizard-open
— reset alongside `hasLoadedInitialValues` in the same `onChange(of: First_run_wizard_shown)` reset
block, so reopening via Settings' "Reset First-Run Setup" re-checks too) skips straight to
`.confirmed` if `state.config.Local_network_confirmed` is already `true`; otherwise it calls
`state.rediscoverDevices()` (same call `SettingsView`'s "Rediscover Devices" button uses) and, for
every device found, `state.ensureLineupLoaded(for:)` — discovering a device's presence isn't proof
of confirmed access on its own; `AppState.confirmLocalNetworkAccessIfNeeded()` only fires on an
actual successful lineup fetch (a real HTTP round trip), so this forces that within the wizard's
visible lifetime instead of waiting on the idle loop's own schedule. The "Open Privacy Settings"
button (`openPrivacySettings()`) opens `x-apple.systempreferences:com.apple.preference.security` —
**deliberately the bare Privacy & Security pane, not a Local-Network-specific deep link**: the
`?Privacy_LocalNetwork` anchor pattern many apps use was tested live on this macOS version during
development and did not land on the Local Network row, only the general pane (same fallback either
with or without the anchor) — button copy/detail text ask the user to navigate the last step
(Privacy & Security → Local Network) themselves rather than promising a jump that doesn't happen.

Save folder (`NSOpenPanel` picker, same control shape as `SettingsView`'s Recording tab), default
transcode profile, min free disk (GB), and failure threshold — each with an `InfoButton` popover
explaining what it does, reusing wording from the equivalent `SettingsView` rows.

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
enum Step: Int { case recordingDefaults, notificationTiming }
```

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
action — matching every other Maintenance button's "run now, report a status string" shape. If the
wizard window is already open in the background, `openWindow(id:)` on an already-open single-instance
`Window` scene just refocuses it without re-running `.onAppear`
(`hdhr_VCRApp.swift`'s own comment on this) — a `.onChange(of: state.config.First_run_wizard_shown)`
inside this view re-runs the value-loading logic whenever the flag transitions `true → false`, so a
reset-while-open still shows fresh values.

## Key Functions

| Function | Purpose |
|---|---|
| `loadCurrentValuesIfNeeded()` | Reads current `AppConfig` values into local `@State`, once per window lifetime (or again after a reset — see above) |
| `goNext()` / `goBack()` | Sets `goingForward` and animates `step` in one action |
| `finish()` | Commits all fields to `state.config`, sets `First_run_wizard_shown = true`, saves, dismisses |
| `chooseFolder()` | `NSOpenPanel` directory picker, same shape as `SettingsView.chooseFolder()` |

## What Still Needs Doing

- [ ] No skip-to-Settings shortcut — a user who wants to change something not covered here (e.g.
      Discord) has to finish the wizard first, then separately open Settings.
