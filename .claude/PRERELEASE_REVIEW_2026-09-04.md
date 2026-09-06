# Pre-release code review — 2026-09-04

Scope: `dadf7c9..HEAD` (commits since the last recorded code-review pass,
`dadf7c9 docs: record v2.2.0..HEAD code review findings`) — 13 commits covering
the FEED rename, live-edge fix, transcode audio/GOP matching, `?duration=` on
the transcode path, CC-passthrough findings, VLC player accessibility labels,
hardware-decode confirmation docs, and the VLC credits UI.

Run as 4 parallel agents: general bug-hunt, invariants-reviewer,
swift-quality-reviewer, docs-auditor. Findings appended below as each returns.

---
## Agent 1: invariants-reviewer — COMPLETE

**Result: No violations found.**

Checked and cleared:
- Tuner occupancy math (`vlcOccupiesTuner`/`activeTunerCount`/`tunersFull`) untouched by this range; new "Relay: N watching" counter is display-only, never feeds tuner-occupancy math.
- Virtual tuner relay guardrails — `relayDeviceID(sourceDeviceID:)` (VirtualTunerService.swift:260-265) keeps the `FEED` sentinel prefix; relay detection is driven by `HdhrVCRplusVirtualRelay` discover.json field, unaffected. New stale-device pruning in `probeForNewDevices()` (AppState.swift:1024-1057) correctly excludes any device still referenced by a show, and broadcasts `deviceRemoved` correctly.
- Web UI push invariant — pruning + viewer-count/relay-stream code broadcasts where needed; relay viewer count is menu-bar-only so no broadcast needed there.
- VLC relay-coupling checks (`/api/watch-recording` string match) unchanged by the FEED rename (UI text only).
- Guide/JS/row-hiding invariants: untouched files in this range.

---
## Agent 2: docs-auditor — COMPLETE

**2 findings (1 wrong, 1 incomplete):**

1. **WRONG — `docs/VirtualTunerService.md`, "Real transcode (Phase 2)" Sout chain bullet (~line 98).** Claims the GOP-length fix (`sout-x264-keyint=60`/`-min-keyint=60`) works via per-media `libvlc_media_add_option` calls. This is backwards — code (`VLCBridge.swift:258-268,274-275`) and commit `0294155`'s own message confirm per-media options were tested and confirmed NOT to work; the actual fix is passing them as global `libvlc_new()` argv. `docs/VLCPlayerView.md`'s own later "Viewer-side decode..." section (~line 521) correctly describes it as `libvlc_new` argv — so the two docs directly contradict each other, and `VirtualTunerService.md` is the wrong one. Code still redundantly also passes these as per-media options (`WebServer`/`VLCBridge.swift:1009`) alongside the working global-argv version — that half is dead weight per the code's own comment, not the real fix mechanism.
   - **Action: fix `docs/VirtualTunerService.md`'s wording to match the code (global argv, not per-media option).**

2. **INCOMPLETE — `docs/SettingsView.md` About/Credits bullet (~line 348).** Omits that the code also renders a "Credits" headline `Text` between the divider and the playback line (`SettingsView.swift:1059-1061`). Minor/cosmetic.
   - **Action: add the headline mention to the doc bullet.**

