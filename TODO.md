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

## Recording

### No reminder-only shows (notify without recording)

Every managed show type records; there's no way to just get notified when something airs without scheduling a recording. TiVo separates "season pass" (record) from "reminder" (notify only) as two different actions on the same show. Would likely reuse the existing notification plumbing (`notify`/Discord embeds) minus the actual `startRecording` call — the guide-matching/scheduling side (`ManagedGuideMatcher`, `resolveSeriesAir`) would need a new non-recording show state to key off. 2026-08-11 feature-gap survey, not yet scoped.

---

## Web Guide

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

**Key file**: `Tests/hdhr_VCRTests/WebServer/WebServerPerfTests.swift` → `guideRefreshLatency_underThreshold`.

---

### RecordingManager/HDHRManager test coverage — seams added 2026-08-13, HDHRManager still has a real gap

Follow-up to the 2026-08-11 coverage-guided pass. Both files got real injection seams this session, same idea as `DiscordNotifier.swift`'s `session: URLSession = .shared` defaulted parameter (0% → 37%):

- **`HDHRManager.swift`: 1.81% → 26.74% line coverage.** Constructor injection (`init(session: URLSession? = nil, dataSession: URLSession = .shared)` — nil still builds the exact original short-timeout `URLSessionConfiguration`) since `session`/`dataSession` were already stored properties rather than per-call params. `fetchDeviceInfo`, `mDNSDiscover`, `cloudDiscover`, `knownHostsDiscover`, `supplementDeviceAuth` were widened from `private` to `internal` (pure visibility change, no behavior change) so `Tests/hdhr_VCRTests/Network/HDHRManagerTests.swift` can exercise them directly against a mocked `URLSession`/`URLProtocol` — success, malformed-JSON, HTTP-error, and network-error cases, plus `setFavorite` and the pure `supplementDeviceAuth` merge logic. **Still genuinely uncovered, and staying that way**: mDNS/UDP broadcast discovery (`udpDiscoverSync`, `subnetBroadcastAddresses`, `udpDiscoverAndFetch`) hits real `getifaddrs`/`socket`/`sendto`/`recvfrom` system calls with no seam — by far the largest remaining chunk of the file's missed lines — and the top-level `discoverDevices(knownHosts:interface:)` orchestrator, which always waits out UDP's ~2s real-broadcast timeout even with mocked HTTP, so it wasn't exercised directly either (would make the test suite slow and network-order-dependent for little unit-level gain over testing its sub-calls directly, which the new tests already do). `tools/mock_hdhr.py` could still support a slower, higher-level integration test of the whole discovery path someday, but wasn't needed for this pass's HTTP-level coverage jump.
- **`RecordingManager.swift`: 7.04% → 89.01% line coverage.** Chose the "mock-curl-script" alternative over a spawn-seam closure: added an injectable `curlExecutablePath` init parameter (default `"/usr/bin/curl"`, unchanged from the old hardcoded literal) rather than touching `spawnDetached`/`posix_spawn` at all. `Tests/hdhr_VCRTests/Recording/RecordingManagerTests.swift` points it at small per-test generated shell scripts that mimic curl's relevant behavior (write the `--dump-header` file, sleep, exit with a controlled code), then drives `start`/`stop`/`stopAll`/`isRunning`/`reattach`/`readHDHRResource`/`readAndClearHDHRError`/`readAndClearExitStatus`/sleep-assertion methods through a **real** spawned-killed-reaped process — an integration-style test (real subprocess, real timing, small `waitUntil` polling helper) rather than a pure unit test, but it exercises the actual `posix_spawn` code path unmodified. Remaining gap is small: the verbose-curl logging branch (`writeCurlLogHeader`/`rotateCurlVerboseLogIfNeeded`, no test uses `verbose: true`), the orphaned-after-restart `ECHILD`/`kill(pid,0)` branch in `isRunning`, and a few unexercised `hdhrErrorLabel`/`curlExitLabel` switch cases.

`WebServer.swift` (still ~14-28%) remains the largest raw-uncovered-line file but stays lower priority per the original plan's "blast radius, not raw percentage" framing — heavily orchestration/`@MainActor`-coupled and already exercised indirectly through `GuideStore`/`ManagedGuideMatcher` test suites plus the post-deploy web server smoke/perf suites. `AppState.swift` was 20.34% at the time this note was written but see the entry below — its core scheduling engine specifically got covered 2026-08-15, moving the file to ~39%.

**Key files**: `RecordingManager.swift`, `HDHRManager.swift`, `Tests/hdhr_VCRTests/Recording/RecordingManagerTests.swift`, `Tests/hdhr_VCRTests/Network/HDHRManagerTests.swift`.

---

### AppState's recording-scheduling engine — covered 2026-08-15; series-scheduling branches still gap

`idleLoop()`/`startRecording(index:)`/`stopRecording(index:natural:)`/`scheduleNextAir(index:)` — the
code that actually decides when a recording starts, stops, retries after failure, and reschedules —
had zero coverage despite being the app's central purpose. Blocked by `AppState.recordingManager`
being a hardcoded `let recordingManager = RecordingManager()` with no injection seam, unlike
`configManager`. Fixed the same way as the `HDHRManager`/`RecordingManager` seams above: `AppState`
now takes an optional `recordingManager: RecordingManager? = nil` init parameter (Optional rather
than a defaulted-inline parameter like `configManager`, because `RecordingManager` is `@MainActor`
and a default *parameter value* expression isn't isolated the same way the enclosing init is — the
real instance is constructed inside the init body instead). `Tests/hdhr_VCRTests/Recording/AppStateRecordingEngineTests.swift`
points it at the same mock-curl-script technique `RecordingManagerTests.swift` already used (now
shared via `TestFixtures.swift`'s `writeMockCurlScript`/`waitUntil`), driving real launches/stops/
reschedules through `makeTestAppState`. `AppState.swift`: 20.34% → 39.03% line coverage.

Also found and fixed a real, load-bearing bug in the process: `diskOK(for:)`'s `maxDiskPct: Double = 93`
was a `private let` — on a dev machine whose real disk happens to be over 93% used (true for the
machine this was found on), the real app would silently refuse to start every recording, with
`diskOK`'s own fallback-to-true path never triggering since the filesystem stats read succeeds fine.
Widened to `var` (test seam, same "widen for testability" precedent as `HDHRManager`'s methods
above) so tests unrelated to disk-space logic can override it; not a source of the coverage number
above, but a correctness finding worth knowing about if a user ever reports recordings silently not
starting on a fairly-full disk.

**Still genuinely uncovered, and staying that way for now**: `scheduleNextAir`'s `.seriesChannel`/
`.seriesAll` branches and `resolveSeriesAir` depend on a freshly-loaded `GuideStore` (a real network
fetch via `guideStore.load()` when stale, or state seeded into `guideStore`'s internal cache some
other way not currently exposed to tests). The underlying lookup methods they call
(`guideStore.currentEpisode`/`nextEpisode`/`currentEntryByTitle`/`nextEntryByTitle`) already have
solid direct coverage via `GuideStoreTests`, so the *matching logic* isn't blind — only these two
functions' own orchestration ("which lookup tier to try, in what order, before giving up and
retrying later") stays untested. Would need either a network-mock seam on `GuideStore` itself or a
way to pre-seed its cache directly — a separate, larger effort than this pass.

**Key files**: `AppState.swift`, `Tests/hdhr_VCRTests/Recording/AppStateRecordingEngineTests.swift`, `Tests/hdhr_VCRTests/TestFixtures.swift`.

---
