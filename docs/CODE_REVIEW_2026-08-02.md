# Code Simplification Review — 2026-08-02

Report-only snapshot. No source or docs were edited in producing this — everything below is a
proposal for the user to triage. Produced by 7 parallel `swift-quality-reviewer` sweeps over all 26
files in `Sources/hdhr_VCR/` (an even sweep, not just the biggest files), synthesized and spot-checked
by the orchestrating session, plus one `invariants-reviewer` cross-check pass on the proposals with
plausible invariant contact. `src/HDHomeRunKit` (unwired parked package) was excluded per user
direction. Scope is efficiency/simplification only — no correctness/bug findings are included; that's
`/code-review`'s job.

---

## Executive Summary — top 10 quick wins

Ranked by (impact × low risk × low effort). All Low risk / S-M effort unless noted.

1. **Remove dead `VLCBridge.volume()`** (`VLCBridge.swift:609`) — confirmed zero call sites anywhere in `Sources/`/`Tests/`; the UI reads/writes volume purely via `@AppStorage`. Zero risk.
2. **Remove dead `.g-logo-ph` CSS rule** (`WebServer.swift:1667`) — confirmed no HTML ever emits this class; only `.g-logo` is used. Zero risk.
3. **Merge duplicate genre-color CSS tables** (`WebServer.swift:1755-1850`) — `.g-prog-now.gg-*` and `.g-prog-sched.gg-*` are two complete 24-genre tables, verified byte-identical value-for-value. Comma-selector merge removes ~96 lines with zero visual change.
4. **Fix `computeDevTuners()` double-computation** (`WebServer.swift:1039-1040, 1398`) — called twice per `buildHTML()`; the surrounding comment already says it was unified "so the two can never define active differently" but the code still computes it twice. Compute once, pass down.
5. **Unify duplicate CRC-32 implementations** (`HDHRManager.swift:308-315` + `WebServer.swift:3324-3330`) — confirmed both exist independently, same IEEE-802.3 polynomial, two different protocols (discovery packet vs. gzip trailer). Move one (prefer the table-driven `WebServer` version) into a shared helper.
6. **Extract `pushShowUpdate()`** (`AppState.swift`) — the `if !menuIsOpen { rebuildMenuEntries() }` + `broadcastGuideChangeEvent(...)` pair repeats at confirmed 9-10 call sites across `addShow`/`updateShow`/`pauseShow`/`resumeShow`/`deleteShow`/`startRecording`/`stopRecording` (bigger than either reviewing group individually scoped — the pattern spans both AppState halves).
7. **Route WebServer's 4 GET handlers through the existing `jsonResponse()` helper** (`WebServer.swift:611-716`) — they currently hand-roll a pointless `Data→String→Data` round trip instead of reusing the helper already used by the 4 POST handlers.
8. **Extract `tunerAvailable()` shared helper** (`AppState.swift:2713-2723, 2751-2761`) — `watchInApp`/`watchInVLC` both run an identical fetch-status + `tunersFull` check + alert block, including a verbatim-copied explanatory comment.
9. **Unify the duplicated unsaved-changes `NSAlert` flow** (`EditShowView.swift:53-83,91-116` + `SettingsView.swift:1076-1099`) — three near-identical hand-built alert flows collapse to one `promptUnsavedChanges()` call, ~70 line reduction.
10. **Extract `GuideStore.performLoad()` shared skeleton** (`GuideStore.swift:69-197`) — `load()`/`loadXMLTV()` are ~90% identical (guard/GET/status/empty/index/timestamp/catch); only the decode step differs. (Effort M — touches the guide-fetch path, verify the single-call/no-pagination behavior is preserved.)

**One proposal was rejected by the invariants cross-check** — see "Rejected proposal" below. Do not implement it as originally described by the reviewing group.

---

## Rejected proposal — do not implement as-is

**`AppState.swift:1023-1040` (`resolveSeriesAir`'s `apply`) vs `1867-1882` (`scheduleNextAir`'s `applyMatch`)**

The reviewing group proposed unifying these two near-identical "apply a SeriesMatch to a Show" closures into one shared `applySeriesMatch(...)`, since they're otherwise duplicate — but `scheduleNextAir`'s copy sets `show_genre` and `resolveSeriesAir`'s does not, and a naive merge would make `resolveSeriesAir` start setting it too.