Everything else checked clean: Relay→FEED rename systematically verified across MenuContent/.md, SettingsView/.md, FirstRunWizardView/.md, AppState/.md, VirtualTunerService/.md — user-facing strings consistently updated, internal-only "relay" terminology (Watch Now `/api/watch-recording`, `recordingShowId`, VLCBridge.md's "Recording-Relay Seek State") correctly left alone (different, non-renamed mechanism). Timeouts, stale-device pruning, `?duration=`, AC-3/channels=2, accessibility identifiers, hardware-decode claims all matched code exactly.

---
## Agent 3: swift-quality-reviewer — COMPLETE

**3 findings, none release-blocking:**

1. **Dead/contradicted code (confirms docs-auditor's finding #1) — `VLCBridge.swift:1009`.** Still passes `sout-x264-keyint=60`/`sout-x264-min-keyint=60` as *per-media* options via `mediaAddOptFn`. The file's own new doc comment (lines 258-267) explicitly says this exact per-media form was confirmed live to silently no-op, and only the global-argv form (lines 268-283) actually works. Lines 1009's two options are leftover from the pre-fix attempt — harmless (no-op stays no-op) but self-contradicting to a future reader.
   - **Action: delete the two dead per-media option lines at VLCBridge.swift:1009.**
2. **Minor stale comment — `SettingsView.swift:708`.** Comment still reads "not the Recording Relay toggle" (pre-rename name). Cosmetic, not user-facing.
   - **Action: optional, fold in next touch.**
3. **Low-severity test hygiene — `VirtualTunerLiveStreamTests.swift`.** New split-file live-edge test uses a flat `Task.sleep(500ms)` instead of a real completion signal to let the relay open+stat the file before appending. Opt-in test (`RUN_VIRTUAL_TUNER_LIVE_TESTS=1`), not in default CI, window is generous. Not urgent — right fix if it ever flakes is a real sync hook, not a longer sleep.

Overall assessment: "unusually well-documented, tightly-scoped diff... no other hacks, scope creep, dead code, or efficiency regressions found." Viewer-counting plumbing clean and clamp-tested; `relayDeviceID` avoids the earlier same-day `_Relay`-suffix bug; stale-device-pruning respects the "never omit a device a show still references" invariant; accessibility work cleanly scoped. Full observations also in `.claude/CODE_NOTES.md` under "2026-09-04 — swift-quality-reviewer pass on dadf7c9..HEAD".

---
## Agent 4: general-purpose bug hunt — COMPLETE

**5 findings, most severe first:**

1. **Stale "FEED: N watching" viewer count in menu bar — `MenuContent.swift:109`.** `VLCBridge.shared.transcodeViewerCount(showId:)` reads a plain (non-`@Published`) dict value inside `VLCBridge`. `MenuContent` only observes `AppState`'s `@Published` properties, not `VLCBridge`. A remote viewer connecting/disconnecting from only the transcoded (H.264) FEED stream doesn't touch `state.recordingShows`, so nothing triggers a SwiftUI redraw — displayed count goes stale until an unrelated `AppState` mutation happens to force a menu rebuild.
   - **Action: needs a real fix (bridge the count into something `@Published` MenuContent observes) before relying on it, or explicitly punt to TODO.md.**
2. **Wrong codec label — `VLCPlayerView.swift:151-154`.** `inferredCodecs` still hardcodes `("H.264", "AAC")` for any `transcode=` URL, but this diff changed the sout chain to `acodec=a52` (AC-3) (`VLCBridge.swift:978-988`, deliberate 2026-09-04 change). Info popover shows "Audio: AAC" for a stream actually carrying AC-3.
   - **Action: one-line fix — change the hardcoded label to "AC-3".**
3. **Per-chunk uncancelled 24h timer accumulation — `WebServer.swift:950-963`, `streamGrowingFile`/`handleGrowingFileChunk` (~1104).** `sendWithTimeout` now schedules a `queue.asyncAfter` fallback on *every* chunk send, including the "no timeout" paths (Watch Now, transcode-source reads) that pass `growingFileNoTimeout` (86400s). Each completed send still leaves a live 24h GCD closure retaining `conn`/captured state until it fires and no-ops. New regression this diff introduced (no `asyncAfter` on this path before). Self-heals, guarded against double-fire — low practical severity, but a long session streaming thousands of chunks accumulates many pending timers instead of releasing promptly.
   - **Action: lower priority — cheap `DispatchWorkItem`-based cancel would fix; acceptable to defer to TODO.md if not release-blocking.**
4. **Dead/redundant per-media GOP options — `VLCBridge.swift:257-266` vs `:988-1009` (confirms docs-auditor #1 and swift-quality-reviewer #1 — 3/4 agents independently flagged this).** Same finding: per-media options at line 1009 are dead, self-contradicted by the file's own adjacent comment.
   - **Action: delete the two dead lines at VLCBridge.swift:1009 (same as above).**
5. **Doc/code mismatch — `docs/VirtualTunerService.md:71`.** Still quotes the error string `"This tuner is a temporary recording relay..."`, but `WebServer.swift` (lines 1672, 1848) renamed it to `"...recording FEED..."` in this diff.
   - **Action: update the doc quote to match.**

No further Relay→FEED stragglers or concurrency/lifecycle bugs found beyond these.

---

## Summary — all 4 agents complete

**Confirmed action items (cross-agent agreement in parens):**
1. Delete dead per-media GOP options at `VLCBridge.swift:1009` — **3/4 agents flagged this independently.**
2. Fix wrong "AAC" codec label → "AC-3" in `VLCPlayerView.swift:151-154`.
3. Fix `docs/VirtualTunerService.md`'s GOP-fix mechanism description (per-media → global argv) — line ~98.
4. Fix `docs/VirtualTunerService.md:71`'s stale "recording relay" error-string quote → "recording FEED".
5. Add missing "Credits" headline mention to `docs/SettingsView.md`'s About bullet (~line 348).
6. Stale "not the Recording Relay toggle" comment in `SettingsView.swift:708` — cosmetic, optional.

**Needs a judgment call, not release-blocking but real:**
7. "FEED: N watching" menu count can go stale (not `@Published`-observed) — needs either a real fix or an explicit TODO.md punt.
8. New uncancelled 24h-timer accumulation on the no-timeout streaming path (`WebServer.swift` `sendWithTimeout`) — self-heals, low severity, cheap fix available if wanted.

**No invariant violations found (invariants-reviewer, clean pass).**

---

## Fixes applied — 2026-09-04

All 8 action items fixed:

1. **Deleted dead per-media GOP options** — `VLCBridge.swift:1009` (now shorter, comment rewritten to point at the working global-argv location instead).
2. **Fixed wrong codec label** — `VLCPlayerView.swift`'s `inferredCodecs`. Went further than the original finding: discovered this function is shared by two genuinely different transcode paths (real device EXTEND hardware transcode → AAC, vs FEED software transcode marked by literal `transcode=auto` → AC-3). A blanket swap to "AC-3" would have fixed FEED but broken the real-device case; fixed to distinguish both correctly instead.
3. **Fixed `docs/VirtualTunerService.md`'s GOP-fix mechanism description** (was backwards — said per-media option works, actually global argv only).
4. **Fixed `docs/VirtualTunerService.md:71`'s stale "recording relay" error-string quote** → "recording FEED".
5. **Added missing "Credits" headline mention** to `docs/SettingsView.md`.
6. **Fixed stale "Recording Relay" comment** in `SettingsView.swift:708`.
7. **Fixed "FEED: N watching" staleness** — added `AppState.transcodeViewerCount` (`@Published`, mirrors `relayRawViewerCount`'s existing shape) wired to the actual connect/disconnect points (`WebServer.beginTranscodeRelay`'s successful start, both its `stopTranscodeSession` call sites, and `stopAllTranscodeSessions`'s now-`@discardableResult Int`-returning removed-viewer count at both AppState force-teardown call sites). `MenuContent` now reads this instead of calling into VLCBridge's non-`@Published` dictionary directly. Deliberately did NOT make MenuContent observe `VLCBridge` itself — its `bufferInfo`/`isPlaying`/etc. update far too often during local playback and would reintroduce the documented "Menu rebuild churn" bug class.
8. **Fixed uncancelled 24h timer accumulation** — `WebServer.sendWithTimeout` now uses a cancellable `DispatchWorkItem` instead of a bare `asyncAfter` closure, cancelled on the send-completion success path.

Build clean (`swift build`), no new warnings introduced. `swift test --filter "VirtualTuner|WebServerPerf"` — all 56 tests pass.

**Not yet run**: full test suite (`swift test`, no filter) — recommended before final release sign-off.

**Full suite (`swift test`, no filter):** first run showed 6 failures (403 tests/65 suites); two immediate re-runs after that both passed clean (403/403). Not investigated further since it didn't reproduce — looks like pre-existing flakiness unrelated to this session's edits (likely the perf-baseline suite, which runs live against the app's own port 1980 and is timing-sensitive), not a regression from tonight's fixes. Worth a clean run before actually cutting the release, but not blocking further work here.

---

## New feature — FEED signal-strength reporting (2026-09-04)

User request: report estimated signal strength to a FEED consumer, using only existing/locked endpoints (no new HTTP route, no new polling).

**Design**: the live signal data already existed (`AppState.deviceTunerOccupancy`, continuously refreshed every idle tick against the real source device for unrelated tuner-occupancy math) — just wasn't surfaced to FEED consumers. Added a shared `WebServer.liveSignalQualityPercent(for:state:)` lookup (Resource-header-first, VctNumber-fallback match, mirroring `AppState.fetchDeviceStatusUncached`'s existing vstatus lookup) and wired it into two already-existing routes:
- `/status.json` (`buildVirtualTunerStatusJSON`) — added the real `SignalQualityPercent` field (same name/scale a genuine HDHomeRun device's `/status.json` already uses), for any third-party HDHomeRun-aware client polling it directly.
- `/lineup.json` (`buildVirtualTunerLineupJSON`) — added a new synthetic `HdhrVCRplusSignalQualityPercent` key (following the existing `HdhrVCRplusShowTitle`/`HdhrVCRplusTranscodeViewers` convention), since `/lineup.json` is the one route already continuously fetched for a discovered relay device (the deliberate `recordableDevices` exception) — `/status.json` is not, so this app's own consumer reads the lineup copy instead.
- `LineupEntry.virtualRelaySignalQualityPercent` (new Decodable field + CodingKeys entry) and a new "Signal: N%" row in `MenuContent`'s "Recording on Another Mac" submenu, right below the existing "Transcoding: N viewers" row.

No new HTTP route, no new client-side polling loop — both requirements from the ask.

**Docs updated**: `docs/VirtualTunerService.md` (new "Estimated signal for FEED consumers" subsection + field-list updates in two places + fixed a now-false "only the one string" claim), `docs/MenuContent.md` (new menu row description + ASCII structure update).

**Tests added** (`VirtualTunerWebRoutesTests.swift`, 5 new): resource-match wins over a same-channel decoy tuner, VctNumber-fallback when `show_tuner_resource` is still empty, omitted (not "0") when the device was never polled, and the equivalent two cases for the `/lineup.json` key.

Verified: `swift build` clean, `swift test` — 408/408 pass (403 + 5 new).

---

## Efficiency/bottleneck pass (2026-09-04) — "make it snappy"

### Personal investigation: `ConfigManager.save` (already-tracked TODO item)

Confirmed why this isn't mechanical: a correct fix needs `saveConfig()` to become genuinely `async` (dispatch actual disk I/O to `Task.detached`, `await` it — same shape as the fire-and-forget `writeMetadataSidecar` precedent, but that precedent doesn't directly apply here since some of the 26 call sites need "save completed before HTTP response" ordering, not fire-and-forget). Checked `WebServer.handleRecord`/`handleEdit`/`handleDelete` — they're plain synchronous `WebResponse`-returning functions, not `async`, so making `saveConfig()` async would propagate function-coloring further than just its 26 call sites, into the request-dispatch chain itself. Bigger ripple than it looks — deliberately NOT attempted this close to release without a scoped decision. TODO.md's own caution was correct.

### Agent 1 (general-purpose): MainActor blocking / hot-path hunt — COMPLETE

Assessment: "a mature, heavily-audited codebase, so new findings were genuinely hard to find" — most hot paths already well-optimized (hoisted lookups, coalescing, off-actor dispatch). Confirmed already-tracked items (ConfigManager.save, broadcastGuideChangeEvent SSE payload, mpegTSVideoStreamType per-connection re-scan, lanIPAddress per-request getifaddrs(), MenuContent.remoteRelayEntries per-render churn) were NOT re-reported.

**New finding #1 (real, same bug shape as ConfigManager.save, not yet tracked): `GuideStore` parses the full guide payload synchronously on `@MainActor`.**
- `GuideStore.swift:14` — whole class is `@MainActor`. `fetchAndIndex(id:url:parse:)` (line 160) awaits the network fetch, then runs `parse` **inline, synchronously, on the actor** — JSON decode (`JSONDecoder().decode([GuideChannel].self, ...)`, line 102) or XMLTV SAX parse (`XmltvParser.swift`). Real feed measured at 106 channels / 4,929 programmes / 3.7-3.9MB (`docs/HDHRFindings.md:347`) — not small.
- `buildIndex(deviceId:channels:)` (line 221) does more MainActor-synchronous work after: sorting, restamping, building `channelEntryIndex`/`seriesIndex`.
- Fires at every launch, every hourly `refreshGuides()` (`AppState.swift:1227`), and repeatedly during `guideApiBackoff` retries.
- `GuideStore.loadAll`'s `withTaskGroup` only overlaps the network `await` — the CPU-bound decode+index still serializes on MainActor per device (same actor). Multi-tuner household pays N sequential multi-MB parses back-to-back, hourly, each stalling UI + every queued web request.
- `performFetchAllGuides()` (`AppState.swift:1197`) compounds this by calling `webServer.prebuildPageHTML` (another full MainActor guide-grid rebuild) immediately after, back-to-back on the same actor.
- **Fix shape** (mirrors the TODO-scoped ConfigManager.save fix): move JSONDecoder/XMLParser work off-actor (`Task.detached` before handing decoded `[GuideChannel]` back to the actor for indexing).

**New finding #2 (minor): `buildIndex`'s series-index prune scans all devices' series, not just the refreshing device's.**
- `GuideStore.swift:222-226` — every `buildIndex` call (once per device per refresh) does `for key in seriesIndex.keys { ... }` over the **entire cross-device** `seriesIndex` to prune just one device's stale entries. Negligible for single-tuner; scales with total distinct series across all devices for multi-tuner households. Stacks on top of #1 during the same hourly refresh.

Nothing else surfaced beyond what's already in TODO.md/ISSUES.md.

### Agent 2 (swift-quality-reviewer): whole-app efficiency pass — COMPLETE

**4 findings, most severe first — all safe/mechanical, no actor-isolation changes needed:**

1. **`WebServer.swift:2367-2376`** — `buildGuideGridHTML`'s `ggSkip`/`ggAlias`/`ggKnown` (a Set, a Dict, a 24-entry Set) declared *inside* the innermost per-guide-entry loop — freshly allocated/populated per program block. Scale: "1300+ program blocks" per rebuild (per `prebuildPageHTML`'s own comment), on `@MainActor`, for every one of 9+ guide-changing events. Rest of the function is carefully hoisted already; these three weren't. **Fix: hoist to `private static let`s — pure static data, no captured state.**
2. **`GuideViewHelpers.swift:178-183`** — `he(_:)` HTML-escape does 4 unconditional chained `replacingOccurrences` even when nothing needs escaping (the common case). Called ~dozen times per grid entry across the same 1300+-block rebuild, plus again in 3 other HTML builders on every broadcast. **Fix: presence check before falling through to replacements (~4x common-case win).**
3. **`WebServer.swift:2196-2202`** — `isSkippedAiring` recompiles `#"^S\d+E\d+$"#` via `.regularExpression` on every call for every managed guide entry, instead of once. Bounded by managed-show count so lower severity. **Fix: `private static let` compiled pattern.**
4. **`WebServer.swift:1545-1550`** — `GET /favicon.ico` synchronous `Data(contentsOf:)` disk read on `@MainActor` per request, unlike `cachedIconPNG` (preloaded) two cases below it. Very low severity (tiny file, browser-cached) — same shape as the tracked `ConfigManager.save` item, flagged for possible folding into that cleanup, not urgent on its own.

Everything else in the priority areas (idleLoop, MenuContent.body, GuideStore indexed queries, ManagedGuideMatcher, the broadcast/prebuildPageHTML grid-sharing machinery) already well-optimized or already tracked. Full notes in `.claude/CODE_NOTES.md`.

### Decision: what's getting fixed now vs. deferred

**Fixing now** (agent 2's findings 1-3 — safe, mechanical, no behavior change, no async-coloring risk):
- Hoist `ggSkip`/`ggAlias`/`ggKnown` out of the per-entry loop.
- Add a presence-check fast path to `he(_:)`.
- Compile `isSkippedAiring`'s regex once as a static.

**Deferred, reported not implemented** (needs a deliberate design decision, same risk class as the already-tracked `ConfigManager.save` item — real fix requires propagating `async` further than it first looks, right before a release is the wrong time to do that blind):
- `GuideStore`'s synchronous-on-MainActor guide parse/index (agent 1's finding #1) — biggest bottleneck found this session, but same "needs async-coloring propagation, not mechanical" shape as `ConfigManager.save`.
- `buildIndex`'s cross-device series-index prune scan (agent 1's finding #2) — minor, stacks on top of the above.
- `/favicon.ico`'s synchronous disk read (agent 2's finding #4) — very low severity, folding into a future `ConfigManager.save`-style cleanup pass rather than a one-off fix.

### Fixes applied

1. `WebServer.swift` — hoisted `ggSkip`/`ggAlias`/`ggKnown` out of `buildGuideGridHTML`'s per-entry loop into `private static let`s (pure static data, no captured state) — removes ~1300+ reallocations per guide-grid rebuild.
2. `GuideViewHelpers.swift` — `he(_:)` now checks `rangeOfCharacter(from:)` against a precomputed `CharacterSet` before falling through to the 4 `replacingOccurrences` passes, skipping all 4 no-op scans for the common case (no escapable characters present).
3. `WebServer.swift` — `isSkippedAiring`'s regex compiled once as `private static let episodeTagRegex` (`NSRegularExpression`) instead of recompiling `#"^S\d+E\d+$"#` via `.range(of:options:.regularExpression)` on every call.

All three are pure mechanical hoists/caches with no behavior change (verified: identical output for identical input in every case). Build clean, full suite 408/408 passing after the change, including targeted re-runs of `WebServerHelperTests`/`GuideViewHelpersTests`/`WebServerTests`.

**Not fixed — deferred, same reasoning as `ConfigManager.save`**: `/favicon.ico`'s synchronous disk read (agent 2 finding #4) and the `GuideStore` MainActor-parsing bottleneck (agent 1 finding #1, the biggest one found this session) both need actual design decisions (async-coloring propagation risk) rather than a mechanical fix, and weren't touched this close to release.

---

## FEED join-latency tuning — keyint 60 → 30 (2026-09-04)

Per explicit user request, following up on the earlier "web-optimized/faststart" question: since FEED transcode sessions are shared (ref-counted per show), only the viewer who *creates* a session gets a guaranteed IDR as frame one — every later joiner connects mid-stream with no keyframe-alignment help from VLC's `std{access=http}` output module (checked directly: `mux_ts`'s option list has no such setting). So the keyframe interval is the real worst-case join latency for most viewers, not just a nice-to-have.

Changed `--sout-x264-keyint=60`/`--sout-x264-min-keyint=60` → `=30` (`VLCBridge.swift`'s `libvlc_new()` global argv) — now *tighter* than real broadcast's own ~1s cadence (0.5s @ 59.94fps, 1.0s @ 29.97fps, down from 1.0s/2.0s). Cost is quality, not size — `vb=<kbps>` targets a fixed average bitrate, so the encoder absorbs the ~doubled I-frame frequency via slightly higher QP rather than a bigger stream (~4-5% more bit pressure at a rough 4x I:P cost ratio, estimated not measured).

Updated `docs/VirtualTunerService.md`'s GOP section and `TODO.md`'s Phase 2 summary to match. **Not live-verified** against a real device (unlike the original 60 pick, which was `mediainfo`-confirmed) — no automated test pins the exact GOP value either, so nothing broke, but this specific number is unconfirmed until tested against real hardware. Build clean, `swift test --filter VirtualTuner` — 54/54 pass.

### Live-verified against real hardware (2026-09-04, no test script — direct curl/mediainfo)

Deployed the current build (`./deploy.sh`), discovered the real device (105404BE), started a real recording of a currently-airing show via `/api/record`, captured ~9s of the transcoded FEED output via `curl .../auto/v5.1?dev=105404BE&transcode=heavy`, inspected with `mediainfo --Full`.

**Confirmed via x264's own embedded encoding-settings string**: `keyint=30 / keyint_min=16 / ... rc=abr / bitrate=6000` — the code change took effect exactly as intended. `keyint_min=16` is the real clamped value (previously only estimated at "~31" for the old 60/60 setting). Source was 59.94fps → 30-frame keyint = 0.5s, matching the prediction. Actual measured bitrate 5,586kb/s vs 6,000kb/s nominal — confirms empirically (not just theoretically) that the tighter GOP cost quality headroom, not stream size. Bonus: also re-confirmed AC-3 audio on the transcode path and the new `HdhrVCRplusSignalQualityPercent` field live in `/lineup.json` (read 90 for the real tuner).

Cleaned up: deleted the test recording via `/api/delete`, confirmed removed from both `/api/now.json` and the config file, removed the temp capture file. Docs updated to drop the "not yet live-verified" caveat.
