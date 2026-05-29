// Hand-maintained changelog displayed in Settings → About.
// Update this file when shipping new features; keep most-recent version at the top.
let appChangelog = """
## 2026-05-29 (260529)
- All log output (guide, curl, app) consolidated into a single ~/Library/Logs/hdhrVCRplus.log
- DeviceAuth cloud token now refreshed every 5 minutes via device probe — guide no longer goes stale after long uptimes on EXTEND devices
- Recording stops are now guaranteed to complete before new recordings start on the same tick, preventing tuner-count races at show boundaries

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
