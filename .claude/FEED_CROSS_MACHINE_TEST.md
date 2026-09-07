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

## Watching it (now automatable — see below; manual click also still works)

**Preferred, added 2026-09-07**: trigger a real Watch action over SSH, no GUI/Accessibility
session needed at all:

```bash
ssh laptop "open 'hdhrvcrplus://watch?dev=FEED04BE&channel=2.4'"
```

This uses the app's own `hdhrvcrplus://` URL scheme (`hdhr_VCRApp.swift`'s `AppDelegate.application(_:open:)`,
`CFBundleURLTypes` in `tools/Info.plist.template`) — `open` goes through Launch Services, which
needs no Accessibility permission, unlike AppleScript UI-scripting (see "Why the GUI can't be
automated" below for why that path never worked over SSH). `dev`/`channel` mirror the real
HDHomeRun device's own `/auto/v<channel>?dev=<deviceId>` addressing — get the live values from
`curl http://<laptop>:1980/lineup.json` after the laptop has discovered the source Mac's relay
(`grep -i FEED ~/Library/Logs/hdhrVCRplus.log` on the laptop to confirm discovery landed). Add
`&transcode=1` to trigger "Watch (H.264)" instead of the plain raw watch.

Alternatively, click "Watch" (or "Watch (H.264)") on the laptop yourself, from the "Recording on
Another Mac" menu bar item — still useful when you need a human actually looking at the screen
(e.g. to confirm the `windowVisible` diagnostic below, or to catch a visual glitch the logs
wouldn't show).

### Why the GUI itself can't be automated (AppleScript path — superseded by the URL scheme above)

This repo's own `Tests/hdhr_VCRTests/Views/WindowNavigationTests.swift` has a working AppleScript
pattern for driving this exact menu bar item via `System Events` (`click menu item "Watch" of menu
1 of menu item "Recording on <title>" of menu 1 of menu bar item 1 of menu bar 2`, inside
`tell process "hdhr_VCR"`). It works fine locally, run from an interactive Terminal session that
already has Accessibility permission. **It does not work over SSH**: `osascript` invoked via a
plain SSH command hangs indefinitely (checked `ps aux` on the laptop — the process sits at ~0%
CPU, never returns) because there's no interactive session to grant/hold Accessibility permission
for whatever's running the AppleEvent. Checked the laptop's TCC database directly
(`sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "SELECT service, client, auth_value
FROM access WHERE service='kTCCServiceAccessibility'"`) — no relevant grant exists. This is the gap
the `hdhrvcrplus://` URL scheme above was built specifically to close — no reason to revisit
AppleScript UI-scripting for this anymore.

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
- After that: steady `[VLC] tick pos=+Xms/3000ms bytes=+Y displayed=+D lost=+L rate=1.000
  windowVisible=<bool>` lines every ~3s — `pos` should be close to `3000ms` each tick once caught
  up. `[VLC] received N MB so far` mirrors the server's own `sent N MB so far` milestones — compare
  the two directly to sanity-check delivery rate.
- **`windowVisible` (added 2026-09-07) is the field that settles whether a stall is real** —
  `NSWindow.occlusionState.contains(.visible)` off the player's own drawable view. Earlier
  sessions this same day repeatedly got stuck arguing over whether a long `displayed=+0` stretch
  was a real VLC-side stall or just the window being backgrounded/the laptop's screen asleep
  (`open`-triggered playback doesn't wake the display) — this field removes the guesswork. A
  confirmed real stall (this investigation's own live result, same day) can still happen with
  `windowVisible=true` the whole time — don't assume `true` alone proves it's benign, only that
  it's *not* a backgrounding artifact.

### What to flag

- `[VLC] STALL — playback position advanced only Xms of the expected 3000ms, ..., windowVisible=<bool>`
  (client) — a real stutter, tagged decode/render-side (bytes still arriving) or network-side (no
  new bytes) — cross-check `windowVisible` before concluding anything about the *cause*.
- `N frame(s) dropped this tick ... windowVisible=<bool> (real render-side hitch, not backgrounding)`
  vs `(window not visible — likely explains this)` — the diagnostic's own log line already states
  which one it thinks this is.
- A `STALL resolved after ~Ns (N tick(s))` line whose resolving tick shows a huge `displayed=+N`
  burst (900+, vs. a normal tick's ~150-250) — the signature of a backgrounded window's decode
  pipeline queuing frames without compositing them, then flushing on return. Distinguish from a
  genuine VLC-side stall (this investigation found real examples of *both*, including one with
  `windowVisible=true` throughout and a genuine negative `pos` delta / real `lost` frames — a true
  PCR/clock discontinuity, not explainable by backgrounding at all).
- Server-side `sent N MB so far` milestones arriving much slower than expected for the channel's
  real bitrate — the original finding that started this whole investigation (see "Resolution" below
  for what that turned out to be, and what it wasn't).

## Resolution (2026-09-07) — read this first if picking the investigation back up

**The actual root cause, found late in the same day this file's earlier sections were written**:
none of the throughput/pacing/backpressure theories below panned out. The real mechanism was
delivery *cadence*, not rate — `pumpGrowingFile` was sending 37.6KB bursts separated by a flat
500ms silent poll whenever it caught up to the live edge, a pattern the real HDHomeRun tuner's own
broadcast-fed stream can never produce (there's no backlog to burst-release from a live antenna
feed). Confirmed with a raw-socket byte sampler comparing the real tuner's own port-5004 stream
(avg 1.5KB chunks, gaps almost always <20ms) against the relay (avg 34.8KB chunks, ~15% of reads
landing on the 500ms silent gap) — a completely different diagnostic approach than the
throughput/bitrate-math investigation below, and the one that actually found the mechanism.

**Fix**: adaptive per-connection chunk size in `WebServer.swift` — small (`watchRecordingChunkSize`,
8 TS packets) at the live edge matching the real tuner's cadence, large
(`watchRecordingBacklogChunkSize`, 200 packets, the old size) only while draining a genuine backlog
(e.g. a Watch Now scrub-bar seek) — plus a 20ms live-edge poll instead of the old 500ms. See
`ISSUES.md`'s (now resolved, moved to `issues_resolved.md`) FEED stall entries for the full trail,
including the earlier VLC-side tuning attempts (`--clock-jitter`, `--prefetch-buffer-size`) that
were tried and ruled out insufficient *before* this was found.

**Verified working**: a live cross-machine test with the window kept frontmost the whole time ran
**7.5+ minutes with zero stalls**, `windowVisible=true` confirmed throughout (see the "What healthy
looks like" section above for that diagnostic field). Not a complete fix, though — see below.

**Still open, marked Beta in the app as of this same day**: the relay-cadence fix measurably
improved things but didn't eliminate every VLC-side stall — a separate live session (also with
`windowVisible=true` confirmed, ruling out backgrounding) showed a real ~66-81s stall and a genuine
negative-`pos`/real-`lost`-frames PCR discontinuity. VLC 3.0.23's own demux/clock-sync pipeline is
still the suspected root cause (see `ISSUES.md`'s original diagnosis), just triggered less often
now. Also found the same day: switching audio/CC tracks on a FEED doesn't take effect (new
`ISSUES.md` entry, not yet root-caused) — plausibly the same class of "reading a disk-backed
stream" limitation already documented for local Watch Now's CC picker.

**Side issue also fixed the same day**: `AppState.probeForNewDevices()`'s missing
`recordableDevices`-equivalent filter (the "first FEED discovery throws a harmless TLS/JSON error"
issue this file used to describe as open) — fixed, see `issues_resolved.md`.

**New tooling from this investigation, useful for the next one**:
- The `hdhrvcrplus://watch?dev=<id>&channel=<channel>` URL scheme (see "Watching it" above) — no
  more needing a human at the laptop for every test iteration.
- The `windowVisible` tick-diagnostic field — settles the "is this a real stall or just a
  backgrounded window" question that ate a lot of time earlier in this same investigation.
- A raw-socket byte-level sampler script (ad hoc, not committed — recreate as needed: connect,
  skip HTTP headers, log `recv()` size + inter-arrival gap for a few seconds) — this is what
  actually found the cadence mismatch; throughput/bitrate math alone (the bulk of this file's
  now-superseded earlier sections) never would have.
