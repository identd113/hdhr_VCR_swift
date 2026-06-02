# hdhrVCRplus Changelog

> In-app changelog (Settings → About) is maintained in [`Sources/hdhr_VCR/Changelog.swift`](Sources/hdhr_VCR/Changelog.swift).

## 2026-06-02 (260602-sparkle)

- **Sparkle auto-updater** — `SPUStandardUpdaterController` integrated; Settings → About now has a **Check for Updates** button that opens Sparkle's standard update panel. The in-changelog version comparison and manual "Update available" banner have been removed in favour of Sparkle handling all update discovery and installation. `SUFeedURL` in Info.plist points to the repo's `appcast.xml`; `SUPublicEDKey` is set to the EdDSA public key matching `~/.sparkle_private_key` (generated once by `tools/generate_sparkle_keys.sh`). `deploy.sh` and `deploy_release.sh` updated to bundle and sign `Sparkle.framework` (including its nested XPC services and `Updater.app`) inside-out before signing the main bundle.
- **Sparkle — `SUPublicEDKey` placeholder crash fix** — Sparkle aborts the process if `SUPublicEDKey` is missing or not a valid EdDSA key. Replaced `SPARKLE_PUBLIC_KEY_PLACEHOLDER` with the real public key from the pre-existing `~/.sparkle_private_key`. `generate_sparkle_keys.sh` parser updated to handle Sparkle's "pre-existing key" output format.
- **Web server settings** — New **Settings → Web Server** panel: enable/disable toggle, port field (validated 1025–65534), live status and access URL (shown only when running). Saving changed web server config calls `setupWebServer()` immediately to start/restart/stop the listener. Port validation blocks Save and `WindowCloseInterceptor` with a consistent error message alongside the existing Discord webhook check.
- **`com.apple.security.network.server` entitlement** — Added to `hdhrVCRplus.entitlements` so `NWListener` can bind under Hardened Runtime. Without it the listener silently failed to start when the app was launched via `open`.
- **`NSLocalNetworkUsageDescription`** — Added to `Info.plist` for the NWListener mDNS service advertisement (required for macOS local network privacy prompt to appear).
- **deploy.sh — iCloud `com.apple.FinderInfo` race fix** — `codesign --options runtime` rejects `com.apple.FinderInfo` as "detritus"; iCloud Drive re-attaches this xattr to Sparkle's nested executables faster than a retry loop can strip it. The signing step now works in a `/tmp` copy of the bundle (outside iCloud Drive), then replaces the in-repo bundle with the freshly signed copy.
- **Web server — early startup** — `setupWebServer()` moved to run right after `loadConfig()` in `startup()`, before device discovery and guide fetch. The server binds the port within ~1s of launch instead of waiting 10–20s for the full startup sequence.
- **AppState.onAirNow(for:at:)** — Extracted the on-air channel lookup from `WatchNowView` into a shared method; also used by `WebServer.buildNowJSON` to avoid duplicating the lineup × guide walk.
- **Shared helpers** — `timeRemaining(until:)` and `he()` (HTML entity escaping) moved from `WatchNowView` / `WebServer` into `GuideViewHelpers.swift` as free functions.

## 2026-06-02 (260602-webserver)