`invariants-reviewer` flagged this as a real behavior change, not a pure dedup: `addShowFromGuide` sets `show.show_genre` from the guide entry the user actually clicked (`AppState.swift:974`), and `resolveSeriesAir` deliberately leaves it alone afterward even when it resolves to a *different* airing (e.g. it may match a currently-airing rerun instead of the clicked slot). Unifying would silently overwrite the user-selected entry's genre with the resolved match's genre at creation time — which flows into the Discord card's genre tag and the `show_bonus_time` sports-genre default (`Models.swift:255`), producing a Bonus Time default the user never saw or chose.

**If deduplicating this, use two thin wrappers around one shared field-assignment core, or a `setGenre: Bool` parameter — not a single unconditional helper.** The duplication itself is real and worth fixing; just not by equalizing the two call sites' behavior.

---

## Findings by theme

### Large functions / god objects

```
File: Sources/hdhr_VCR/AppState.swift
Lines: 1114-1391 (idleLoop)
Current: 277 lines, 7 unrelated jobs at one nesting level (device-discovery retry, guide-refresh
check, stop-completed-recordings, per-show housekeeping, start-ready-recordings, device-status
polling, diagnostic guide scan). The function's own `// Pass 1` / `// Pass 2` comments (confirmed at
lines 1161, 1180) already mark the extraction seams.
Proposed: Thin orchestrator calling private helpers per pass; each must re-resolve `shows` by id
internally per the idle-loop-safety invariant.
Risk: Low (mechanical if each helper preserves the re-resolve-by-id pattern) · Effort: M
```

```
File: Sources/hdhr_VCR/AppState.swift
Lines: 1404-1598 (startRecording)
Current: 194 lines chaining ~9 sequential validation/execution concerns in one flat function.
Proposed: Split into a validation phase (`recordingBlockReason(for:device:) -> String?`) and an
execution phase (path planning + launch + bookkeeping).
Risk: Medium — checks currently interleave early-return with `shows[index]` mutation and Discord
side effects; ordering must be preserved exactly. · Effort: M
```

```
File: Sources/hdhr_VCR/AppState.swift
Lines: 2951-3030 (fetchDeviceStatusUncached)
Current: ~80 lines doing occupancy publishing, signal-dropout tracking, and a second network
fetch+kv-parse, all at one level.
Proposed: Split into applyOccupancy(), trackSignal() (must still derive keys via
ChannelSignalStore.key(for:)), fetchVstatusDetail().
Risk: Medium — several menuIsOpen/shows-contains guards are load-bearing around suspension points
and must stay attached to their original sub-scope. · Effort: M
```

```
File: Sources/hdhr_VCR/Views/VLCPlayerView.swift
Lines: 410-596 (toolbar computed property)
Current: ~186 lines combining 9 unrelated UI clusters (channel picker, buffer/catch-up pill,
volume, audio/CC/output pickers, screen picker, etc.) at one level — inconsistent with this same
file's already-established pattern of extracting posterOverlay/errorOverlay/endedOverlay separately.
Note: an earlier line-count estimate in the review brief (~530 lines for a different function,
showId(fromLiveGuideNumber:)) was wrong — that function is actually 4 lines; this toolbar property
is the real large unit in the file.
Proposed: Extract each cluster into its own private var/@ViewBuilder func, mirroring the existing
overlay pattern.
Risk: Low — pure decomposition · Effort: M
```

```
File: Sources/hdhr_VCR/WebServer.swift
Lines: 1237-1352 (buildGuideGridHTML per-entry loop body)
Current: ~115 lines interleaving gap computation, status-ring precedence, genre-class/gradient
computation, tooltip assembly, and data-* attribute assembly at one flat level — the densest
invariant region in the codebase (status precedence recording>skip>conflict>scheduled;
tuner-scoped managed-marker keys).
Proposed: 2-3 named helpers (status precedence, genre coloring, attribute assembly), matching the
file's own existing showRow/tunerBox extraction pattern.
Risk: Medium — must preserve exact precedence order and key construction; invariants-reviewer did
not find a conflict in the proposal as scoped (it explicitly commits to preserving both), but this
is the single highest-care item in the whole report if implemented. · Effort: M
```

```
File: Sources/hdhr_VCR/Views/MenuContent.swift
Lines: 119-137, 163-189, 196-227, 231-252 (body)
Current: 5 near-identical per-device-grouped Section blocks (Recording/Up Next/Scheduled/
Paused/Unavailable) repeat the same "multi-device? loop+filter+Section : one flat Section" shape.
Proposed: Shared deviceGroupedSection<Item>(...) @ViewBuilder helper for 4 of the 5 sites (Up Next
keeps its extra time-bucketing layer). ~50-60 line reduction.
Risk: Low — pure view-construction restructuring, no new @Published writes (invariants-reviewer
confirmed no menu-rebuild-churn conflict). · Effort: M
```

```
File: Sources/hdhr_VCR/VLCBridge.swift
Lines: 474-553 (tickController, runs every 3s while playing)
Current: 5 distinct concerns (state polling, track-list trigger, rate-ramp math, stats decode,
auto-catch-up decisioning) in one flat function.
Proposed: Split into pollPlaybackState/rampBufferRate/refreshStats/maybeAutoCatchUp helpers, keep
tickController as orchestrator.
Risk: Low-Medium — touches the buffer/catch-up hot path; verify ordering (corruptDelta must compute
before the recordingShowId early-return per its own comment). · Effort: M
```

### Duplication (Swift)

```
File: Sources/hdhr_VCR/AppState.swift
Lines: 1990-2155 (6 confirmed sites in this slice; 9-10 total across the file — see Exec Summary #6)
Current: rebuildMenuEntries()+broadcastGuideChangeEvent(...) pair repeated verbatim; 4 of 6 sites
in the reviewed slice carry the literal comment "See addShow's identical call for why this
precedes the broadcast" — the duplication is self-acknowledged.
Proposed: pushShowUpdate(type:show:) helper.
Risk: Low · Effort: S
```

```
File: Sources/hdhr_VCR/AppState.swift
Lines: 2257-2258, 2397-2398
Current: Episode-tag regex #"[_ ](S\d+(?:E\d+)?)"# copy-pasted identically in
organizeSeriesRecordings and recordedEpisodeTags; the latter's doc comment already admits the
coupling ("Reuses the same filename tag regex... so parsing stays consistent").
Proposed: episodeTag(inFilename:) -> String? helper.
Risk: Low · Effort: S
```

```
File: Sources/hdhr_VCR/AppState.swift
Lines: 2713-2723, 2751-2761 (watchInApp/watchInVLC)
Current: Identical fetch-status + tunersFull check + alert block, including a verbatim-copied
explanatory comment about the fresh hw poll.
Proposed: tunerAvailable(_:context:) async -> Bool shared helper.
Risk: Low · Effort: S
```

```
File: Sources/hdhr_VCR/GuideStore.swift
Lines: 69-197 (load vs loadXMLTV)
Current: ~90% identical skeleton (guard/GET/timing/status/empty checks/index/timestamps/catch);
only the Data→[GuideChannel] decode step differs.
Proposed: performLoad(id:url:decode:) shared skeleton.
Risk: Low — preserve the single-call/no-pagination/GuideHours-clamp behavior at the call sites
building the URL. · Effort: M
```

```
File: Sources/hdhr_VCR/DiscordNotifier.swift
Lines: 48-170 (sendDiscordEmbed / sendDiscordEmbedCapturing / editDiscordEmbed)
Current: Each independently builds a URLRequest, serializes the embed, calls URLSession, checks
the response, and logs an OK/FAILED pair — only method/URL-shape/success-handling differ.
Proposed: Shared postOrPatch(req:actionLabel:title:) helper; preserve exact SEND/CREATE/EDIT log
prefixes since discordLog's format is documented as independently reviewable.
Risk: Low · Effort: S-M
```

```
File: Sources/hdhr_VCR/WebServer.swift
Lines: 3373-3445 (isLocalAddress)
Current: 3 near-duplicate ifaddrs-traversal loops; the mapped-IPv6 and plain-IPv4 branches are
functionally identical (both walk AF_INET, compare s_addr & mask) — mapped-IPv6 just normalizes to
a plain IPv4 string first.
Proposed: Normalize mapped-IPv6 up front, route through the same AF_INET branch as plain IPv4,
eliminating one of the three loops. Note: this function underlies the LAN-subnet access-control
check for all mutating endpoints — behavior-preserving only, no logic change.
Risk: Low · Effort: S
```

```
File: Sources/hdhr_VCR/WebServer.swift
Lines: 611-716 (4 GET handlers) — see Exec Summary #7
```

```
File: Sources/hdhr_VCR/WebServer.swift
Lines: 748-755, 789-793, 836-842, 900-907 (4 POST handlers)
Current: Each opens with the identical JSON-body-parse guard boilerplate.
Proposed: parseJSONBody(_:) -> [String: Any]? helper.
Risk: Low · Effort: S
```

```
File: Sources/hdhr_VCR/WebServer.swift
Lines: 29-36, 157-167, 178-180, 248-266, 287-289, 446-455
Current: Two independent NSLock+Array pairs (sseLock/sseConns, connLock/liveConns) get the same
lock→mutate→unlock treatment repeated at ~8 call sites.
Proposed: Small generic LockedArray<T> type, replace both pairs.
Risk: Low — same locking semantics · Effort: S
```

```
File: Sources/hdhr_VCR/HDHRManager.swift + WebServer.swift — see Exec Summary #5 (CRC-32)
```

```
File: Sources/hdhr_VCR/Views/EditShowView.swift + SettingsView.swift — see Exec Summary #9
(unsaved-changes NSAlert unification)
```

```
File: Sources/hdhr_VCR/Views/AddShowView.swift
Lines: 272-288, 341-363, 365-391
Current: 3 functions independently populate the same ~10 show.* fields from 3 differently-shaped
entry inputs, each ending with an identical 3-line show_time/airDays computation.
Proposed: Extract the shared tail (applyAirTime(_:)); optionally also the common field-set.
Risk: Low · Effort: S
```

```
File: Sources/hdhr_VCR/Views/ShowFormSection.swift:15, EditShowView.swift:27, AddShowView.swift:
287,359,389,420, Models.swift:575,634, plus AppState.swift:982,993, WebServer.swift:845
Current: The 7-day weekday-name array literal is hand-typed at 10+ sites across the codebase
(confirmed via grep). CAUTION found during spot-check: AppState.swift:982's copy is
["Monday",...,"Sunday"] (Monday-first) while every other copy is Sunday-first. This is not
currently a bug — that specific array is assigned wholesale to show_air_date for the "airs every
day" case, where order doesn't affect the *[weekday-1] index-lookup sites (a different set of
arrays), so unordered use is safe — but if show_air_date's order is ever surfaced in a UI listing
"which days," consolidating to one Sunday-first constant would silently change that display order
for existing "airs every day" shows written with the Monday-first array. Verify before unifying.
Proposed: One Show.weekdayNames constant (Models.swift, Sunday-first, matching the *[weekday-1]
sites), all use sites updated — after confirming the AppState.swift:982 caveat above doesn't matter
for the "every day" display case.
Risk: Low, contingent on the display-order check above · Effort: S
```

```
File: Sources/hdhr_VCR/ChannelSignalStore.swift
Lines: 110-121, 123-140 (flush / scheduleSave)
Current: Both contain an identical "JSONEncoder + encode + atomic write" block; only the debounce
timing differs.
Proposed: Shared persist() helper.
Risk: Low · Effort: S
```

```
File: Sources/hdhr_VCR/Views/WatchNowView.swift
Lines: 92-112, 136-149
Current: prefetchPosters()/prefetchPostersForDate() run near-identical withTaskGroup fetch blocks,
differing only in URL-list derivation.
Proposed: Shared fetchMissingPosters(urls:) helper.
Risk: Low · Effort: S
```

### Duplication (JS / CSS, inside WebServer.swift)

```
Lines: 1755-1850 — see Exec Summary #3 (genre CSS tables)
Lines: 1705-1730 — --gg-* custom properties duplicated a second time as .gg-*{background:...}
  rules with the same literal values instead of var(--gg-*) references. Low/S.
