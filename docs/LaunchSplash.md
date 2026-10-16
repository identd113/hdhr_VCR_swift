# LaunchSplash — launch screen (and the first-run opening)

`Views/LaunchSplashView.swift`. Shown at every launch when `AppConfig.Show_launch_splash` is on (Settings → General, default on), the app isn't under tests, and macOS "Reduce motion" is off (`LaunchSplashPlan.shouldShow`). **A brand-new install gets it too**: the splash then flows into the setup wizard (and the donation card) as cards in the same window, instead of ending with the fly-to-the-menu-bar finale — see "Cards" below.

## What it shows
- **The splash card is a dark panel** (520×600 design size, `LaunchCard` — the same size and look as the wizard and donation cards, drawn once by `blendedLaunchPanel()`), over the poster wall. On-air show posters (from the guide) fly in from every direction — random points on a ring outside the screen, spinning as they land — and settle into a loose 12×7 wall designed at 1100×760 around the panel and scaled by the same factor as the panel (`MosaicTiles.designWall`) (slightly jittered and tilted, centre posters dimmed). The logo, "hdhrVCRplus", the release version (`CFBundleShortVersionString`, build stamp as fallback) and a three-line checklist sit in that panel. The checklist flips to check marks as `AppState` publishes them — tuner found (name · tuner count), channel lineup (N channels), guide ready; no tuner after startup → "No tuner found".
- **Poster source:** `posterURLs()` takes `onAirNow` art across the recordable tuners. The list is saved to `UserDefaults` (`launchSplashPosterURLs`) at the end of every splash, so the next launch has it instantly (the images are in `ChannelIconCache` on disk); fresh posters are merged in if the guide is up within ~1 s, and fetching is capped at ~1.5 s. The wall isn't drawn at all until that load finishes (`tilesReady`), and the flight clock starts then — otherwise the still-empty wall rendered a flash of generic placeholder tiles before the real posters flew in. No posters at all → cached station logos (`ChannelIconCache.sampleCachedImages`), then the app's placeholder mark.
- **Finale:** the wall fades while the last panel shrinks and glides up to the menu-bar icon (the splash card itself, or the wizard / donation card when one follows), a ring pulses there, and the window closes — "I'm loaded; I live up here". The icon's position is found from our own `NSStatusBarWindow` (private class, matched loosely) with a top-right-of-screen fallback.

**On demand:** Settings → Maintenance → *Preview Launch Splash* opens the same window any time (it ignores the enable toggle).

