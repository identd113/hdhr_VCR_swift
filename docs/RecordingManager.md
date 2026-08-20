# RecordingManager.swift — Recording Process Management

Launches and tracks `curl` processes directly. Prevents sleep during recordings and Watch Now streams via tracked IOKit assertions.

---

## API

```swift
func start(showId:, title:, url:, outputPath:, durationSeconds:, transcode:, showEnd:, verbose:, networkInterface:)
func reattach(showId:, pid:, title:, endDate:)    // register an existing PID without launching (boot-resume)
func stop(showId:)
func readHDHRResource(showId:) -> String?          // reads X-HDHomeRun-Resource without deleting the file
func readAndClearHDHRError(showId:) -> String?     // reads X-HDHomeRun-Error, deletes the file
func readAndClearExitStatus(showId:) -> String?    // decodes curl's own exit code into a reason; see below
func preventSleep(id:, reason:, duration:)         // create or replace a tracked sleep assertion
func releaseAssertion(id:)                         // release one assertion by key
func releaseAllAssertions()                        // release all; called when status check confirms idle
```

`networkInterface: String = ""` — when non-empty, appends `--interface <name>` to curl args, binding the stream to a specific NIC. Sourced from `AppConfig.Network_interface`; empty string means auto-select (curl default).

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

## Sleep Prevention

Sleep assertions are tracked by key in `assertionIds: [String: IOPMAssertionID]`:

- **Per recording**: key = `showId`. Created in `start()` and `reattach()` for `durationSeconds + 300` seconds.
- **Watch Now**: key = `"vlc"`. Created in `AppState.watchInApp()` when a guide entry's end time is known, sized to `max(60, entry.endDate.timeIntervalSinceNow) + 300`.

`preventSleep(id:reason:duration:)` releases any existing assertion for that key before creating a new one, preventing stale assertions from accumulating on repeated calls.

`releaseAssertion(id:)` releases and removes one entry. Called by `stop()` so the assertion drops the moment a show is deleted — not when its timer would have naturally expired.

`releaseAllAssertions()` releases every tracked assertion and clears the dict. Called by `AppState.releaseAssertionsIfIdle()` when the status check confirms zero active tuners, zero recording shows, and no VLC session — a safety net for assertions left behind by crashed or force-killed streams.

The OS also auto-expires each assertion via `kIOPMAssertionTimeoutActionRelease` after `duration` seconds — the explicit tracking is belt-and-suspenders so abnormal terminations don't hold sleep assertions past the point where anything is actually streaming.

---

## Natural Stop + File Verification

After `show_end` passes, the idle loop calls `stopRecording(index:natural:true)`. Either branch below ends by calling `scheduleNextAir` — a failed recording is rescheduled too, not left stranded:
- If the output file is missing or zero bytes → increments `show_fail_count`, sends a notification and a Discord "Recording Failed" card (via `fireDiscordCard`, reusing/capturing the existing lifecycle card rather than a fresh POST), then calls `scheduleNextAir` and returns immediately (no completion embed/file-size bookkeeping). The failure reason picks the most specific source available, in priority order: the device-reported `X-HDHomeRun-Error` (captured *before* teardown, since `RecordingManager.stop()` deletes the header file) → `show_fail_reason` from a FAIL already recorded *this* attempt (tracked via `failedThisAttempt`, so a stale reason from an unrelated earlier episode isn't reused) → the generic fallback `"Output file missing or empty — check disk space"`. When an underlying reason is found, `" — output file missing or empty"` is appended (idempotently — the suffix isn't re-added if a resumed attempt already carries it).
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

---

## Checking Live Status

```bash
ps -Aa | grep show_id | grep -v grep   # one line per active recording
```

One curl PID per recording (`pids`). At startup, `reattachRecordings()` populates `pids` by scanning `ps -Axo pid,args` for lines containing `show_id:` + `/usr/bin/curl` + `hdhrVCRplus`, then looks up the show ID in `shows[]`. If found and `show_end` is still future, calls `reattach(showId:pid:title:endDate:)` which stores the PID and re-arms the sleep assertion for the remaining duration.
