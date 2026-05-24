# hdhrVCRplus Changelog

## 2026-05-24 (260524-0119)

- **Discord webhook notifications** — Settings → Notifications → Discord Webhook; paste a webhook URL to send rich embeds to any Discord channel. Per-event toggles (enabled by default): Recording Started, Recording Complete, Recording Failed, Show Paused, Skipped (Disk Full), Tuner Conflict, Guide Load Failed. Off by default: Up Next, Recording Soon, Show Added. Each toggle has a **Test** button that fires a live embed to the draft URL using real show data without saving. Embeds include: station icon (`author.icon_url` from guide channel image), show poster thumbnail, bold title + episode number/title + synopsis, Channel/Type/Time inline fields, filter tags as `` `Drama` `` `` `Series` `` code buttons, and event-color sidebar (green=started, blue=complete, red=failed, orange=paused/skipped, yellow=conflict, teal=added, purple=reminders, grey=errors). Recording Complete embeds additionally show **Format** (file extension, e.g. `TS`) and **File Size** (e.g. `2.34 GB`) inline fields from the actual output file. Blank or non-discord.com URLs are silently skipped.
- **Watch Now! ungated** — the VLC in-app player "Watch Now!" button no longer requires the `Player_unlocked` easter egg; it appears whenever VLC is installed at `/Applications/VLC.app`
- **Tuner availability check** — clicking "Watch Now!" fetches live `/status.json` from the device and shows an alert if all tuners are occupied; channel switching in an already-open player window bypasses the check since that window already holds a tuner slot
- **Channel picker sync** — the channel picker in the VLC player window now syncs to the channel you clicked "Watch Now!" from; switching channels while the window is open also updates the picker; `suppressNextChannelPlay` flag prevents a redundant second play call on sync-driven selection changes
- **Settings: Save & Close as default** — Save & Close is now the rightmost, prominent (`.borderedProminent`) button in the Settings footer, triggered by Return; Save (⌘S) is secondary and only enabled when dirty; Save & Close is always enabled (just closes when nothing is dirty)

## 2026-05-23 (260523-1751)

- **Config moved to Application Support** — config file relocated to `~/Library/Application Support/hdhrVCRplus/hdhr_VCR-{hostname}.json`; ad-hoc re-signing during development no longer resets TCC permissions and clears all shows; one-time migration from `~/Documents` runs on first launch, old file preserved for AppleScript app compatibility
- **Unbuffered log output** — `setbuf(stdout/stderr, nil)` applied after `freopen`; every `print()` line now lands on disk immediately instead of buffering in 8 KB chunks
- **Cable guide vertical scroll sync** — replaced `.onScrollGeometryChange` (fires only on SwiftUI re-evaluation, not AppKit layer scroll) with `VerticalScrollTracker: NSViewRepresentable`; embeds a zero-size `NSView` that hooks `NSView.boundsDidChangeNotification` on the enclosing `NSScrollView`, firing on every scroll frame
- **Guide summary poster fills panel height** — poster image is now `frame(width: 180).frame(maxHeight: .infinity)` (was `frame(width: 140, height: 100)`); channel icon enlarged to 52 pt
- **Stale channel icon cleared** — `ChannelIcon` now sets `img = nil` when `urlString` changes to nil/empty; switching from a channel with a logo to one without no longer shows the previous channel's logo
- **Wizard SeriesID scheduling fixed** — `save()` now calls `resolveSeriesAir()` before `addShow()`, matching the menu-flow; selecting a future airing now correctly schedules from the current (or nearest) episode
- **"Watch in App" gated on onAir** — button only appears when the selected show is currently broadcasting, consistent with "Watch in VLC"; applies in both the guide summary panel and `entryMenu()`
- **In-app AVKit player** — `Player_unlocked` easter egg (5-tap About logo) unlocks a pop-out `AVPlayerView` window; always forces `transcode=heavy` since AVPlayer does not support raw MPEG-2

## 2026-05-23 (260523-1212)

