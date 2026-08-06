# Code Observations — append-only; bugs go to ISSUES.md, deferred work to TODO.md, completed fixes to CHANGELOG.md

## 2026-07-06 — Full-codebase craftsmanship review (verified-safe, no action needed)

- `WebServer.swift:9` `final class WebServer: @unchecked Sendable` — verified intentional and safe.
  `cachedHTML`/`cachedHTMLGzip` are only ever written (`prebuildPageHTML`/`invalidateHTMLCache`) and
  read (`routeOnMain` line ~561) from `@MainActor` contexts; `sseConns`/`liveConns` (the only
  members touched from the non-MainActor `queue`) are protected by `sseLock`/`connLock`. No data
  race found. Worth re-checking if a future edit adds a new stored property that's touched from
  both `queue` and `@MainActor` without one of these two protections.
- `AppState.swift:2273-2280` `refreshTunerOccupancy()`'s flat `Task.sleep(1.5s)` before polling
  `status.json` is a genuine wait-and-hope, but it's waiting on external HDHomeRun hardware to
  register a tuner-state change — there's no local event to observe, so this is about as good as it
  gets without a device-side push API. Documented inline; not flagging as a fixable hack, just
  noting the justification for the next reviewer.
- Signal-bucket / channel-icon caches (`ChannelIconCache.mem`, `ChannelSignalStore`) both have
  explicit bounds (`mem.count > 600` reset; 50-sample-per-channel cap) — checked, not unbounded.

## 2026-07-06 — tunersFull()/activeTunerCount bootstrap staleness (not fixed, just noting)

Both now depend on `deviceTunerOccupancy` being warm — a machine that just launched and hasn't
completed its first `fetchDeviceStatus` poll yet has `hw == 0` and briefly falls back to
local-only (`recordingShows`+VLC) counting, same as pre-fix behavior. The app already primes
`deviceTunerOccupancy` immediately after device discovery at launch (`AppState.swift` ~226-228),
so this window is small, but it isn't literally zero. Relevant if multi-machine tuner-count
accuracy regresses right after app launch specifically.

## 2026-07-17 — Range 9ec4aa9..HEAD craftsmanship review (Watch-Now relay/scrub, VLC native-res, keep-alive, Sparkle removal)

- `VLCBridge.swift:2054-2055` `nonisolated(unsafe) let inst/mp = newFn(0,nil)` — verified safe:
  freshly-created libvlc handles with no other owner, handed to `MainActor.run` in the same
  detached task. OpaquePointer isn't Sendable; this is the correct minimal escape hatch. Justified
  inline. Don't re-flag.
- `WebServer.swift` recording relay (`pumpGrowingFile`, ~355) polls the growing MPEG-TS file every
  0.5s once caught up to the live write pointer. Looks like time-based polling but there is no
  filesystem-append push event that's cheaper/simpler here (DispatchSource vnode watches on a file
  curl keeps `write()`-ing are flaky), and it mirrors how the real tuner stream drips. Accepted;
  the loop is cancellation-aware (checks `conn.state` each recursion) and closes the FileHandle on
  every exit path. Not a leak.
- `AppState.swift:2506` / `VLCBridge.beginRecordingSeek` — the `DispatchQueue.main.async` deferral
  of `beginRecordingSeek` is a genuine SwiftUI render-timing workaround (setting `recordingShowId`
  synchronously inside the same window-open transaction never re-renders the toolbar). Guarded
  against staleness by re-checking `currentURL` still encodes this show id. Verified intentional and
  defended in comments on both sides; not a hack-with-a-timer.
