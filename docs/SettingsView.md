# SettingsView.swift — Settings Window

## Intent

`SettingsView` is a `NavigationSplitView` settings window (sidebar + detail, like Finder column view). All app configuration lives here. Changes are held in a `draft: AppConfig` until the user explicitly presses **Save** (⌘S) — nothing writes to disk mid-edit.

Window size: **560×520** (fixed).

---

## Draft / Save Pattern

```swift
@State private var draft: AppConfig = AppConfig()
private var isDirty: Bool { draft != state.config }
```

- `.onAppear` seeds `draft = state.config`
- All controls bind to `$draft.*` — not to `state.config` directly
- **Save** → `applyAndSave()` sets `state.config = draft`, calls `state.saveConfig()`, and applies side effects: if `Idle_timer_interval` changed, calls `state.startTimer()`; if `Network_interface` changed, invalidates the guide cache and triggers `state.rediscoverDevices()` + `state.refreshGuide()` in a background Task so the new NIC is active immediately
- **Save & Close** → calls `applyAndSave()` then `NSApp.keyWindow?.close()`. Only enabled when `isDirty`.
- **Discard** → `draft = state.config`
- **Close with unsaved changes** → `WindowCloseInterceptor` intercepts and shows an NSAlert: Save / Discard / Cancel

The Save button turns **orange** when `isDirty` (`.tint(isDirty ? .orange : .accentColor)`) — it was always blue and `.disabled` when clean, making it hard to know at a glance whether changes existed.

---

## Settings Categories

Sidebar entries (with SF Symbol icons):

| Category | Icon | Contents |
|---|---|---|
| General | `gear` | Launch at Login, Add Show Method |
| Recording | `record.circle` | Folder, transcode, disk, failures, VLC, Bonus Time |
| Guide | `tv` | Guide hours, series scan retry |
| Notifications | `bell.badge` | Up Next timing, Recording alert timing |
| Advanced | `terminal` | Network interface, idle interval, verbose curl, config file path |
| Maintenance | `wrench.and.screwdriver` | Show maintenance, guide/device ops, brew tool installs, Developer (OS sim) |
| About | `info.circle` | App logo, version, history, GitHub link |

---

### General

- **Launch at Login** — `SMAppService.mainApp` toggle. Uses `register()`/`unregister()` from `ServiceManagement`. Errors are printed but not surfaced to the user.
- **Add Show Method** — radio-style chooser between:
  - **Wizard** — opens `AddShowView` window (3-step guide browser). Default.
  - **Menu** — inline cascading menu from the menu bar (Device → Channel → Entry → Type)
  
  Stored in `@AppStorage("addShowMode")` (`AddShowMode` enum), not in `AppConfig`.

---

### Recording

- **Default folder** — label (last path component) + Choose… + Reset. Stored in `@AppStorage("defaultSaveDirectory")` (not `AppConfig`). Priority order for resolution: UserDefaults → `config.Hdhr_setup_folder` → `~/Documents/hdhr_videos`.
- **Default transcode** — `Picker`: None / Heavy / Mobile / Internet 720. Stored in `draft.Default_transcode`.
- **Min free disk** — `Stepper` (1–100 GB). Recording is refused when free space is below this threshold (`AppState.diskOK(for:)`).
- **Pause after N failures** — `Stepper` (1–10). After `Fail_count_setting` consecutive failures, `show_active = false` and the show moves to Paused. Each successful recording start decrements `show_fail_count` by 1.
- **Watch in VLC** — `Toggle`, only shown when `/Applications/VLC.app` exists. Enables "Watch in VLC" buttons throughout the app. Stored in `draft.Watch_in_VLC`. **Auto-initialized**: on first launch (when `Watch_in_VLC_initialized == false`), the setting is auto-enabled if VLC is installed, then `Watch_in_VLC_initialized` is set to true so subsequent user toggles are never overridden.
- **Bonus Time for sports** — `Toggle` (on by default). Extends recording past the guide end for shows where `show_genre` contains "sports". Stored in `draft.Sports_padding_enabled`.
- **Bonus Time duration** — `Stepper` (10–60 min, step 5, default 30). Only visible when Bonus Time toggle is on. Stored in `draft.Sports_padding_minutes`.

