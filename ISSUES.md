# Issue Log

Historical record of bugs encountered during development. Used as a "don't repeat this" reference during code reviews. Unrelated bugs found during work go here rather than fixed inline — note the resolving commit when done. Deferred features go in `TODO.md`.

**This file holds only what's still open, or accepted as-is (won't-fix / by-design / too marginal to schedule).** Once something is actually fixed, its entry moves to [`issues_resolved.md`](issues_resolved.md) rather than staying here — that file is the "how was X fixed" archive, this one is "what still needs attention." Findings about *technique* (things tried repeatedly and abandoned, independent of any specific still-open bug) live in [`FAILED_APPROACHES.md`](FAILED_APPROACHES.md) instead of either issue file.

**Format**: each issue has a status (`OPEN` or `ACCEPTED`), a brief description, root cause, and a fix note if one's been scoped but not done.

---

## Accepted — flagged, not scheduled (marginal / by-design)

Re-verified against current code 2026-08-10 — all four still accurate.

- **`RecordingManager.swift:161`** — orphaned-recording liveness uses `kill(pid,0)`, which tests PID existence not identity; PID reuse could report a dead recording as running. Astronomically low probability (slow PID cycling); accept.
- **`Models.swift`** (`GuideEntry`) — `==`/`hash`/`id` are StartTime-only, unsafe for cross-channel `Set`/`ForEach(id:)`. Already documented (`WatchNowView.swift`) and every call site deliberately uses `\.GuideNumber` — latent trap, no live bug.
- **`WebServer.swift`** — `stateCallback`/`activePort`/`listener` are unsynchronized under `@unchecked Sendable` (benign word writes); a dropped SSE conn lingers in `sseConns` up to 25 s until the keepalive prunes it (self-heals). Neither observed to misbehave.
- **`VLCBridge.swift`** (~line 55-60 at time of writing) — a CoreAudio device-change callback already in flight during `stopDeviceChangeMonitoring()` teardown could read a freed context. Very edge; related listener-lifecycle issue (double-registration) is fixed — see `issues_resolved.md` — this is a narrower residual case that wasn't.

---

# Code audit — 2026-08-08

8-angle `/code-review` sweep of the committed diff plus that session's uncommitted working-tree changes (vertical time-axis guide mode, log rotation, `ChannelIconCache` disk cap, markdown changelog renderer, deploy script fixes, `FloatingGuideView` removal, web guide now-button/channel-column fixes, new `WindowNavigationTests.swift`). Findings tied directly to that session's own uncommitted work were fixed immediately. The four below predate that session (from earlier, already-committed work) and are logged rather than fixed inline, per this file's own convention.

Re-verified against current code 2026-08-10 — all four still open and accurate, none stale.

## OPEN — Verbose curl `-v` logging can silently exceed `RotatingLogFile`'s cap, and a rotation mid-recording can race an open curl file descriptor

**File:** `RecordingManager.swift` (curl's `-v` stderr piped via `posix_spawn`'s `stderrPath` directly to `hdhrVCRplus.log`); `Models.swift` (`RotatingLogFile`)

**Root cause**: `RotatingLogFile.bytesWritten` only increments inside `RotatingLogFile.write()`, called by `glog()`. When Settings → Advanced → Verbose curl logging is on, curl's own `-v` stderr stream is piped straight into the same log file via its process spawn config, invisible to that byte counter — so the documented 20MB cap isn't actually enforced while verbose logging is active for a long recording. Separately, if a rotation does fire (`rotate()` renames the file to `.log.1` and may delete a prior `.log.1`) while curl's fd is still open and writing to the pre-rotation path, curl keeps writing into the now-renamed file until it closes; a *second* rotation before that close could unlink that renamed file out from under curl, losing whatever it wrote in the interim.

**Fix**: Either route curl's `-v` output through `glog()`/`RotatingLogFile.write()` instead of a direct file redirect (so it's counted and rotation-safe), or give verbose curl logging its own separately-capped file the way Discord sends already do.

## OPEN — `ChannelIconCache.pruneDiskCacheIfNeeded()` runs a full directory scan + per-file `stat` after every single disk write

**File:** `ChannelIconCache.swift`

**Root cause**: The actor-isolated prune runs unconditionally after every icon write, listing the whole disk cache directory and calling `resourceValues` (a `stat`) on each file. `AppState.prefetchChannelIcons` fans out one concurrent `Task` per missing icon via `withTaskGroup` on cold start / lineup refresh — since the cache is an actor, every one of those (potentially hundreds, up to the ~2000-file cap) completions serializes through this full O(n) scan, turning a bulk prefetch into effectively O(n²) directory I/O and stalling unrelated cache-hit reads on the same actor during startup.

**Fix**: Only run the prune periodically (e.g. every N writes, or time-gated) rather than on every single write, or debounce it to run once after a burst of writes settles.

## OPEN — `prebuildPageHTML` now does two full-page HTML builds + two sequential gzip passes on every guide-changing event

**File:** `WebServer.swift` (`prebuildPageHTML`, `@MainActor`)

**Root cause**: Since vertical time-axis mode added a second cached page (`cachedVerticalHTML`/`cachedVerticalHTMLGzip` alongside `cachedHTML`/`cachedHTMLGzip`), every rebuild — which per this file's own comments fires on every add/delete/pause/resume/edit/favorite-toggle and recording start/stop — now runs `buildHTML` and a ~30-60ms gzip pass twice, sequentially, on `@MainActor`, roughly doubling how long menu/UI responsiveness blocks on each such state change versus before vertical mode existed.

**Fix**: Run the two gzip passes concurrently (e.g. via a `TaskGroup` or `DispatchQueue.concurrentPerform`) rather than sequentially, since they're independent of each other once the shared grid HTML is built.

## OPEN — `RotatingLogFile.write()` advances `bytesWritten` even when the underlying write silently no-ops

**File:** `Models.swift` (`RotatingLogFile`)

**Root cause**: If `open()` fails to obtain a `FileHandle` (transient permissions issue, full disk, Logs directory briefly unavailable), `handle?.write(data)` is a silent no-op via optional chaining, but `bytesWritten += UInt64(data.count)` runs unconditionally regardless. The counter can then cross `rotateThreshold` and trigger `rotate()` based on phantom growth that never actually reached disk, potentially renaming/deleting a file that's smaller than the counter believes (or doesn't exist).

**Fix**: Only advance `bytesWritten` when `handle` is non-nil (i.e. the write actually happened).
