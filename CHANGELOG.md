# hdhrVCRplus Changelog

## 2026-05-22 (260522-1500)

- **Network interface binding** — Settings → Advanced → "Discovery & recording interface" picker; binds UDP device discovery and curl recordings to a specific NIC; "Auto" uses OS routing (default); VPN tunnels (utun*, tun*, cscotun*, gpd*, zt*, etc.) are listed alongside physical interfaces, each labelled with its current IP address; tunnel detection uses the kernel's `IFF_POINTOPOINT` flag so all VPN types are caught regardless of vendor naming
- **VPN recording support** — when a VPN tunnel interface is selected, UDP broadcast is automatically skipped (tunnels don't support broadcast); known-hosts discovery (device IPs from saved shows) handles remote device lookup; curl stream is explicitly bound to the tunnel; enables recording from an HDHomeRun on a remote network via any standard VPN
- **OS simulation picker default** — Maintenance → Developer picker now shows "macOS X (current)" as the pre-selected default on first launch; stored as sentinel 0 so the AppStorage default always matches a picker tag (eliminates blank-picker flash on first open)
- **Stale interface auto-clear** — on Settings open, if the saved `Network_interface` names an interface that is no longer available (e.g. VPN disconnected), it is silently reset to Auto so a Save can't persist a value that breaks every recording
- **Changelog version filtering** — Settings → About now shows only the changelog sections up to the running build version; if a newer version exists in the fetched changelog, an "Update X is available" notice with a Releases link is shown above the changelog

## 2026-05-22 (260522-1342)

- **Pop-out cable guide** — toolbar button in the guide step opens the cable guide as a standalone floating window; Escape closes it; duplicate presses re-focus the existing window instead of opening a new one; browse-only (no Record button)
- **Homebrew install buttons** — Settings → Maintenance shows a Tools section when Homebrew is installed; buttons to install VLC (`brew install --cask vlc`) and the HDHomeRun CLI (`brew install libhdhomerun`); buttons replaced by a green "Installed" checkmark when the tool is already present
- **Stop Recording confirmation** — clicking Stop Recording now shows an NSAlert ("Stop & Deactivate / Keep Recording") to prevent accidental permanent deactivation
- **Delete confirmations** — Delete in scheduled menus, paused menus, and Edit Show now shows an NSAlert before permanently removing a show
- **Edit Show close warning** — closing Edit Show with unsaved changes prompts Save / Discard / Cancel, matching the Settings window behaviour; uses the same `WindowCloseInterceptor` pattern
- **Bonus Time callout in recording menu** — when a sports show is recording past its guide end time, a "🏈 Bonus Time (+N min)" info line appears in the recording submenu; remaining time now reflects the padded end, not the guide end
- **Paused show context** — paused show submenus now show show type and channel at the top, not just the last error reason
- **Notification timing validation** — Settings → Notifications shows an orange warning when the Recording alert interval is ≥ the Up Next interval, preventing a silent broken notification sequence
- **Clear Guide Cache** — new button in Settings → Maintenance discards all cached guide data immediately without requiring a restart
- **App icon** — `app.jpg` converted to `AppIcon.icns` (all required sizes, dark-padded square) and declared as `CFBundleIconFile`; the app bundle now shows the logo in Finder; `NSApplication.shared.applicationIconImage` set on launch so Force Quit and Activity Monitor also display it; `deploy.sh` regenerates the icns from `Resources/app.jpg` on every deploy
- **macOS 13+ compatibility** — deployment target lowered from macOS 15 to macOS 13 (Ventura); `onScrollGeometryChange` replaced with a version-adaptive `View.onScrollOffset` extension that uses the native API on macOS 15+ and a `PreferenceKey + GeometryReader` fallback on macOS 13/14; `ContentUnavailableView` wrapped in `EmptyStateView` (native on macOS 14+, custom VStack fallback on macOS 13); all `onChange` two-parameter closures converted to single-parameter form; `Color(Color)` initialiser replaced with direct `.opacity()` call
- **OS simulation picker** — Settings → Maintenance → Developer section lets you select "macOS 14 (Sonoma)" or "macOS 13 (Ventura)" to preview compatibility fallback paths on the current machine; reopen the guide or Add Show wizard to activate; orange warning label shown while simulation is active

## 2026-05-22 (260522-1210)

- **Project renamed to hdhrVCRplus** — bundle name, identifier (`com.hdhr.vcrplus`), Quit button, and process marker updated; source directory and config filename unchanged for AppleScript compatibility
- **App icon in menu bar** — `app.jpg` bundled locally (`Contents/Resources/`); used as the menu bar icon, proportionally scaled to actual menu bar height (`NSStatusBar.system.thickness − 2`); dimmed during startup, full opacity when idle; falls back to SF Symbol `tv` if bundle resource is absent
- **App icon in About** — Settings → About now loads the icon from the local bundle instead of fetching from GitHub; instant display, no network required
- **Tuner signal status in recording menu** — signal strength, lock type, and bitrate (`"Signal: 78% · lock: qam256 · 12.4 Mbps"`) appear in the recording submenu, polled from `http://<device-ip>/tuner{N}/vstatus` each idle loop tick
- **Recording conflict detection** — `⚠️` badge on scheduled show labels when all tuner slots are occupied at that show's start time; conflict detail line inside the submenu
- **Skip This Airing** — new button in active recording submenu; stops the recording and advances to the next scheduled airing without incrementing the fail count
- **Cable guide dynamic width** — guide grid fills available window width; `pxPerMin` scales up as the window is widened (min 4.2 px/min); window resizable from 1100×720 minimum instead of fixed 980×700
- **Starburst animation in summary panel** — sports show with Bonus Time enabled now shows the animated 🏈 starburst badge in the guide step summary panel, not only in the Details step
- **Watch in VLC — on-air only** — VLC button in the guide summary panel is now suppressed for future shows; only appears when the selected entry is currently broadcasting
- **Next Up submenus** — shows in the "Next Up" section now open full submenus (poster, synopsis, episode info, timing, Edit/Deactivate/Delete) matching the Scheduled section
- **Scheduled menu: poster + synopsis** — poster image and synopsis added at the top of each scheduled show submenu, consistent with the recording now menu
- **SeriesChannel icon** — SeriesID(Channel) shows now use 🔂 instead of 📺 to distinguish from a plain TV icon
- **"ch" → "Channel"** — all user-visible strings changed from `"ch N"` to `"Channel N"` throughout menus, summary panel, and notifications
- **VLC button orange** — all "Watch in VLC" button labels now render in VLC brand orange (#FF7B00)
- **Settings: Save & Close** — new button in Settings bottom bar saves and closes the window in one click
- **Settings: Update Guides Now** — button in Settings → Guide section triggers an immediate guide refresh for all devices
- **Watch in VLC auto-enable** — on first launch, if `/Applications/VLC.app` is installed the Watch in VLC setting is automatically enabled; subsequent user toggles are never overridden
- **Double-click tuner to advance** — double-clicking a device in the tuner selection step immediately advances to the guide step
- **Richer device info in tuner step** — device rows now show IP, tuner count, lineup channel count, firmware version, and active recording count (red when > 0)
- **Tuner switch invalidates cache** — changing the tuner picker in the guide step immediately clears the guide and lineup cache for that device and reloads fresh data
- **Cancel buttons removed; Escape exits** — Cancel buttons removed from AddShowView and EditShowView nav bars; Escape key dismisses both windows via `.onExitCommand`
- **Config recovery from backup** — if the main config file is missing or corrupt on launch, the app automatically restores it from the `.json.bak` backup
- **Documentation overhaul** — `cableView.md` deleted; `docs/CableGuideView.md` rewritten with full layout reference; `docs/CableGuideView_pitfalls.md` created (10 failed layout attempts); all view docs updated to reflect current code; CLAUDE.md Documentation section added; `docs/todo.md` created with known improvement areas

## 2026-05-22 (v1.0.0)

- **SeriesID title fallback** — when the guide omits a SeriesID for a currently-airing episode, recording scheduling now falls back to a title match against the channel entry index; ensures shows like daily court/syndicated programs are picked up even when the guide API omits the SeriesID for that specific slot
- **Maintenance panel** — Settings → Maintenance (wrench icon) with five action buttons: Rescan Series (re-check guide for updated next-air times on all active SeriesID shows), Reset Fail Counts, Reactivate Paused Shows, Refresh Guide, and Rediscover Devices; each shows a spinner and result message
- **Add Show at top of menu** — moved above Recording Now so it is always the first action, regardless of how many shows are scheduled
- **Recording process survives force-quit** — recording processes (caffeinate + curl) are now launched via `posix_spawn` with `POSIX_SPAWN_SETSID`, placing them in their own POSIX session independent of the app's process group; a force-quit of the app leaves recordings running and the existing boot-resume mechanism reattaches them on next launch
- **Refresh Guide removed from main menu** — available in Settings → Maintenance instead

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
