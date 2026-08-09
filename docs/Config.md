# Config — AppConfig & ConfigManager

## File

**Location**: `~/Library/Application Support/hdhrVCRplus/hdhr_VCR-{hostname}.json`  
**Backup**: `.json.bak` written before each save.

**Format versions**:
- v2 (current): dates encoded as ISO8601 strings (`"2026-05-30T21:00:00Z"`), top-level shows key is `"shows"`.
- v1 (legacy): dates encoded as string epochs (`"1748613600"`), top-level shows key is `"the_shows"`.

`ConfigManager` auto-migrates v1 → v2 on first load and saves immediately. If the save fails (disk full, permissions), a warning is logged and migration retries on the next launch. The custom date decoder also accepts numeric epoch, so any format round-trips correctly.

**Test seam:** `ConfigManager.init(appSupportDir:)` takes an optional directory override; production always passes `nil` and gets the real path above. `AppState.init(configManager:)` accepts an injected `ConfigManager`, defaulting to a real `ConfigManager()` — the app's own startup (`hdhr_VCRApp.swift`) always uses that default. Tests go through `makeTestAppState()` (`Tests/hdhr_VCRTests/TestFixtures.swift`), which points every test's `ConfigManager` at a fresh per-call temp directory. Without this seam, any test exercising a mutating `AppState` path that calls `saveConfig()` (`deleteShow`, `addShow`, `updateShow`, `pauseShow`, `resumeShow`) would silently overwrite the real on-disk config the deployed app uses — this is exactly what would have happened testing `deleteShow`'s side-table cleanup (`Tests/hdhr_VCRTests/AppStateDeleteShowCleanupTests.swift`) before this seam existed.

## Adding a New Field

1. Add `var MyField: Type = defaultValue` to `AppConfig` in `Models.swift`.
2. Existing configs decode fine — missing key uses the default.
3. Wire into UI in `SettingsView.swift`.

---

## AppConfig Fields

```
Notify_upnext           Double  35.0    minutes before show to send "Up Next" notification
Notify_recording        Double  15.5    minutes before recording to send "Recording Soon" notification
GuideHours              Int     24      hours of guide to fetch; also controls refresh interval; clamped to 1...28 (Settings Stepper range, and min(28,...) on decode of an old saved value) — GuideStore.load() makes a single API call and the cloud guide.php endpoint silently truncates any Duration beyond ~29h regardless of what's requested (docs/HDHRFindings.md)
Guide_use_xml           Bool    false   use XMLTV endpoint instead of JSON; triggers guide refresh on toggle; devices without DeviceAuth fall back to JSON
Default_transcode       String  "none"  none | heavy | mobile | internet720
Fail_count_setting      Int     3       pause show after N consecutive failures
Min_disk_free_gb        Double  10.0    refuse to record below this free space (GB)
Idle_timer_interval     Int     10      seconds between idle loop checks (min enforced: 5)
Series_subfolder_enabled Bool   false   when true, SeriesID recordings are saved to Title/Season XX/ subfolders inside the recording folder; falls back to flat path if no parseable season in guide EpisodeNumber
Skip_recorded_episodes  Bool    false   when true (needs Series_subfolder_enabled), skip recording a series episode whose SxxExx is already on disk — advances to the next airing without recording or a fail count; only when the guide entry has a full season+episode tag
Post_recording_script   String  ""      POSIX path to a shell script run after each successful recording; $1 = file path; HDHR_PATH, HDHR_TITLE, HDHR_CHANNEL, HDHR_TRANSCODE, HDHR_EPISODE, HDHR_DEVICE, HDHR_SERIES, HDHR_FILESIZE set as env vars; Homebrew paths prepended to PATH; script exits are logged but never block the app
Series_scan_retry_hours Int     4       hours before re-scanning guide when no episode found
Network_interface       String  ""      bind UDP discovery + curl to NIC; empty = Auto; utun* = VPN
Verbose_curl            Bool    false   add -v to curl; stderr appended to hdhrVCRplus.log
Watch_in_VLC            Bool    false   show "Watch in VLC" buttons (only when VLC installed)
Watch_in_VLC_initialized Bool   false   set true after first VLC auto-detect; prevents overriding user's toggle on subsequent launches
Player_buffer_min_rate  Int     93      floor playback rate % for adaptive buffer fill (90–100); 100 = disabled
Sports_padding_enabled  Bool    true    master Bonus Time toggle; extends recording past guide end (any show can enable; sports entries default to true)
Sports_padding_minutes  Int     30      Bonus Time extension duration in minutes (10–60, step 5)
Discord_enabled         Bool    false   master Discord on/off toggle; decode fallback is `!Discord_webhook_url.isEmpty` (auto-enables for existing configs that already have a webhook set)
Discord_webhook_url     String  ""      Discord webhook URL; blank = disabled
Discord_on_start        Bool    true    embed when recording starts
Discord_on_complete     Bool    true    embed when recording completes (includes file size)
Discord_on_failed       Bool    true    embed on recording failure
Discord_on_paused       Bool    true    embed when show is paused
Discord_on_skipped      Bool    true    embed when recording skipped (disk full)
Discord_on_duplicate    Bool    true    embed when recording skipped (episode already recorded)
Discord_on_conflict     Bool    true    embed on tuner conflict
Discord_on_guide_error  Bool    true    embed on guide load failure
Discord_on_upnext       Bool    false   embed for Up Next reminder
Discord_on_soon         Bool    false   embed for Recording Soon reminder
Discord_on_show_added   Bool    false   embed when show is added
Discord_on_progress     Bool    false   edit the "Recording Started" embed every 5 min with elapsed/remaining time
Web_server_enabled      Bool    false   enable NWListener LAN web server (Settings → Web Server)
Web_server_port         Int     1980    TCP port for the web server (1025–65534; macOS requires root for <1024)
Hdhr_setup_folder       String  ""      default recording folder (POSIX path; empty = ~/Movies/hdhr_videos)
Signal_quality_enabled      Bool false   collect per-channel SNQ signal history and show signal bars when scheduling a recording (Add/Edit/web Record)
Signal_quality_alert_notify Bool false   notify + Discord embed when a recording's signal drops below 30% for ~20s, and again on recovery
Status_light_blink_enabled  Bool false   blink the recording/up-next menu bar status light (6s cycle: 5s lit, 1s off) instead of showing it lit continuously; driven by AppState's own 1Hz timer, independent of the idle loop
Donation_unlocked       Bool    false   set true once a valid donation-nag unlock code is entered; see docs/DonationNagView.md
Donation_unlock_code    String  ""      the validated code entered on successful unlock; shown back in Settings → About as registration confirmation
Dock_icon_mode          String  "auto"  auto | always | never — Settings → Advanced override for the launch-time Dock-icon heuristic (see TODO.md's "Show Stoppers" entry)
Local_network_confirmed Bool    false   internal, not user-facing; auto-set true on the first successful lineup load, drives "auto" mode's switch back to accessory
Config_version          String  "2"     format version marker; "2" = ISO8601 dates + "shows" key
```

---

## Default Recording Folder (`AppState.defaultSaveDir`)

Priority order:
1. `UserDefaults["defaultSaveDirectory"]` — set by folder picker in Settings
2. `config.Hdhr_setup_folder` — from config JSON
3. `~/Movies/hdhr_videos` — created automatically if absent
