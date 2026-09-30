# RecordingManager.swift — Recording Process Management

Launches and tracks `curl` processes directly. Prevents sleep during recordings and Watch Now streams via tracked IOKit assertions.

---

## API

```swift
func start(showId:, title:, url:, outputPath:, durationSeconds:, transcode:, showEnd:, verbose:, networkInterface:, excludeFromBackup:)
func reattach(showId:, pid:, title:, endDate:)    // register an existing PID without launching (boot-resume)
func stop(showId:)
func readHDHRResource(showId:) -> String?          // reads X-HDHomeRun-Resource without deleting the file
func readAndClearHDHRError(showId:) -> String?     // reads X-HDHomeRun-Error, deletes the file
func readAndClearExitStatus(showId:) -> String?    // decodes curl's own exit code into a reason; see below
func preventSleep(id:, reason:, duration:)         // create or replace a tracked sleep assertion
func releaseAssertion(id:)                         // release one assertion by key
func releaseAllAssertions()                        // release all; called when status check confirms idle

// FEED local disk cache puller — see its own section below
func startFeedCachePull(sessionId:, url:, outputPath:, networkInterface:) throws
func stopFeedCachePull(sessionId:)
func isFeedCachePullRunning(sessionId:) -> Bool
func stopAllFeedCachePulls()
```

`networkInterface: String = ""` — when non-empty, appends `--interface <name>` to curl args, binding the stream to a specific NIC. Sourced from `AppConfig.Network_interface`; empty string means auto-select (curl default).

`excludeFromBackup: Bool = false` — added 2026-09-27, resolved by the caller (`AppState`) from `config.TimeMachine_exclude_mode == "perFile"`. When true, `start()` pre-creates an empty file at `outputPath` (right after creating its parent directory) and excludes it from Time Machine (`excludeFromTimeMachine(_:)`, `Models.swift`) before curl ever runs — `CSBackupSetItemExcluded` needs a real existing file to tag (live-verified 2026-09-27: `excludeByPath: true`, which Apple's header says tolerates a not-yet-existing path, actually fails with a permissions error on this app's signing/entitlements; `excludeByPath: false` works but requires the target to already exist, hence the pre-create). curl's `-o` then opens and truncates that same file rather than unlinking and recreating it, so the xattr survives. The `"perFolder"` mode is *not* handled here at all — `AppState` tags the containing directory itself, at its own directory-creation point, before ever calling `start()`.

---

## Process Model

Each recording produces **one ps line**: a direct `curl` process in its own POSIX session. No caffeinate wrapper.

- `durationSeconds` = **remaining time until `show_end`** (not total show length) — handles late starts and boot-resume correctly.
- Stream URL: `{channel_url}?duration={seconds}&transcode={profile}`
- curl `--connect-timeout 10` — aborts if the TCP connection to the tuner is not established within 10 seconds.
- curl `--max-time` = `durationSeconds + 120` (2-minute buffer against network stalls).
- PIDs stored in `pids: [String: Int32]`; liveness checked via `isRunning(showId:)` — see below.
- `POSIX_SPAWN_SETSID` — curl is spawned in its own POSIX session so it survives an app force-quit and can be reattached on restart.
- `POSIX_SPAWN_CLOEXEC_DEFAULT` (OR'd into the same `posix_spawnattr_setflags` call) — curl otherwise inherits every fd open at spawn time (the web server's listener socket, log handles, live SSE connections), and — being `SETSID`'d to survive a force-quit — can hold them open for the rest of a recording afterward. Only the three fds explicitly wired via `posix_spawn_file_actions_addopen` (stdin/stdout → `/dev/null`, stderr → the log path) stay open across the exec; every `RotatingLogFile`-backed log (`Models.swift`) also marks its own fd `FD_CLOEXEC` independently, closing the same gap for non-`posix_spawn` children too (`AppState`'s post-recording script hook, `reattachRecordings()`'s `ps` call). See `issues_resolved.md`'s "`RecordingManager.spawnDetached`'s curl ... inherited the app's entire open-fd table" entry.
- `--dump-header {NSTemporaryDirectory()}hdhrVCRplus-{showId}.headers` captures response headers for tuner resource and error detection (see below).

## Stop