---

### Guide

- **Show next N hours** — `Stepper` (1–48). Controls how far ahead the guide fetches and how long until the guide auto-refreshes (`max(3600, GuideHours × 1800)` seconds).
- **Series scan retry** — `Stepper` (1–24 hr). How long to wait before re-scanning the guide for a SeriesID show's next episode when no match was found.
- **Update Guides Now** — `Button` (always visible). Calls `state.refreshAll()` immediately, invalidating and reloading guide data for all devices. Useful any time fresh data is needed without restarting the app.

---

### Notifications

- **Up Next** — `Stepper` (5–120 min, step 5). Minutes before air to send the "Up Next" notification. Stored as `Double` (`Notify_upnext`) but displayed as `Int`.
- **Recording alert** — `Stepper` (1–60 min). Minutes before recording starts to send the "Recording Soon" notification. Stored as `Double` (`Notify_recording`).

---

### Advanced

- **Discovery & recording interface** — `Picker`: "Auto" (empty string) plus all IPv4-bearing interfaces, each shown as `name  ip` (e.g. `en0  192.168.1.5`, `utun0  10.8.0.2`). Populated by `availableNetworkInterfaces()` via `getifaddrs`; uses `IFF_POINTOPOINT` to detect all VPN/tunnel types (utun*, tun*, cscotun*, gpd*, zt*, ppp*, ipsec*, etc.) regardless of vendor naming. Stored in `draft.Network_interface`. On Settings open, if the saved value names an interface that is no longer available (VPN disconnected), `draft.Network_interface` is silently reset to `""` so a Save can't persist a broken value. **On Save**, if the interface changed, `applyAndSave()` invalidates the guide cache and triggers `rediscoverDevices()` + `refreshGuide()` in a background Task — the new NIC is active immediately. When non-empty:
  - UDP discovery (`HDHRManager.udpDiscoverSync`) binds via `IP_BOUND_IF`+`if_nametoindex`; **automatically skipped for tunnel/point-to-point interfaces** (`isPointToPointInterface()` check) since tunnels don't support broadcast — known-hosts (saved device IPs) handles remote device lookup
  - curl recordings get `--interface <name>` appended to args
  - URLSession HTTP requests rely on OS routing — correct for VPN since the VPN routes the remote subnet through the tunnel automatically
  - Leave on Auto for single-NIC setups.
- **Idle check interval** — `Stepper` (5–60 sec, step 5). How often the idle loop fires. Minimum enforced at 5s (`max(5, config.Idle_timer_interval)`). Changing this calls `state.startTimer()` immediately via `applyAndSave()`.
- **Verbose curl logging** — `Toggle`. Adds `-v` to curl args and pipes curl stderr to `~/Library/Logs/hdhrVCRplus.log`. When enabled, shows the log path (selectable text) and a "Show curl log in Finder" button. Log path is `RecordingManager.curlLogPath` (static let).
- **Config file path** — read-only display (`state.configManager.configPath`) + "Show config in Finder" button using `NSWorkspace.shared.selectFile(_:inFileViewerRootedAtPath:)`.

---

### About

- **App logo** — local `app.jpg` from the app bundle, displayed via `Image(nsImage: appIconImage)`. Tapping it 5 times unlocks the in-app AVKit player (`Player_unlocked = true`, saved to config) and shows an alert.
- **App name** — `.largeTitle` bold `"hdhr_VCR"`
- **Version** — `Text("Version \(appVersion) — Swift/SwiftUI rewrite")`. `appVersion` is a global `let` in `Sources/hdhr_VCR/Version.swift`, generated by `deploy.sh` before each build in the format `YYMMDD-HHMM` (e.g. `260521-2011`).
- **In-App Player status** — `"In-App Player: Unlocked ✓"` shown when `state.config.Player_unlocked`
- **History text** — multi-paragraph description of the app's origin (AppleScript 2016 → Swift rewrite)
- **Changelog** — rendered via `renderChangelog(_:)`: `## ` date headers appear as bold caption, `- ` items show `•` bullet prefix, inline `**bold**` renders bold. Fetched live from GitHub on open (falls back to bundled copy offline). Only the section matching the running build version is shown; a blue "Update available" banner appears when the fetched changelog has a newer version.
- **GitHub link** — `Link("View on GitHub", destination: URL(...))`

