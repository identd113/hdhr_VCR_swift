# RecordingManager.swift — Recording Process Management

Launches and tracks `caffeinate -i curl` processes. Prevents sleep during recordings.

---

## API

```swift
func start(showId:, url:, outputPath:, durationSeconds:, transcode:, showEnd:, verbose:, networkInterface:)
func reattach(showId:, pid:)             // register an existing PID without launching (boot-resume)
func stop(showId:)
func readHDHRResource(showId:) -> String?    // reads X-HDHomeRun-Resource without deleting the file
func readAndClearHDHRError(showId:) -> String? // reads X-HDHomeRun-Error, deletes the file
```

`networkInterface: String = ""` — when non-empty, appends `--interface <name>` to curl args, binding the stream to a specific NIC. Sourced from `AppConfig.Network_interface`; empty string means auto-select (curl default). Set to empty to let curl pick the default route.

---

## Process Model

Each recording produces **two ps lines**: `caffeinate -i` (parent) + `curl` (child). Both contain `show_id:xxx` and `appname:hdhrVCRplus` so `reattachRecordings()` can find them after a restart.

- `durationSeconds` = **remaining time until `show_end`** (not total show length) — handles late starts and boot-resume correctly.
- Stream URL: `{channel_url}?duration={seconds}&transcode={profile}`
- curl `--connect-timeout 10` — aborts if the TCP connection to the tuner is not established within 10 seconds (catches unreachable devices quickly without waiting for `--max-time`)
- curl `--max-time` = `durationSeconds + 120` (2-minute buffer against network stalls)
- PIDs stored in `pids: [String: Int32]`; liveness checked via `isRunning(showId:)` — see below.
- `--dump-header {NSTemporaryDirectory()}hdhrVCRplus-{showId}.headers` is always passed to curl so response headers are captured to disk. The file is used for two purposes after the stream starts (see below).

## Stop

`stop()` sends `SIGTERM` to both the curl PID (via `curlPids`) and the caffeinate PID directly. **Do not use `kill(-caffenatePID, SIGTERM)` (process-group kill)** — on macOS, `caffeinate` moves itself into the curl child's process group after forking, so the process group ID equals the curl PID, not the caffeinate PID; the negative-PID form targets the wrong group and does nothing.

On successful recording start, `show_fail_count` is decremented by 1 (min 0) to give recovering shows headroom.

---

## Natural Stop + File Verification

After `show_end` passes, the idle loop calls `stopRecording(index:natural:true)`. Before scheduling the next air time:
- If the output file is missing or zero bytes → increments `show_fail_count` with reason `"Output file missing or empty"` and sends a notification.
- If the file exists and is non-empty → calls `scheduleNextAir`.

---

## HDHomeRun Response Headers

Both headers are extracted from the `--dump-header` file written by curl at stream start. The same file is reused for both reads so no extra curl invocations are needed.

### X-HDHomeRun-Resource

`readHDHRResource(showId:)` — reads `X-HDHomeRun-Resource: tunerN` from the header file and returns it lowercased (e.g. `"tuner0"`). **Does not delete the file** — ownership of the delete belongs to the error reader. Returns `nil` if the file doesn't exist yet (called 1.5 s after start; any curl connection delivers headers within that window) or if the header is absent.

Called from `AppState.captureResourceHeaders()` which runs inside `refreshTunerOccupancy`'s 1.5 s Task. The result is stored in `show.show_tuner_resource` and used by `fetchDeviceStatus` to target `/tunerN/vstatus` directly instead of searching by channel number.

### X-HDHomeRun-Error

`readAndClearHDHRError(showId:)` — reads `X-HDHomeRun-Error:` from the same file and maps the numeric code to a human-readable string. **Deletes the file after reading.** Called when curl exits unexpectedly (idle-loop detection); the result replaces the generic `"curl exited unexpectedly"` in `show_fail_reason`, the system notification subtitle, and the Discord embed.

Error codes: 804 Tuner In Use · 805 All Tuners In Use · 806 Tune Failed · 807 No Video Data · 808 DVR Failure · 809 Playback Connection Limit · 810 DVR Full · 811 Content Protection Required.

`stop()` deletes the header file immediately via `clearHeaderFile(showId:)` — if the recording is manually stopped before the error reader fires, the file is cleaned up without being read.

---

## Verbose curl Logging

Toggle in Settings → Advanced → "Verbose curl logging". When enabled:
- Adds `-v` to curl args.
- Appends curl stderr to `~/Library/Logs/hdhrVCRplus.log`.
- Each recording block starts with a timestamp header and the full command line.
- **Log rotation**: before writing each block header, if the log file exceeds **5 MB**, it is truncated to empty. This prevents unbounded disk growth during long-running verbose sessions.

---

## Liveness Check — `isRunning(showId:)`

Uses `waitpid(pid, &status, WNOHANG)` as the primary check, with `kill(pid, 0)` as a fallback for reattached (orphaned) processes:

```
waitpid returns 0      → our direct child, still running → true
waitpid returns pid    → our direct child exited; zombie reaped → false
waitpid returns -1 (ECHILD) → not our child (orphaned to launchd after an app restart)
  kill(pid, 0) == 0   → process exists (launchd reaps orphan zombies, so no false positives) → true
  kill(pid, 0) != 0   → process gone → false
```

**Why `waitpid` instead of just `kill(pid, 0)`:** `kill(pid, 0)` returns 0 for zombie processes — exited but not yet reaped. This caused `show_recording` to stay `true` for the full scheduled window even after curl and caffeinate had both exited, making the show appear as "Recording" while the HDHR tuner was actually free.

**Why the `ECHILD` fallback:** `waitpid` only works for direct children. After an app restart, reattached caffeinate processes are orphaned and adopted by launchd — they are no longer children of the new process. For these, `waitpid` returns `ECHILD` and `kill(pid, 0)` is used instead. launchd auto-reaps orphan zombies so the `kill` check is reliable in this case.

---

## Checking Live Status

```bash
ps -Aa | grep show_id | grep -v grep   # two lines per active recording
```

Both the caffeinate PID (`pids`) and the curl PID (`curlPids`) are tracked. At startup, `reattachRecordings()` populates both by scanning `ps -Axo pid,args` in a single pass: lines containing `"caffeinate"` → `pids`; lines containing `/usr/bin/curl` (without caffeinate) → `curlPids` via `reattachCurlPid(showId:pid:)`. This replaces the old async `pgrep -P caffeinate_pid` approach which was unreliable due to the PGID mismatch.
