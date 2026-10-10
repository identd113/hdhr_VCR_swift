# LaunchSplash — returning-user launch screen

`Views/LaunchSplashView.swift`. Shown at launch **only** when first-run setup is already complete, `AppConfig.Show_launch_splash` is on (Settings → General, default on), the app isn't under tests, and macOS "Reduce motion" is off. A brand-new install gets the first-run wizard instead.

## What it shows
- **No window or panel.** On-air show posters (from the guide) fly in from every direction — random points on a ring outside the screen, spinning as they land — and settle into a loose 10×5 wall (slightly jittered and tilted, centre posters dimmed). The logo, "hdhrVCRplus", the release version (`CFBundleShortVersionString`, build stamp as fallback) and a three-line checklist float over it on a soft edgeless dark glow. The checklist flips to check marks as `AppState` publishes them — tuner found (name · tuner count), channel lineup (N channels), guide ready; no tuner after startup → "No tuner found".
- **Poster source:** `posterURLs()` takes `onAirNow` art across the recordable tuners. The list is saved to `UserDefaults` (`launchSplashPosterURLs`) at the end of every splash, so the next launch has it instantly (the images are in `ChannelIconCache` on disk); fresh posters are merged in if the guide is up within ~1 s, and fetching is capped at ~1.5 s. No posters at all → cached station logos (`ChannelIconCache.sampleCachedImages`), then the app's placeholder mark.
- **Finale:** the wall fades, the logo shrinks and flies to the menu-bar icon, a ring pulses there, and the window closes — "I'm loaded; I live up here". The icon's position is found from our own `NSStatusBarWindow` (private class, matched loosely) with a top-right-of-screen fallback.

**On demand:** Settings → Maintenance → *Preview Launch Splash* opens the same window any time (it ignores the enable toggle).

## Timing
`LaunchSplashPlan` (pure, unit-tested): never shorter than `minimumSeconds` (3.4 s), ends once startup finishes (`!isStartingUp`), never longer than `capSeconds` (7 s) — so a missing tuner can't hold it up.

## Window
A `Window(id: "launch-splash")` scene; `LaunchSplashView` turns its `NSWindow` into a borderless, clear, click-through canvas covering the menu-bar screen at `.popUpMenu` level (above the menu bar, so the logo can land on the icon). It never takes input.

## Not load-bearing
Startup (`AppState.startup()` — discovery, lineups, guide, icon prefetch) is unchanged and runs whether or not the splash appears; the splash only reflects it. It is opened once per run by `openLaunchSplashIfNeeded()` from the status-item label's `onAppear` (the first hook to fire), with the menu's `onAppear` as a backup. The donation nag is not held back by it.