---

## Version Stamping

`Version.swift` is generated by `deploy.sh` with:
```bash
printf 'let appVersion = "%s"\n' "$(date +%y%m%d-%H%M)" > Sources/hdhr_VCR/Version.swift
```

This file should NOT be edited manually. It can be `.gitignore`d, but is currently committed so `swift build` (without running deploy) works. If you need to do a `swift build` without deploying, run `deploy.sh` once or write a placeholder manually: `let appVersion = "000000-0000"`.

---

## `WindowCloseInterceptor`

An `NSViewRepresentable` that attaches an `NSWindowDelegate` to the settings window on `.onAppear`. The coordinator holds mutable `isDirty` and `onSave` values that are updated via `updateNSView` so they stay current across re-renders without recreating the delegate.

```swift
func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard isDirty else { return true }
    let alert = NSAlert()
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Discard")
    alert.addButton(withTitle: "Cancel")
    switch alert.runModal() {
    case .alertFirstButtonReturn:  onSave(); return true   // save + close
    case .alertSecondButtonReturn: return true              // discard + close
    default:                       return false             // cancel — keep open
    }
}
```

---

## AppConfig Codable Safety

`AppConfig` uses a **custom `init(from:)` decoder** (not synthesized) that uses `try?` with fallback defaults for every field:

```swift
extension AppConfig: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Notify_recording = (try? c.decode(Double.self, forKey: .Notify_recording)) ?? 15.5
        // ... all fields with try? + default
    }
}
```

This means:
- Old config files missing any field decode cleanly (missing key → default value)
- New fields can be added to `AppConfig` without breaking existing user configs
- `Min_disk_free_gb` handles both `Double` and `Int` JSON types for compatibility with the AppleScript app's JSONHelper format

**Critical**: every time a new field is added to `AppConfig`, it MUST be added to this custom decoder with a default. The synthesized decoder (`Codable` without `init(from:)`) would throw `keyNotFound` on any config file that predates the new field, returning `nil` from `ConfigManager.load()` and silently overwriting the user's config with defaults.

---

## Config File Location

`~/Library/Application Support/hdhrVCRplus/hdhr_VCR-{hostname}.json` where hostname is `ProcessInfo.processInfo.hostName` (e.g. `woodflix.local`).

On first launch after updating from an older build, `ConfigManager` automatically migrates the file from its old location at `~/Documents/hdhr_VCR-{hostname}.json`. The old file is preserved so the original AppleScript app can still read it. This move was necessary because macOS TCC resets `~/Documents` access on every ad-hoc re-sign (`codesign --force --sign -`), causing the app to lose all scheduled shows after each development build.

**Important**: `ProcessInfo.processInfo.hostName` is used — NOT `Host.current().localizedName`. On macOS 26, `localizedName` returns the display name (`"Mac mini"`) instead of nil, causing the config filename to change and all user data to appear lost. Using `processInfo.hostName` avoids this regression.

A `.json.bak` backup is written before each save. The config format is shared with the original AppleScript app (`hdhr_VCR-AS`).

---

## What Still Needs Doing

- **No per-show overrides** — all recording settings (transcode, Bonus Time, fail threshold) apply globally. A useful future feature would be per-show overrides: "this show always transcodes to Mobile" or "this show gets 60 minutes of Bonus Time."

- **Bonus Time label clarity** — the stepper says "Bonus Time: 30 min". A note like "(adds 30 min after guide end for sports)" would clarify what it does without requiring the tooltip hover.

- **No export/import of config** — power users who manage multiple machines have no UI for this. The config JSON is in `~/Documents/` and can be copied manually, but "Export config…" / "Import config…" buttons in Advanced would be user-friendly.

- **Notification timing validation** — the "Recording alert" value must be less than the "Up Next" value for the notification sequence to make sense, but there's no enforcement or warning when they overlap.

- **Version stamp only on deploy** — running `swift build` directly won't update `Version.swift`. A Xcode pre-build phase or Swift Package Manager build plugin would make the version always current.

- **Settings window size is fixed** — `560×520` is hardcoded. On smaller displays this can crowd the form content.