- **Web server — multi-device Recording badge fix** — `recChannels` was a flat set of channel numbers across all devices, so a recording on device A incorrectly showed the red ● Recording badge on device B's same channel number in the guide grid. Replaced with `recChannelsByDevice: [String: Set<String>]` keyed by device ID; `isRecCh` now checks only the current device's recording channels.
- **Web server — paused-show badge alignment** — `buildNowJSON`'s `isScheduled` field was querying `managedShowBySeriesID`/`managedShowByTitle` (which include paused shows) while the guide HTML's ★ badge logic excluded paused shows via `activeMgd`. Added `!show_paused` guards to both checks in `buildNowJSON` so the JSON API and the guide grid agree on managed-show status.
- **Web server — `</script>` injection prevention** — `JSONSerialization` does not escape `<`, `>`, or `&` by default; a show title containing `</script>` would terminate the script block in the served page. Added `jsEscapeForScript()` (replaces `<`/`>`/`&` with `\uXXXX` escapes) applied to both `var tuners` and `var recsByDev` before embedding in the `<script>` block. `tunerJS` also moved from raw string interpolation to `JSONSerialization` so DeviceID and LocalIP values are never interpolated directly into JS string literals.
- **Web server — tuner popover innerHTML XSS fix** — `showTunerInfo()` was concatenating `r.title`, `r.ch`, `r.chname`, and `r.tuner` directly into `innerHTML`. Added client-side `hej(s)` helper (escapes `&`, `<`, `>`) and applied it to all four values.
- **Web server — onclick JS injection fix** — device filter buttons and tuner badge buttons now use `onclick="setDev(this.dataset.dev)"` / `onclick="showTunerInfo(this.dataset.dev,this)"`, reading DeviceID from the already-`he()`-escaped `data-dev` attribute rather than interpolating it into a JS string argument.
- **Web server — IPv4-mapped loopback** — `isLocalAddress()` now strips the `::ffff:` prefix before the loopback check so `::ffff:127.0.0.1` (IPv4-in-IPv6 localhost connection) is correctly allowed without falling into the AF_INET6 subnet walk.
- **Web server — 128 KB request cap** — `accumulate()` now rejects any connection whose total buffered bytes exceed 128 KB (or whose `Content-Length` header declares more) with `413 Content Too Large`, preventing memory exhaustion from slow or malicious LAN clients.
- **Web server — O(n²) buffer copies fixed** — `let data = buffer + chunk` allocated a full copy of the accumulated buffer on every receive callback. Changed to `var data = buffer; data.append(chunk)` so Swift reuses existing storage capacity; a 128 KB request arriving in small chunks now copies each byte once instead of ~4 MB total.
- **Web server — `\r\n\r\n` separator static constant** — the HTTP header separator `Data` was re-created from a string literal on every `conn.receive` callback. Promoted to `private static let httpSep`.
- **Web server — `recordingShows` captured once per render** — `state.recordingShows` (a computed `shows.filter` property) was accessed six times inside `buildHTML`. Captured as `let recording = state.recordingShows` at the top of the function.
- **Web server — single-pass isSeries filter** — `activeMgd.filter { $0.isSeries }` was called twice to build `mgdSID` and `mgdTitSeries`. Merged into a single `for s in activeMgd where s.isSeries` loop.
- **Web server — Watch Now avoids redundant guide walk** — `state.onAirNow(for:)` was performing a full lineup × `guideStore.entries` walk that the guide grid loop had just completed for every channel. Now `nowByDevice` is populated in-place during the grid pass (`if isNow { nowByDevice[device.DeviceID, default: []].append((ch, e)) }`); the Watch Now section iterates this dict directly.
- **Web server — `pct()` uses integer arithmetic** — the percentage-position formatter called `String(format: "%.4f", ...)` for every guide block's left and width positions (~1500 calls per full-guide render). Replaced with integer multiply/divide and manual digit extraction; no `String(format:)` at all in the hot loop.
- **Web server — removed dead `.redirect` case** — `WebResponse.redirect` was defined and handled in `send()` but never returned by any route handler. Removed.

## 2026-05-31 (260531-1700)

- **`X-HDHomeRun-Error` header parsing** — `RecordingManager` now passes `--dump-header /tmp/hdhrVCRplus-<showId>.headers` to every curl recording. When curl exits unexpectedly mid-recording, `AppState` reads the header file via `readAndClearHDHRError(showId:)` and maps the error code to a human-readable string (e.g. "Tuner In Use (804)", "No Video Data (807)", "DVR Full (810)"). The precise reason replaces "curl exited unexpectedly" everywhere it appears: `show_fail_reason`, the system notification subtitle, and the Discord embed `Reason` field. Falls back to "curl exited unexpectedly" if no `X-HDHomeRun-Error` header was written (connection-level failures). Header file is cleaned up on both stop and read.
- **Native Markdown changelog** — Settings → About replaces the hand-parsed `renderChangelog()` `@ViewBuilder` with a `MarkdownView: NSViewRepresentable` backed by `NSTextView` + `AttributedString(markdown:options: .init(interpretedSyntax: .full))`. Delivers proper heading sizes, real bullet lists, inline code, and bold text. Height is self-measured via `layoutManager.usedRect(for:)` after each layout pass and injected as `.frame(height:)` so the view grows with content.

## 2026-05-31 (260531-1625)

