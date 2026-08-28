# FirstRunWizardView.swift — First-Run Setup Wizard

## Visual Appearance

### Overall window
Fixed **480×460**, hidden title bar (traffic lights only, no title text) — same "modern floating
panel" look as `DonationNagView`, since this is a focused onboarding flow rather than a
document-style window. Unlike `AddShowView`'s two very differently-sized steps, both screens here
are similarly-shaped settings forms, so the window never resizes between them — only the content
slides.

**Top of window**: 2 small 8pt circles — identical visual pattern to `AddShowView`'s step
indicator. Filled accent-color circle = current step; hollow gray circle = other step. Below the
circles: a `Divider`.

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
Save folder (`NSOpenPanel` picker, same control shape as `SettingsView`'s Recording tab), default
transcode profile, min free disk (GB), and failure threshold — each with an `InfoButton` popover
explaining what it does, reusing wording from the equivalent `SettingsView` rows.

### Step 2 — Notification Timing
Up Next / Recording Soon lead-time minutes, same `Stepper` controls and warning banner (shown when
the recording alert would fire at or after Up Next) as `SettingsView`'s Notifications tab.

**Nav bar** (bottom): Back (step 2 only) and Next/Finish, right-aligned, Next/Finish
`.borderedProminent`. A `Divider` above.

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
