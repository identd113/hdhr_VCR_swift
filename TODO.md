# TODO

Deferred features and improvements. Add items here when a task is punted. Remove when complete and note the resolving commit in `ISSUES.md` if the work was non-trivial.

---

## Show Stoppers

### macOS Local Network permission block — lineup (and likely device-info/favorites) fetch fails on every launch

Confirmed root cause via an instrumented build (2026-08-09). `AppState.fetchAllLineups`'s call into `HDHRManager.fetchLineup` (a plain `URLSession.shared.data(from:)` GET to `http://{LocalIP}/lineup.json`) fails with:

```
NSURLErrorDomain Code=-1009 "The Internet connection appears to be offline."
NSUnderlyingError={..., _NSURLErrorNWPathKey=unsatisfied (Local network prohibited), ...}
```

— macOS's Local Network Privacy (TCC) is blocking the app's direct-IP HTTP requests to the HDHomeRun tuner. Reproduced identically on both the ad-hoc-signed dev build (`deploy.sh`) and the Developer-ID-signed release build running from `/Applications` — same `[WARN] [Lineup] {id} fetch failed` on every launch of either, no exception.

Guide data loads fine (`GuideStore.load()` hits `api.hdhomerun.com`, a cloud host — not gated by LNP), which is why the guide looks healthy in the log while lineup silently fails right next to it, and why the on-screen symptom can read as "guide is broken" when the actual break is lineup-only. Once lineup is empty, everything downstream of it degrades too: `reconcileFavorites` (channel favorite flags), `streamURL(for:)` (used by `updateShowURLsFromLineups` when a device's IP changes — stale/broken Watch Now and recording URLs), and the channel list in Settings.

**Suspected trigger**: Info.plist correctly declares `NSLocalNetworkUsageDescription`, so the OS *should* prompt on first local-subnet connection attempt — but this is an `LSUIElement` (no Dock icon, no main window) menu-bar-only app, a known case where the system permission dialog can fail to surface on first launch, leaving the app permanently in "prohibited" state with no visible ask and no self-recovery path. Confirming this needs `sudo tccutil reset LocalNetwork com.hdhr.vcrplus` to force a re-prompt — which itself failed here with error 70, most likely because the calling process lacks Full Disk Access, a second permission gate standing in front of the fix.

**User-side fix — partial, unresolved as of 2026-08-09 20:50Z**: System Settings → Privacy & Security → Local Network → find hdhrVCRplus and toggle it on. On this machine the toggle was confirmed present and on (single row, no separate `hdhr_VCR` entry) — after that, the ad-hoc dev build (`~/Documents/github/hdhr_VCR_swift/hdhrVCRplus.app`) started succeeding consistently (`[Lineup] 105404BE loaded 112 channels`), **but the Developer-ID-signed `/Applications/hdhrVCRplus.app` build kept failing on repeated relaunches immediately after**, with the same single toggle reportedly already on. So flipping the one visible toggle did not fix the actual installed app. Working theory: some OS-level network-path/NECP cache keyed by the app's code identity (separate from the TCC permission row itself) is holding a stale "prohibited" verdict for the Developer-ID-signed binary specifically, independent of the TCC toggle state — untested fixes for next session: toggling Wi-Fi off/on (clears NECP path cache), a full reboot, or waiting out whatever cache TTL is in play, then relaunching `/Applications/hdhrVCRplus.app` again and checking `hdhrVCRplus.log` for `[Lineup] ... loaded` vs `fetch failed`. If it's not listed in Local Network at all on a clean machine, grant Full Disk Access to Terminal first, then `sudo tccutil reset LocalNetwork com.hdhr.vcrplus` and relaunch to force a fresh prompt.

**Code fix already applied**: `AppState.fetchAllLineups` (`AppState.swift`, `fetchAllLineups`) previously swallowed the failure via `try?`, logging only `"fetch failed"` with zero detail — this made the bug silent and effectively undiagnosable from the log alone. Now does `do`/`catch` and logs the real `NSError` (including the NWPath reason), so this class of failure is self-diagnosing from `hdhrVCRplus.log` going forward.

**Code fix applied 2026-08-09**: `fetchDeviceInfo(ip:)` (`HDHRManager.swift` → `fetchDeviceInfo`, called from `knownHostsDiscover` and `udpDiscoverAndFetch`) hit the same silent-failure shape as the lineup bug before today's first fix — both callers used bare `try?` with zero logging. Both now do the same `do`/`catch` + `glog("[Discovery] fetchDeviceInfo(...) failed: ...", level: .warning)` treatment, preserving each caller's existing fallback (`nil` for `knownHostsDiscover`, the raw UDP-reply `device` for `udpDiscoverAndFetch`).

**Verified already correct, not a bug**: `setFavorite` (`HDHRManager.swift` → `setFavorite`) only logs on HTTP error *responses* itself, but its one caller — `AppState.toggleFavorite` — already wraps every call in a `do`/`catch` that logs *any* thrown error (including a connection that never completes, this LNP case) at `.error` level and reverts the optimistic UI update. This has existed since the original favorites commit, predating this investigation. No fix needed.

**Still open** — an OS permission decision, not something code can fix:
- Ad-hoc dev builds (`deploy.sh` → `Signature=adhoc`, no Team ID) and Developer-ID release builds (`deploy_release.sh` → a real Team ID) are different code identities as far as TCC is concerned — granting Local Network access on one does not carry over to the other. Worth remembering during dev/release testing so "I already approved this" doesn't get assumed incorrectly.
- Per the 2026-08-09 20:50Z note above: the Developer-ID-signed `/Applications` build kept failing even after the TCC toggle was confirmed on, suggesting a possible stale OS-level network-path cache keyed by code identity, separate from the TCC row itself — untested: Wi-Fi off/on, full reboot, or waiting out whatever cache TTL is in play.

**Deeper dig, 2026-08-09 ~21:15Z — the toggle showing "on" is probably cosmetic, not a real grant.** Queried the actual permission stores directly on the affected machine rather than trusting the Settings UI: `sqlite3` against both `~/Library/Application Support/com.apple.TCC/TCC.db` (per-user) and `/Library/Application Support/com.apple.TCC/TCC.db` (system) — the system db is readable (30 unrelated rows exist, so this isn't a read-access problem) but has **zero** `kTCCServiceLocalNetwork` rows for any client, hdhr or otherwise. Also checked the newer `REG.db` macOS 26 keeps alongside `TCC.db` in the same folder, in case Local Network moved there — dead end, it turned out to be an unrelated internal registry mapping each user account to the path of *their own* `TCC.db` file, not an app-permission store. So on this machine (macOS 26.6, confirmed real hardware — an M4 MacBook Air, not a VM, ruling out that theory too), **no decision has ever actually been recorded for this app**, in any store checked, despite System Settings displaying the row as already toggled on. Best working explanation: Settings shows an app's Local Network row as on-by-default once it sees `NSLocalNetworkUsageDescription` declared, before the OS has ever actually completed a real consent handshake with the user — i.e. the UI can lie in the "allowed" direction for an app that's actually stuck undetermined-and-failing-closed. This also explains the earlier `tccutil reset` error 70: with no record in the database, there was nothing to reset.
- Next untested step, and now the leading theory over the network-path-cache one above: a full reboot, since that clears both any lingering NECP path-evaluation cache *and* whatever half-finished consent-negotiation state might be stuck in memory for this specific `LSUIElement` app. After rebooting, launch `/Applications/hdhrVCRplus.app` once and watch closely for an actual system dialog — not just the Settings row — before assuming it's still broken.

**Research correction, 2026-08-09 ~22:00Z — the TCC.db finding above was checking the wrong store.** Local Network privacy is **not** implemented via TCC at all — it's a packet filter in the Network Extension framework, with its own separate state (reportedly `/Library/Preferences/com.apple.networkextension.plist` and `.uuidcache.plist`), confirmed against Apple DTS forum threads and independent research. So the "zero `kTCCServiceLocalNetwork` rows" finding doesn't prove permission was never granted — it was looking in a store this permission was never stored in, which also explains why `tccutil reset LocalNetwork` errored (nothing there to reset). This is also a **confirmed, currently-unresolved, widespread macOS bug** (Apple DTS engineer: reproducible on 100% of tested Sequoia/Tahoe systems, radar filed, no supported fix), not unique to this app. Neither Apple source confirms or denies that `LSUIElement`/activation policy affects whether the prompt is shown — the "leading theory" framing above was stronger than what's actually verified anywhere.

**Real-world confirmation, 2026-08-09 ~22:30Z — a reboot did trigger the actual system prompt** on the affected machine, matching the "next untested step" theory above. The already-running app didn't pick up the change on its own; a manual quit + relaunch was needed to see it take effect. This directly motivated the fast-retry addition below.

**Mitigation implemented 2026-08-09 (effectiveness vs. the actual root cause still unconfirmed — see the research correction above; implemented anyway as a plausible, low-risk thing to try):**
- `LSUIElement` in Info.plist changed from unconditional `true` to `false`; `hdhr_VCRApp.init()` now decides the activation policy at runtime instead — `.regular` (Dock icon visible) until `AppState.confirmLocalNetworkAccessIfNeeded()` (called from `fetchAllLineups` on the first successful lineup load) flips `AppConfig.Local_network_confirmed` and persists it, then `.accessory` from then on. A synchronous `ConfigManager().load()` peek at the top of `init()` decides the very first launch's policy, independent of `AppState`'s own later async load.
- **Settings → Advanced → "Dock icon"** picker (`AppConfig.Dock_icon_mode`: `auto`/`always`/`never`) lets a user override the heuristic permanently in either direction; an explicit change applies immediately via `SettingsView.applyAndSave()`, not just next launch.
- **Fast-retry**: `idleLoop()` now retries `fetchAllLineups` on every idle tick (not just the hourly boundary) while `Local_network_confirmed` is still false, guarded by its own `lineupConfirmRetryInFlight` reentrancy flag — added directly in response to the reboot finding above, so a permission grant (whenever/however it actually lands) is picked up within one tick instead of requiring a manual relaunch or waiting up to an hour.
- **Verified end-to-end** (not just unit tests — real launches, polling `lsappinfo`'s reported process `type`): with `Local_network_confirmed` reset to `false`, a fresh launch measurably starts as `type="Foreground"` (`.regular`) and flips to `type="UIElement"` (`.accessory`) ~96ms later, right when the lineup fetch completes. The mechanism itself works exactly as designed; whether it actually helps the underlying OS bug is still unconfirmed and worth watching for on a genuinely affected machine.
- Not done: no attempt to detect the system dialog directly (no public API exposes that) — the fast-retry above is a practical substitute, not literal detection.

**Key files**: `hdhr_VCRApp.swift` (`init()` — activation-policy decision), `AppState.swift` (`confirmLocalNetworkAccessIfNeeded`, `idleLoop`'s fast-retry branch, `fetchAllLineups`, `toggleFavorite`), `Models.swift` (`AppConfig.Dock_icon_mode`/`Local_network_confirmed`), `SettingsView.swift` (Advanced → Dock icon picker), `hdhrVCRplus.app/Contents/Info.plist` (`LSUIElement`). `HDHRManager.swift` → `fetchLineup` (unaffected), `fetchDeviceInfo`'s two callers (instrumented 2026-08-09), `setFavorite` (verified already correct).

---

## Player / Watch Now

### Check whether WatchNowView should get the web guide's status-ring system

The web guide's program blocks show a 5-state colored ring + badge system (`.g-st-sched` blue ⏱,
`.g-st-rec` red ⏺, `.g-st-skip` slate ⏭, `.g-st-conflict` orange ⚠, `.g-st-inuse` purple ▶ — see
`docs/WebServer.md`'s "Status ring + badge"). `WatchNowView`'s native rows (`Views/WatchNowView.swift`)
have nothing equivalent — just a genre-color background (`guideEntryColor(for:onAir:)`) and a plain
"🔴 Recording" text badge for this instance's own recordings (`managedShow?.show_recording == true`).
No skip/conflict/in-use-by-other-tuner indication exists natively at all. User flagged 2026-08-11
(screenshot of Watch Now next to the web guide) asking whether the native view should carry the same
circled-ring + color language, for visual consistency between the two guide surfaces. Not scoped or
implemented — needs a design pass (SwiftUI equivalent of a `box-shadow` ring + corner badge is a
different mechanism, e.g. `.overlay`/`.background` with a `Circle()`) and a decision on whether all
five states are worth surfacing here or just a subset (Watch Now is browse-and-watch focused, not a
full scheduling view — skip/conflict may be less relevant than in the full grid).

**Key files**: `Views/WatchNowView.swift`, `Views/GuideViewHelpers.swift` (`guideEntryColor`), `docs/WatchNowView.md`.

---

### Elapsed/remaining timer in recording menu doesn't tick

Times shown in `recordingMenu` / `scheduledMenu` are computed when the menu opens and stay static for the duration it's open. NSMenu doesn't auto-refresh its view hierarchy. A real-time display would require redesigning recording detail as a window-based popover.

---

### No "Record Now" shortcut

No direct path to immediately record an in-progress show without going through Watch Now or the Add Show wizard. A quick-action from `MenuContent` or `WatchNowView` would skip the wizard for shows currently on air.

---

### No "Recording Now" section separating active recordings

Watch Now currently only splits entries into Favorites / Others (`content`'s `favs`/`others` filter on `channel.isFavorite`). Shows that are actively recording (`managedShow?.show_recording == true`) are mixed into whichever section they'd normally land in, so "what's recording right now" isn't visually distinct from "what's just on air." Add a third partition, above Favorites, for entries whose managed show is currently recording — when the recording ends, the entry falls back into Favorites/Others automatically since the partition is just a filter re-evaluated on every render. Companion to the web Guide's version below — implement together for one consistent story across both surfaces.

**Key file**: `Views/WatchNowView.swift` → `content` (favs/others filter, ~line 206).

---

### No watched/resume tracking across sessions

VLC's own scrub bar handles resume-within-a-single-playback-session, but nothing persists a recording's watched state or last playback position across app restarts or between Watch Now and a later Finder-opened file. Comparable apps (Plex, Channels DVR) track both, letting a library view distinguish "new," "in progress," and "watched." Would need a small persisted per-recording-file record (position + watched flag), keyed by a stable identifier since filenames can be reorganized — 2026-08-11 feature-gap survey, not yet scoped.

---

### No commercial-skip markers

Channels DVR and Plex DVR both run a comskip-style detection pass on completed recordings and let playback jump commercial breaks. This app already does local recording + built-in VLC playback, so the pieces exist, but there's no detection step or marker format today. Bigger lift than the other items here — needs an actual black-frame/silence detection pass (or a bundled comskip binary) plus a playback-side "skip to next marker" UI. 2026-08-11 feature-gap survey, not yet scoped.

---

### Watch Now-from-disk relay could "catch up" faster by front-loading the already-recorded backlog

Watching a currently-recording show via `AppState.watchRecordingInApp` plays it back from disk through the local relay (`/api/watch-recording`, `WebServer.swift`'s `streamGrowingFile`/`pumpGrowingFile`) rather than the live tuner stream. Unlike live TV, the bytes this relay serves up to the current live edge already exist on disk the instant playback starts — there's no reason to wait for them to "arrive" the way a real live stream does. But `VLCBridge.play(url:)` applies a blanket `--network-caching=2000` VLC option (`VLCBridge.swift` ~line 345) to every media load, live tuner stream and disk relay alike, with no distinction — so VLC deliberately buffers 2 seconds before starting playback even when the relay could in principle burst-deliver a much larger already-on-disk backlog instantly over the loopback connection. This likely means the disk-relay path "catches up" to the live edge slower than it has to, since it's paced by a caching setting tuned for smoothing real live-stream jitter, not for a same-machine relay serving data that's already fully present on disk.

Worth investigating: whether `pumpGrowingFile`'s own chunk-by-chunk send loop (200 TS packets, 37.6KB, per `conn.send` completion — no artificial delay of its own) is actually the bottleneck, or whether it's purely VLC's fixed network-caching value holding back startup. If the latter, a lower (or relay-specific) caching value — passed only when playing a `/api/watch-recording` URL, not a live tuner URL — could plausibly cut Watch Now's "catch up to live" latency without touching genuinely live playback's jitter-smoothing behavior.

**Key files**: `VLCBridge.swift` → `play(url:)` (network-caching option, ~line 345); `WebServer.swift` → `streamGrowingFile`/`pumpGrowingFile` (`/api/watch-recording` relay); `AppState.swift` → `watchRecordingInApp`.

---

## Add Show / Edit Show

### No time offset picker for DateTime shows

Air time is locked to the guide entry's start time. Users who want to record a few minutes early have no control in the wizard.

---

### `show_genre` not exposed in Edit Show

The genre field (used for Bonus Time detection) is set from the guide on add but can't be corrected in Edit. Shows added before Bonus Time can't get a genre retroactively without delete + re-add.

---

### SeriesID is read-only in Edit Show

Can't update `show_seriesid` if SiliconDust changes a series' ID (which happens occasionally). Only fix today is delete + re-add.

---

## Recording

### Skip-already-recorded: extend to episode-title matching

The season/episode-number half of "skip already-recorded episodes" is **done** (`Skip_recorded_episodes`, filesystem `SxxExx` scan — see `CHANGELOG.md`). Still deferred: dedup for shows the guide numbers by episode **title** only (no `SxxExx`). The blocker is that the filename doesn't carry the episode title today. Plan: first extend the recording filename to embed a sanitized episode title (update `Show.outputPath` and the `Organize`/`recordedEpisodeTags` parse regex together), then have `recordedEpisodeTags` also collect title keys so the same scan-based, self-healing approach covers title-only shows — no persisted ledger, no stale-delete caveat.

---

### No recurring rules beyond SeriesID (keyword/genre auto-record)

`SeriesID`/title-based recording (see `Models.md`'s `ShowState`) only covers "record this specific show." Comparable apps (TiVo's "wishlist," MythTV's keyword-record) let a user set a standing rule like "record anything new tagged Sports" or "record any airing matching this keyword" across the whole guide, not tied to one series. Would build on the existing SeriesID scheduling machinery (`AppState.resolveSeriesAir`/`scheduleNextAir`) but needs a new match dimension (keyword/genre instead of SeriesID) and its own conflict/dedup story. 2026-08-11 feature-gap survey, not yet scoped.

---

### No retention/auto-cleanup rules

Recordings accumulate with no automatic pruning beyond duplicate-skip (`Skip_recorded_episodes`) — nothing deletes old episodes on its own. Comparable apps offer per-show retention like "keep only the last N episodes" or "delete after N days" (and often "delete once watched," which would depend on the watched-tracking item above). Would need a scheduled sweep (idle loop, similar cadence to the hourly guide refresh) comparing `recordedEpisodeTags`-style on-disk state against a per-show retention setting. 2026-08-11 feature-gap survey, not yet scoped.

---

### No reminder-only shows (notify without recording)

Every managed show type records; there's no way to just get notified when something airs without scheduling a recording. TiVo separates "season pass" (record) from "reminder" (notify only) as two different actions on the same show. Would likely reuse the existing notification plumbing (`notify`/Discord embeds) minus the actual `startRecording` call — the guide-matching/scheduling side (`ManagedGuideMatcher`, `resolveSeriesAir`) would need a new non-recording show state to key off. 2026-08-11 feature-gap survey, not yet scoped.

---

## Web Guide

### No "Recording Now" section pulling active-recording channel rows to the top

The web Guide already partitions channel rows into Favorites vs. everything else (`favRows`/`otherRows`, sorted via `ch.isFavorite` at ~line 1200, joined with a `.g-fav-sep` divider at ~line 1374). Channels with an actively-recording show are mixed in wherever they'd normally sort, so a recording in progress isn't immediately obvious without scanning the whole grid. Add a third partition, above Favorites, for channels where `recChannelsByDevice[device]` contains the channel's `GuideNumber` (already computed per-row as `isRecCh`, ~line 1219) — pull that channel's entire row out of Favorites/Others into a new section with its own divider (e.g. `.g-rec-sep`, red-themed to match `.g-prog-rec`). Since the grid rebuilds on every recording-state change (`broadcastGuideChangeEvent`/`broadcastRecordingEvent`), the channel returns to its normal section automatically once the recording ends — no explicit "un-pin" logic needed. Companion to Watch Now's version above — implement together for one consistent story across both surfaces.

Note: this is the shared web guide grid (`WebServer.swift`) rendered both in a browser and embedded via WKWebView in `AddShowView.swift`'s guide step — there is no separate native "cable view" implementation anymore (the old `CableGuideView`, and later the unreachable `FloatingGuideView`/"Cable Guide" window built on top of it, were both removed; fixing it here covers both remaining embeddings at once).

**Key file**: `WebServer.swift` → `buildGuideGridHTML`/`buildHTML` (favRows/otherRows split, `.g-fav-sep` divider, `recChannelsByDevice`).

---

### No guide search

The web guide has a genre filter (`filterGenre`/`rebuildGenreFilter` in `guide.js`, dims non-matching blocks) but no title/keyword text search — finding "where is Jeopardy airing" today means browsing channel-by-channel or scrolling. Every comparable guide app (Channels DVR, Plex, TiVo) has a search box. Could reuse `GuideStore`'s existing per-channel entry index for a client-side search-as-you-type, or a small new `/api/guide-search` endpoint if the dataset gets too large to ship to the browser wholesale. 2026-08-11 feature-gap survey, not yet scoped.

---

### No recordings library view in the web UI

The web guide covers scheduling *future* recordings; there's no browse/search of *past* recordings (what's already on disk) from a phone or browser — only the native app's Finder-adjacent folder structure. A library view (list/grid of completed recordings, searchable, maybe pairing with the watched/resume-tracking item above) would make the web UI useful after a show airs, not just before. 2026-08-11 feature-gap survey, not yet scoped.

---

## Settings

### No per-show fail threshold or bonus duration

`Fail_count_setting` and `Sports_padding_minutes` are global-only. Per-show overrides would be useful for shows that regularly run long or need different failure tolerance.

---

### No export / import config

Power users managing multiple machines must copy the JSON manually. Export / Import buttons in the Advanced settings section would simplify this.

---

### About tab: highlight the current version's changes, cap the visible changelog at 6 entries

Today `SettingsView.aboutView` renders the *entire* filtered changelog (every section whose version stamp is ≤ the running build, via `Self.parseChangelog`/`MarkdownView`) with no limit and no visual distinction for the current version's own entry — it reads the same as every older one.

Wanted: the current build's changelog section should be visually highlighted (e.g. an accent background/border or a "Current" badge) as the first item, followed by only the last 5 older versions — 6 sections total in the About view. `CHANGELOG.md` itself and `parseChangelog`'s version-filtering behavior (nothing newer than `appVersion` is ever shown) should stay untouched — this is a display cap on `aboutView`, not a change to what's tracked or kept in the file.

**Key files**: `Views/SettingsView.swift` — `aboutView` (rendering), `parseChangelog` (currently returns the *entire* filtered string + `latestVersion`; will need to also split out/limit to the first 6 `## `-delimited sections and identify which one is the current version's).

---

## Distribution

### Release builds are arm64-only, not a universal binary

`deploy_release.sh`/`deploy.sh` both call plain `swift build` (`-c release` for the former) with no
`--arch` flags, so every shipped build (including v2.0.0) is a single arm64 slice — confirmed via
`lipo -info` on the built binary. Intel Macs can't run it. Adding an x86_64 slice would mean
building both architectures (`swift build --arch arm64 --arch x86_64 [-c release]`) and combining
the two `hdhr_VCR` binaries with `lipo -create` before the existing codesign/notarize steps —
notarization and stapling both operate fine on a universal binary, so this only touches the build
step, not signing. Not started; no known demand from an Intel-Mac user yet.

**Key file**: `deploy.sh` / `deploy_release.sh` (build + binary-copy steps).

---

### Mac App Store distribution requires a sandbox rewrite

Full blocker-by-blocker analysis already lives in **`docs/MAS_COMPLIANCE.md`** — do not duplicate it here, keep this pointer up to date instead. Direct-distribution notarization (Developer ID cert + `notarytool`, see `tools/setup_signing.sh` / `deploy_release.sh`, and `docs/Distribution.md`) does **not** require sandboxing and is the in-progress track as of 2026-08-08. MAS is a separate, larger track: App Sandbox is mandatory for submission, and `docs/MAS_COMPLIANCE.md` tracks the open blockers (curl subprocess spawning — three options weighed: URLSession/XPC-helper/bundled-curl, no decision made yet; VLC dlopen; `Process()` brew installs; security-scoped bookmarks for the recording directory) plus what's already done (Launch at Login via `SMAppService`, Privacy Manifest, narrowed ATS exception).

**Not started.** Sequenced after direct-distribution notarization is working.

---

## Code Quality

### `deploy.sh`/`deploy_release.sh`'s favicon-generation heredoc is duplicated verbatim

Added to `deploy_release.sh` on 2026-08-07 by copying `deploy.sh`'s existing ~13-line inline `python3` heredoc that builds `favicon.ico` from the iconset's 16×16/32×32 PNGs, rather than factoring it into one shared script. Matches this codebase's existing pattern of keeping the two deploy scripts independently self-contained (the "Deploying resources" `cp` block is duplicated the same way), so not urgent — but a future fix to the ICO-writing logic (wrong byte order, a malformed header, adding more sizes) has to be found and applied in both places, and it's easy to fix one and forget the other.

**Key file**: `deploy.sh` / `deploy_release.sh` (favicon generation block).

---

### Local Network fast-retry has no backoff for a permanent denial

Flagged in the v2.0.2 pre-release review (`swift-quality-reviewer`). `idleLoop()`'s fast-retry (see "Show Stoppers" above — retries `fetchAllLineups` every tick while `Local_network_confirmed` is false) is correctly bounded to eventually stop once access is confirmed working, but if permission is genuinely denied (indistinguishable from "still pending" per this project's own research into the underlying macOS bug), it retries forever at the full idle-tick cadence (default 10s) with no backoff or attempt cap. Low real-world cost today (a LAN GET to a device already polled every tick anyway for tuner status), but worth an exponential backoff or a cap-then-fall-back-to-hourly if this needs revisiting.

**Key file**: `AppState.swift` → `idleLoop` (fast-retry branch).

---

### Homebrew installer spawning (`runBrew`) needs a sandbox story

`SettingsView.swift` → `runBrew()` spawns `/opt/homebrew/bin/brew` / `/usr/local/bin/brew` with `install`/`install --cask` to install VLC / hdhomerun_config from the Settings → Maintenance "Tools" section. This is a second class of `Process`-spawning beyond the curl sandbox debt tracked in "Mac App Store distribution requires a sandbox rewrite" above, and isn't covered by that helper-app rewrite either. There's no sandboxed way to invoke Homebrew, so the likely fix is dropping this row entirely in a sandboxed build.

**Key file**: `SettingsView.swift` → `runBrew()`.

---

### Watch for UI hitches from `broadcastGuideChangeEvent`'s wider call-site fan-out

As of the 2026-08-01 pre-release review, `broadcastGuideChangeEvent` is called from 9+ show-lifecycle sites (add/update/pause/resume/delete/favorite-toggle/duplicate-override-clear), each triggering a full page rebuild (`buildGuideGridHTML` + `buildDevBarHTML` + gzip'd `prebuildPageHTML`) on the main actor — previously only the hourly refresh and recording start/stop paid this cost. With `Series_subfolder_enabled && Skip_recorded_episodes` both on, each rebuild also re-scans every managed series' recording folder. Deliberate tradeoff for guide freshness on new tab loads, and show mutations are human-paced so likely fine — but if a large recording library with many managed series shows UI hitches on Add/Edit/Delete/favorite-toggle, this rebuild fan-out is the first place to look.

**Key file**: `WebServer.swift` → `broadcastGuideChangeEvent`.

---

### Re-check `guideRefreshLatency_underThreshold` under a quiet machine

Failed repeatedly on 2026-08-07 (median 374ms–1451ms vs. a 250ms threshold) across several `swift test --filter WebServerPerfTests` runs, but `WebServer.swift`/`buildGuideGridHTML` had zero diff that session — the failures tracked a concurrently high system load average (~4-5, a Virtualization VM at 23%+ CPU, a CrashPlan backup, other Claude sessions running) rather than any code change; even the trivial `pingLatency`/`pageLoad` tests briefly ballooned to 4.5s each on the same runs. Never confirmed clean on a quiet machine before the session ended. Re-run the suite next time the machine is idle — if it still fails at a normal load average, treat it as a real regression and bisect; if it passes, this was pure noise and needs no code change.

**Key file**: `Tests/hdhr_VCRTests/WebServerPerfTests.swift` → `guideRefreshLatency_underThreshold`.

---

### RecordingManager/HDHRManager still low measured test coverage

The 2026-08-11 coverage-guided pass (`swift test --enable-code-coverage` + `xcrun llvm-cov report`) replaced judgment-based gap guessing with real numbers and confirmed the earlier prediction: `RecordingManager.swift` 7.04% line coverage, `HDHRManager.swift` 1.81%, vs. `DiscordNotifier.swift`'s 0% → 37% after that pass added a URLSession-injection seam + `DiscordNotifierTests.swift` (the cheap win — no source restructuring needed beyond a defaulted parameter). The other two need real seams first: `RecordingManager` wraps `curl` via `Process`/`posix_spawn` with no injection point for a fake process (would need a spawn-seam abstraction or a mock-curl shell script swapped in for tests); `HDHRManager` does concurrent known-hosts/mDNS/UDP discovery against real network primitives, though `tools/mock_hdhr.py` already exists for exactly this and might cover the HTTP-reachable parts (mDNS/UDP discovery would still need its own seam). `AppState.swift` (9.56%) and `WebServer.swift` (27.41%) have by far the most raw uncovered lines but are graded lower priority per the plan's "blast radius, not raw percentage" framing — both are heavily orchestration/`@MainActor`-coupled and already exercised indirectly through `GuideStore`/`ManagedGuideMatcher` test suites plus the post-deploy web server smoke/perf suites.

**Key files**: `RecordingManager.swift`, `HDHRManager.swift`.

---