`stop()` sends `SIGKILL` to the curl PID, removes the PID from `pids`, releases its sleep assertion, then reaps the zombie via `waitpid(pid, nil, 0)` on a background utility queue — **not** inline. `SIGKILL` is normally reaped in microseconds, but it can't be delivered while curl sits in an uninterruptible (D-state) syscall — e.g. blocked writing to a stalled network mount, a perfectly valid recording target. A blocking `waitpid` here would freeze the menu-bar UI (`RecordingManager` is `@MainActor`, and `stopAll()` loops this over every recording) until the mount recovered. Backgrounding it is safe because `pids[showId]` is already cleared before the async reap runs, and `isRunning()` guards on `pids` — so no other `waitpid` call can ever race this pid.

`SIGKILL` is used (not `SIGTERM`) because curl processes spawned with `POSIX_SPAWN_SETSID` may have `SIGTERM` masked from a previous bad app state, and `SIGKILL` cannot be ignored or blocked.

---

## FEED local disk cache puller

A second, deliberately separate `curl`-spawning subsystem — `startFeedCachePull(sessionId:url:outputPath:networkInterface:)`/`stopFeedCachePull(sessionId:)`/`isFeedCachePullRunning(sessionId:)`/`stopAllFeedCachePulls()` — added for the "FEED scrub via local disk cache" feature (`docs/VirtualTunerService.md`'s own section), which lets scrubbing work for FEED (watching another Mac's in-progress recording) the same way it already works for Watch Now. Not built on `start()`/`stop()`/`pids` above: that pair's signature is tailored to a real recording — `?duration=&transcode=` appended to the stream URL, `show_id`/`show_end` headers, `--max-time`/sleep-assertion duration sized off `durationSeconds` — none of which fits a FEED pull (an already-complete URL with no known end time, and no sleep-assertion need since the *source* Mac is the one actually recording, not this one).

- **Tracked in `feedCachePullPids: [String: Int32]`, a dictionary kept deliberately separate from `pids`** — unlike a real recording curl (`POSIX_SPAWN_SETSID`'d specifically so it survives a force-quit and gets reattached next launch, per "Process Model" above), a FEED cache puller must never get that treatment: once this process's `WebServer` is gone, nothing could ever serve its cache file again. `stopAllFeedCachePulls()` is called unconditionally — not gated on any "keep recordings running" flag, since that's about the user's own recordings and doesn't apply here — from both `AppState.teardownForExit` and the SIGTERM handler.
- **curl args**: `--connect-timeout 10 -H appname:hdhrVCRplus -H feed_cache:<sessionId> [--interface <if>] <url> -o <outputPath>` — no `--max-time` (runs until explicitly killed, or the remote closes the connection on its own), no `--dump-header` (nothing reads HDHomeRun error headers from a FEED pull; that's the *source* Mac's own recording's concern, not this Mac's). The `-H feed_cache:<sessionId>` marker exists purely so `AppState.sweepOrphanedFeedCachePullers()` can positively identify these processes at startup via `ps`, mirroring how `reattachRecordings()` (see "Checking Live Status" below) identifies real recording curls by their own `-H show_id:` marker.
- **`isFeedCachePullRunning(sessionId:)`** mirrors `isRunning(showId:)`'s exact `waitpid(WNOHANG)` reap pattern (no `ECHILD`/orphan-reattach fallback needed — a FEED cache puller is always this process's own direct child, never reattached across a restart).
- **No sleep assertion, no header file, no exit-status decoding** — none of those concepts apply: nothing here needs to keep the Mac awake beyond what `AppState.maintainVLCSleepAssertionIfNeeded()`'s existing `"vlc"`-keyed assertion already covers (see "Sleep Prevention" below, which already includes FEED playback), there's no HDHomeRun device on the other end of this connection to report an error, and a puller that dies is simply treated as "no data, retry/fail" by `AppState.startFeedCacheSession`'s own liveness poll rather than decoded into a specific reason.
- **Startup orphan sweep**: `AppState.sweepOrphanedFeedCachePullers()`, called once from `startup()` right after `reattachRecordings()` — unlike that function's own `ps` scan, which *reattaches* a still-valid recording, this one needs no liveness check at all and unconditionally kills every match, since a FEED cache puller is never reattached in the first place. See `docs/VirtualTunerService.md`'s own section for the full design.

---

## Sleep Prevention

Sleep assertions are tracked by key in `assertionIds: [String: IOPMAssertionID]`:

