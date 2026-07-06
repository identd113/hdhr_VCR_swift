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
