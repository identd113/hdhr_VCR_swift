# DonationNagView.swift — Donation Nag Window

A soft, honor-system donation reminder — **not DRM**. Implements the "Option A" lightweight tier
of the monetization plan in [`Distribution.md`](Distribution.md).

## Visual Appearance

Fixed-width (400pt) window, single-instance (`Window`, not `WindowGroup` — see
`hdhr_VCRApp.swift`), styled as a modern floating card rather than a standard document window:
- `.windowStyle(.hiddenTitleBar)` — no title text; the traffic-light buttons remain, floating over
  the header band (content has enough top padding to clear them)
- The whole card is clipped to a 20pt continuous rounded rect with a subtle 1px light stroke and a
  soft drop shadow, on a `.thickMaterial` base — reads as a floating panel, not a flat window
- A private `FloatingWindowLevelSetter` (`NSViewRepresentable` setting `window?.level = .floating`
  once mounted — the same technique the old, now-removed `FloatingGuideView` used, see git history)
  keeps the nag above other windows so it can't get lost behind the guide, Settings, etc.
- An `.onAppear` resets `enteredCode`/`showMismatch` to a clean slate — macOS window-state
  restoration can otherwise repopulate a closed-and-reopened single-instance `Window`'s field
  contents from its last session, which looked like a bug in testing (a stale typed code + a
  mismatch error already showing) before this was added.

Top to bottom, leaning into the app's own visual language (the recording-red/action-orange accent
already used elsewhere — see `litColor: .red` in `hdhr_VCRApp.swift`'s status icon, `.tint(.orange)`
on `SettingsView`'s dirty Save button — and its terminal/monospace-flavored `Advanced` tab) rather
than generic system-blue chrome:
- Header band: a top-down orange→red→clear `LinearGradient` behind the content, `appIconImage`
  (the app's own icon, from `AppIcon.swift` — same asset the About tab and menu bar use) at 60×60
  with rounded corners + a soft one-shot radial-gradient glow that eases out on appear, then
  "Support hdhrVCR+" in `.system(.title3, design: .monospaced)`
- Body: a short "this app is free, consider a tip" message
- A full-width blue-gradient capsule "Tip via PayPal" button with a heart icon (custom
  `.buttonStyle(.plain)` + `.background(...).clipShape(Capsule())`, not the default
  `.borderedProminent` — kept PayPal's recognizable blue rather than the app's own orange/red, so
  the button still reads as trustworthy/branded against the app-colored chrome around it)
- Divider
- "Already tipped?" section: a monospaced plain-style text field (rounded-rect quaternary
  background, matching the card aesthetic rather than the default system field look) + a capsule
  "Unlock" button (orange gradient when enabled, quaternary/disabled-looking when the field is
  empty), with an inline "That code didn't match." warning (with a triangle icon) on a failed
  attempt
- "Not now" — plain-style, tertiary-foreground, bottom-right — closes the window via
  `@Environment(\.dismiss)`

## Trigger points

Two, both gated on `!AppState.config.Donation_unlocked` (a no-op once unlocked):

1. **App launch** — once per run. Guarded in `hdhr_VCRApp.swift` by a local `@State private var
   launchDonationNagShown` flag inside the `MenuBarExtra` content's existing `.onAppear` (the same
   `.onAppear` that tracks `menuIsOpen`). That `.onAppear` fires reliably at launch because of the
   app's existing "silently open+close the menu" warm-up (see `statusLabel`'s doc comment in
   `hdhr_VCRApp.swift`) — but it *also* fires on every real user menu-open, so the local flag is
   what confines the nag to firing once per run rather than every time the menu opens.
2. **A show is scheduled** — from either the native Add Show wizard or the web guide's Record
   action. Both already funnel through the single `AppState.addShow(_ show: Show)` function
   (`addShowFromGuide`, the web/guide-entry path, ends by calling `addShow(show)`), so a single
   hook there — bumping `@Published var pendingDonationNagTrigger: Int` — covers both callers. A
   `.onChange(of: appState.pendingDonationNagTrigger)` in `hdhr_VCRApp.swift` reopens the window.

Both trigger paths call a shared `hdhr_VCRApp.openDonationNagIfNeeded()` private method (checks
`Donation_unlocked`, activates the app, calls `openWindow(id: "donation-nag")`). `openWindow(id:)`
on an already-open single-instance `Window` scene just re-focuses it rather than duplicating — see
`docs/MenuContent.md`'s "No duplicate windows" note — so this is safe to call repeatedly without
checking whether the window is already open.

There is deliberately **no throttling or snooze** — "Not now" just closes the window; it reappears
at the next trigger. If this proves too aggressive in practice, the natural fix is a cooldown
timestamp in `AppConfig`, not a design change here.

## Unlock mechanism

A code is valid when it passes a private validation rule checked against
`AppConfig.Donation_target_checksum` — many distinct valid codes exist for a given target, so a
fresh one can be handed to each tipper rather than reusing a single shared string. Still
honor-system, not cryptographic enforcement. A per-person HMAC-based scheme is already sketched
(unused) in `Distribution.md` if that's ever wanted instead. The exact rule and a code generator
are intentionally kept out of this (public) repo — ask the developer directly if you're extending
this feature and need the details.

**The target is deliberately NOT in the source file** — this repo is public, and `Donation_unlocked`/
`Donation_target_checksum` are real `AppConfig` fields (Settings → Advanced → "Unlock target"),
persisted only in this machine's local
`~/Library/Application Support/hdhrVCRplus/hdhr_VCR-{hostname}.json`, which is never part of git.
`Donation_target_checksum` defaults to `-1`, which the validation rule can never match, so the nag
simply never unlocks until you set a real value in Settings.

`paypalURL` is the developer's own info, identical in every distributed build, so it's still a
plain hardcoded constant in `DonationNagView.swift` (fine to commit) — unlike the checksum target.
