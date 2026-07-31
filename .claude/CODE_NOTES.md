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
