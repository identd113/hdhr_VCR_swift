# LaunchSplash — returning-user launch screen

`Views/LaunchSplashView.swift`. Shown at launch **only** when first-run setup is already complete, `AppConfig.Show_launch_splash` is on (Settings → General, default on), the app isn't under tests, and macOS "Reduce motion" is off. A brand-new install gets the first-run wizard instead.

## What it shows
- A centred card: the logo, "hdhrVCRplus", the release version (`CFBundleShortVersionString`, build stamp as fallback) and a three-line checklist that flips to check marks as `AppState` publishes them — tuner found (name · tuner count), channel lineup (N channels), guide ready. No tuner after startup → "No tuner found".
- Behind the card, slowly drifting images sampled from the on-disk icon cache (`ChannelIconCache.sampleCachedImages(limit:)` — disk only, never the network, so it works offline). Station logos are always there; show posters appear once Watch Now or the wizard has fetched them. An empty cache just means a plain card.
- **Finale:** the card fades, the logo shrinks and flies to the menu-bar icon, a ring pulses there, and the window closes — "I'm loaded; I live up here". The icon's position is found from our own `NSStatusBarWindow` (private class, matched loosely) with a top-right-of-screen fallback.

## Timing
`LaunchSplashPlan` (pure, unit-tested): never shorter than `minimumSeconds` (2.6 s), ends once startup finishes (`!isStartingUp`), never longer than `capSeconds` (7 s) — so a missing tuner can't hold it up.

## Window
A `Window(id: "launch-splash")` scene; `LaunchSplashView` turns its `NSWindow` into a borderless, clear, click-through canvas covering the menu-bar screen at `.popUpMenu` level (above the menu bar, so the logo can land on the icon). It never takes input.

## Not load-bearing
Startup (`AppState.startup()` — discovery, lineups, guide, icon prefetch) is unchanged and runs whether or not the splash appears; the splash only reflects it. It is opened once per run by `openLaunchSplashIfNeeded()` from the status-item label's `onAppear` (the first hook to fire), with the menu's `onAppear` as a backup. The donation nag is not held back by it.