- **VLC error overlay** — when VLC hits a fatal stream error (connection refused, no route to host, etc.), an orange triangle + "Stream Unavailable" overlay appears within ~3 seconds instead of a silent black screen; a Retry button restarts the stream. Powered by `libvlc_media_player_get_state` (state 7 = `libvlc_Error`) polled each rate-controller tick.
- **Start button gating** — the poster overlay's Start button now shows a spinner + "Connecting…" (disabled) until VLC confirms `libvlc_Playing` (state 3); prevents unmuting a stream that hasn't connected yet. `VLCBridge` publishes `isPlaying: Bool` updated each tick.
- **MPEG-2 audio init fix** — added `--no-audio-time-stretch` media option to prevent the `too low audio sample frequency (0)` crash that occurs on live MPEG-2 streams before the first audio frame arrives.
- **Real-time tuner occupancy refresh** — `AppState.refreshTunerOccupancy()` polls `/status.json` 1.5 s after any tuner-affecting event (recording start/stop, VLC open/close, channel switch) so the menu header count updates promptly instead of waiting for the next idle-loop tick (~10 s).
- **Tuner count includes VLC player** — the "app expects N" figure in the menu header now counts the VLC player as +1 tuner on its device; recording one show while watching = "app expects 2".
- **Now Watching section** — moved below the Settings divider, directly above Recording Now; wrapped in a `Section("Watching · <deviceID>")` header matching the style of Recording Now / Scheduled.

## 2026-05-31 (260531-1324)

- **Tuner audit log** — `fetchDeviceStatus` now logs `[TunerAudit] DEVID: N/M active  rec=N vlc=N` every idle tick (~10s), making unexpected tuner usage immediately visible in the log without manual status endpoint polling
- **VLC stop on quit** — `quit()` now calls `VLCBridge.shared.stop()` in all three exit branches (fast-quit, Keep Recording & Quit, Stop Recordings & Quit) so the in-app player releases its tuner immediately on app exit rather than relying on OS-level cleanup

## 2026-05-31 (260531-1212)

- **Immediate channel buffering** — `playChannel` now calls `VLCBridge.play()` immediately when the channel picker changes so the new stream starts buffering the moment the poster overlay appears; tuner status check moved to a fire-and-forget background Task that logs results without blocking stream start
- **Now Watching tracks channel switches** — `state.vlcCurrentURL` is now updated by `playChannel` (picker-driven switches), not only by `watchInApp`, so the Now Watching indicator stays accurate after switching channels inside the player
- **Start button logs buffer depth** — clicking Start to dismiss the poster overlay logs `[VLC] Start clicked — buffer ~X.Xs built before unmute` showing how much headroom accumulated while the poster was visible
- **Post-switch tuner log** — after each channel switch, `playChannel` fetches `status.json` and logs `[VLC] post-switch tuner status ch X.X: N/M active (ours=N other=N)`; warns if other streams appear to have taken all slots
- **VLC diagnostic logging** — comprehensive `[VLC]` log lines throughout `VLCBridge` and `VLCPlayerView` to diagnose the black-screen issue: `play()` logs URL and warns when deferred to pending (drawable not ready); `stop()` logs drawable state at call time; `setDrawable()` logs view identity and pending-URL handoff; `catchUpToLive()` logs the reconnect URL; `syncChannel()` logs match result; `playChannel()` logs channel + URL; `WindowManager.open` logs reuse vs new window; remote Stop command (media key / Now Playing) logged as the likely black-screen cause — clears `drawableView`, leaving window black until closed

## 2026-05-31 (260531-0239)

- **Close VLC player on show delete/skip** — deleting or skipping a show now closes the in-app VLC player window if it is currently streaming that show's URL, freeing the tuner immediately alongside the recording PID kill; uses `VLCPlayerWindowManager.closeIfPlayingURL(_:)` — exact URL match, no-op when the player is on a different channel
- **URL match fix** — `nowWatchingInfo` channel lookup now uses exact URL equality instead of a bidirectional prefix check, preventing false matches when one channel URL is a prefix of another (e.g. `v5.1` matching when watching `v5.10`)

## 2026-05-31 (260531-0239)

- **Now Watching indicator** — when the VLC player is open, a `play.tv.fill` button appears in the menu between the status row and Watch Now showing the current channel number, name, and on-air show title (e.g. "Ch 5.1  NBC · Jeopardy!"); clicking it focuses the player window without switching the stream. Disappears automatically when the player window is closed.
- **VLCPlayerWindowManager.focus()** — new method that brings the player window to the front without affecting the stream; used by the Now Watching button and available for future callers
- **Player window clear on close** — `vlcCurrentURL` is now cleared to `""` when the VLC player window is dismissed, ensuring the Now Watching button never lingers after the player is gone

## 2026-05-31 (260531-0223)

