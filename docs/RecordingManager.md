# RecordingManager.swift — Recording Process Management

Launches and tracks `caffeinate -i curl` processes. Prevents sleep during recordings.

---

## API

```swift
func start(showId:, url:, outputPath:, durationSeconds:, transcode:, showEnd:, verbose:)
func reattach(showId:, pid:)             // register an existing PID without launching (boot-resume)
func stop(showId:)
func readHDHRResource(showId:) -> String?    // reads X-HDHomeRun-Resource without deleting the file
func readAndClearHDHRError(showId:) -> String? // reads X-HDHomeRun-Error, deletes the file
```

---

## Process Model

Each recording produces **two ps lines**: `caffeinate -i` (parent) + `curl` (child). Both contain `show_id:xxx` and `appname:hdhrVCRplus` so `reattachRecordings()` can find them after a restart.

- `durationSeconds` = **remaining time until `show_end`** (not total show length) — handles late starts and boot-resume correctly.
- Stream URL: `{channel_url}?duration={seconds}&transcode={profile}`
- curl `--max-time` = `durationSeconds + 120` (2-minute buffer against network stalls)
- PIDs stored in `pids: [String: Int32]`; liveness checked via `kill(pid, 0)` — more reliable than `Process.isRunning`.
- `--dump-header /tmp/hdhrVCRplus-{showId}.headers` is always passed to curl so response headers are captured to disk. The file is used for two purposes after the stream starts (see below).

## Stop

`stop()` calls `p.terminate()` and sends `SIGTERM` to the process group (`kill(-pid, SIGTERM)`) so the curl child dies even if `Process` no longer tracks it.

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

---

## Checking Live Status

```bash
ps -Aa | grep show_id | grep -v grep   # two lines per active recording
```

The caffeinate PID is what RecordingManager tracks. `kill -0 <pid>` is the liveness check.
