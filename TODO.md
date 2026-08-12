# TODO

Deferred features and improvements. Add items here when a task is punted. Remove when complete and note the resolving commit in `ISSUES.md` if the work was non-trivial.

---

## Accepted — not our bug / not scheduled

### macOS Local Network permission block — lineup fetch can silently fail on launch

A confirmed, widespread macOS bug, not unique to this app (Apple DTS engineer: reproducible on 100% of tested Sequoia/Tahoe systems, radar filed, no supported fix) — Local Network Privacy can fail-closed for an `LSUIElement` menu-bar app with no visible prompt ever surfacing, and no self-recovery path. Root-caused and instrumented 2026-08-09 (`AppState.fetchAllLineups` previously swallowed the failure via bare `try?`; now logs the real `NSError`/`NWPath` reason, so a recurrence is diagnosable from `hdhrVCRplus.log` instead of silent). `fetchDeviceInfo`'s two callers got the same do/catch+log treatment; `setFavorite`'s caller was checked and already handled this correctly.

**Mitigations shipped** (effectiveness against the actual OS bug unconfirmed — Apple has to fix the underlying bug):
- Dock icon shown on launch (`.regular` activation policy) until a real lineup fetch succeeds, giving the OS's permission prompt a normal foreground app to attach to — then hides itself. **Settings → Advanced → Dock icon** (auto/always/never) overrides this.
- `idleLoop()` retries the lineup fetch every tick (not just hourly) while unconfirmed, so a permission grant — whenever/however it lands — takes effect within one tick instead of requiring a manual relaunch or waiting up to an hour.
- Verified end-to-end (real launches, polling `lsappinfo`'s process type): the Dock-icon flip happens correctly, right when the lineup fetch completes.

Ad-hoc dev builds and Developer-ID release builds are different code identities to TCC/Local-Network — granting access on one doesn't carry over to the other; worth remembering during testing.

**Key files**: `hdhr_VCRApp.swift` (`init()` activation-policy), `AppState.swift` (`confirmLocalNetworkAccessIfNeeded`, `idleLoop` fast-retry, `fetchAllLineups`), `Models.swift` (`Dock_icon_mode`/`Local_network_confirmed`), `SettingsView.swift` (Dock icon picker).

---

### No "Record Now" shortcut

No direct path to immediately record an in-progress show without going through Watch Now or the Add Show wizard. A quick-action from `MenuContent` or `WatchNowView` would skip the wizard for shows currently on air. Low priority, not scheduled.

---

## Player / Watch Now

### No watched/resume tracking across sessions

VLC's own scrub bar handles resume-within-a-single-playback-session, but nothing persists a recording's watched state or last playback position across app restarts or between Watch Now and a later Finder-opened file. Comparable apps (Plex, Channels DVR) track both, letting a library view distinguish "new," "in progress," and "watched." Would need a small persisted per-recording-file record (position + watched flag), keyed by a stable identifier since filenames can be reorganized — 2026-08-11 feature-gap survey, not yet scoped.

---

### Watch Now-from-disk relay could "catch up" faster by front-loading the already-recorded backlog

Watching a currently-recording show via `AppState.watchRecordingInApp` plays it back from disk through the local relay (`/api/watch-recording`, `WebServer.swift`'s `streamGrowingFile`/`pumpGrowingFile`) rather than the live tuner stream. Unlike live TV, the bytes this relay serves up to the current live edge already exist on disk the instant playback starts — there's no reason to wait for them to "arrive" the way a real live stream does. But `VLCBridge.play(url:)` applies a blanket `--network-caching=2000` VLC option (`VLCBridge.swift` ~line 345) to every media load, live tuner stream and disk relay alike, with no distinction — so VLC deliberately buffers 2 seconds before starting playback even when the relay could in principle burst-deliver a much larger already-on-disk backlog instantly over the loopback connection. This likely means the disk-relay path "catches up" to the live edge slower than it has to, since it's paced by a caching setting tuned for smoothing real live-stream jitter, not for a same-machine relay serving data that's already fully present on disk.

Worth investigating: whether `pumpGrowingFile`'s own chunk-by-chunk send loop (200 TS packets, 37.6KB, per `conn.send` completion — no artificial delay of its own) is actually the bottleneck, or whether it's purely VLC's fixed network-caching value holding back startup. If the latter, a lower (or relay-specific) caching value — passed only when playing a `/api/watch-recording` URL, not a live tuner URL — could plausibly cut Watch Now's "catch up to live" latency without touching genuinely live playback's jitter-smoothing behavior.

**Key files**: `VLCBridge.swift` → `play(url:)` (network-caching option, ~line 345); `WebServer.swift` → `streamGrowingFile`/`pumpGrowingFile` (`/api/watch-recording` relay); `AppState.swift` → `watchRecordingInApp`.

---

## Recording

### No reminder-only shows (notify without recording)

Every managed show type records; there's no way to just get notified when something airs without scheduling a recording. TiVo separates "season pass" (record) from "reminder" (notify only) as two different actions on the same show. Would likely reuse the existing notification plumbing (`notify`/Discord embeds) minus the actual `startRecording` call — the guide-matching/scheduling side (`ManagedGuideMatcher`, `resolveSeriesAir`) would need a new non-recording show state to key off. 2026-08-11 feature-gap survey, not yet scoped.

---

## Web Guide

### No "Recording Now" section pulling active-recording channel rows to the top

The web Guide already partitions channel rows into Favorites vs. everything else (`favRows`/`otherRows`, sorted via `ch.isFavorite` at ~line 1200, joined with a `.g-fav-sep` divider at ~line 1374). Channels with an actively-recording show are mixed in wherever they'd normally sort, so a recording in progress isn't immediately obvious without scanning the whole grid. Add a third partition, above Favorites, for channels where `recChannelsByDevice[device]` contains the channel's `GuideNumber` (already computed per-row as `isRecCh`, ~line 1219) — pull that channel's entire row out of Favorites/Others into a new section with its own divider (e.g. `.g-rec-sep`, red-themed to match `.g-prog-rec`). Since the grid rebuilds on every recording-state change (`broadcastGuideChangeEvent`/`broadcastRecordingEvent`), the channel returns to its normal section automatically once the recording ends — no explicit "un-pin" logic needed. (The equivalent Watch Now version of this was considered and declined 2026-08-12 — not needed there.) Keep for later — not scheduled yet.

Note: this is the shared web guide grid (`WebServer.swift`) rendered both in a browser and embedded via WKWebView in `AddShowView.swift`'s guide step — there is no separate native "cable view" implementation anymore (the old `CableGuideView`, and later the unreachable `FloatingGuideView`/"Cable Guide" window built on top of it, were both removed; fixing it here covers both remaining embeddings at once).

**Key file**: `WebServer.swift` → `buildGuideGridHTML`/`buildHTML` (favRows/otherRows split, `.g-fav-sep` divider, `recChannelsByDevice`).

---

### No guide search

The web guide has a genre filter (`filterGenre`/`rebuildGenreFilter` in `guide.js`, dims non-matching blocks) but no title/keyword text search — finding "where is Jeopardy airing" today means browsing channel-by-channel or scrolling. Every comparable guide app (Channels DVR, Plex, TiVo) has a search box. Could reuse `GuideStore`'s existing per-channel entry index for a client-side search-as-you-type, or a small new `/api/guide-search` endpoint if the dataset gets too large to ship to the browser wholesale. 2026-08-11 feature-gap survey, not yet scoped.

---

## Settings

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

**Flagged 2026-08-12 as worth actively working on next**, not just a background item. Full blocker-by-blocker analysis already lives in **`docs/MAS_COMPLIANCE.md`** — do not duplicate it here, keep this pointer up to date instead. Direct-distribution notarization (Developer ID cert + `notarytool`, see `tools/setup_signing.sh` / `deploy_release.sh`, and `docs/Distribution.md`) does **not** require sandboxing and is the in-progress track as of 2026-08-08. MAS is a separate, larger track: App Sandbox is mandatory for submission, and `docs/MAS_COMPLIANCE.md` tracks the open blockers (curl subprocess spawning — three options weighed: URLSession/XPC-helper/bundled-curl, no decision made yet; VLC dlopen; `Process()` brew installs; security-scoped bookmarks for the recording directory) plus what's already done (Launch at Login via `SMAppService`, Privacy Manifest, narrowed ATS exception).

**Homebrew installer spawning (`runBrew`) folds into this same blocker list** — `SettingsView.swift` → `runBrew()` spawns `/opt/homebrew/bin/brew`/`/usr/local/bin/brew` to install VLC/hdhomerun_config from Settings → Maintenance's "Tools" section, a second class of `Process`-spawning beyond curl that isn't covered by a curl-specific rewrite either. There's no sandboxed way to invoke Homebrew, so the likely fix is dropping this row entirely in a sandboxed build — track it alongside the other blockers in `docs/MAS_COMPLIANCE.md` rather than as a separate TODO entry.

**Not started.** Sequenced after direct-distribution notarization is working (which it now is).

---

## Code Quality

### `deploy.sh`/`deploy_release.sh`'s favicon-generation heredoc is duplicated verbatim

Added to `deploy_release.sh` on 2026-08-07 by copying `deploy.sh`'s existing ~13-line inline `python3` heredoc that builds `favicon.ico` from the iconset's 16×16/32×32 PNGs, rather than factoring it into one shared script. Matches this codebase's existing pattern of keeping the two deploy scripts independently self-contained (the "Deploying resources" `cp` block is duplicated the same way), so not urgent — but a future fix to the ICO-writing logic (wrong byte order, a malformed header, adding more sizes) has to be found and applied in both places, and it's easy to fix one and forget the other.

**Key file**: `deploy.sh` / `deploy_release.sh` (favicon generation block).

---

### Local Network fast-retry has no backoff for a permanent denial

Flagged in the v2.0.2 pre-release review (`swift-quality-reviewer`). `idleLoop()`'s fast-retry (see "Accepted — not our bug / not scheduled" above — retries `fetchAllLineups` every tick while `Local_network_confirmed` is false) is correctly bounded to eventually stop once access is confirmed working, but if permission is genuinely denied (indistinguishable from "still pending" per this project's own research into the underlying macOS bug), it retries forever at the full idle-tick cadence (default 10s) with no backoff or attempt cap. Low real-world cost today (a LAN GET to a device already polled every tick anyway for tuner status), but worth an exponential backoff or a cap-then-fall-back-to-hourly if this needs revisiting.

**Key file**: `AppState.swift` → `idleLoop` (fast-retry branch).

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

### `ImageRenderer`-based snapshot tests can't capture `ScrollView`/`List` content

Discovered 2026-08-11 while adding a snapshot test for `WatchNowView`'s new status-ring badge
(`guideRingBadge`, `GuideViewHelpers.swift`): seeding real on-air guide data via
`GuideStore.buildIndex` (temporarily `internal` for exactly this, since reverted back to `private`
2026-08-12 once this snapshot test was removed and nothing else needed the wider access) correctly
got `WatchNowView` into its
`ScrollView { ForEach(...) }` branch — but the rendered `ImageRenderer` output was entirely blank,
same as an empty view, regardless of how many rows should have been in it. Confirmed this isn't
specific to the new ring code: `SnapshotTests.swift`'s two pre-existing `WatchNowView` cases never
actually exercise this branch (`watchNowEmpty` has no devices, `watchNowWithDevice` has a device but
no guide data — both land in a plain `VStack` fallback, not the `ScrollView`), so this gap in
`assertSnapshot`/`SnapshotHelper.swift` predates this session and was simply never triggered before.
`ImageRenderer` is documented to have real limitations with scroll/list containers that expect a
live `NSScrollView`/hosting-window layout pass it doesn't fully provide off-screen. A blank-vs-blank
snapshot silently "passes" without proving anything, which is worse than no test — don't add a
`ScrollView`-containing snapshot test without first confirming content actually renders (check the
saved reference PNG, don't just trust the test result). Fixing this properly likely means either
finding an `ImageRenderer` configuration/workaround that forces `ScrollView` layout, or switching
those specific snapshot targets to a real (even if off-screen) `NSHostingView` + window attachment
instead of `ImageRenderer`.

**Key files**: `Tests/hdhr_VCRTests/SnapshotHelper.swift`, `SnapshotTests.swift`.

---

