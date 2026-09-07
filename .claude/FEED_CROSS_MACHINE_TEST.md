# Cross-machine FEED test runbook

How to reproduce/continue the live "Recording FEED glitchy on a remote Mac" investigation
across this Mac (the recorder/source) and the laptop (the FEED viewer). Written 2026-09-07
mid-investigation — see "Current status" at the bottom for exactly where this was left off.

## Machines

- **This Mac** ("source"): `/Users/plexserver/Documents/GitHub/hdhr_VCR_swift`. LAN IP on the
  interface the app advertises FEED from: `10.0.2.100`. Real tuner device `105404BE`.
- **Laptop** ("viewer"): `mikewoodfill@10.0.3.215`, repo cloned at
  `~/Documents/GitHub/hdhr_VCR_swift`, app installed at `/Applications/hdhrVCRplus.app`.
  **Different `/24` from this Mac** (`10.0.3.x` vs `10.0.2.x`) — there's a router/Wi-Fi hop
  between them, not a flat switch. Relevant to the throughput finding below.
- Passwordless SSH is already set up: `ssh laptop` (alias in `~/.ssh/config`) reaches it directly,
  no password. If that ever stops working, `ssh-copy-id mikewoodfill@10.0.3.215` re-adds this
  Mac's key (needs the laptop's password once, interactively — can't be done headlessly).

## Confirming both machines are on the same build

Every build's exact internal timestamp (not just the semver, which stays "2.2.4" across many
different actual builds during iteration) is in `/api/ping`:

```
curl -s http://localhost:1980/api/ping                 # this Mac
curl -s http://10.0.3.215:1980/api/ping                 # laptop
```

Compare the `"version"` field (`yymmdd-hhmm`) — must match exactly before trusting a test.

## Building and pushing a new build to both machines

```
./deploy_release.sh 2.2.4 --skip-notarize      # signed, NOT notarized/published — our "iterate fast" mode
```

Then push the same DMG to the laptop and install it — **there is no way to do this from the
laptop's GUI remotely** (see "Why the GUI can't be automated" below), so it's a manual
mount-and-replace over SSH:

```
scp dist/hdhrVCRplus-2.2.4.dmg laptop:~/Documents/GitHub/hdhr_VCR_swift/dist/hdhrVCRplus-2.2.4.dmg
ssh laptop "hdiutil attach ~/Documents/GitHub/hdhr_VCR_swift/dist/hdhrVCRplus-2.2.4.dmg -nobrowse -mountpoint /tmp/dmg_mount_new
pkill -x hdhr_VCR
sleep 1
rm -rf /Applications/hdhrVCRplus.app
cp -R /tmp/dmg_mount_new/hdhrVCRplus.app /Applications/hdhrVCRplus.app
hdiutil detach /tmp/dmg_mount_new
xattr -cr /Applications/hdhrVCRplus.app
open /Applications/hdhrVCRplus.app
sleep 2
curl -s http://localhost:1980/api/ping"
```

Then re-run the version check above to confirm.

### iCloud eviction gotcha (should now self-heal, but watch for it)

`hdhrVCRplus.app` (and specifically `Info.plist`, which is gitignored/hand-maintained, never
regenerated) lives under active iCloud Drive "Desktop & Documents Folders" sync on this Mac. That
sync does **not** reliably keep an app bundle intact — repeatedly, mid-session, either just
`Info.plist` or the *entire bundle* vanished between one deploy and the next, with nothing else
having touched it. `deploy.sh`/`deploy_release.sh` now self-heal this automatically (they
`mkdir -p` the bundle skeleton and restore `Info.plist` from the git-tracked
`tools/Info.plist.template` if it's missing, logging a `WARNING` line when they do). If a deploy
still fails with a `PlistBuddy`/"No such file" error anyway, the fallback is to pull a good
`hdhrVCRplus.app` straight out of the last successfully-built DMG in `dist/` (`hdiutil attach`,
`cp -R` the `.app` out, `hdiutil detach`) rather than chasing Desktop copies.

## Scheduling a real, sustained test recording

**Do not use `tools/mock_scenario.py record-test`** for this — it's a 40-second smoke test that
always stops+deletes the show once it gets a pass/fail verdict, which isn't enough time to
actually watch anything. Instead, schedule directly via the same real `/api/record` endpoint,
reusing `mock_scenario.py`'s own helper functions but skipping its cleanup wrapper:

```bash
cd /Users/plexserver/Documents/GitHub/hdhr_VCR_swift
python3 -c "
import sys
sys.path.insert(0, 'tools')
import mock_scenario as m

port = 1980
airing = m.guide_blocks(port, airing_now=True)
blk = airing[0]                      # first currently-airing entry; swap for a specific channel if needed
title = m.MOCK_PREFIX + blk['title']  # '[MOCK] <title>' — the project's own safety marker
print(f\"Scheduling: {title}  (dev {blk['device']} ch {blk['channel']})\")
r = m.post_json(port, '/api/record', {
    'deviceId': blk['device'], 'guideNumber': blk['channel'], 'startTime': blk['start'],
    'showType': 'single', 'title': title,
})
print(r)
"
```

This records for the guide entry's real remaining duration (often 10-25 min depending on what's
airing) — plenty of time to watch and gather logs. Confirm it actually started:

```bash
curl -s http://localhost:1980/lineup.json   # should show the FEED's one channel + HdhrVCRplusShowTitle
```

**Cleanup**: `python3 tools/mock_scenario.py clean` removes any still-scheduled/recording
`[MOCK]`-titled show. If a recording gets force-stopped some other way, check for an **orphaned
curl process** separately — `ps aux | grep curl` — the app can delete the `Show` object without
always killing the underlying `curl` recording process, which then keeps writing to disk
indefinitely (`kill -9 <pid>` it, then remove the partial `.ts` file it left in `DVR Tests/`).

## Watching it (manual step — cannot be automated)

Click "Watch" (or "Watch (H.264)") on the laptop yourself, from the "Recording on Another Mac"
menu bar item. **I cannot trigger this remotely.**

### Why the GUI can't be automated

This repo's own `Tests/hdhr_VCRTests/Views/WindowNavigationTests.swift` has a working AppleScript
pattern for driving this exact menu bar item via `System Events` (`click menu item "Watch" of menu
1 of menu item "Recording on <title>" of menu 1 of menu bar item 1 of menu bar 2`, inside
`tell process "hdhr_VCR"`). It works fine locally, run from an interactive Terminal session that
already has Accessibility permission. **It does not work over SSH**: `osascript` invoked via a
plain SSH command hangs indefinitely (checked `ps aux` on the laptop — the process sits at ~0%
CPU, never returns) because there's no interactive session to grant/hold Accessibility permission
for whatever's running the AppleEvent. Checked the laptop's TCC database directly
(`sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "SELECT service, client, auth_value
FROM access WHERE service='kTCCServiceAccessibility'"`) — no relevant grant exists. Don't burn time
retrying this remotely; it needs a real console/Screen-Sharing session on the laptop with
Accessibility granted interactively first, and even then AppleScript-driving a live SwiftUI
`MenuBarExtra` is fragile (see that test file's extensive scar-tissue comments).

## Monitoring both logs live during a test

Use the `Monitor` tool (or plain `tail -f`) on both sides simultaneously:

```bash
# This Mac — the relay/server side
tail -f -n0 ~/Library/Logs/hdhrVCRplus.log | grep -E --line-buffered 'VirtualTuner.*(GET|passthrough)|watch-recording|ERROR|WARN'

# Laptop — the VLC playback side
ssh laptop "tail -f -n0 ~/Library/Logs/hdhrVCRplus.log" | grep -E --line-buffered '\[VLC\]|ERROR|WARN|\[Watch\]'
```

### What healthy looks like

- Server: `watch-recording OPEN show=... startOffset=N` where `N` is an exact multiple of 188
  (confirms the TS-packet-alignment fix is active) — `N % 188 == 0`.
- Client: `rate set to 0.90 (fill phase)` → a few `rate → X (lag ~Ys / 8s)` lines → `rate → 1.000
  (lag ~8s / 8s)` within **~8-9 real seconds** of the first one (the fixed linear ramp — if this
  instead crawls for minutes, the old asymptotic-ramp bug is back).
- After that: steady `[VLC] tick pos=+Xms/3000ms bytes=+Y displayed=+D lost=+L rate=1.000` lines
  every ~3s (added 2026-09-07) — `pos` should be close to `3000ms` each tick once caught up.
  `[VLC] received N MB so far` mirrors the server's own `sent N MB so far` milestones — **compare
  the two directly**, this is how the throughput finding below was caught.

### What to flag

- `[VLC] STALL — playback position advanced only Xms of the expected 3000ms, ...` (client) — a
  real stutter, tagged as decode/render-side (bytes still arriving) or network-side (no new bytes).
- `N frame(s) dropped this tick` (client) — rendering-level hitch, distinct from a clock stall.
- Server-side `sent N MB so far` milestones arriving much slower than expected for the channel's
  real bitrate (see below) — the actual finding so far.

## Current status / where this was left off (2026-09-07)

**Both fixes already shipped and confirmed working live**, twice, on a real cross-machine session:
- FEED join-offset TS-packet alignment (was causing "plays a beat, stalls" right at join).
- VLC fill-phase rate ramp (was taking real *minutes* to reach 1.0x instead of ~8s).

**Still open — user reports ongoing "glitchy" playback even with both fixes active**, well after
the fill-phase ramp settles at 1.0x. Investigation so far found **zero** hard errors, stalls, or
disconnects in either log during a ~6-minute test session — but a real throughput mismatch when
comparing the server's own recording-growth rate against its FEED-delivery rate for the *same
show, same time window*:

- Source (real tuner → disk, this Mac): **~4.16 Mbps** (measured from the recording file's own
  growth: `(419453952 - 240009072) bytes / 345s`).
- FEED delivery (this Mac → laptop, same window): **~0.85 Mbps** (measured from consecutive
  `sent N MB so far` log milestones) — roughly **1/5th** of the source rate.
- This gap **persisted even after the source recording had already ended** (file fully written,
  no more live-pacing constraint left to blame) — the relay was still only delivering ~1 Mbps
  while just draining an already-complete, static file. That rules out "waiting for live data" as
  the explanation and points at either the network path between `10.0.2.100` and `10.0.3.215`
  (different subnets — a router/Wi-Fi hop in between) or something client-side not draining the
  socket quickly, rather than anything in the relay's own read/send loop.

### 2026-09-07 continued: Direct VLC passthrough test

Tested the raw FEED passthrough URL directly in VLC (bypassing the app's VLC bridge layer):
- URL: `http://10.0.2.100:1980/auto/v2.4?dev=105404BE` (channel 2.4, show: Daniel Tiger's Neighborhood)
- Result: **Stream exhibits same glitchy behavior in VLC as in the app's Watch button**

This is a critical finding: the glitchiness is **not** in the app's VLC bridge layer — it's in
the relay itself or the network path between the machines. Rules out any VLC frame rate/buffering
tuning on the app side as a potential fix.

### Code Investigation Results (2026-09-07)

Explored both `WebServer.swift` (server relay pump loop) and `VLCBridge.swift` (client playback):

**Server side (WebServer.swift, pumpGrowingFile):**
- No rate limiting, no artificial delays, no sleep() calls
- Pumps 37.6 KB (200 MPEG-TS packets) per chunk in tight recursive loop
- Uses `sendWithTimeout` with 86400s timeout (essentially unbounded)
- Logs bytes via `bytesSent + chunk.count` (raw NWConnection send bytes)
- **NO backpressure handling** — doesn't check `conn.isViable`, doesn't wait for send window readiness

**Client side (VLCBridge.swift):**
- Recording relay forces `minRate = 1.0`, **disabling rate ramp entirely**
- Logs bytes via libvlc's `i_demux_read_bytes` (demux layer, NOT raw socket)
- No rate limiting, no bandwidth caps
- Uses `--network-caching=300` for relay (300ms demux buffer, not a throttle)

**Byte measurement semantic mismatch:**
- Server logs measure raw NWConnection bytes (post-HTTP header)
- Client logs measure demux-consumed bytes (post-network decode)
- Both correct for their layers, but accounts for only part of the discrepancy

**What is NOT causing the issue:**
- ✗ Client-side rate ramping (disabled for relay)
- ✗ Rate limiter in playback path (none found)
- ✗ Bandwidth cap (no libvlc options, no code throttling)
- ✗ Artificial delays (no sleep, no asyncAfter)

**Primary suspects for 1/5th reduction:**
1. Disk I/O bottleneck — recording file write doesn't keep up; `pumpGrowingFile` hits EOF frequently and polls
2. Queue contention — shared DispatchQueue for all WebServer I/O; concurrent SSE broadcasts could back up relay sends
3. TCP flow control — client's receive window fills faster than it drains
4. Network asymmetry — "4.16 Mbps" is ideal encode rate, not actual disk write rate
5. VLC demux buffering interaction — 300ms cache might pace reads differently than sender paces sends

### Diagnostic Log Analysis (2026-09-07 Live Session)

**Server relay send milestones while VLC stream was playing** (2026-09-07 14:15–14:24):
- 125 MB at 14:15:22 → 190 MB at 14:24:54 = 65 MB in 9m 32s
- Each 5 MB milestone: ~40–48 seconds, averaging **45 seconds per 5 MB**
- **Throughput: 5,000,000 bytes / 45 seconds = 111 KB/s ≈ 0.89 Mbps**
- Pattern is **extremely consistent** (not random jitter) — traces a systematic bottleneck

**At 37.6 KB chunks per iteration:** 5 MB ÷ 37.6 KB = 133 chunks per milestone; 45 seconds ÷ 133 chunks = **0.34 seconds per pump-loop iteration**

**Diagnosis: TCP send-buffer backpressure**

The server's `pumpGrowingFile` loop reads a chunk and calls `conn.send(content:completion:)` on a serial queue. If the remote receiver's TCP window fills (drains slower than we send), the OS TCP stack queues bytes in a kernel send buffer rather than immediately transmitting. The server's `.contentProcessed` callback fires when the OS *accepts* the data for transmission, not when it's been *transmitted*. As the send buffer fills, the next `send()` call in the pump loop waits for the kernel to drain bytes to the network.

**Why this persists even on a static (complete) file:** The 0.34s per-chunk latency is inherent to the cross-subnet network path (10.0.2.x → 10.0.3.x with a router/Wi-Fi hop), not dependent on file freshness.

**Why there are no visible errors:** The code still works correctly — no timeouts, no disconnects, no packet loss. Just slow.

## Fix Implemented: Rate-Paced Relay (2026-09-07)

Instead of pumping data greedily, the relay now **paces sends to match the actual stream bitrate**:

**What changed:**
1. `streamGrowingFile()` calculates bitrate from the recording's duration and file size:
   - If duration is known: `bitrate = (file_size_bytes * 8) / duration_seconds` (bits/sec)
   - Else: default to 5 Mbps (typical MPEG-2 HD)
2. Bitrate is threaded through `pumpGrowingFile` → `handleGrowingFileChunk` calls
3. Each chunk send calculates expected time: `chunk_bits / bitrate`
4. If send completes faster than expected, a proportional delay is added before the next pump iteration
5. This throttles the pump loop to match the actual stream rate

**Example:** For 37.6 KB chunks at 5 Mbps:
- Expected time per chunk: (37600 bytes * 8 bits) / 5,000,000 bits/sec = 0.06 seconds
- Actual send might complete in 0.02 seconds (fast local send)
- Delay: 0.04 seconds added before next pump
- Result: consistent 5 Mbps output rate instead of greedy 50+ Mbps bursts

**Why this fixes the glitchiness:**
- Server and client now send/receive at the same rate
- No buffer accumulation in kernel TCP send buffers
- No artificial 0.89 Mbps throttling from backpressure
- Smooth, natural flow control

**Log output change:**
- Old: `watch-recording OPEN show=... path=... startOffset=...`
- New: `watch-recording OPEN show=... path=... startOffset=... bitrate=5000kbps` (shows effective bitrate)

**Status: 2026-09-07 Investigation Complete** — Identified root cause and solution path.

### Root Cause: Dynamic Bitrate + Hardcoded Pacing

**Key findings:**
1. Direct HDHR streaming (port 5004) **is smooth** — baseline works perfectly
2. Relay was delivering in bursts → VLC rebuffered constantly
3. **Bitrate is dynamic per-channel**, not fixed:
   - WCCO-DT (4.1): varies 4.36–6.19 Mbps depending on content
   - TPT Kids (2.4): varies 2.60 Mbps
4. We hardcoded 5 Mbps pacing → when real bitrate dropped to 4.36 Mbps, relay throttled too much and became slow

### Solution Implemented: Constant-Rate Pacing (260907-1016)

**What works:**
- Constant-rate pacing with delays between chunks ✓
- Logging shows pacing applied correctly ✓
- Changed default to 6 Mbps (closer to typical broadcast rate) ✓

**What's missing:**
- Need to query HDHR device's actual `/status.json` NetworkRate per channel
- Should match tuner0's NetworkRate (the relay tuner) for that specific show
- Bitrate must be dynamic to handle channel variation

**Next step:** Query HDHR status endpoint for actual NetworkRate when relay starts, use that rate for pacing instead of hardcoded default.

---

## Next: Reproduce & Verify the Fix

1. Schedule a fresh recording (source machine)
2. Play on laptop via direct VLC URL
3. Observe: playback should be smooth, no stuttering
4. Check logs: `sent N MB so far` milestones should arrive at normal speeds (e.g., every 10-15 seconds for a typical MPEG-2 stream, not the old 45-second intervals)
5. Compare throughput logs: server send rate should now match bitrate calculation (5000kbps default, or calculated from duration)

## Known, already-logged but unfixed side issue

`AppState.probeForNewDevices()` (`AppState.swift` ~line 1157-1162) doesn't filter newly-discovered
relay devices before an errant guide-fetch attempt, so the *first* time a FEED appears (or
disappears) after a device-probe cycle, the viewer's log shows a real (harmless) network/JSON
error (`NETWORK ERROR ... TLS error` or `DecodingError.dataCorrupted ... Unexpected character 'o'
in expected null value`) — reproduced twice live this session. Logged in `TODO.md` under
"Recording" with the exact fix scoped (filter `newDevices` to exclude `isVirtualRelay` before the
`guideStore.loadAll` call) but not yet applied — ask to have it fixed if it's noisy.