- `Views/SettingsView.swift:519` hard-codes `/System/Applications/Utilities/Console.app` and launches
  via `NSWorkspace.openApplication` (LaunchServices, not `Process()` — the direct-exec path SIGKILLs
  Console on a launch-constraint violation, fixed in 7c23a65). System path, not a home-dir path;
  hardened-runtime/Gatekeeper safe. Sandbox-later note: launching another app is an LSOpen the App
  Store sandbox will block, but this is a diagnostics-only button — degrade gracefully when it fails.
  The Console predicate uses `Bundle.main.bundleIdentifier` while `glog`'s `Logger` subsystem is the
  string literal `"com.hdhr.vcrplus"` (`Models.swift:10`); they currently match (Info.plist), but a
  bundle-id change would silently empty the Console filter. Minor coupling, noted not flagged.
- `VLCBridge.swift:516-517` `videoPixelSize` republished only on change (`if newPixelSize != …`),
  computed once per 3s stats tick — not per render. Good; no churn.

## 2026-07-28 — cb327a1 review (native/web add-flow parity + Show.seriesTitle/localFallbackDir helpers)

- Verified `Show.localFallbackDir`'s self-heal repair condition (`decodedTempDir == show_dir &&
  show_dir != Show.localFallbackDir`) has no legitimate false-positive case: every current write
  path (AddShowView.swift:405, EditShowView.swift:199, AppState.swift:930) sets
  `show_temp_dir = Show.localFallbackDir` unconditionally, never to a copy of `show_dir`, and the
  one case where a user deliberately sets `show_dir` to the fallback path itself is explicitly
  excluded from the repair. Confirmed clean, no misfire risk found.
- `ManagedGuideMatcher` (Models.swift ~562-643) changed from `Set<String>` membership tables to
  `[String: Show]` lookup tables with a new `owner(for:)` method, consumed by the skip-already-
  recorded corner-flag logic (`WebServer.swift:1234`) — confirmed this replaces what would
  otherwise be a second, separately-maintained series→Show lookup, not redundant/dead. `isManaged`
  is now a one-line wrapper (`owner(for:) != nil`) — no remaining direct Set-membership callers.

## 2026-07-31 — 0fc566b review (VCR-glyph guide markers, conflict-simulation rewrite)

- `AppState.swift:894-916` conflict-simulation's `ordered.contains { … }` inner scan (populating
  `conflictBeatenByFavorite`) is O(N) per loser, O(N²) worst case per device — technically
  reintroduces the quadratic shape the rewrite's headline goal was to eliminate. Not worth fixing:
  it only runs for actual conflict losers (rare), bounded by shows-per-device (tens, not
  thousands), and the whole `rebuildMenuEntries()` call itself is already gated to run once per
  idle tick / guide load (not once per menu open, per its own comment) — nowhere near a hot path
  at this app's scale. Tracking slot *occupant* instead of just free-at `Date` (to make this O(1)
  lookup) would add real complexity for a savings that never matters here.

## 2026-08-01 — v1.3.0..HEAD pre-release quality gate (94 commits)

- `Views/ShowFormSection.swift:148-157` (`duplicateCheckKey` `.task(id:)`) debounces the
  already-recorded-episode check with `try? await Task.sleep(for: .milliseconds(350))` before
  calling `AppState.duplicateEpisodeTag(for:isSeries:baseDir:)`, whose comment explicitly
  acknowledges `recordedEpisodeTags` does synchronous `FileManager` calls (`contentsOfDirectory` +
  `attributesOfItem` per file, two directory levels) on the main actor and "can block the whole
  app for real wall-clock time if the recording folder is on a slow-to-wake external drive." The
  debounce reduces *frequency* (once per typing pause instead of per keystroke) but doesn't remove
  the main-actor blocking risk it names — a genuinely slow volume still stalls the Add/Edit dialog
  (and, since this is `@MainActor` `AppState`, the whole app) for that one scan. Real fix would hop
  the scan off `@MainActor` (e.g. `Task.detached` + `nonisolated` FileManager work) and publish the
  result back. Low real-world severity (feature is opt-in via `Skip_recorded_episodes`, and local
  disks return near-instantly) but worth fixing before it's someone's bug report from a NAS-backed
  recording folder.
- `WebServer.broadcastGuideChangeEvent` (added this range) is now called from 9+ `AppState` show
  lifecycle sites (add/update/pause/resume/delete/favorite-toggle/duplicate-override-clear), each
  triggering a full `buildGuideGridHTML` + `buildDevBarHTML` + `prebuildPageHTML` (gzip) rebuild on
  the main actor — previously only the hourly guide refresh and recording start/stop paid this
  cost (`prebuildPageHTML`'s own comment cites ~30-60ms for the gzip pass alone on the ~1.5MB page).
  When `Series_subfolder_enabled && Skip_recorded_episodes` are both on, each of those rebuilds also
  re-scans every managed series' recording folder via `recordedEpisodeTags` (one `FileManager`
  directory walk per series, per CLAUDE.md's own documented "one scan per managed series per
  build" invariant) — so toggling a single favorite now costs one full-page rebuild + N directory
  scans where before it was a bare `{type,device,guideNumber}` SSE push. Deliberate tradeoff for
  guide-freshness on new tab loads (documented in the surrounding comments), and show mutations are
  low-frequency (human-paced, not per-render/per-tick), so likely fine — but if a large recording
  library with many managed series starts showing UI hitches on Add/Edit/Delete/favorite-toggle,
  this rebuild-fan-out is the first place to look.

## 2026-08-06 — vertical time-axis mode (uncommitted working-tree review)

- `Sources/hdhr_VCR/WebServer.swift:681-683` carries a stale comment ("`/vertical` is a plain
  alias for `/` — kept only because it was bookmarked/typed during vertical-mode development…
  the guide is identical either way") that describes an *earlier, since-replaced* design —
  `docs/WebServer.md`'s new "Vertical time-axis mode" section explicitly says that alias
  behavior was replaced specifically so `/` and `/vertical` would differ (`includeVerticalCSS`
  false vs true, `VT_ELIGIBLE` token baked differently). The very next case block (`"/vertical"`,
  line 693-696) and every other comment added in this diff correctly describe the real,
  divergent behavior. Left as a flag for the main agent to fix (delete/replace the stale
  comment) rather than edited directly, per this agent's write restrictions.
- `Resources/guide.js` — `updateNowLine()` (~899-916), `scrollToNow()` (~918-921), and the
  now-button visibility `check()` (~1083-1090) each hand-roll the same
  `ch/cw + (gi.scrollHeight/scrollWidth - ch/cw) * (nowPct()/100)` formula in parallel
  `isVT() ? … : …` branches (3x duplication of the vertical-axis formula, 3x of the horizontal
  one). Explicitly justified in `docs/WebServer.md` ("kept as small paired branches rather than
  a shared abstraction, matching this file's existing terse style") and not currently diverged
  (all three copies agree), so not flagged as a bug — but it's exactly the shape CLAUDE.md calls
  out as WebServer.swift's JS-string repeat-offender pattern. Worth collapsing into one
  `nowScrollTarget()` helper returning `{prop, value}` if a fourth call site ever needs the same
  math, or if any of the three drift out of sync.
- `Resources/guide.css` has two separate `@media(max-width:600px){...}` blocks (~line 88 and
  ~line 151) rather than one merged block — pre-existing summary-panel rules in the first,
  new toolbar/grid/modal compaction rules in the second. Not a functional bug (CSS allows
  repeated media queries; no property collisions between the two), just a missed tidy-up.
- `guide-vertical.css`/`guide.js`'s `isVT()`-branching code is unusually well-commented with
  on-device WebKit failure modes (sticky-left-in-flex-row unreliability, `content-visibility:auto`
  + sticky-descendant paint bug, `contain-intrinsic-size` two-group requirement) — read as
  hard-won findings, not speculative hedging. Treat these as load-bearing constraints, not
  cleanup targets, if touching vertical-mode CSS later.
