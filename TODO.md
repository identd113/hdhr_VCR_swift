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

## Terminal Guide

See `docs/TUIGuide.md`'s "Deferred ideas" section for open feature gaps and known limitations.

---

## Distribution

### Universal binary — build-side change done 2026-08-19, real signed release not yet cut

`deploy_release.sh` now builds `swift build -c release --arch arm64 --arch x86_64` — SwiftPM itself
combines both slices into one fat Mach-O (no manual `lipo -create` needed, unlike originally
scoped), output at `.build/apple/Products/Release/hdhr_VCR` instead of the old single-arch
`.build/release/hdhr_VCR`. Verified: `lipo -info` on the built binary shows both `x86_64 arm64`
slices; the x86_64 slice launches cleanly under Rosetta from within a real `.app` bundle (a bare
binary outside one crashes on *both* architectures identically at `UNUserNotificationCenter` —
needs a real bundle proxy — so that alone isn't an arch-specific signal; had to control for it).
`deploy.sh` (the fast local dev loop, ad-hoc signed, not shipped) deliberately stays single-arch —
doubling every local build for Intel coverage nothing local needs isn't worth the iteration-speed
cost; only what actually ships needed to change.

**Not yet done, needs a human**: an actual signed + notarized universal release has never been cut
— Developer ID codesign needs physical Touch ID presence each run (`tools/setup_signing.sh` /
`deploy_release.sh` without `--adhoc`), so this could only be build-verified, not released, in an
unattended session. `--adhoc` mode *would* run start-to-finish without Touch ID (ad-hoc `codesign
--sign -`, skips notarization), but was deliberately not run here either — it replaces the live
`hdhrVCRplus.app` bundle in place and stamps a real `CFBundleShortVersionString`/`CFBundleVersion`
into `Info.plist`, i.e. actually cutting a release artifact, not just verifying the build mechanism.
Next real release should confirm the universal binary end-to-end: `lipo -info` on the final signed
artifact, and ideally an actual smoke test on real Intel hardware (Rosetta translation isn't a
substitute — it proves the x86_64 slice's instructions are valid, not that everything the app does
behaves identically on real Intel silicon).

**Key file**: `deploy_release.sh` (build + binary-copy steps).

---

### Mac App Store distribution requires a sandbox rewrite

**Flagged 2026-08-12 as worth actively working on next**, not just a background item. Full blocker-by-blocker analysis already lives in **`docs/MAS_COMPLIANCE.md`** — do not duplicate it here, keep this pointer up to date instead. Direct-distribution notarization (Developer ID cert + `notarytool`, see `tools/setup_signing.sh` / `deploy_release.sh`, and `docs/Distribution.md`) does **not** require sandboxing and is the in-progress track as of 2026-08-08. MAS is a separate, larger track: App Sandbox is mandatory for submission, and `docs/MAS_COMPLIANCE.md` tracks the open blockers (curl subprocess spawning — three options weighed: URLSession/XPC-helper/bundled-curl, no decision made yet; VLC dlopen; security-scoped bookmarks for the recording directory, refined 2026-08-19 into a two-tier plan — see its own entry there) plus what's already done (Launch at Login via `SMAppService`, Privacy Manifest, narrowed ATS exception, and — as of 2026-08-19 — the `Process()` brew-install blocker, resolved by removing that UI entirely rather than reworking it for MAS).

**Not started.** Sequenced after direct-distribution notarization is working (which it now is).

---

### First-run/onboarding flow (mainly for the eventual MAS track)

**2026-08-19 design discussion, not yet scoped as a concrete plan.** Came up while discussing MAS blocker #5 (`docs/MAS_COMPLIANCE.md`) — a MAS install is a genuinely fresh sandbox container even for an existing direct-distribution user on the same Mac, since the two are separate containers with nothing carrying over automatically. Several independent things converge naturally into one first-launch screen:

- **Recording folder picker** — the natural moment to capture the one security-scoped bookmark most users will ever need (default `~/Movies` needs none at all, per blocker #5's refined plan), instead of the user backing into a folder picker mid-Add-Show.
- **Import Config** — offer to import an existing config (Export/Import Config shipped 2026-08-19, `ConfigManager.importConfig(from:)`) so someone moving from direct-distribution to MAS can restore their whole show list in one step instead of rebuilding every show by hand. This is the biggest lever for making a MAS install not feel like starting over.
- **Local Network permission** — proactively explain "click Allow when macOS asks" while the app is already in the foreground (it already goes `.regular` activation policy until a lineup fetch succeeds — see the "Local Network permission block" entry above), instead of the user discovering the prompt as a mystery on its own.
- **VLC pointer** — a one-line "install VLC for in-app playback, e.g. `brew install --cask vlc`" link, now that the auto-install-for-you Homebrew buttons are gone (removed 2026-08-19 — didn't pull its weight, and incidentally resolved a separate MAS blocker).

Real feature, not a small tweak — new UI, new state, ongoing maintenance — and specifically MAS-track-motivated (today's direct-distribution users wouldn't see it unless a lighter first-run was separately wanted for them too, a different and smaller scope). Not started; revisit alongside the MAS work above.

---

## Code Quality

### `ConfigManager.save`'s disk write runs synchronously on the MainActor — 26 call sites

Scoped 2026-08-24, following up on the "web guide feels laggy" report in `ISSUES.md`. **Demoted from prime suspect to independently-worth-doing** the same day: further investigation (see `ISSUES.md`'s entry, and the `broadcastGuideChangeEvent` entry above) found and confirmed the actual root cause is the SSE broadcast payload size, not this — real synthetic disk pressure alone measurably did *not* reproduce the reported lag. Still a legitimate finding on its own merits, just not the fix for that report.

`AppState.saveConfig()` → `ConfigManager.save(_:)` does three blocking filesystem calls (remove old `.bak`, copy current config to it, atomic-write the new one) directly on `@MainActor`, called from 26 sites in `AppState.swift` covering essentially every show mutation. `WebServer` hops onto that same actor for nearly every request touching `AppState`, so a slow disk write here stalls every web request queued behind it. Same bug shape as two already-fixed call sites — `writeMetadataSidecar`/`recordedEpisodeTags` (`AppState.swift`, ~line 2826) are deliberately `nonisolated` so a slow-to-wake NAS/external drive can't block the whole app — but `ConfigManager.save` never got the same treatment, and it's the most frequently hit of the three by far.

**Fix shape** (mirror the existing pattern, not invented fresh): mark `ConfigManager.save`'s file I/O `nonisolated` (it already takes its data by value — `ConfigFile`, not `self`-derived state — so this should be mechanical), then have `AppState.saveConfig()` dispatch it to a detached background `Task` instead of calling it inline. **Not mechanical, though** — needs real review before doing it: `saveConfig()` is called from 26 sites, and at least some (e.g. inside `handleRecord`/`handleEdit`/`handleDelete`'s web-request handlers) may be relying on the save completing *before* the HTTP response is sent — making it fire-and-forget could let a client see "ok":true for a change that hasn't actually hit disk yet (harmless for a crash immediately after, since the in-memory state is already correct and the next save would catch it, but worth confirming that's actually an acceptable tradeoff before shipping it, not assuming it away).

**Key files**: `ConfigManager.swift` (`save(_:)`), `AppState.swift` (`saveConfig()` and its 26 call sites), `Tests/hdhr_VCRTests/AppState/AppStateDiskIOLatencyTests.swift` (the regression test to re-check against once this lands).

---

### `deploy.sh`/`deploy_release.sh`'s favicon-generation heredoc is duplicated verbatim

Added to `deploy_release.sh` on 2026-08-07 by copying `deploy.sh`'s existing ~13-line inline `python3` heredoc that builds `favicon.ico` from the iconset's 16×16/32×32 PNGs, rather than factoring it into one shared script. Matches this codebase's existing pattern of keeping the two deploy scripts independently self-contained (the "Deploying resources" `cp` block is duplicated the same way), so not urgent — but a future fix to the ICO-writing logic (wrong byte order, a malformed header, adding more sizes) has to be found and applied in both places, and it's easy to fix one and forget the other.

**Key file**: `deploy.sh` / `deploy_release.sh` (favicon generation block).

---

### `broadcastGuideChangeEvent` pushes the full ~2.2MB uncompressed grid to every SSE client — confirmed root cause of the "web guide feels laggy" report

As of the 2026-08-01 pre-release review, `broadcastGuideChangeEvent` is called from 9+ show-lifecycle sites (add/update/pause/resume/delete/favorite-toggle/duplicate-override-clear), each triggering a full page rebuild (`buildGuideGridHTML` + `buildDevBarHTML` + gzip'd `prebuildPageHTML`) on the main actor. That part was already known. **Confirmed 2026-08-24** (full trail in `ISSUES.md`'s open entry) as the actual root cause of a live "web guide feels laggy, feels like it's stuck connecting" report — not disk I/O, not raw TCP connect time (both measured and ruled out). The real mechanism: the event this triggers embeds the *entire* guide grid HTML, uncompressed, in the SSE JSON payload — measured at **~2.2MB for one broadcast** on this app's own guide — pushed to every connected SSE client (every open guide tab/window). `WebServer`'s `NWListener` and every `NWConnection` share one serial `DispatchQueue`, so those large sends compete directly with accepting brand-new connections — which is why it manifests as "slow to connect" even though the TCP handshake itself stays instant. Reproduced live: 8 held-open SSE connections + a favorite-toggle burst pushed `/api/ping` latency to 650-950ms with zero disk pressure involved. Regression test: `WebServerPerfTests.swift` → `apiLatency_staysResponsive_duringGuideChangeBurst()` (now correctly opens real SSE connections — the first version didn't, and passed for the wrong reason).

**Not done — needs a deliberate design decision, not a drive-by fix**: three candidate approaches, tradeoffs noted, see `ISSUES.md`'s entry for the full writeup:
1. Stop embedding the full grid in every SSE push — send a lightweight "guide_changed" notification instead, let clients pull `/api/guide-refresh` themselves. Biggest structural fix; changes the SSE contract `guide.js`'s `applyGuidePayload` currently depends on.
2. Gzip the SSE payload (Content-Encoding on the persistent stream). Keeps the current push-full-content design; cuts ~2.2MB down close to the page cache's own ~190KB gzip'd size.
3. Give the listener's accept path its own queue instead of sharing one serial queue with every connection's I/O — doesn't shrink the payload, but stops a slow SSE fan-out from being able to starve new-connection accept processing specifically.

With `Series_subfolder_enabled && Skip_recorded_episodes` both on, each rebuild also re-scans every managed series' recording folder — an additional cost stacked on top of the above, not yet separately measured.

**Key file**: `WebServer.swift` → `broadcastGuideChangeEvent`, `broadcastEvent`, `queue`.

---

### RecordingManager/HDHRManager test coverage — seams added 2026-08-13, HDHRManager still has a real gap

Follow-up to the 2026-08-11 coverage-guided pass. Both files got real injection seams this session, same idea as `DiscordNotifier.swift`'s `session: URLSession = .shared` defaulted parameter (0% → 37%):

- **`HDHRManager.swift`: 1.81% → 26.74% line coverage.** Constructor injection (`init(session: URLSession? = nil, dataSession: URLSession = .shared)` — nil still builds the exact original short-timeout `URLSessionConfiguration`) since `session`/`dataSession` were already stored properties rather than per-call params. `fetchDeviceInfo`, `mDNSDiscover`, `cloudDiscover`, `knownHostsDiscover`, `supplementDeviceAuth` were widened from `private` to `internal` (pure visibility change, no behavior change) so `Tests/hdhr_VCRTests/Network/HDHRManagerTests.swift` can exercise them directly against a mocked `URLSession`/`URLProtocol` — success, malformed-JSON, HTTP-error, and network-error cases, plus `setFavorite` and the pure `supplementDeviceAuth` merge logic. **Still genuinely uncovered, and staying that way**: mDNS/UDP broadcast discovery (`udpDiscoverSync`, `subnetBroadcastAddresses`, `udpDiscoverAndFetch`) hits real `getifaddrs`/`socket`/`sendto`/`recvfrom` system calls with no seam — by far the largest remaining chunk of the file's missed lines — and the top-level `discoverDevices(knownHosts:interface:)` orchestrator, which always waits out UDP's ~2s real-broadcast timeout even with mocked HTTP, so it wasn't exercised directly either (would make the test suite slow and network-order-dependent for little unit-level gain over testing its sub-calls directly, which the new tests already do). `tools/mock_hdhr.py` could still support a slower, higher-level integration test of the whole discovery path someday, but wasn't needed for this pass's HTTP-level coverage jump.
- **`RecordingManager.swift`: 7.04% → 89.01% line coverage.** Chose the "mock-curl-script" alternative over a spawn-seam closure: added an injectable `curlExecutablePath` init parameter (default `"/usr/bin/curl"`, unchanged from the old hardcoded literal) rather than touching `spawnDetached`/`posix_spawn` at all. `Tests/hdhr_VCRTests/Recording/RecordingManagerTests.swift` points it at small per-test generated shell scripts that mimic curl's relevant behavior (write the `--dump-header` file, sleep, exit with a controlled code), then drives `start`/`stop`/`stopAll`/`isRunning`/`reattach`/`readHDHRResource`/`readAndClearHDHRError`/`readAndClearExitStatus`/sleep-assertion methods through a **real** spawned-killed-reaped process — an integration-style test (real subprocess, real timing, small `waitUntil` polling helper) rather than a pure unit test, but it exercises the actual `posix_spawn` code path unmodified. Remaining gap is small: the verbose-curl logging branch (`writeCurlLogHeader`/`rotateCurlVerboseLogIfNeeded`, no test uses `verbose: true`), the orphaned-after-restart `ECHILD`/`kill(pid,0)` branch in `isRunning`, and a few unexercised `hdhrErrorLabel`/`curlExitLabel` switch cases.

`WebServer.swift` (still ~14-28%) remains the largest raw-uncovered-line file but stays lower priority per the original plan's "blast radius, not raw percentage" framing — heavily orchestration/`@MainActor`-coupled and already exercised indirectly through `GuideStore`/`ManagedGuideMatcher` test suites plus the post-deploy web server smoke/perf suites. `AppState.swift` was 20.34% at the time this note was written but see the entry below — its core scheduling engine specifically got covered 2026-08-15, moving the file to ~39%.

**Key files**: `RecordingManager.swift`, `HDHRManager.swift`, `Tests/hdhr_VCRTests/Recording/RecordingManagerTests.swift`, `Tests/hdhr_VCRTests/Network/HDHRManagerTests.swift`.

---

### AppState's recording-scheduling engine — covered 2026-08-15; `resolveSeriesAir` still gap

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

Also found a real, load-bearing bug in the process: `diskOK(for:)`'s `maxDiskPct: Double = 93`
was a `private let` — on a dev machine whose real disk happens to be over 93% used (true for the
machine this was found on), the real app would silently refuse to start every recording, with
`diskOK`'s own fallback-to-true path never triggering since the filesystem stats read succeeds fine.
Widened to `var` (test seam, same "widen for testability" precedent as `HDHRManager`'s methods
above) so tests unrelated to disk-space logic can override it; not a source of the coverage number
above, but a correctness finding worth knowing about. Follow-up requested same day: raised
`Min_disk_free_gb`'s default from 10 GB to 30 GB (see `issues_resolved.md` — the 93%-full check
itself is unchanged and independent, so a drive in the exact situation that surfaced this is still
correctly flagged, just for that reason alone now).

**`scheduleNextAir`'s tier-ordering covered 2026-08-24**: `Tests/hdhr_VCRTests/Recording/AppStateSeriesSchedulingTests.swift`
now exercises the `.seriesChannel`/`.seriesAll` branch's own orchestration directly — which of the
four lookup tiers (`currentEpisode` → `nextEpisode` → `currentEntryByTitle` → `nextEntryByTitle` →
no-match retry-bump) wins when more than one could match, that `seriesChannel` never follows a
same-series match onto a different channel while `seriesAll` does (and updates `show_channel` when
it does), and that a no-match tick re-syncs `show_end` off the bumped `show_next` rather than
leaving it stale. Pre-loads the mocked `GuideStore` via a direct `guideStore.load(for:)` call before
constructing `AppState` (so `isFresh` is already true and `scheduleNextAir` never re-enters its own
guide-fetch branch), a simpler variant of the request-handler-timed-to-an-`await` technique
`AppStateIdleLoopStaleIndexTests.swift` uses. **Still uncovered**: `resolveSeriesAir` (a separate
function, called from the Add Show flow via `applyGuideEntry`, not from `scheduleNextAir`) has
similar tier-matching logic of its own that these tests don't exercise.

Three more gaps found by the 2026-08-16 full-codebase audit — Bonus Time (sports-genre default +
`show_end` padding arithmetic), idle-loop stale-index-across-`await` safety, and `deleteShow`'s
`discordEpisodeSnapshots` cleanup — were resolved the same day; see `issues_resolved.md`.

**Key files**: `AppState.swift`, `Tests/hdhr_VCRTests/Recording/AppStateRecordingEngineTests.swift`, `Tests/hdhr_VCRTests/Recording/AppStateIdleLoopStaleIndexTests.swift`, `Tests/hdhr_VCRTests/Recording/AppStateSeriesSchedulingTests.swift`, `Tests/hdhr_VCRTests/AppState/AppStateDeleteShowCleanupTests.swift`, `Tests/hdhr_VCRTests/TestFixtures.swift`.

---
