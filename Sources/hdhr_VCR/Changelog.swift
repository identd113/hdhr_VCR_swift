// Hand-maintained changelog displayed in Settings → About.
// Update this file when shipping new features; keep most-recent version at the top.
let appChangelog = """
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
- Verbose curl logging to ~/Library/Logs/hdhr_VCR_curl.log
- Up Next and Recording Soon notifications
- Boot-resume: reattach recordings that survived a restart
- Initial Swift/SwiftUI rewrite of the original 2016 AppleScript app
"""