- **Per recording**: key = `showId`. Created in `start()` and `reattach()` for `durationSeconds + 300` seconds.
- **Live channel watch**: key = `"vlc"`. Created in `AppState.watchInApp()` when a guide entry's end time is known, sized to `max(60, entry.endDate.timeIntervalSinceNow) + 300`.
- **Watching an in-progress recording (Watch Now) or another instance's FEED relay**: same `"vlc"` key, but neither `watchRecordingInApp` nor `watchRemoteRelay` can compute a one-shot duration up front (a recording keeps growing; a remote relay's synthetic channel has no guide entry at all) — added 2026-09-13 after a laptop went to sleep mid-FEED-playback with no assertion held at all. Instead, `AppState.maintainVLCSleepAssertionIfNeeded()` runs on every `idleLoop()` tick (~5s) and re-arms a fresh 300s assertion whenever `VLCBridge.shared.recordingShowId` or `VLCPlayerWindowManager.shared.currentFeedRemoteURL` is non-nil — a no-op when neither is playing.

`preventSleep(id:reason:duration:)` releases any existing assertion for that key before creating a new one, preventing stale assertions from accumulating on repeated calls.

`releaseAssertion(id:)` releases and removes one entry. Called by `stop()` so the assertion drops the moment a show is deleted — not when its timer would have naturally expired.

`releaseAllAssertions()` releases every tracked assertion and clears the dict. Called by `AppState.releaseAssertionsIfIdle()` when the status check confirms zero active tuners, zero recording shows, and no VLC session — a safety net for assertions left behind by crashed or force-killed streams.

The OS also auto-expires each assertion via `kIOPMAssertionTimeoutActionRelease` after `duration` seconds — the explicit tracking is belt-and-suspenders so abnormal terminations don't hold sleep assertions past the point where anything is actually streaming.

---

## Natural Stop + File Verification

After `show_end` passes, the idle loop calls `stopRecording(index:natural:true)`. Either branch below ends by calling `scheduleNextAir` — a failed recording is rescheduled too, not left stranded:
- If the output file is missing or zero bytes → increments `show_fail_count`, sends a notification and a Discord "Recording Failed" card (via `fireDiscordCard`, reusing/capturing the existing lifecycle card rather than a fresh POST), then calls `scheduleNextAir` and returns immediately (no completion embed/file-size bookkeeping). The failure reason picks the most specific source available, in priority order: the device-reported `X-HDHomeRun-Error` (captured *before* teardown, since `RecordingManager.stop()` deletes the header file) → `show_fail_reason` from a FAIL already recorded *this* attempt (tracked via `AppState.showRuntime[showId]?.failedThisAttempt`, so a stale reason from an unrelated earlier episode isn't reused) → the generic fallback `"Output file missing or empty — check disk space"`. When an underlying reason is found, `" — output file missing or empty"` is appended (idempotently — the suffix isn't re-added if a resumed attempt already carries it).
- If the file exists and is non-empty → runs the post-recording script, builds the completion embed's file-size fields, then calls `scheduleNextAir`.

---

## HDHomeRun Response Headers

Both headers are extracted from the `--dump-header` file written by curl at stream start.

### X-HDHomeRun-Resource

`readHDHRResource(showId:)` — reads `X-HDHomeRun-Resource: tunerN` and returns it lowercased (e.g. `"tuner0"`). **Does not delete the file** — ownership of the delete belongs to the error reader. Returns `nil` if the file doesn't exist yet or the header is absent.

Called from `AppState.captureResourceHeaders()` 1.5 s after start. Result stored in `show.show_tuner_resource` and used by `fetchDeviceStatus` to target `/tunerN/vstatus` directly.

### X-HDHomeRun-Error

`readAndClearHDHRError(showId:)` — reads `X-HDHomeRun-Error:` and maps the numeric code to a human-readable string. **Deletes the file after reading.** Called when curl exits unexpectedly.

Error codes: 804 Tuner In Use · 805 All Tuners In Use · 806 Tune Failed · 807 No Video Data · 808 DVR Failure · 809 Playback Connection Limit · 810 DVR Full · 811 Content Protection Required.

`stop()` deletes the header file via `clearHeaderFile(showId:)` — if the recording is manually stopped before the error reader fires, the file is cleaned up without being read.

### curl Exit Code (fallback when there's no HDHomeRun error)

