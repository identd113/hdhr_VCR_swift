# Config — AppConfig & ConfigManager

## File

**Location**: `~/Library/Application Support/hdhrVCRplus/hdhr_VCR-{hostname}.json`  
**Migration**: on first launch, `ConfigManager` copies `~/Documents/hdhr_VCR-{hostname}.json` to the new path; old file preserved for AppleScript app compatibility.  
**Backup**: `.json.bak` written before each save.  
**Format shared** with the AppleScript app — both can read the same config.

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
Default_transcode       String  "none"  none | heavy | mobile | internet720
Fail_count_setting      Int     3       pause show after N consecutive failures
Min_disk_free_gb        Double  10.0    refuse to record below this free space (GB)
Idle_timer_interval     Int     10      seconds between idle loop checks (min enforced: 5)
Series_scan_retry_hours Int     4       hours before re-scanning guide when no episode found
Network_interface       String  ""      bind UDP discovery + curl to NIC; empty = Auto; utun* = VPN
Verbose_curl            Bool    false   add -v to curl; stderr appended to hdhrVCRplus.log
Watch_in_VLC            Bool    false   show "Watch in VLC" buttons (only when VLC installed)
Watch_in_VLC_initialized Bool   false   set true after first VLC auto-detect; prevents overriding user's toggle on subsequent launches
Player_unlocked         Bool    false   gates the in-app VLC player (unlocked by 5-tap easter egg on About logo)
Sports_padding_enabled  Bool    true    master Bonus Time toggle; extends recording past guide end for sports shows
Sports_padding_minutes  Int     30      Bonus Time extension duration in minutes (10–60, step 5)
Discord_enabled         Bool    false   master Discord on/off toggle; distinct from having a non-empty webhook URL
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
Hdhr_setup_folder       String  ""      default recording folder (POSIX path; empty = ~/Documents/hdhr_videos)
Config_version          String  "1"     format version marker
```

---

## Default Recording Folder (`AppState.defaultSaveDir`)

Priority order:
1. `UserDefaults["defaultSaveDirectory"]` — set by folder picker in Settings
2. `config.Hdhr_setup_folder` — from config JSON
3. `~/Documents/hdhr_videos` — created automatically if absent
