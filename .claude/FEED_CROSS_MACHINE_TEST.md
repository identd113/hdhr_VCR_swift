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

**Next step, not yet done**: an app-independent raw network throughput test between the two
machines (e.g., time a large file transfer via `scp`/`curl`, or `iperf3` if available on both) to
confirm or rule out the LAN path itself as the bottleneck before chasing anything further in code.
If confirmed, this is a network/infrastructure issue, not an app bug, and no further FEED code
changes would fix it — the fix would be on the network side (Wi-Fi placement, wired connection,
QoS, etc.).

## Known, already-logged but unfixed side issue

`AppState.probeForNewDevices()` (`AppState.swift` ~line 1157-1162) doesn't filter newly-discovered
relay devices before an errant guide-fetch attempt, so the *first* time a FEED appears (or
disappears) after a device-probe cycle, the viewer's log shows a real (harmless) network/JSON
error (`NETWORK ERROR ... TLS error` or `DecodingError.dataCorrupted ... Unexpected character 'o'
in expected null value`) — reproduced twice live this session. Logged in `TODO.md` under
"Recording" with the exact fix scoped (filter `newDevices` to exclude `isVirtualRelay` before the
`guideStore.loadAll` call) but not yet applied — ask to have it fixed if it's noisy.
