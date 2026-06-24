# Config — AppConfig & ConfigManager

## File

**Location**: `~/Library/Application Support/hdhrVCRplus/hdhr_VCR-{hostname}.json`  
**Backup**: `.json.bak` written before each save.

**Format versions**:
- v2 (current): dates encoded as ISO8601 strings (`"2026-05-30T21:00:00Z"`), top-level shows key is `"shows"`.
- v1 (legacy): dates encoded as string epochs (`"1748613600"`), top-level shows key is `"the_shows"`.

`ConfigManager` auto-migrates v1 → v2 on first load and saves immediately. If the save fails (disk full, permissions), a warning is logged and migration retries on the next launch. The custom date decoder also accepts numeric epoch, so any format round-trips correctly.

## Adding a New Field

1. Add `var MyField: Type = defaultValue` to `AppConfig` in `Models.swift`.
2. Existing configs decode fine — missing key uses the default.
3. Wire into UI in `SettingsView.swift`.

---

## AppConfig Fields

```
Notify_upnext           Double  35.0    minutes before show to send "Up Next" notification
Notify_recording        Double  15.5    minutes before recording to send "Recording Soon" notification
GuideHours              Int     24      hours of guide to fetch; also controls refresh interval
Guide_use_xml           Bool    false   use XMLTV endpoint instead of JSON; triggers guide refresh on toggle; devices without DeviceAuth fall back to JSON
Default_transcode       String  "none"  none | heavy | mobile | internet720
Fail_count_setting      Int     3       pause show after N consecutive failures
Min_disk_free_gb        Double  10.0    refuse to record below this free space (GB)
Idle_timer_interval     Int     10      seconds between idle loop checks (min enforced: 5)
Series_subfolder_enabled Bool   false   when true, SeriesID recordings are saved to Title/Season XX/ subfolders inside the recording folder; falls back to flat path if no parseable season in guide EpisodeNumber
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
Discord_on_conflict     Bool    true    embed on tuner conflict
Discord_on_guide_error  Bool    true    embed on guide load failure
Discord_on_upnext       Bool    false   embed for Up Next reminder
Discord_on_soon         Bool    false   embed for Recording Soon reminder
Discord_on_show_added   Bool    false   embed when show is added
Discord_on_progress     Bool    false   edit the "Recording Started" embed every 5 min with elapsed/remaining time
Web_server_enabled      Bool    false   enable NWListener LAN web server (Settings → Web Server)
Web_server_port         Int     1980    TCP port for the web server (1025–65534; macOS requires root for <1024)
Hdhr_setup_folder       String  ""      default recording folder (POSIX path; empty = ~/Movies/hdhr_videos)
Config_version          String  "2"     format version marker; "2" = ISO8601 dates + "shows" key
```

---

## Default Recording Folder (`AppState.defaultSaveDir`)

Priority order:
1. `UserDefaults["defaultSaveDirectory"]` — set by folder picker in Settings
2. `config.Hdhr_setup_folder` — from config JSON
3. `~/Movies/hdhr_videos` — created automatically if absent
