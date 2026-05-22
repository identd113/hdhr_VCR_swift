# hdhr_VCR Changelog

## 2026-05-22

- **Next Up section** — main menu now shows the next upcoming recording time slot and all shows starting then, so you can see what's coming without opening submenu
- **Episode info in menu labels** — scheduled and recording menu items now show season/episode number and title (e.g. "📅 Sister Sister · S02E05") without having to open the submenu
- **Tuner shown in recording submenu** — recording details now include which tuner device is in use ("tuner 105404BE")
- **Show Recording in Finder** — recording submenu includes a button to reveal the in-progress file in Finder
- **Tuner slot enforcement** — recording start is now blocked when all tuner slots on a device are occupied; logged as "TUNER FULL" in the guide log
- **Auto-detect new tuners** — idle loop probes for newly-connected HDHomeRun devices every 5 minutes and adds them without restarting the app
- **SeriesID earliest-episode resolution** — when adding a SeriesID show, the app now finds the earliest available episode (including currently-airing), not the episode you happened to click
- **Menu readability** — all non-interactive info text in menus uses a Button wrapper to defeat AppKit's automatic dimming of disabled NSMenuItems
- **Synopsis removed from recording submenu** — synopsis was too long and pushed action buttons off screen; episode info is preserved
- **Upcoming recording slots** — scheduled show submenu now lists upcoming recording dates for all show types (Single, DateTime, SeriesID)
- **Settings deferred save** — Add Show Mode, Default Folder, and Launch at Login no longer apply immediately; all settings require pressing Save (⌘S) to take effect
- **SeriesID-only badge matching** — "already managed" bookmark badge in cable guide now matches strictly by SeriesID when present; title fallback only used for shows with no SeriesID
- **Live changelog** — Settings → About fetches the latest CHANGELOG.md from GitHub; falls back to bundled copy when offline; scrolls inline with the rest of the About view
- **Cable guide status badges** — guide cells now show a red border + dot for actively recording shows and an orange border + clock for shows recording within 30 minutes; bookmark badge remains for all managed shows
- **Next Up menu text** — show names in the Next Up section now match the body font size of the Scheduled section
- **Record defaults to Single** — clicking Record in the guide wizard now defaults to Single type; series options remain available
- **Quit defaults to Keep Recording** — when quitting with recordings in progress, "Keep Recording & Quit" is now the default (Return key) button; caffeinate/curl survive the quit and reattach on next launch
- **SeriesID(All) device fix** — when a SeriesID(All) show resolves to an episode on a different tuner than the one browsed, the recording now targets the correct device and channel URL instead of silently falling back to the wrong one
- **Menu first-click warmup** — app pre-renders the menu view 2 seconds after startup so the first click is as fast as subsequent ones
- **Cable guide lazy rows** — guide channel rows now render lazily (only visible rows), reducing initial load from ~50 rows to ~13

## 2026-05-21

- **Guide summary panel polish** — cable guide summary panel shows upcoming airings for SeriesID shows, with channel + day/time formatting
- **IP auto-update** — when a device's IP changes (e.g. DHCP lease renewal), stream URLs in saved shows are automatically updated from the fresh lineup data
- **Flat record options** — "Record as series…" sub-submenu removed; Single, DateTime, SeriesID-channel, and SeriesID-all are now all at the same menu level
- **Performance** — static DateFormatters cached across the app lifetime to avoid repeated allocations in menu and guide rendering
- **Discovery reliability** — startup now attempts up to 10 discovery retries; idle loop retries every tick while device list is empty
- **Menu tuner lines** — menu bar header shows each tuner's device ID and active/total recording slot count

## 2026-05-20

- **Cable guide grid** (`CableGuideView`) — full cable TV-style guide with rows per channel, proportional show blocks, genre-color coding, sticky channel column, synchronized vertical scroll, "Now" snap button, and genre filter picker
- **VLC integration** — "Watch in VLC" buttons appear in recording submenus and on-air guide entries when `/Applications/VLC.app` is installed and the toggle is enabled in Settings
- **Settings window** — `NavigationSplitView` settings with draft/save pattern, close warning, and six categories: General, Recording, Guide, Notifications, Advanced, About
- **Bonus Time for sports** — recording extends past the guide end time for shows whose genre contains "sports"; duration and toggle configurable in Settings
- **Fail threshold** — show is auto-paused after N consecutive recording failures (configurable); each successful start decrements the counter
- **Launch at Login** — `SMAppService` toggle in Settings → General
- **Verbose curl logging** — curl `-v` output piped to `~/Library/Logs/hdhr_VCR_curl.log`; toggled in Settings → Advanced
- **Notifications** — "Up Next" and "Recording Soon" alerts with configurable lead times
- **Boot resume** — recordings that survive an app restart are reattached on next launch by scanning `ps` for the caffeinate PID
- **Swift/SwiftUI rewrite** — full rewrite of the original 2016 AppleScript app; config file format preserved for compatibility