- **Prevent duplicate scheduling** — the guide wizard and menu-mode Add Show now detect already-managed shows (matched by SeriesID, falling back to title) and replace the Record button / record menu items with an "Edit Show" action; you can no longer accidentally create a duplicate entry for a show already in your schedule; clicking "Edit Show" opens the existing show directly in EditShowView
- **Record/Edit button layout stability** — the button is now a single SwiftUI `Button` view with a fixed minimum width (90 pt) that switches label and color in place; previously two separate `if/else` views caused the Spacer to relax and the channel-time text to shift when clicking between managed and unmanaged shows
- **Overlap warning layout stability** — the bonus-time overlap warning text in the guide summary panel is always in the layout (opacity 0 when absent) so the button row above it stays at a fixed vertical position when switching between shows that do and don't trigger a warning
- **Per-show bonus time flag** — `show_bonus_time: Bool` added to `Show`; any show type can now opt into the recording extension, not just shows whose genre contains "sports"; existing config files migrate automatically (genre-based detection used as the decode fallback)
- **Bonus-time overrun box redesign** — the dotted overrun box in the cable guide is now filled with the bonus show's genre color (70% opacity) instead of just a colored outline; the overlapped show's title is displayed inside the box; the box is tappable and selects the overlapped show in the summary panel
- **ShowFormSection extracted** — title, type, days/day, transcode, and folder picker rows extracted into a shared `ShowFormSection` component; used by both the Add Show details step and EditShowView, eliminating ~80 lines of duplication
- **Starburst badge in details step and EditShowView** — the animated starburst badge now appears when `show_bonus_time` is true in both the Add Show details step and EditShowView; removal uses a shrink+fade transition
- **CableGuideView vertical scroll** — removed the `CompatibilityHelpers.onScrollOffset` shim; vertical scroll offset now uses `onScrollGeometryChange` directly since macOS 15 is the deployment floor

## 2026-05-22 (260522-2057)

- **Multi-selection bug fixed** — selecting a show in the cable guide no longer highlights every block at the same start time across all channels; caused by Swift's `nil == nil` evaluating to `true` when lineup data was absent — `ShowBlocksRow` now requires `lineupEntry != nil` before comparing `GuideNumber`
- **Record and Watch in VLC buttons now reliably enabled** — `AppState.ensureLineupLoaded(for:)` re-fetches lineup on demand if `lineups[deviceID]` is nil or empty (recovering from silent `try?` failures in `fetchAllLineups`); called at the start of guide loading in both `AddShowView` and `FloatingGuideView`, guaranteeing `selectedChannel` resolves correctly before the guide grid populates
- **FloatingGuideView lineup fix** — the floating cable guide was clearing `state.lineups` on device change, leaving `selectedChannel` permanently nil and disabling both buttons; lineup is now stable across device changes (only the guide cache is invalidated)
- **StarburstBadge** — extracted starburst animation into a standalone reusable `StarburstBadge` component (`StarburstBadge.swift`); uses two stacked `keyframeAnimator` modifiers for a pop-in animation on appear and a 5-tap celebration spin; used in AddShowView details step, AddShowView summary panel, and FloatingGuideView summary panel
- **macOS 13 support dropped** — minimum deployment target raised from macOS 13 to macOS 14; `EmptyStateView` simplified to call `ContentUnavailableView` directly; macOS 13 simulation option removed from Settings → Maintenance → Developer; `keyframeAnimator` (macOS 14+) now available without availability guards

## 2026-05-22 (260522-1600)

- **Discard resets OS-sim picker** — the Discard button in Settings now correctly reverts the OS simulation picker to its saved value (was missing from the reset list, causing `isDirty` to stay true permanently after touching the picker then discarding)
- **Stale-interface clear propagates to live config** — when Settings opens and detects a disconnected interface (e.g. VPN dropped), it now clears `Network_interface` in both the draft AND the live `AppConfig` and saves immediately; previously only the draft was cleared, so Discard-and-close left the dead interface name active for all subsequent curl recordings, causing every recording to fail silently
- **`refreshGuides()` guards concurrent runs** — added an in-flight flag so the idle loop and an interface-change Save can't both enqueue a `refreshGuides()` simultaneously; the second call returns immediately rather than racing through guide invalidation and rebuild at interleaved await points
- **`refreshGuides()` retry on empty load** — `lastGuideRefresh` is now only stamped when at least one channel was actually loaded, matching `fetchAllGuides()`; previously a refresh that found no devices (e.g. right after a VPN reconnect) would suppress the next periodic retry for up to 12 hours
- **`if_nametoindex` failure logged** — when the UDP socket can't resolve a configured interface name to an index, a `[Discovery]` log line is printed instead of silently falling back to the OS default route

## 2026-05-22 (260522-1530)

- **All new settings require Save** — the OS simulation picker in Maintenance → Developer now follows the draft/save pattern; changing the picker marks Settings as dirty (Save button turns orange) but does not apply until Save is clicked; Discard reverts the draft; the existing `isDirty` banner and ⌘S shortcut work as expected
- **Interface change triggers refresh** — switching the "Discovery & recording interface" in Settings → Advanced and clicking Save automatically invalidates the guide cache, clears loaded device channels, re-runs device discovery (so UDP binds to the new NIC), and reloads the guide; the new interface is fully active immediately without restarting the app

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
