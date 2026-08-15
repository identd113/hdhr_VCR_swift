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
  "Support hdhrVCRplus" in `.system(.title3, design: .monospaced)`
- Body: a short "this app is free, consider a tip" message
- A full-width blue-gradient capsule "Tip via PayPal" button with a heart icon (custom
  `.buttonStyle(.plain)` + `.background(...).clipShape(Capsule())`, not the default
  `.borderedProminent` — kept PayPal's recognizable blue rather than the app's own orange/red, so
  the button still reads as trustworthy/branded against the app-colored chrome around it). `paypalURL`
  itself ends in `/10` — PayPal.me's amount-suffix syntax — so the visitor's checkout pre-fills a
  $10 suggested tip (still editable, not enforced).
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

A code is valid when it passes a private validation rule checked against a target number baked
into the app — many distinct valid codes exist for a given target, so a fresh one can be handed to
each tipper rather than reusing a single shared string. Still honor-system, not cryptographic
enforcement. A per-person HMAC-based scheme is already sketched (unused) in `Distribution.md` if
that's ever wanted instead. The exact rule is intentionally kept out of this (public) repo — ask
the developer directly if you're extending this feature and need the details.

**The target ships identically in every build, but not as plaintext.** `DonationNagView.swift`
hardcodes `targetChecksumHash`, a SHA256 hash of the real target number, and `attemptUnlock()`
hashes the entered code's digit-sum and compares hashes rather than comparing the raw number
directly — so the actual target isn't grep-able from a casual read of this (public) repo's source,
while still being the same fixed value compiled into every distributed copy of the app. This is a
correction of an earlier design that stored the raw target in per-install `AppConfig`
(`Donation_target_checksum`, since removed) — that kept the number out of git too, but also meant
every fresh install (including everyone who actually downloaded the app) started unconfigured, so
nobody except the developer's own already-configured machine could ever unlock it. Hashing a
single shared constant fixes that while keeping the same "not visible in git" property.

`paypalURL` is the developer's own info, identical in every distributed build, so it's a plain
hardcoded constant in `DonationNagView.swift` same as before — unlike the checksum target, it was
never sensitive to begin with.

**Generating codes**: no script needed — a fresh valid code can be constructed by hand for each
tipper from the target number in seconds. The exact construction rule, the target itself, and the
mechanism's known weakness (quantified — how small the search space actually is) are kept out of
this public doc on purpose; see `tools/donation_target_notes.md` (gitignored, private) for all
three. Back that file up somewhere private along with `tools/donation_target.txt` — losing both
means recovering the target only by brute-forcing the hash.
