# DonationNagView.swift — Donation Nag Window

A soft, honor-system donation reminder — **not DRM**. Implements the "Option A" lightweight tier
of the monetization plan in [`Distribution.md`](Distribution.md).

## Visual Appearance

**Restyled 2026-10-15 to match the launch cards** (splash, setup wizard): a 520pt-wide card (`LaunchCard.width`) in the shared dark
panel, with the wizard's header layout — the app icon (44pt, rounded, soft shadow) on the left, a bold rounded title and a one-line
subtitle beside it, 20pt side padding. Its accent is a warm rose (the splash panel's glow turns rose while this card is up) and the
flair is a small heart badge on the icon that springs in on appear, over the one-shot rose glow. As a launch card the splash's
persistent panel is behind it (see "As a launch-splash card" below); in its own window (a later nag) it draws the same panel itself
(`launchCardChrome`). Still single-instance (`Window`, not `WindowGroup` — see `hdhr_VCRApp.swift`), `.windowStyle(.hiddenTitleBar)`:
- `WindowAction` (`Views/WindowAction.swift`) sets `window?.level = .floating` in its own window — keeps the nag above other windows
  so it can't get lost behind the guide, Settings, etc. (skipped as a launch card)
- An `.onAppear` resets `enteredCode`/`showMismatch` to a clean slate — macOS window-state restoration can otherwise repopulate a
  closed-and-reopened single-instance `Window`'s field contents from its last session.

Top to bottom:
- Header: icon + heart badge, "Support hdhrVCRplus" (`.system(size: 20, weight: .bold, design: .rounded)`), "Free to use — tips keep it going."
- Body: a short "this app is free, consider a tip" message
- (*Superseded 2026-10-15 — see "Lighter styling" below.*) A full-width blue-gradient capsule "Tip via PayPal" button with a heart icon (custom
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
- "Not yet" (was "Not now" until 2026-10-15) — bordered, large button in a footer pinned to the bottom of the card (a `Divider` then the button right-aligned, 20pt side / 14pt vertical padding — the same bar as the setup wizard's Back / Next row; changed 2026-10-15 from plain tertiary text floating under the content) — closes the window via
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

There is deliberately **no throttling or snooze** — "Not yet" just closes the window; it reappears
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
this public doc on purpose; see the developer's own private, untracked notes for all three. Back
those up somewhere private along with `tools/donation_target.txt` — losing both means recovering
the target only by brute-forcing the hash.

## As a launch-splash card (2026-10-15)
At launch the nag is not opened as its own window: when the launch splash plays, `runCards` shows this view as the splash's last
card (after the first-run wizard on a new install), sliding in over the poster wall in the shared dark 520pt panel (`LaunchCard`, same as the splash and wizard), when `Donation_unlocked` is false. It reads
`\.embeddedCardClose` (`Views/EmbeddedCard.swift`): "Not yet" and a valid code call it instead of `dismiss()`, and the floating
window-level `WindowAction` is skipped (the splash window owns the level). `openDonationNagIfNeeded` returns early while
`LaunchSplashController.isPlaying`. Nags triggered later (after adding a show) still open the `donation-nag` window. See `docs/LaunchSplash.md`.

## Lighter styling (2026-10-15)
The card was heavier than the splash and the wizard (a filled blue PayPal pill with a blue glow, a filled orange Unlock pill, a filled
code field, a divider, plus the rose accents). It is now: one short line of text; the "Tip via PayPal" button as a rose-**outlined**
capsule (16 % rose fill, 65 % rose border, no shadow or glow — the PayPal-blue branding on this button was dropped); and a quiet code
row (a one-line caption, an outlined code field, and an Unlock capsule that is outlined and dim until text is entered, then orange).
The heart badge and the panel's rose glow are the card's only strong colour. The "Already tipped?" divider is gone.

**Entrance (2026-10-15):** calmed to match the other cards — the heart badge fades in and the one-shot glow eases out (no spring), and as a launch card the code field is not allowed to take focus on appear (a focus ring popping in mid-slide). The splash also holds deferred launch work off during the slide (`LaunchSplashController.motionActive`, docs/LaunchSplash.md).

Escape closes the card, like "Not yet" (`.onExitCommand`, added 2026-10-15; before that only the button did).

**Accessibility polish (2026-10-22):** the header icon is decorative (`.accessibilityHidden(true)`; the title beside it names the app). With Reduce Motion on, the appear glow is skipped (heart and ring jump straight to their end state, no animation). The "That code didn't match." warning clears as soon as the code field is edited (`.onChange(of: enteredCode)`), and pressing Return in an empty (or whitespace-only) field does nothing instead of showing the mismatch warning (`attemptUnlock` also guards on an empty code).