Lines: 1279-1288 (Swift) + 2091-2092 (JS) — ggSkip/ggAlias/ggKnown genre tables hand-mirrored in
  both languages; a genre added to one and not the other silently desyncs JS tag-pill coloring
  from Swift row/dim classing. Proposed: (a) hoist to static constants (currently rebuilt per
  guide entry — Low/S), (b) serialize the Swift table into the JS literal like tunerJS already
  does, single source of truth (Medium/M — needs jsEscapeForScript treatment).
Lines: 2088-2089 vs 1705-1706 — _gcDk/_gcLk JS palette (8-of-24 genres) has already drifted a few
  HSL percentage points from the canonical --gg-* CSS values (verified: drama is hsl(216,48%,35%)
  in JS vs hsl(216,48%,36%) in CSS) — a second, incomplete, silently-diverging color source.
  Proposed: read via getComputedStyle(...).getPropertyValue('--gg-'+g) instead. Low-Medium (visible
  color shift for the 8 genres currently covered, extends coverage to all 24 for free) / S.
Lines: 2100, 2379 — toggleBonusStar()/toggleRmBonusStar() structurally identical, differ only by
  id prefix. Proposed: parameterize. Low/S.
Lines: 2278-2293, 2733-2739 — day-button construction duplicated between record modal and edit
  modal, same pattern this file already extracted renderTypeRow for elsewhere. Proposed:
  buildDayButtons(containerId, selectedPredicate, onToggle) with differing selection logic passed
  in. Medium/M — the two modals' selection semantics genuinely differ (exclusive vs multi-toggle),
  must preserve both.