`isRunning(showId:)` captures the raw `waitpid` status into `lastExitStatus: [String: Int32]` whenever it reaps a dead curl. `readAndClearExitStatus(showId:)` decodes that status (`WIFEXITED`/`WEXITSTATUS`, or "killed by signal N" if curl didn't exit normally) into a human-readable string via `curlExitLabel(_:)` — e.g. `"curl couldn't connect (7)"`, `"curl timeout (28)"`, `"curl empty reply from server (52)"`. This fills in the gap left when `readAndClearHDHRError` finds no `X-HDHomeRun-Error` header — i.e. curl itself failed (bad network, DNS, timeout) rather than the tuner device reporting an error — so a failure message still says *why* instead of falling back to a generic string. A clean exit (`code == 0`) returns `nil`, since that isn't itself a failure reason.

---

## Verbose curl Logging

Toggle in Settings → Advanced → "Verbose curl logging". When enabled:
- Adds `-v` to curl args.
- curl's own stderr is appended directly to its own dedicated file, `~/Library/Logs/hdhrVCRplus-curl.log` (`curlVerboseLogFilePath`, `Models.swift`), via a raw `posix_spawn` file descriptor (`spawnDetached`'s `stderrPath`) — independent of `glog()`'s queue.
- Each recording block starts with a timestamp header and the full command line, written via its own ad-hoc `FileHandle` open/append/close in `writeCurlLogHeader`.
- **Log rotation**: `start()` calls `rotateCurlVerboseLogIfNeeded()` (`Models.swift`) once per verbose recording start, before `writeCurlLogHeader`. It stats the file directly and, if ≥ 5 MB, renames it to `hdhrVCRplus-curl.log.1` (overwriting any existing backup) rather than truncating in place — a prior in-place truncate-at-5MB approach was removed because it raced with `RotatingLogFile`'s persistently-open handle back when this feature shared `logFilePath` with the main app log, desyncing that handle's internal byte counter from the file's real (now-zero) size. Neither race is possible now: this is its own dedicated path, no persistent Swift-side handle is held on it between recordings, and — unlike `RotatingLogFile` — nothing here tracks a running byte count, so there's nothing to desync. The per-recording-start check (rather than per-line) is the practical limit of what's reachable given curl writes directly to the fd, entirely outside Swift's visibility once spawned — a single verbose recording whose own `-v` output alone exceeds 5 MB won't be caught until the *next* recording starts.

---

## Liveness Check — `isRunning(showId:)`

Uses `waitpid(pid, &status, WNOHANG)` as the primary check, with `kill(pid, 0)` as a fallback for reattached (orphaned) processes:

```
waitpid returns 0      → our direct child, still running → true
waitpid returns pid    → our direct child exited; zombie reaped → false
waitpid returns -1 (ECHILD) → not our child (orphaned to launchd after an app restart)
  kill(pid, 0) == 0   → process exists → true
  kill(pid, 0) != 0   → process gone → false
```

**Why `waitpid` instead of just `kill(pid, 0)`:** `kill(pid, 0)` returns 0 for zombie processes — exited but not yet reaped. This caused `show_recording` to stay `true` for the full scheduled window even after curl had exited, making the show appear as "Recording" while the HDHR tuner was actually free.

**Why the `ECHILD` fallback:** `waitpid` only works for direct children. After an app restart, reattached curl processes are orphaned and adopted by launchd — they are no longer children of the new process. `kill(pid, 0)` is used instead. launchd auto-reaps orphan zombies so the `kill` check is reliable in this case.

**New caller, added 2026-09-09**: `AppState.startRecording(index:)`'s own resync guard (`docs/AppState.md`) checks this directly, ahead of the device/tuner checks in that function, treating it as the actual source of truth for "is a process already running for this show" — more trustworthy than the `shows` array's own `show_recording` copy of that fact, which was found live to desync from reality (see `issues_resolved.md`). This is not the *second* call site — `AppState.idleLoop()` already calls `isRunning(showId:)` at several points of its own (the natural-stop detection, failure handling) — just the newest one. If `isRunning` itself is ever wrong (e.g. its own `pids` entry got cleared incorrectly by something upstream), `startRecording`'s resync guard inherits the same blind spot — it's a defense against the *symptom* (a stuck-false flag looping forever), not a guarantee the underlying tracking is always accurate.

---

## Checking Live Status

```bash
ps -Aa | grep show_id | grep -v grep   # one line per active recording
```

One curl PID per recording (`pids`). At startup, `reattachRecordings()` populates `pids` by scanning `ps -Axo pid,args` for lines containing `show_id:` + `/usr/bin/curl` + `hdhrVCRplus`, then looks up the show ID in `shows[]`. If found and `show_end` is still future, calls `reattach(showId:pid:title:endDate:)` which stores the PID and re-arms the sleep assertion for the remaining duration.

```bash
ps -Aa | grep feed_cache | grep -v grep   # one line per active FEED cache puller
```

Same `ps -Axo pid,args` scan shape, but for `feed_cache:` markers instead of `show_id:` — `AppState.sweepOrphanedFeedCachePullers()` runs this once at startup (see "FEED local disk cache puller" above) and unconditionally kills every match, rather than reattaching it the way a real recording curl gets reattached.
