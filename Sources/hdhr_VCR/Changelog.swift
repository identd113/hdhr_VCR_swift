// Hand-maintained changelog displayed in Settings → About.
// Update this file when shipping new features; keep most-recent version at the top.
let appChangelog = """
## 2026-05-31 (260531-0223)
- Native resolution button (aspectratio icon) in VLC player toolbar — resizes window to 1:1 physical pixels using the stream's actual decoded dimensions
- Buffer monitor now shows a waveform icon; catch-up button updated to forward.end.circle with "Speed up to live" tooltip

## 2026-05-31 (260531-0157)
- Buffer monitor in VLC player toolbar — waveform icon + fill bar showing live buffer fill (0–8s); hover for lag, rate, bitrate, and corruption count
- Watch Now focus-or-open — clicking Watch Now in the menu brings the existing window forward if already open

## 2026-05-31 (260531-0137)
- Proportional poster images — Watch Now thumbnails are ~50% larger and scale with window resize; VLC player poster also scales with the player window

## 2026-05-31 (260531-0001)
- Buffered live TV playback — in-app player builds an ~8-second buffer to absorb signal drops; adaptive rate controller starts at the configured floor rate (default 93%) and ramps to 100% as the buffer fills; corrupt/late frames dropped rather than shown as artifacts
- Auto catch-up on bad signal — corruption stats polled every 3 seconds; stream restarts at live edge automatically when signal degrades beyond threshold (30s debounce)
- Catch Up button (⟳) in VLC player toolbar — manually discard buffer and reconnect at live edge without showing poster
- Min buffer rate setting (Settings → Recording, 90–100%, default 93%) — sets fill-phase floor speed; 100% disables buffering
- Discord progress updates — new toggle in Settings → Discord; edits the Recording Started embed in-place every 5 minutes with elapsed/remaining time; completion and failure also edit the same message instead of posting a new one

## 2026-05-29 (260529-1620)
- Recording Started notification now shows the correct end time when Bonus Time is active (was showing the un-padded guide end instead of the extended time)
- Tuner signal data now falls back to any locked tuner when the channel number format in status.json doesn't match exactly — fixes missing signal strength on some sub-channel configurations
- Config v2 migration failure (e.g. disk full) now logs a warning instead of silently retrying on every launch

## 2026-05-29 (260529-1534)
- Config format updated to v2: dates now stored as ISO8601 strings ("2026-05-30T21:00:00Z") instead of string epochs — existing configs auto-migrate on first launch
- "the_shows" JSON key renamed to "shows"; Mac alias path conversion removed; Int/Double type ambiguity in show_length, show_fail_count, and Min_disk_free_gb eliminated

## 2026-05-29 (260529-1432)
- VLC player: audio is now muted until Start is clicked — stream buffers silently; Start restores saved volume; volume persists across sessions
- Conflict indicator: a scheduled show overlapping an already-recording show now correctly gets the conflict triangle (was limited to scheduled-vs-scheduled)
- Default recording folder is now ~/Movies/hdhr_videos consistently (was ~/Documents/hdhr_videos or bare ~/Movies depending on code path)

## 2026-05-29 (260529-1145)
- Deactivating a show now deletes it immediately — no more "inactive" limbo state that was lost on restart
- Show stuck in a fail→pause→resume loop no longer re-pauses immediately — fail count cleared on auto-resume
- CableGuideView: lineup dictionary built once per render instead of once per channel row — smoother scrolling on large lineups
- CableGuideView: time-slot formatter is now a static instance — eliminates repeated DateFormatter allocation during guide scroll
- WatchNowView: guide entry resolved once per channel per refresh instead of twice — halves guide lookups on each 30 s tick
- UDP device discovery: EINTR no longer terminates the receive loop early — transient signal interrupts are retried

## 2026-05-29 (260529-0957)
- VLC player: poster overlay with Start button — stream buffers silently on open; poster + title + synopsis fill the video area until Start is clicked, then fades to live video; poster reappears on channel change
- Tuner conflict notifications fire once per show+episode window, not every idle tick — eliminates per-tick spam when a show can't start due to a full tuner
- Discord sends now log success or failure to hdhrVCRplus.log for easier webhook debugging
- Menu header device warnings consolidated inline: "DEVID 0/4  ⚠ no lineup, no guide" in orange instead of separate warning rows below each device

## 2026-05-29 (260529-0830)
- About screen changelog now reads from the bundled Changelog.swift instead of fetching CHANGELOG.md from GitHub
- Mock HDHomeRun tool: DeviceAuth background refresh thread keeps fallback cache current; proxy logging for lineup/guide/status requests; --auth-refresh flag

## 2026-05-29 (260529)
- All log output (guide, curl, app) consolidated into a single ~/Library/Logs/hdhrVCRplus.log
- DeviceAuth cloud token now refreshed every 5 minutes via device probe — guide no longer goes stale after long uptimes on EXTEND devices
- Recording stops are now guaranteed to complete before new recordings start on the same tick, preventing tuner-count races at show boundaries

## 2026-05-28 (260528-2055)
- Menu header: live tuner occupancy polled from status.json each idle tick — shows real active/total count; flags count mismatch vs app's expected recording count
- Menu header: orange device health warnings (no lineup, no guide) after startup; unhealthy devices excluded from the "N tuner(s) ready" status count
- Guide summary panel poster now correctly clipped with clipShape(RoundedRectangle) — content no longer bleeds past rounded corners

## 2026-05-24 (260524-0119)
- Discord webhook notifications (Settings → Notifications): rich embeds per event with show poster, episode info, and genre tags; per-event toggles; Test button sends a live embed without saving
- Watch Now! ungated — in-app VLC player button appears whenever VLC is installed; easter egg no longer required
- Tuner availability check — Watch Now! shows an alert when all tuners are occupied before opening the player
- Channel picker sync — VLC player picker syncs to the channel you opened Watch Now! from; switching channels while the window is open also updates the picker
- Settings: Save & Close is now the default (Return) button; Save (⌘S) only enabled when dirty

## 2026-05-23 (260523-1751)
- Config moved to ~/Library/Application Support/hdhrVCRplus/; auto-migrated from ~/Documents on first launch; old file preserved for AppleScript app compatibility
- Unbuffered log output — log lines written to disk immediately after every glog() call
- Cable guide vertical scroll sync — replaced onScrollGeometryChange with VerticalScrollTracker (NSViewRepresentable) that fires on every AppKit scroll frame
- Guide summary poster fills panel height; channel icon enlarged to 52 pt
- Stale channel icon cleared when switching to a channel with no logo
- Wizard SeriesID scheduling fixed — now correctly schedules from the current or nearest airing
- Watch in App gated on on-air entries only, consistent with Watch in VLC

## 2026-05-23 (260523-1212)
- Duplicate show guard — Record replaced with Edit Show for already-managed shows (SeriesID or title match); opens EditShowView directly
- Per-show Bonus Time flag (show_bonus_time) — any show type can enable Bonus Time; existing configs migrate automatically with genre-based fallback
- Bonus-time overrun box redesigned — filled with genre color, shows the overlapped show's title, tapping it selects that show in the summary panel
- ShowFormSection extracted — shared form fields used by both Add Show wizard and Edit Show
- Starburst badge in Add Show details step and Edit Show when Bonus Time is enabled

## 2026-05-22 (260522-2057)
- Multi-selection bug fixed — guide blocks no longer highlight across all channels at the same start time; caused by nil == nil when lineup data was absent
- Record and Watch in VLC buttons reliably enabled — lineup re-fetched on demand if missing (recovers from silent startup failures)
- FloatingGuideView lineup fix — lineup no longer cleared on device change; buttons always resolve correctly
- StarburstBadge extracted to standalone reusable component with pop-in and 5-tap celebration keyframe animation
- macOS 14 minimum — deployment target raised from macOS 13; keyframeAnimator now available without availability guards

## 2026-05-22 (260522-1600)
- Code-review fixes: Discard button now resets OS-sim picker draft; stale-interface clear propagates to live config (prevents dead-interface curl failures after Discard-close); refreshGuides() guards against concurrent runs and stops suppressing retries after an empty-devices refresh; if_nametoindex=0 now logs a diagnostic instead of silently skipping the interface bind

## 2026-05-22 (260522-1530)
- All new settings require Save: OS simulation picker now uses draft/save pattern (was live-updating @AppStorage); Save commits, Discard reverts, ⌘S works
- Interface change triggers refresh: switching network interface on Save automatically runs device rediscovery + guide reload so curl and UDP bind to the new NIC immediately

## 2026-05-22 (260522-1500)
- Network interface binding (Settings → Advanced): bind UDP discovery + curl to a specific NIC or VPN tunnel
- VPN recording support: tunnel selected → UDP broadcast skipped, known-hosts discovery used, curl bound to tunnel
- OS sim picker: shows "macOS X (current)" as default; always anchored to tag(0) so no blank-picker flash
- Stale interface auto-clear on Settings open (prevents saving a disconnected interface)
- Changelog version filtering in About: shows only entries up to running build; update notice when newer version available

## 2026-05-22 (260522-1342)
- Pop-out cable guide window from wizard toolbar
- Brew install buttons in Maintenance (VLC, HDHomeRun CLI)
- Stop Recording / Delete confirmations (NSAlert)
- Edit Show unsaved-changes warning on close
- Bonus Time callout in recording menu; remaining time reflects padded end
- Paused show submenus show type + channel context
- Notification timing validation warning in Settings
- Clear Guide Cache button in Maintenance
- App icon (AppIcon.icns) generated from app.jpg; shown in Finder and Force Quit
- macOS 13+ compatibility (deployment target lowered from 15); version-adaptive scroll, EmptyStateView
- OS simulation picker in Maintenance → Developer

## 2026-05-22 (260522-1210)
- Project renamed to hdhrVCRplus — bundle name, identifier, Quit button, and process marker updated
- App icon in menu bar — local bundle image scaled to menu bar height; dimmed during startup
- Tuner signal in recording submenu — signal %, lock type, and bitrate polled from /tuner{N}/vstatus each tick
- Recording conflict detection — ⚠️ badge on scheduled shows when all tuner slots are occupied at start time
- Skip This Airing — stops the current recording and advances to the next scheduled airing without incrementing fail count
- Cable guide dynamic width — guide fills window width; window resizable from 1100×720 minimum
- Next Up submenus — full submenu with poster, synopsis, episode info, timing, and actions
- Watch in VLC auto-enabled on first launch if VLC is installed
- Config recovery from backup — restores from .json.bak if main config is missing or corrupt

## 2026-05-22 (v1.0.0)
- SeriesID title fallback — falls back to title match when guide omits SeriesID for an airing
- Maintenance panel (Settings → Maintenance): Rescan Series, Reset Fail Counts, Reactivate Paused, Refresh Guide, Rediscover Devices
- Recording process survives force-quit — launched via posix_spawn in its own POSIX session; boot-resume reattaches on next launch
- Add Show moved to top of main menu

## 2026-05-22
- Next Up section in main menu (next recording time slot + all shows)
- Episode info in menu labels (S01E02 · Title without opening submenu)
- Tuner ID shown in recording submenu
- Show Recording in Finder button
- Tuner slot enforcement (won't exceed device TunerCount)
- Auto-detect new tuners while running (5-minute probe)
- SeriesID earliest-episode resolution (finds currently-airing episodes)
- Universal menu text readability fix (Button wrapper defeats AppKit dimming)
- Upcoming recording slots in scheduled show submenu
- Settings deferred save (Add Show Mode, Default Folder, Launch at Login now require Save)
- SeriesID-only badge matching in cable guide (title fallback only when no SeriesID)
- Live changelog in About tab (fetched from GitHub, inline scroll, offline fallback)
- Cable guide status badges (red=recording, orange=next up within 30 min)
- Next Up menu text size matches Scheduled section
- Record button defaults to Single type
- Quit alert defaults to Keep Recording & Quit
- SeriesID(All) device fix: resolves correct device/URL when episode is on a different tuner
- Menu first-click warmup (pre-render 2s after startup)
- Cable guide lazy row rendering (~4x faster initial load)

## 2026-05-21
- Guide summary panel polish + upcoming airings for SeriesID shows
- IP auto-update when device DHCP address changes
- Flat record options (no "Record as series…" sub-submenu)
- Static DateFormatter caching for performance
- Discovery reliability: 10 retries at startup
- Menu header shows tuner device ID and active/total slot count

## 2026-05-20
- Cable TV-style guide grid with genre colors and sticky channel column
- VLC integration for live stream watching
- Settings window (draft/save, close warning, 6 categories)
- Bonus Time extension for sports recordings
- Fail threshold: auto-pause after N failures
- Launch at Login via SMAppService
- Verbose curl logging to ~/Library/Logs/hdhrVCRplus.log
- Up Next and Recording Soon notifications
- Boot-resume: reattach recordings that survived a restart
- Initial Swift/SwiftUI rewrite of the original 2016 AppleScript app
"""
