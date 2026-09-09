# Cross-machine FEED test runbook

How to reproduce/continue the live "Recording FEED glitchy on a remote Mac" investigation
across this Mac (the recorder/source) and the laptop (the FEED viewer). Written 2026-09-07
mid-investigation — see "Current status" at the bottom for exactly where this was left off.

## Machines

- **This Mac** ("source", hostname `woodflix`): `/Users/plexserver/Documents/GitHub/hdhr_VCR_swift`.
  LAN IP on the interface the app advertises FEED from: `10.0.2.100`. Real tuner device `105404BE`.
  Always runs the repo-local dev-folder build (`./deploy.sh` — never installs to `/Applications`).
  **Had a macOS Login Item named "hdhrVCRplus" pointed at this exact dev-repo app bundle, on top of
  the `com.hdhr.vcrplus.plist` LaunchAgent** (`ISSUES.md`'s open duplicate-launch entry) — two
  independent OS-level auto-launch triggers for the same target, found and the Login Item removed
  2026-09-09 (`osascript -e 'tell application "System Events" to delete login item "hdhrVCRplus"'`).
  The LaunchAgent itself is still present, deliberately not also removed in the same pass — next
  restart should confirm whether the Login Item alone was the trigger.
- **Laptop** ("viewer"): `mikewoodfill@10.0.3.215`, repo cloned at
  `~/Documents/GitHub/hdhr_VCR_swift`. **`/Applications/hdhrVCRplus.app` is the laptop's correct
  test/everyday install — always test from there, never from the repo-local dev-folder build.**
  A 2026-09-09 pass wrongly concluded the opposite (deleted `/Applications/hdhrVCRplus.app` as
  "stray," left the dev-repo copy running instead) — **corrected same day, per explicit user
  direction**: `/Applications/hdhrVCRplus.app` was recreated from the dev-repo build (`cp -R`,
  ad-hoc signature carries over fine — codesign `-` isn't path-bound) and is once again the
  laptop's running/tested copy; the dev-repo copy under `~/Documents/GitHub/hdhr_VCR_swift` still
  gets built by `./deploy.sh` there (needed for the iCloud-synced fast-iteration workflow below)
  but should not be the one left *running* on this machine.
  **Also removed 2026-09-09, and this part of that pass still stands**: a macOS Login Item named
  "hdhrVCRplus" that had been silently auto-launching *some* copy at every login, independent of
  any LaunchAgent (the laptop has none) — this, not "two legitimate installs," was the actual
  cause of the "two processes" symptom investigated that night. Removing the Login Item was
  correct; removing the `/Applications` bundle itself was not — those were two separate fixes
  bundled into one pass, and only the first one should have shipped.
  Workflow: build via `./deploy.sh` in the dev-repo directory (below), then `pkill -x hdhr_VCR`
  followed by `rm -rf /Applications/hdhrVCRplus.app && cp -R
  ~/Documents/GitHub/hdhr_VCR_swift/hdhrVCRplus.app /Applications/hdhrVCRplus.app` and `open
  /Applications/hdhrVCRplus.app` to actually pick up and run the new build — a plain `./deploy.sh`
  on the laptop alone launches the *dev-repo* copy, not `/Applications`, and would silently retest
  the old build if skipped. **The `rm -rf` first is required, not optional** — confirmed live
  2026-09-09: `cp -R src dst` when `dst` already exists as a directory nests `src` *inside* `dst`
  rather than replacing it (a plain macOS `cp` behavior, not specific to this app), silently
  leaving the old binary in place at `dst/Contents/MacOS/hdhr_VCR` while the new one lands one
  level deeper and is never launched — caught by checking `/api/ping`'s `version` field after a
  redeploy and finding it hadn't moved. Confirm via `/api/ping`'s `version` field either way.
  **Different `/24` from this Mac** (`10.0.3.x` vs `10.0.2.x`) — there's a router/Wi-Fi hop
  between them, not a flat switch. Relevant to the throughput finding below.
- Passwordless SSH is already set up: `ssh laptop` (alias in `~/.ssh/config`) reaches it directly,
  no password. If that ever stops working, `ssh-copy-id mikewoodfill@10.0.3.215` re-adds this
  Mac's key (needs the laptop's password once, interactively — can't be done headlessly).

## If `ssh laptop` fails, retry before asking the user "is it online?"

Confirmed 2026-09-08: this LAN has two active Bonjour Sleep Proxies (`dns-sd -B _sleep-proxy._udp`
showed "Master Bedroom" and "Basement AppleTV", both Apple TVs), and the laptop has Wake for
Network Access enabled (`pmset -g` → `womp 1`) with SSH/Remote Login already Bonjour-advertised
(automatic once Remote Login is on — no extra setup). That means a `ssh laptop` attempt while the
laptop is genuinely *asleep* (not powered off, not off-Wi-Fi) should itself trigger a proxy-mediated
wake — the router's own ARP resolution on the laptop's local segment is what a sleep proxy
intercepts, so this works even from this Mac's different `/24`, no manual magic-packet crafting
needed.

**So**: a single failed `ssh -o ConnectTimeout=5 laptop "..."` is not proof the laptop is
unreachable — wait ~10-15s (waking from sleep isn't instant) and retry once before concluding it's
actually off/disconnected and asking the user. Only escalate to asking after a retry also fails.

## Confirming both machines are on the same build

Every build's exact internal timestamp (not just the semver, which stays "2.2.4" across many
different actual builds during iteration) is in `/api/ping`:

```
curl -s http://localhost:1980/api/ping                 # this Mac
curl -s http://10.0.3.215:1980/api/ping                 # laptop
```

Compare the `"version"` field (`yymmdd-hhmm`) — must match exactly before trusting a test.

## Building and pushing a new build to both machines

**Fast path (dev iteration — use this by default), discovered 2026-09-08**: the whole repo
(source included) is already iCloud-synced between the two machines' `~/Documents/GitHub`
folders — an edit made here shows up on the laptop within a few seconds with no `scp`/`git push`
needed (confirmed via matching `md5` of the same file on both machines). So iterating is just:

```
./deploy.sh                                             # this Mac — builds AND leaves this copy running, that's correct here
ssh laptop "cd ~/Documents/GitHub/hdhr_VCR_swift && ./deploy.sh && pkill -x hdhr_VCR && sleep 1 && rm -rf /Applications/hdhrVCRplus.app && cp -R hdhrVCRplus.app /Applications/hdhrVCRplus.app && open /Applications/hdhrVCRplus.app"
```

The laptop's `./deploy.sh` alone only builds the dev-repo copy and launches *it* — the extra
`pkill`/`cp -R`/`open` after `&&` is what actually gets the new build into `/Applications` and
running from there, which is the copy that must be the one left running on the laptop (see
"Machines" above — corrected 2026-09-09 after a prior pass got this backwards). Skipping that
tail silently retests against a stale `/Applications` build while the dev-repo copy runs unseen.

`.build` on both machines is a symlink to `/tmp/hdhr_vcr_build_cache` (see CLAUDE.md's iCloud
notes) — that target is a real local directory, not itself synced (`/tmp` never syncs), so a
laptop that hasn't built since its last reboot may need `mkdir -p /tmp/hdhr_vcr_build_cache`
once before `./deploy.sh` will build at all (it fails with a misleading
`NSCocoaErrorDomain Code=512 ... Not a directory` otherwise — found live 2026-09-08).

**Only run ONE instance on the laptop at a time** — see the "Laptop" entry under Machines above.
Both `/Applications` (the laptop's normal everyday install and the one to test from) and the
repo-local dev build (needed only as the source `./deploy.sh` compiles into, not itself meant to
stay running) exist there; the rule is never let both run *simultaneously*, since Launch Services
then silently routes test traffic to whichever it considers canonical, independent of which was
actually just redeployed (cost a chunk of a session before this was caught, 2026-09-08). Always
`pkill -x hdhr_VCR` before `open`ing either one, and always finish a laptop redeploy by launching
`/Applications`, per the corrected workflow above — not the dev-repo copy `./deploy.sh` itself
launches.

**Heavier path (an actual signed-build/DMG-install test, not ordinary iteration)**:
`./deploy_release.sh 2.2.4 --skip-notarize` (signed, not notarized/published), then push the DMG
and mount-and-replace over SSH — see `docs/Distribution.md`'s Release Checklist for the DMG
install steps if this is ever actually needed; don't reach for it just to test a code change.

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

## 2026-09-08 — live-edge cushion attempt: reverted, VLC demux stall on backlog

Tried next, aimed at the "still open" residual stall above (disk-read-latency hypothesis: every
byte served has now had ~2-3s to settle on disk before the relay touches it, via a fixed cushion
behind the recording's true current size — `WebServer.swift`'s `feedLiveEdgeCushionBytes`,
`streamGrowingFile`/`pumpGrowingFile`'s `liveEdgeCushionBytes` param). The cushion mechanics
themselves worked exactly as designed — confirmed via a temporary debug log (`[DEBUG-CUSHION]`,
removed before commit): correct join offset, correct ceiling enforcement, correct backlog-aware
chunk-size switching (small at the live edge, `watchRecordingBacklogChunkSize` once a real gap
exists) once a follow-up fix caught the tiny-chunk-size-during-real-backlog bug (RTT-bound
throughput on the cross-subnet hop, ~0.6-0.9 Mbps — see the fix's own comment on
`backlogAvailable`).

**But the actual live result was worse than the problem it was trying to solve**: once any backlog
formed (which happens almost immediately on this link), VLC on the laptop stopped progressing
entirely — `pos=+0ms/3000ms displayed=+0` on every tick, indefinitely, while still slowly absorbing
~300KB every 3s into some internal buffer. Not a stall-and-recover, a flat non-progress. Ruled out:
raw network capacity (confirmed ~580 Mbps via `iperf3` between the two machines, same link,
same time), source-side queue contention (checked the source Mac's own log for the exact window —
no competing `buildHTML`/`TunerAudit` work), and the chunk-size computation itself (the debug log
confirmed it was correct). Working theory, not confirmed: serving a real backlog in ~37.6KB jumps
recreates the *same class* of bursty-delivery problem the original cadence fix (above) solved —
just via backlog catch-up instead of the old poll-interval bursts — and VLC's demux/PCR handling
chokes on it the same way. Not root-caused further; would need VLC's own `--file-logging` verbose
output during a live repro to actually confirm.

**Status as of this writing: code still in the tree, not deployed to either machine, decision on
keep-vs-revert not yet made.** If picked up again: get a real VLC verbose log during the stall
before trying another relay-side mechanical fix — this session spent a lot of cycles on
plausible-sounding server-side theories (disk latency, chunk size, network bandwidth) that all
measured out fine, while the client's own demux behavior was never directly instrumented.

**Resolved (decision made), 2026-09-09**: `feedLiveEdgeCushionBytes` set to `0` after this same
regression reproduced fresh in a follow-up cross-machine session, this time with a real thread-level
capture (`sample <pid>` on the laptop, squarely mid-stall) confirming the client's own demux pipeline
goes idle — not backed up, not blocked trying to read — while the relay keeps delivering bytes
normally. A 4m39s clean retest with the cushion disabled (zero stalls, vs. two stalls within ~90s
each with it on) supports the decision without fully proving the underlying VLC bug is gone. Full
write-up: `ISSUES.md`'s "VLC-side FEED playback stalls" entry and `docs/VirtualTunerService.md`'s
live-edge cushion entry.

**Also found and fixed this same day, unrelated to the cushion itself**: the laptop had two
divergent app copies running *simultaneously* (`/Applications/hdhrVCRplus.app`, stale, vs. the
repo-local `./deploy.sh` build) — Launch Services routed the `hdhrvcrplus://` URL scheme to
whichever it considered canonical, independent of which had just been redeployed, so several
live tests silently exercised a two-day-stale build. Both copies are legitimate and both stay —
`/Applications` is the laptop's normal everyday install, not just test scaffolding — the actual
fix is discipline about never running both at once; see the "Machines"/"Building and pushing"
sections above for the corrected single-instance-at-a-time workflow.