```

### Dead code

```
- VLCBridge.swift:609 volume() — confirmed zero call sites. Low/S.
- WebServer.swift:1667 .g-logo-ph CSS rule — confirmed zero producers. Low/S.
- WebServer.swift: inline color/background/border attributes on several static elements (#t-pop-c,
  #t-pop-hdr, #sum-*, #em-rec-warn, #em-dev-warn, etc.) are unconditionally shadowed by an
  !important CSS rule a few hundred lines earlier — inert on every load. Verified each cited pair;
  note #rm-tuner/#rm-sig-warn do NOT have a matching override and must be left alone. Low/S,
  recommend a visual smoke test after removal.
- hdhr_VCRApp.swift:83-84 — a comment claims the code "silently opens+closes the menu" to warm
  SwiftUI's view graph, but no such open/close call exists anywhere in the file or in
  AppState.isReady (grepped). Either stale from a past refactor or misplaced. Comment-only fix,
  but a stale rationale comment will mislead future edits to menu-open behavior. Low/S.
```

### Manual reimplementation / efficiency

```
File: Sources/hdhr_VCR/WebServer.swift
Lines: 1279-1288 vs 2091-2092 — see JS/CSS section above (ggSkip/ggAlias/ggKnown hoisting)

File: Sources/hdhr_VCR/Views/SettingsView.swift
Lines: 619, 626 — URL(string: urlStr)! force-unwraps a URL built from interpolated (non-literal)
ip/port values. Low real risk (both already sanitized elsewhere) but it's the one non-literal
force-unwrap in this slice. Proposed: if let. Low/S.
```

### Misplaced types (secondary type embedded in the wrong file)

```
- AppState.swift:3245-3261 NotificationActionDelegate → own file. Low/S.
- AppState.swift:3234-3243 (declared) / :349 (used) MenuJITPlaceholder → move near its call site
  or its own file, alongside the above. Low/S, low priority.
- VLCPlayerView.swift:833-984 VLCPlayerWindowManager + WindowCloseObserver + NSScreen extension →
  own file (Views/VLCPlayerWindowManager.swift). Keep VLCVideoSurface with VLCPlayerView (private,
  used only there). Low/S.
- SettingsView.swift:1044-1101 WindowCloseInterceptor → own file, since EditShowView.swift also
  depends on it (a reader looking in EditShowView has no reason to check SettingsView.swift). Bundle
  with the unsaved-changes-alert dedup (Exec Summary #9) since both land in the same new file. Low/S.
```

### Unbounded state / cache growth

```
File: Sources/hdhr_VCR/Views/WatchNowView.swift
Lines: 11, 80-149
Current: posterCache: [String: NSImage] is only ever merged into, never pruned, across a 24/7
session; also duplicates ChannelIconCache.shared's own already-bounded mem cache — double-holding
the same decoded images in memory.
Proposed: Either cap/prune posterCache, or drop it and read from ChannelIconCache.shared directly
(already a single actor hop).
Risk: Low — display-only, no correctness dependency. · Effort: S
```

```
File: Sources/hdhr_VCR/DiscordNotifier.swift
Lines: 8-28 (discordLog)
Current: Opens the discord log once and appends forever, 24/7, no rotation — unlike
RecordingManager.writeCurlLogHeader, which already rotates its own verbose log at 5MB for exactly
this reason (same review batch, same fix pattern available to copy).
Proposed: Apply the same rotate-at-N-MB check.
Risk: Low — low-volume traffic, slow growth, but genuinely unbounded over a long-running install.
Effort: S
```

```
File: Sources/hdhr_VCR/ChannelIconCache.swift
Lines: 74-77
Current: if mem.count > 600 { mem.removeAll() } drops the entire cache at the cap rather than
evicting oldest entries — a blunt instrument, rarely triggered given realistic channel counts.
Proposed: Noted, not recommended as a priority — low-impact given typical lineup sizes. If ever
revisited, simple FIFO/LRU trim avoids the re-fetch burst.
Risk: Low · Effort: S (if addressed)
```

### Considered, not recommended

```
File: Sources/hdhr_VCR/AppState.swift
The AppState-Lifecycle group evaluated consolidating the dozen-plus show_id-keyed tracking
dictionaries (showRetryAfter, conflictNotifiedEpochs, discordCardTasks, etc.) into one
struct-of-fields dictionary, since deleteShow's per-table cleanup is repetitive. Explicitly NOT
recommended: the tables have different value types with read/write sites scattered across ~1300
lines, and — more importantly — it works against the CLAUDE.md invariant that a show_id table's
clear-on-delete be individually auditable at a glance in deleteShow. The one low-risk piece is
relocating discordCardTasks's declaration (line 2598) up next to its ~10 siblings (lines 37-224)
purely for discoverability. Everything else should stay as-is.
```

```
File: Sources/hdhr_VCR/Models.swift
Show.init(from:) and AppConfig.init(from:) repeat the (try? c.decode(...)) ?? default pattern
dozens of times. Real repetition, but any simplification must preserve the exact fallback-default
per field, and Swift has no reflection-based way to do this generically without a macro (nontrivial
tooling lift, out of scope for a same-session refactor). Flagging so it isn't re-discovered as
"missed" in a future pass.
```

---

## Structural recommendations (bigger than a quick win — plan separately)

### `WebServer.swift`'s `buildHTML()` (~1700 lines, lines 1389-3150)

Honest assessment from the reviewing group, which I agree with: the size is largely defensible
as one `return """ ... """` heredoc assembling a self-contained HTML document — splitting purely
for line-count would trade readability for indirection in several places. **Not recommended as a
standalone refactor.**

If ever tackled, the natural seams (already implicit in the file's own section structure):
- `buildStyleBlock() -> String` — the ~460-line `<style>` block (1496-1953), genuinely static, almost no dynamic interpolation.
- `buildBodySkeleton(...)` — the static modal/toolbar markup (1955-2064), a handful of interpolations.
- `buildClientScript(...) -> String` — the `<script>` block (2067-3146), ~1100 lines of essentially static JS with only ~10 interpolation points. **This is the best split candidate** — pulling it out would make future JS edits (which CLAUDE.md already flags as error-prone re: regex escaping) diffable in isolation, and doesn't require touching the HTML/CSS structure at all.

Treat as its own planning session and commit, with a `node --check`-based JS-extraction verification pass per the file's existing convention.

### `AppState.swift` as a whole (~3260 lines, ~104 methods)

Classic god-object `@MainActor ObservableObject`. The per-function extractions above (idleLoop,
startRecording, fetchDeviceStatusUncached) chip at this without a file-level restructure. A genuine
type-level split (e.g. separating the recording engine from show-lifecycle/Discord/watch-relay
concerns into extension files or delegate types) is a bigger, higher-risk undertaking that deserves
its own design discussion — not attempted here.

---

## Even-sweep appendix — all 26 files

| File | LOC | Group | Findings | Verdict |
|---|---|---|---|---|
| WebServer.swift | 3456 | 1+2 | 17 | Largest finding count; mix of quick wins (CSS/JSON dedup, dead code) and one high-care structural item (guide-grid loop) |
| AppState.swift | 3261 | 3+4 | 16 | God-object; strong extraction candidates along existing comment boundaries; one rejected proposal (genre dedup) |
| Views/SettingsView.swift | 1101 | 6 | 4 | Line estimates in the review brief were inflated — applyAndSave/groupToggle/runBrew are all appropriately sized, not findings; real findings are the misplaced WindowCloseInterceptor type + minor items |
| Views/VLCPlayerView.swift | 984 | 5 | 3 | One brief line-estimate was wrong (showId is 4 lines, not ~530); real large unit is the toolbar property |
| VLCBridge.swift | 711 | 5 | 2 | tickController decomposition, dead volume() |
| Models.swift | 651 | 6 | 0 direct (contributes to 2 cross-file findings) | No dead code (spot-checked); Codable boilerplate noted-not-actionable |
| Views/AddShowView.swift | 553 | 6 | 2 | 3-function field-population dedup, weekday array |
| Views/MenuContent.swift | 522 | 6 | 1 | deviceGroupedSection extraction |
| Views/WatchNowView.swift | 433 | 5 | 2 | posterCache growth, prefetch duplication |
| GuideStore.swift | 418 | 7 | 1 | load/loadXMLTV dedup |
| HDHRManager.swift | 347 | 7 | 2 | CRC-32 duplication (cross-file), udpDiscoverSync TLV extraction |
| RecordingManager.swift | 297 | 7 | 0 | Clean — log rotation here is the good example other files should match |
| Views/EditShowView.swift | 261 | 6 | 1 (shared w/ SettingsView) | Unsaved-changes alert dedup |
| XmltvParser.swift | 211 | 7 | 0 | Proportional to XMLTV's complexity, no dead branches |
| Views/GuideViewHelpers.swift | 209 | 5 | 0 | Appropriately scoped shared-utilities file |
| DiscordNotifier.swift | 170 | 7 | 2 | 3-function send/edit dedup, unbounded log growth |
| Views/ShowFormSection.swift | 161 | 6 | 0 direct (contributes to weekday-array finding) | Correctly shared by Add/Edit already |
| ChannelSignalStore.swift | 141 | 5 | 1 | flush/scheduleSave dedup |
| hdhr_VCRApp.swift | 140 | 7 | 1 | Stale comment |
| Views/StarburstBadge.swift | 120 | 5 | 0 | Single-purpose, tightly coupled to its animation, no findings |
| ConfigManager.swift | 104 | 7 | 0 | Three-tier fallback logic proportional to what it solves |
| Views/FloatingGuideView.swift | 100 | 5 | 0 | Appropriately sized |
| ChannelIconCache.swift | 80 | 5 | 1 (minor, not prioritized) | Blunt cache-eviction pattern, low-impact given realistic sizes |
| CompatibilityHelpers.swift | 58 | 7 | 0 | Different-purpose ifaddrs walk from HDHRManager's; forcing a shared iterator would be a net complexity increase |
| AppIcon.swift | 39 | 7 | 0 | One-time bundle load, proportionate |
| Version.swift | 1 | 7 | 0 | 1-line constant |

All 26 files accounted for. `src/HDHomeRunKit` excluded per scope decision.

---

# Workstream 2 — CLAUDE.md trim (redline proposal)

`.claude/CONVENTIONS.md`'s existing split from CLAUDE.md is correct and untouched — the opportunity
here is prose density within CLAUDE.md itself. Build & Deploy, the Architecture table, Documentation
section, and the Tools/Agents tables are already tight and are left unchanged. The lever is the
Invariants & Gotchas section.

**Result: modest — 5 targeted cuts, roughly a 10% reduction of that section.** This is not a
dramatic rewrite; the doc is already reasonably dense for its content, and most invariant paragraphs
mix rule + rationale in a way that's genuinely load-bearing (the rationale exists specifically to
stop a past bug from recurring) and shouldn't be cut just to hit a bigger number.

### 1. Remove the "Issue tracking" invariant entirely — full duplication

**Current** (CLAUDE.md, end of Invariants & Gotchas):
> **Issue tracking** — bugs found during work → `ISSUES.md` (note commit hash on resolve). Deferred features → `TODO.md`.

**Finding**: this is a verbatim-in-substance duplicate of `.claude/CONVENTIONS.md`'s existing "Issue Tracking" section:
> Unrelated bugs found during work → `ISSUES.md` at repo root. Note commit hash on resolution.

CLAUDE.md already points to CONVENTIONS.md at the top of the file for exactly this category of rule ("Conventions, commits, deploy rules"). Nothing is lost by removing it from CLAUDE.md — the rule still exists, in the file that already owns this topic.

**Proposed**: delete the "Issue tracking" invariant line from CLAUDE.md.
**Reason**: pure duplication, zero information loss.

### 2. Trim mechanical restatement in "Web guide managed markers are tuner-scoped"

**Current** (trailing clause):
> ...*instead of* the blue `.g-st-sched` one — computed in `buildGuideGridHTML` via `AppState.recordedEpisodeTags(...)`, one scan per managed series per build.

**Proposed**: end the sentence at "...the blue `.g-st-sched` one." Drop the trailing clause.
**Reason**: the function name + per-build scan detail is implementation mechanism recoverable by reading `buildGuideGridHTML`/`recordedEpisodeTags`, not part of the rule itself (the rule is: skip-flag replaces sched-flag when the episode is already on disk).

### 3. Trim mechanical restatement in "Web guide is per-tuner"

**Current** (trailing sentence):
> Dropdowns update via `refreshGuide` (swaps each `.tdrop` body) and the recording-event SSE (`tdrop`/`tdropDev` → swaps `#tdrop-{device}`).

**Proposed**: remove this sentence.
**Reason**: this is mechanism (specific event names, DOM selectors) that's already covered in substance by the general "Web UI push" invariant a few lines below (state changes must broadcast). Keeping both is redundant; the general rule is the one a contributor actually needs to follow when adding new state.

### 4. Trim a parenthetical in "Web UI push"

**Current**:
> ...for recording start/stop use `broadcastRecordingEvent(...)` (embeds pre-rendered HTML fragments)...

**Proposed**: drop the parenthetical.
**Reason**: implementation detail recoverable from the function name; the rule (which function to call, for which event type) is unaffected.

### 5. Trim a cross-reference parenthetical in "Discord card sends"

**Current**:
> `fireDiscordCard` chains per-show sends behind each other via `discordCardTasks` (mirrors `ensureLineupLoaded`'s `loadingLineupTasks` idiom) so two lifecycle events...

**Proposed**: drop the "(mirrors...)" parenthetical.
**Reason**: a nice-to-know cross-reference, not part of the rule or its rationale (the rationale — race prevention — is fully stated in the rest of the sentence and is kept).

### Rule-preservation checklist

All content changes are cuts of mechanism/cross-reference clauses, or removal of a fully-duplicated
rule. No MUST/MUST-NOT rule, rationale clause, or code citation central to a rule is dropped.

| # | Invariant | Status |
|---|---|---|
| 1 | Tuner occupancy | Unchanged |
| 2 | Web guide rows never hidden | Unchanged |
| 3 | Managed markers tuner-scoped | Condensed — meaning preserved (cut #2 above) |
| 4 | Offline devices shown | Unchanged |
| 5 | Web guide is per-tuner | Condensed — meaning preserved (cut #3 above) |
| 6 | Now-line origin | Unchanged |
| 7 | New show field (4 steps) | Unchanged |
| 8 | show_id-keyed tracking table | Unchanged |
| 9 | Bonus Time | Unchanged |
| 10 | Web UI push | Condensed — meaning preserved (cut #4 above) |
| 11 | Discord card sends | Condensed — meaning preserved (cut #5 above) |
| 12 | WebServer.swift ~half JS / no-auth | Unchanged |
| 13 | Signal keys | Unchanged |
| 14 | Guide API limits | Unchanged |
| 15 | Idle-loop show-array safety | Unchanged |
| 16 | Menu rebuild churn | Unchanged |
| 17 | Testing recordings | Unchanged |
| 18 | Issue tracking | **Removed** — full duplicate of `.claude/CONVENTIONS.md`'s Issue Tracking section |

Net effect: 18 invariants → 17, ~5 sentence-level trims elsewhere, no rule content lost.
