# RecordingManager.swift — Recording Process Management

Launches and tracks `caffeinate -i curl` processes. Prevents sleep during recordings.

---

## API

```swift
func start(showId:, url:, outputPath:, durationSeconds:, transcode:, showEnd:, verbose:)
func reattach(showId:, pid:)   // register an existing PID without launching a new process (boot-resume)
func stop(showId:)
```

---

## Process Model

Each recording produces **two ps lines**: `caffeinate -i` (parent) + `curl` (child). Both contain `show_id:xxx` and `appname:hdhr_VCR_swift` so `reattachRecordings()` can find them after a restart.

- `durationSeconds` = **remaining time until `show_end`** (not total show length) — handles late starts and boot-resume correctly.
- Stream URL: `{channel_url}?duration={seconds}&transcode={profile}`
- curl `--max-time` = `durationSeconds + 120` (2-minute buffer against network stalls)
- PIDs stored in `pids: [String: Int32]`; liveness checked via `kill(pid, 0)` — more reliable than `Process.isRunning`.

## Stop

`stop()` calls `p.terminate()` and sends `SIGTERM` to the process group (`kill(-pid, SIGTERM)`) so the curl child dies even if `Process` no longer tracks it.

On successful recording start, `show_fail_count` is decremented by 1 (min 0) to give recovering shows headroom.

---

## Natural Stop + File Verification

After `show_end` passes, the idle loop calls `stopRecording(index:natural:true)`. Before scheduling the next air time:
- If the output file is missing or zero bytes → increments `show_fail_count` with reason `"Output file missing or empty"` and sends a notification.
- If the file exists and is non-empty → calls `scheduleNextAir`.

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