- **Native resolution button** — `aspectratio` icon in VLC player toolbar; calls `libvlc_video_get_size`, divides by screen backing scale, and resizes the window to display video at 1:1 physical pixels; no-op until the first frame is decoded
- **Buffer monitor icon** — `waveform` SF Symbol added to the left of the fill bar; color tracks fill state (accent while filling, green when full)
- **Speed up to live** — catch-up button updated to `forward.end.circle` icon with tooltip "Speed up to live — discard buffer and jump to live edge"
- **Native resolution** — `videoNativeSize()` added to `VLCBridge` via `libvlc_video_get_size`; `VLCPlayerWindowManager.sizeToNativeVideo()` handles window resize

## 2026-05-31 (260531-0157)

- **Buffer monitor** — `waveform` icon + fill-bar capsule in VLC player toolbar (visible only when buffering enabled); fill = lag / 8s, blue while filling, green when full (≥ 7s); hover popover shows lag, rate, bitrate, and corruption count. `VLCBridge` made `ObservableObject`; `VLCBufferInfo` published every 3s; rate/lag published unconditionally before stats guard so bar works on VLC 4+
- **Watch Now focus-or-open** — clicking Watch Now in the menu now brings the existing window forward if already open, matching Add Show / Edit Show / Settings behaviour

## 2026-05-31 (260531-0137)

- **Proportional poster images** — Watch Now thumbnails are now ~50% larger (34% of window width, capped at 220pt, aspect-ratio locked at 96:68) and scale with window resize instead of being fixed at 96×68pt; VLC player poster overlay scales to 30% of the player window width instead of a hardcoded 300pt

## 2026-05-31 (260531-0001)

- **Buffered live TV playback** — the in-app VLC player now builds and maintains an ~8-second live buffer to absorb brief signal drops invisibly. Uses an adaptive rate controller: starts at the user-configured floor rate (default 93%), ramping toward 100% as the buffer fills over ~3 minutes, then holds at 1.0× to maintain the lag. `--drop-late-frames` and `--avcodec-hurry-up` tell VLC to drop corrupt/late frames rather than showing artifacts.
- **Auto catch-up on bad signal** — polls `libvlc_media_player_get_stats` every 3 seconds; if `i_demux_corrupted` rises by >15 or `i_lost_pictures` rises by >20 in a single tick, the stream restarts at the live edge automatically (30s debounce). The rate controller resets and the fill phase begins again.
- **Catch Up button** — `⟳` button in the VLC player toolbar; discards buffered content and reconnects at the live edge on demand without showing the poster overlay or requiring a Start click.
- **Min buffer rate setting** — Settings → Recording → Min buffer rate picker (90%–100%, default 93%). Sets the floor speed during the fill phase; 100% disables buffering entirely while keeping the Catch Up button functional.
- **Buffering diagnostics** — VLC version logged at startup; WARNING if VLC 4+ detected (stats struct changed); rate acceptance verified after `set_rate` and logged as WARNING if ignored; stats call failures logged; rate ramp ticks logged to `hdhrVCRplus.log`.
- **Discord progress updates** — new "Progress updates (every 5 min)" toggle in Settings → Discord. When enabled, the Recording Started embed is edited in-place every 5 minutes with elapsed and remaining time (e.g. "32m elapsed · 28m remaining"). Completion and failure events also edit the same message rather than posting a new one, so each recording produces a single Discord message that tracks its full lifecycle. Uses `?wait=true` capture on the start embed and `PATCH /messages/{id}` for edits.

## 2026-05-30

- **Code modularization** — extracted duplicated helpers from AddShowView, FloatingGuideView, MenuContent, and CableGuideView into a shared `GuideViewHelpers.swift`: `ManagedFlagView` (yellow corner triangle), `sortedGuideChannels(_:favorites:)`, `guideTimeRange(_:)`, and shared DateFormatters (`origAirdateFormatter`, `upcomingFormatter`, `timeRangeFormatter`). `GuideEntry.episodeInfoLabel` moved to a Models.swift extension. `bonusOverlapWarning` moved to AppState. Show failure field mutations consolidated into `Show.recordFailure(reason:)` and `Show.clearFailures()`. Guide API backoff+notify logic deduplicated into `handleGuideLoadFailure(deviceId:)`. Net: −139 lines, no behaviour changes.
- **vstatus log removed** — "no locked tuner found in status.json" warning suppressed; it fired spuriously when the tuner released between recording end and the vstatus poll
- **Bonus overlap display fix** — overlap minutes now floor at 1 so sub-60-second overlaps never display as "First 0 min overlap"
- **Bad config repair** — four shows had a stale Mac alias path (`Raid6:DVR Tests:`) as `show_temp_dir`; updated to `/Volumes/Raid6/DVR Tests` to match all other shows

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