## Cards: splash → setup wizard → donation (one window, one card at a time)
The poster wall is the **one persistent backdrop**, and on it sits **one persistent panel** (520×600 design size, scaled to the display, `LaunchCard`, drawn once by `blendedLaunchPanel()`: a nearly opaque (92 %) dark pool with a warm glow and a faintly softened edge, no border or shadow, so it sits in the wall without posters showing through the controls); the cards slide *inside* the panel (and the panel's glow takes each card's accent colour: orange for the splash, teal for setup, rose for support — `LaunchSplashView.accent`), clipped to its edges — the next card enters from the panel's right edge while the previous one leaves through its left edge (`LaunchSplashView.slide`, 0.55 s). Nothing crosses the screen. **Everything scales with the display:** the panel and its cards are designed at 520×600 for a 1440×900 screen and scaled so the panel is about 42 % of the screen height and at most 30 % of its width (`min(0.42·H/600, 0.30·W/520)`, clamped 0.5–1.6, `LaunchSplashView.displayScale`) with `scaleEffect`, and the wall (designed at 1100×760) is scaled by the same factor, so the wall and panel keep their proportions to each other and to the display. The cards draw no panel of their own while embedded. **The ending is the same for every flow** (`flyPanelToMenuBar`): once the last card is done — the splash card itself when nothing else is due, or the wizard or donation card — the whole panel, with that card still in it, glides up to the menu-bar icon (0.95 s ease-in-out), shrinking to icon size, while the wall fades away behind it; then a ring pulses on the icon. The window drops to `.popUpMenu` for this so the panel can land on the icon (found via our own `NSStatusBarWindow`, top-right fallback). Order: the **splash card** (logo, version,
checklist) → the **setup wizard** (`FirstRunWizardView`, only while first-run setup isn't done) → the **donation card**
(`DonationNagView`, only while `Donation_unlocked` is false). Both are the existing views, run as cards: they read the
`\.embeddedCardClose` environment value (`Views/EmbeddedCard.swift`) to close themselves and skip their own window setup.
- Which cards: `hdhr_VCRApp.openLaunchSplashIfNeeded()` sets `AppState.launchSplashHandsOffToWizard` (first run) and calls
  `LaunchSplashController.play(state:offersDonation: true)`; Settings → Maintenance → *Preview Launch Splash* passes `false` and has no
  wizard, so it is just the splash. After the splash card (startup done, 3.4–7 s) `runCards` shows whichever of the wizard / donation
  are due, waiting for each to close (`closedCards`), then the panel glides to the menu-bar icon (see below). With **no** card due
  the splash card itself is the last panel and glides to the menu-bar icon. While cards are up the splash window takes input (`SplashWindow` can
  become key; level `.modalPanel`), is hidden and click-through while another app is frontmost, and the wall is frozen (≈0 % CPU).
- The launch-time donation nag no longer opens its own window while the splash is playing (`openDonationNagIfNeeded` checks
  `LaunchSplashController.isPlaying`); later nags (after adding a show) and the Settings → Reset First-Run Setup wizard still open as
  their own windows.
- **Posters on a brand-new install:** there is no saved poster list and usually no guide yet when the wall is built, so it starts as
  placeholder tiles (or cached station logos). `upgradeToRealPosters()` polls the guide (≤ 60 s) and, once it supplies on-air art, swaps
  the real posters in (0.9 s animation, logged `[Splash] wall upgraded …`) and saves the list for the next launch.
- Safety net: `openLaunchSplashIfNeeded` starts a 14 s fallback; if the splash hasn't cleared `launchSplashHandsOffToWizard` by then it
  opens the wizard in its own window.

### `--demo-first-run` (launch argument)
`hdhrVCRplus.app/Contents/MacOS/hdhr_VCR --demo-first-run` (or `open -a hdhrVCRplus --args --demo-first-run` after quitting the
running instance) plays the whole flow — splash, first-run wizard, donation card — as a brand-new install would, ignoring the saved
config (first-run flag, splash toggle, Reduce Motion, `Donation_unlocked`), and **writes nothing to the config file**
(`AppState.saveConfig` returns early; `demoFirstRunRequested` in `Models.swift`). Use it to look at or test the flow on a configured
Mac without moving `hdhrVCRplus/` aside.

## Timing
`LaunchSplashPlan` (pure, unit-tested): never shorter than `minimumSeconds` (3.4 s), ends once startup finishes (`!isStartingUp`), never longer than `capSeconds` (7 s) — so a missing tuner can't hold it up.

## Window
`LaunchSplashView` turns its `NSWindow` (a `SplashWindow`, see Window lifetime) into a borderless, clear canvas (click-through except while a card is up) covering the menu-bar screen at `.popUpMenu` level (above the menu bar, so the logo can land on the icon). It never takes input.

## Not load-bearing
Startup (`AppState.startup()` — discovery, lineups, guide, icon prefetch) is unchanged and runs whether or not the splash appears; the splash only reflects it. It is opened once per run by `openLaunchSplashIfNeeded()` from the status-item label's `onAppear` (the first hook to fire), with the menu's `onAppear` as a backup. The launch-time donation nag is shown as the splash's last card (see Cards).

**Window lifetime (2026-10-15):** the splash is **not** a SwiftUI `Window` scene. A scene's window is only ever ordered out, never destroyed — so a finished splash stayed in memory and its endless `TimelineView` animation kept rendering the invisible wall (~21 % idle CPU, a ~0.6 s main-thread stall every 10 s). `LaunchSplashController` (bottom of `LaunchSplashView.swift`) now creates a borderless full-screen `NSWindow` with an `NSHostingView` when the splash plays and **destroys it when it ends**: `release()` orders the window out and drops the hosting view, freeing the SwiftUI graph, its `@State` and the poster images (a fresh-process footprint went 123–129 MB → 109 MB). Callers: the app's launch (`openLaunchSplashIfNeeded`) and Settings → Maintenance → Preview Launch Splash both call `LaunchSplashController.shared.play(state:openWindow:)`; playing while one is up just brings it forward (never stacks). The view takes `offersDonation` and `onFinish`. **With cards:** `finish()` is only reached after the last card closes, so the wall stays as the backdrop and is released only then. Guards: live `launchSplashPlaysEndsAndLeavesNothingRunning` (window must not exist after the finale, CPU < 5 %) and `idleAppUsesAlmostNoCPU`.
