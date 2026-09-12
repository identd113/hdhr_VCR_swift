# TODO

Deferred features and improvements. Add items here when a task is punted. Remove when complete and note the resolving commit in `ISSUES.md` if the work was non-trivial.

---

## Accepted — not our bug / not scheduled

### macOS Local Network permission block — lineup fetch can silently fail on launch

A confirmed, widespread macOS bug, not unique to this app (Apple DTS engineer: reproducible on 100% of tested Sequoia/Tahoe systems, radar filed, no supported fix) — Local Network Privacy can fail-closed for an `LSUIElement` menu-bar app with no visible prompt ever surfacing, and no self-recovery path. Root-caused and instrumented 2026-08-09 (`AppState.fetchAllLineups` previously swallowed the failure via bare `try?`; now logs the real `NSError`/`NWPath` reason, so a recurrence is diagnosable from `hdhrVCRplus.log` instead of silent). `fetchDeviceInfo`'s two callers got the same do/catch+log treatment; `setFavorite`'s caller was checked and already handled this correctly.

**Mitigations shipped** (effectiveness against the actual OS bug unconfirmed — Apple has to fix the underlying bug):
- Dock icon shown on launch (`.regular` activation policy) until a real lineup fetch succeeds, giving the OS's permission prompt a normal foreground app to attach to — then hides itself. **Settings → Advanced → Dock icon** (auto/always/never) overrides this.
- `idleLoop()` retries the lineup fetch every tick (not just hourly) while unconfirmed, so a permission grant — whenever/however it lands — takes effect within one tick instead of requiring a manual relaunch or waiting up to an hour.
- Verified end-to-end (real launches, polling `lsappinfo`'s process type): the Dock-icon flip happens correctly, right when the lineup fetch completes.

Ad-hoc dev builds and Developer-ID release builds are different code identities to TCC/Local-Network — granting access on one doesn't carry over to the other; worth remembering during testing.

**Key files**: `hdhr_VCRApp.swift` (`init()` activation-policy), `AppState.swift` (`confirmLocalNetworkAccessIfNeeded`, `idleLoop` fast-retry, `fetchAllLineups`), `Models.swift` (`Dock_icon_mode`/`Local_network_confirmed`), `SettingsView.swift` (Dock icon picker).

---

### No "Record Now" shortcut

No direct path to immediately record an in-progress show without going through Watch Now or the Add Show wizard. A quick-action from `MenuContent` or `WatchNowView` would skip the wizard for shows currently on air. Low priority, not scheduled.

---

### Closed captions don't survive the FEED transcode path

Backlogged 2026-09-04, explicit user choice — a future idea, not something to start on without asking first. Confirmed via `mediainfo`: a real source carries 6 embedded EIA-608/708 CC tracks, the x264 transcode output has 0. Root cause confirmed too: VLC's own `x264` stream-out module (`VLCBridge.startTranscodeSession`'s sout chain) has no exposed option for A/53 caption passthrough at all (`vlc -p x264 --advanced --help-verbose` — nothing caption/SEI/a53-related), so the MPEG-2 decode → H.264 encode pipeline silently drops the embedded user-data. Raw (untranscoded) FEED needs no fix — CC already passes through untouched, and the player's existing CC picker already works for it with zero FEED-specific code (confirmed live: VLC directly detects `Adding CC track 1-4` on a real FEED URL, see `docs/VLCPlayerView.md`'s CC picker section).

If ever picked up, two directions were floated, neither started, no clear winner chosen: (a) switch the transcode implementation to shell out to `ffmpeg -a53cc 1` instead of libvlc's stream-out chain — a real new dependency this app doesn't otherwise need; (b) write a custom TS-level CC extractor that pulls EIA-608/708 user-data from the source and manually re-injects it as SEI into the x264 output — meaningful new code, no existing scaffolding to build on.

---

## Menu Bar

### FEED-available status light shows even when no one is actually watching

Added 2026-09-06: the menu bar blue light (`AppState.hasAvailableRemoteFeed`/`.feedAvailable` in `statusLightCandidates`) lights up whenever *any* remote hdhrVCRplus instance's Recording FEED relay is discovered with a show attached — regardless of whether anyone is actually watching it from this Mac or anywhere else. Flagged live 2026-09-06, deferred: arguably this status should only matter (and only light up) once a real viewer is connected to that relay, not just because it exists and *could* be watched — otherwise it's less "something needs your attention" and more "a relay happens to be up," which is a much weaker signal. Not scoped: would need the discovering side to know the relay's own current viewer count (the source Mac already tracks this internally — `relayRawViewerCount`/`VLCBridge.transcodeViewerCount`, surfaced today only as `MenuContent`'s own "FEED: N watching" header row on the *source* Mac, not published anywhere a remote discoverer could read it) — likely a new non-standard `/lineup.json`/`/discover.json` field alongside `HdhrVCRplusShowTitle`, or deciding the light should instead reflect "am *I* currently watching this," which is trivially already known locally (`VLCBridge.shared.currentURL` matching a remote relay entry's own URL) but changes what the light actually means.

---

### Dock icon flash workaround — user doesn't recall why it's needed, considering removal

Raised 2026-09-09: the user no longer remembers the specific reason this was added and wants to consider removing it. Context for when this comes back up — see "Accepted — not our bug / not scheduled" section above ("macOS Local Network permission block") for the full original writeup: `hdhr_VCRApp.swift`'s `init()` briefly sets `NSApplication.shared.setActivationPolicy(.regular)` (showing a Dock icon) at launch in `"auto"` Dock-icon mode, until `AppState.confirmLocalNetworkAccessIfNeeded()` flips it back to `.accessory` once a real guide/lineup fetch succeeds — a mitigation for a confirmed, Apple-acknowledged macOS bug where a fully backgrounded (`LSUIElement`) menu-bar app can silently never receive the system's Local Network permission prompt at all, with no self-recovery path.

**Confirmed inert on this Mac right now** (2026-09-09 investigation, chasing an unrelated duplicate-app-launch bug — see `ISSUES.md`): live config here has `Dock_icon_mode: "never"` and `Local_network_confirmed: true`, so the activation-policy-toggling code path never actually executes on this machine — no flash to see. It would still matter for `"auto"` mode (the default) on a fresh install or after a config reset, where Local Network access hasn't been confirmed yet.

**Also clarified while looking into this**: the "forced silent open+close at launch" mentioned in `MenuContent`'s `onAppear` comment (`hdhr_VCRApp.swift`) is unrelated — it's not code this app wrote (nothing in the source implements an explicit trigger), just `MenuBarExtra` itself instantiating its content view once internally, which this codebase observed and leaned on as a free launch hook. Not part of the Dock-icon mitigation and nothing to remove there.

**Not yet decided**: whether to actually remove the Dock-icon toggle code. Tradeoff is real — doing so would remove the only defense (however unconfirmed in effectiveness) against a bug Apple hasn't fixed, for anyone running in `"auto"` mode. Revisit when actually deciding, not just investigating.

---

## Player / Watch Now

### More insistent tuner release for the yield-to-record flow — without killing anything

Flagged 2026-09-11/12: the Watch Now yield-tuner-to-Record flow's tuner-free wait (`AppState.recordAfterYieldingWatchNow`'s tuner-free poll) is genuinely variable in practice — live-tested twice post-`yieldingWatchNowDeviceID`-fix, once resolving in ~1s, once taking 16s (cross-machine re-test, see `issues_resolved.md`'s follow-up on that entry) — because the real HDHomeRun device only frees a port-5004 tuner once it notices the underlying TCP connection actually closed, and that detection isn't instant. A raw `kill -9` on a recording's own curl process frees the same tuner immediately by comparison, but killing anything here isn't an option — `VLCBridge` is a shared, long-lived libvlc engine used for all playback in the app, not a disposable per-stream process like a recording's curl; killing it would tear down far more than just this one connection.

**Real candidate, not yet attempted**: `docs/HDHRFindings.md`'s ClientID/SessionID mechanism — officially documented for port 4999 (SiliconDust's separate Record Engine daemon, not what this app uses), where "sending the same ClientID with a new SessionID tells the engine to free the previous tuner and allocate a new one... without them, the old connection must fully close before the new tuner can start." That's exactly this problem. The doc's own port-5004 section says it was tried once (2026-05-31): the device accepted a request carrying both params without error, but **it was never confirmed whether the device actually honors them there or silently ignores them** — "further testing needed."

**What it would take to actually use this**: (1) live-test whether reusing a ClientID across a port-5004 stop+restart genuinely makes the device release the old tuner faster than today's passive TCP-close detection — this needs to happen against a real device before writing any code, since the whole idea is moot if port 5004 just ignores the params; (2) if confirmed, `AppState`/`RecordingManager`/`VLCBridge` would all need to agree on a persistent per-app-instance `ClientID` (generated once, likely at `startup()`) and thread fresh `SessionID`s through both the VLC playback URL and the curl recording URL — a real, multi-file plumbing change, not a one-line fix. Not scoped further than this until the live test confirms it's worth building.

**2026-09-12 update — user confirmed this doesn't work on this endpoint** (ClientID/SessionID has no effect on port 5004 against this device), so this candidate is likely dead; not removed above since it's still a useful record of what was checked and ruled out.

**Researched instead: is there a libvlc-side "quick drop" for a live network stream?** Checked VLC's own bug tracker, forums, and other client-library issues (VLC.DotNet, LibVLCSharp) — this turns out to be a well-known, longstanding, generally-unsolved libvlc characteristic: `libvlc_media_player_stop()` on a live/network stream commonly takes several seconds up to ~40s in other projects' reports too, matching our own 16-29s range. No documented fast-abort flag exists; every workaround found in the wild is architectural (don't block your own thread on it — which this app's polling loop already does), not a way to make the underlying close itself instant. Also checked whether this is an HDHomeRun-specific quirk via Jellyfin's own very similar-sounding "tuner stays locked" bug — turned out to be a Jellyfin-specific bookkeeping bug (sometimes never even attempting the close), not a transferable finding.

**Diagnostic armed 2026-09-12, not yet run**: a log-triggered `sample <pid> 30` watcher is running in the background on the laptop (`tail -F` piped to a trigger script, started via SSH, `disown`ed so it survives) — the moment `~/Library/Logs/hdhrVCRplus.log` shows `"[Watch] Yielding this instance"`, it auto-samples the app process for the full 30s window to `/tmp/hdhr_stop_delay.sample.txt` on the laptop, no manual timing needed. Pair with a manually-started `sudo tcpdump -i en0 host hdhr-105404be.local and port 5004 -w /tmp/tuner_release.pcap` (needs an interactive password, can't be automated remotely) for wire-level ground truth. Waiting on the user to re-run the yield-to-record scenario on the laptop — deferred, not done yet. Together these settle whether the delay is libvlc being slow to actually send the disconnect, or the device being slow to act on one it already received — determines whether there's anything left to fix in this app at all, or whether this is purely a device/libvlc limitation to document and accept.

---

### No watched/resume tracking across sessions

VLC's own scrub bar handles resume-within-a-single-playback-session, but nothing persists a recording's watched state or last playback position across app restarts or between Watch Now and a later Finder-opened file. Comparable apps (Plex, Channels DVR) track both, letting a library view distinguish "new," "in progress," and "watched." Would need a small persisted per-recording-file record (position + watched flag), keyed by a stable identifier since filenames can be reorganized — 2026-08-11 feature-gap survey, not yet scoped.

---

### Generalize the stop()-not-releasePlayer() smooth-reconnect technique to every live→disk-relay handoff, not just the yield-to-record flow

Flagged 2026-09-11. The Watch Now yield-tuner-to-Record feature (`AppState.recordAfterYieldingWatchNow`) root-caused and fixed a "stuck on Connecting…" bug by calling `VLCBridge.shared.stop()` (leaves `VLCPlayerWindowManager`'s `drawableView` attached) instead of `releasePlayer()` (nils it) right before handing off to `watchRecordingInApp(_:)` — `releasePlayer()` would have meant `VLCVideoSurface.makeNSView` never re-fires for a same-device window reuse, so a later `play()` just sits queued forever with no surface to render into. See `recordAfterYieldingWatchNow`'s own doc comment and `issues_resolved.md` for the full root-cause writeup.

That fix is currently scoped to just this one flow. Any *other* place in the app that transitions a live, in-app-network-watched channel over to watching its own now-in-progress recording from disk (or the reverse — recording-relay playback handing back to a live stream) should go through the same `stop()`-then-`watchRecordingInApp`/`watchInVLC` sequence rather than whatever it does today, or it risks hitting the identical stuck-on-Connecting failure mode.

**Audited 2026-09-12 (while resuming FEED work on `feature/recording-feed`) — no current FEED code path is actually exposed to this.** Checked every `releasePlayer()`/`stop()`/`mgr.open()` call site: `VLCPlayerWindowManager.open()`'s reuse-vs-recreate branch is keyed on device match, and a FEED relay's device ID is always distinct from any real physical device *and* ephemeral (the relay stops advertising entirely once its source recording ends, rather than being reconnected to) — so any FEED-related open either takes the safe "recreate" path (different device) or the source simply vanishes rather than triggering a same-device reconnect. The one FEED path that *does* reconnect in place — `VLCPlayerView.toggleFeedTranscode` (raw ↔ H.264) — calls `bridge.play(url:)` directly on the already-alive player and never touches `VLCPlayerWindowManager.open()`, so it was never exposed to this bug class either. Nothing to fix here today; revisit only if a future feature actually adds a same-device FEED reconnect (e.g. a FEED session handing off to local disk playback once its source recording finishes — not a real code path today, just a hypothetical raised during this audit).

---

### ~~Watch Now should show whether the video is currently reading from the network or from disk~~ — done 2026-09-11

Requested and shipped same day: the Native-resolution toolbar button's icon color and its hover popover's top row both now show live-network-vs-disk-relay source (`VLCPlayerView.swift`'s `nativeIconSourceColor`, keyed off `bridge.recordingShowId`). See `docs/VLCPlayerView.md`'s "Native resolution button" entry.

---

### ~~Show buffer information next to Local Recording / network device listings~~ — done 2026-09-12

Requested and shipped same day: turned out to mean the existing "Local recording (disk)" / "Live network stream" indicator in the native-resolution button's hover popover (`VLCPlayerView.swift`'s `nativeResPopover`, see the item right above this one) — not the menu bar or web guide device lists. Added an "On disk" row showing the recording file's current size (`VLCPlayerView.recordingSizeText`, a plain `FileManager.attributesOfItem` stat), shown only for the disk-relay case. Deliberately a one-shot snapshot recomputed each time the popover reopens, not tracked on a timer like the separate "Live Buffer" pill's `lagSec` — matching the explicit request that this not need continuous updates. See `docs/VLCPlayerView.md`'s "Native resolution button" entry.

---

## Recording

### No reminder-only shows (notify without recording)

Every managed show type records; there's no way to just get notified when something airs without scheduling a recording. TiVo separates "season pass" (record) from "reminder" (notify only) as two different actions on the same show. Would likely reuse the existing notification plumbing (`notify`/Discord embeds) minus the actual `startRecording` call — the guide-matching/scheduling side (`ManagedGuideMatcher`, `resolveSeriesAir`) would need a new non-recording show state to key off. 2026-08-11 feature-gap survey, not yet scoped.

---

### Virtual tuner relay transcode — remaining polish after Phase 2's live verification

Phase 1 shipped 2026-09-01; Phase 2 (real H.264 transcode) implemented and live-verified against a real HDHomeRun device 2026-09-02 (`Tests/hdhr_VCRTests/WebServer/VirtualTunerLiveStreamTests.swift`, `RUN_VIRTUAL_TUNER_LIVE_TESTS=1`) — see `docs/VirtualTunerService.md`'s "Real transcode (Phase 2)" section for the full design and what's actually been confirmed working live (raw passthrough, transcode to H.264 with surviving stereo audio). `?duration=` now honored on the transcode path too (fixed 2026-09-04), audio re-encodes to AC-3 (not MPEG Layer 2) so it stays the same codec end to end, and the GOP length now targets ~0.5-1s via `sout-x264-keyint`/`-min-keyint` (down from x264's own ~4.2s default; tightened from an initial ~1-2s/broadcast-matching target to deliberately *beat* real broadcast cadence 2026-09-04, since most FEED viewers join an already-running shared transcode mid-stream rather than getting a fresh IDR as frame one — live-verified against a real device same day, see `docs/VirtualTunerService.md`'s GOP note) — see `docs/VirtualTunerService.md`'s own notes on all three. Remaining gaps, not blocking:

1. `VLCBridge.transcodeBitrateKbps(for:)`'s numbers per profile are a first-pass guess, not measured against real watched playback quality — worth a real living-room sanity check. Per an explicit user request (2026-09-02), bitrate is deliberately the *only* thing that varies by profile now — every profile keeps the source's own frame rate/dimensions (no `scale=`/`width=`/`height=`/`fps=` in the sout chain), so a `mobile` request against a full-resolution source will look blockier than a genuinely downscaled stream at the same bitrate would. That's the accepted tradeoff, not something to "fix" without asking first.
2. Live testing so far covers short-lived sessions (~15-20s windows). Multiple concurrent viewers of the same show sharing one `TranscodeSession` correctly (the reference-counting path, including across *different* requested profiles — sharing is now keyed by `showId` alone, not `showId`+profile, per a 2026-09-03 explicit user request) has been live-verified against the real deployed app. Not yet verified: a long-running session's resource behavior over a full-length recording rather than a short test window.
3. **Dead end, confirmed 2026-09-04 — no hardware encode path exists via libvlc.** The active transcode is pure CPU/software encoding (`libvlc`'s `x264` module, confirmed via its own log output and live CPU/GPU sampling 2026-09-03 — ~90-112% CPU per active session, no measurable GPU engagement). VideoToolbox can hardware-encode H.264 on this hardware in principle (confirmed via a direct `VTCopyVideoEncoderList` check) and cannot hardware-*decode* MPEG-2 on Apple Silicon at all (`VTIsHardwareDecodeSupported` returns `false`, so a fully-hardware MPEG2→H264 pipeline was never possible regardless) — but the previously-"unverified" question of whether libvlc's own transcode module exposes a way to select a VideoToolbox encoder for the output side is now answered: it doesn't. Checked directly against the same `/Applications/VLC.app` install `VLCBridge` `dlopen`s (`vlc --list | grep encoder`, and `vlc -p videotoolbox --advanced --help-verbose`) — the `videotoolbox` plugin is decode-only (just hw-decode options, no encoder), and the full encoder module list has only `x264`/`x264 10-bit`/`x265`/generic `avcodec` (all software, no VideoToolbox hw-encode flag on any of them). There is nothing to select — a runtime "check hardware availability, fall back to software" mechanism would be dead code, since the hardware branch could never trigger with this VLC build. The only route to real hardware encode would be dropping libvlc's sout chain entirely for something like a shelled-out `ffmpeg -c:v h264_videotoolbox` transcode — a materially different implementation, not a tweak to the current one. Not scoped; no plan to pursue unless asked.

Closed-caption passthrough for the transcode path specifically is a separate, lower-priority idea — see the "Accepted — not our bug / not scheduled" section above, "Closed captions don't survive the FEED transcode path."

---

### FEED relay must not cut off a viewer who's still behind the live edge once the source recording stops

Flagged 2026-09-08, alongside the live-edge cushion added the same day (`WebServer.swift`'s `feedLiveEdgeCushionBytes` — `streamGrowingFile`/`pumpGrowingFile`/`handleGrowingFileChunk`'s `liveEdgeCushionBytes` param): that cushion's own "recording finished" branch was written to drain its small (~2-3s) remaining tail before closing, so it already shouldn't lose the very end of the show for a viewer sitting right at the cushion boundary. Not yet verified for the much bigger case the user actually described: a viewer who has drifted **far** further behind the live edge than the cushion — e.g. a full minute, via VLC's own client-side jitter-buffer growth (see the "close to 1:1" FEED discussion the same day) or a deliberate seek — at the moment the source show's recording ends. Need to confirm two things live: (1) that no *other* code path (a stop-recording handler, a connection-cleanup pass) force-closes an in-progress FEED viewer connection the instant `show_recording` flips false, independent of `pumpGrowingFile`'s own drain logic — if one exists, it would cut off a deeply-behind viewer mid-show; (2) that a viewer who joined via a real backlog drain (not just the small cushion-fill case) actually receives the *entire* remaining file before the connection closes, not just whatever was left within the cushion window. If either isn't already true, the fix should be: never treat "`show_recording` is now false" as a reason to close a FEED viewer connection on its own — only actually close once that viewer's own read position has genuinely caught up to the recording's true final byte.

---

### Other instances' "Recording on Another Mac" menu should update promptly once a FEED session naturally winds down

Flagged 2026-09-08: today, when the *source* Mac's recording finishes and its last FEED viewer finishes draining (`pumpGrowingFile` reaches true EOF with `show_recording == false` and closes), nothing proactively tells a *discovering* Mac's menu bar ("Recording on Another Mac (Beta)" — see `MenuContent.swift`) that the relay is gone. That menu currently relies on the existing polling/staleness machinery — `probeForNewDevices()` marking the device `isAvailable == false` within a few minutes, `remoteRelayEntries` filtering on `isVirtualRelay && isAvailable` (see `issues_resolved.md`'s entry around line 1105) — so a discoverer's menu can lag behind the relay's actual end by up to that polling interval, showing a "Watch" option for a relay that's already gone. Not yet scoped: the source Mac would need to actively announce "this relay is done" the moment its last viewer drains (a UDP broadcast or an SSE-style push, mirroring how `VirtualTunerService` already announces the relay's *existence*) rather than a discoverer having to notice its absence on its own next poll. Worth deciding whether this is worth the added protocol surface versus just shortening the existing poll interval for this one case.

---

### FEED consumers should get a minimal, locally-sourced "now playing" guide/lineup — never a real SiliconDust API call

Explicit user request, 2026-09-06: a discovering instance's guide/lineup for a FEED (virtual relay) device should be a small, filtered view — just what's currently airing on the relay's one advertised channel — built from data the FEED server itself already has and serves, not fetched the way a real device's guide is. **A FEED consumer must never send a real API request to SiliconDust's servers (or attempt any cloud/device guide fetch at all) for a relay device.**

The concrete bug this request also surfaced — `probeForNewDevices()` sending a real guide-fetch request (including a TLS attempt against a plain-HTTP LAN address) for a newly-discovered relay — was fixed 2026-09-07 and is documented in `issues_resolved.md` (moved there 2026-09-11; was previously duplicated here). That fix stops the errant request outright but doesn't give a discovering instance anything to show for the relay beyond what `/lineup.json`'s existing `HdhrVCRplusShowTitle` extra already carries — the feature below is what actually would.

**The fuller feature** this TODO is really about: have `VirtualTunerService`/`WebServer` serve a deliberately minimal guide (one entry: the currently-relayed show, on its one channel — everything already known and already carried in `/lineup.json`'s `HdhrVCRplusShowTitle`/`HdhrVCRplusShowTitle`-adjacent fields, `docs/VirtualTunerService.md`'s wire-protocol notes) from a new endpoint (or reuse `/lineup.json`'s existing per-channel data directly, no new endpoint at all, if that's already sufficient for whatever UI would consume it), and have the discovering side populate a minimal `guideByDevice[relayId]` entry *from that*, never from `GuideStore.load()`'s normal cloud-guide-API/device-`/guide.json` machinery. Not yet scoped: what UI (if any) actually wants to read `guideByDevice[relayId]` once it exists — today nothing does, by `docs/VirtualTunerService.md`'s "Known limitation" note, since the relay is never listed as a pickable tuner anywhere a guide would render. Needs a concrete consumer in mind before designing the data shape, not just filling in the dictionary for its own sake.

---

### ~~Simplification ideas for the FEED client-side local relay~~ — idea 1 done 2026-09-12, ideas 2-4 resolved/superseded

Raised 2026-09-12 once the disk-backed pacing fix (`issues_resolved.md`'s "VLC-side FEED playback stalls" entry) was confirmed live; idea 1 was then done the same day.

1. **Done.** Replaced the puller-curl-to-temp-file design with an in-memory proxy (`WebServer.FeedRelayProxyDelegate`, mirroring `pumpTranscodeProxy`/`TranscodeProxyDelegate`'s existing shape) — see `docs/VirtualTunerService.md`'s "Client-side local relay" section for the full mechanics. Removed wholesale: `RecordingManager.startFeedPull`/`stopFeedPull`/`isFeedPullRunning`/`stopAllFeedPulls`/`feedPullPids`, the temp-file naming scheme and its startup orphan sweep, and the disk I/O itself.
2. **Resolved as a side effect of idea 1**, not separately fixed: with no local temp file accumulating history, there's no backlog left to replay — every new proxy connection (including a `catchUpToLive` reconnect) starts fresh at the remote's own live edge. The byte-zero-replay quirk this idea described no longer applies.
3. **Superseded** — `handleVirtualTunerStream`'s client is no longer a puller curl either; it's `WebServer`'s own in-process `URLSession`-based proxy. Re-evaluating `feedLiveEdgeCushionBytes` against that client, if ever wanted, starts from a clean slate rather than the puller-curl framing this idea was written against.
4. **Moot** — the FEED-local-relay path no longer calls `streamGrowingFile` at all (idea 1's in-memory replacement bypasses it entirely), so `stillActiveCheck`'s generalization on that function has nothing left to justify it either way; left in place since both remaining callers (`handleWatchRecording`/`handleVirtualTunerStream`) already pass one trivially and reverting it would be pure churn for no behavior change.

---

### Raw FEED passthrough (`/auto/v<channel>`) never shares one stream across multiple viewers, unlike the transcode path

Raised 2026-09-12, deliberately **not scoped or started** — an explicit "not now" from an exploratory discussion, kept here only so the tradeoff is written down rather than re-litigated from scratch later. Every viewer of the raw (non-transcoded) FEED endpoint gets its own independent `streamGrowingFile` call — its own `FileHandle`, its own read/poll loop, its own outbound send from the source Mac — confirmed live 2026-09-12 by running two simultaneous raw viewers (the app's own client-side local relay + plain VLC.app) against the same show and observing the source do the read and the send twice. This is unlike `VLCBridge.TranscodeSession` (the transcode path), which is already ref-counted — N viewers of a transcoded stream share one real encode and one output.

**Why this hasn't been changed**: sharing one raw stream the same way would need a real fan-out design, not a small tweak — a late joiner wants to start at their own live edge, not wherever a single shared reader currently sits, and a slow viewer's connection can't be allowed to block delivery to a fast one, so it'd need a per-viewer buffer/cursor into one shared upstream read rather than literally one socket fanned out. That's a legitimate broadcast-server pattern (real backpressure handling, ref-counted lifecycle mirroring `TranscodeSession`'s own), just non-trivial to get right.

**Why it's not worth it today**: this app's actual usage is normally one Mac watching another's recording — rarely more than one simultaneous raw viewer of the same show. The 2026-09-12 test that surfaced this was a deliberate double-watch for comparison purposes, not two independent real viewers. Revisit only if multiple concurrent raw viewers of the same FEED becomes an actual observed pattern, not a hypothetical one.

---

## Terminal Guide

See `docs/TUIGuide.md`'s "Deferred ideas" section for open feature gaps and known limitations.

---

## Distribution

### Universal binary — build-side change done 2026-08-19, real signed release not yet cut

`deploy_release.sh` now builds `swift build -c release --arch arm64 --arch x86_64` — SwiftPM itself
combines both slices into one fat Mach-O (no manual `lipo -create` needed, unlike originally
scoped). Output path is resolved via `swift build --show-bin-path` (same flags) rather than
hardcoded — it moved once already, from the old single-arch `.build/release/hdhr_VCR` to
`.build/apple/Products/Release/hdhr_VCR` under the classic SwiftPM "native" build system, then
again to `.build/out/Products/Release/hdhr_VCR` once Xcode 26+'s newer "swiftbuild" engine became
the default (2026-08-28) — asking the tool avoids a third hardcoded-path breakage next time this
changes. Verified: `lipo -info` on the built binary shows both `x86_64 arm64` slices; the x86_64
slice launches cleanly under Rosetta from within a real `.app` bundle (a bare binary outside one
crashes on *both* architectures identically at `UNUserNotificationCenter` — needs a real bundle
proxy — so that alone isn't an arch-specific signal; had to control for it).
`deploy.sh` (the fast local dev loop, ad-hoc signed, not shipped) deliberately stays single-arch —
doubling every local build for Intel coverage nothing local needs isn't worth the iteration-speed
cost; only what actually ships needed to change.

**Not yet done, needs a human**: an actual signed + notarized universal release has never been cut
— Developer ID codesign needs physical Touch ID presence each run (`tools/setup_signing.sh` /
`deploy_release.sh` without `--adhoc`), so this could only be build-verified, not released, in an
unattended session. `--adhoc` mode *would* run start-to-finish without Touch ID (ad-hoc `codesign
--sign -`, skips notarization), but was deliberately not run here either — it replaces the live
`hdhrVCRplus.app` bundle in place and stamps a real `CFBundleShortVersionString`/`CFBundleVersion`
into `Info.plist`, i.e. actually cutting a release artifact, not just verifying the build mechanism.
Next real release should confirm the universal binary end-to-end: `lipo -info` on the final signed
artifact, and ideally an actual smoke test on real Intel hardware (Rosetta translation isn't a
substitute — it proves the x86_64 slice's instructions are valid, not that everything the app does
behaves identically on real Intel silicon).

**Key file**: `deploy_release.sh` (build + binary-copy steps).

---

### Mac App Store distribution requires a sandbox rewrite

**Flagged 2026-08-12 as worth actively working on next**, not just a background item. Full blocker-by-blocker analysis already lives in **`docs/MAS_COMPLIANCE.md`** — do not duplicate it here, keep this pointer up to date instead. Direct-distribution notarization (Developer ID cert + `notarytool`, see `tools/setup_signing.sh` / `deploy_release.sh`, and `docs/Distribution.md`) does **not** require sandboxing and is the in-progress track as of 2026-08-08. MAS is a separate, larger track: App Sandbox is mandatory for submission, and `docs/MAS_COMPLIANCE.md` tracks the open blockers (curl subprocess spawning — three options weighed: URLSession/XPC-helper/bundled-curl, no decision made yet; VLC dlopen; security-scoped bookmarks for the recording directory, refined 2026-08-19 into a two-tier plan — see its own entry there) plus what's already done (Launch at Login via `SMAppService`, Privacy Manifest, narrowed ATS exception, and — as of 2026-08-19 — the `Process()` brew-install blocker, resolved by removing that UI entirely rather than reworking it for MAS).

**Not started.** Sequenced after direct-distribution notarization is working (which it now is).

---

### First-run/onboarding flow (mainly for the eventual MAS track)

**2026-08-19 design discussion, not yet scoped as a concrete plan.** Came up while discussing MAS blocker #5 (`docs/MAS_COMPLIANCE.md`) — a MAS install is a genuinely fresh sandbox container even for an existing direct-distribution user on the same Mac, since the two are separate containers with nothing carrying over automatically. Several independent things converge naturally into one first-launch screen:

- **Recording folder picker** — ✅ shipped: `FirstRunWizardView` Step 1's "Default folder" (`docs/FirstRunWizardView.md`). Still just a plain `NSOpenPanel` path today, no security-scoped bookmark handling — that part of this bullet only matters once the MAS/App Sandbox track (blocker #5) is actually underway; not a gap for today's direct-distribution build.
- **Import Config** — offer to import an existing config (Export/Import Config shipped 2026-08-19, `ConfigManager.importConfig(from:)`) so someone moving from direct-distribution to MAS can restore their whole show list in one step instead of rebuilding every show by hand. This is the biggest lever for making a MAS install not feel like starting over. **Still not in the wizard.**
- **Local Network permission** — ✅ shipped 2026-08-28: `FirstRunWizardView` Step 1's network-status row actively (re)runs discovery + a lineup fetch right when the wizard is on screen and explains what's happening/what to do, instead of relying on `AppState`'s own launch-time discovery firing the system prompt with nothing on screen correlated to it (`docs/FirstRunWizardView.md`'s "Network status row"). Applies to every install, not just the MAS track — this bullet turned out not to be MAS-specific despite how this entry originally grouped it.
- **VLC pointer** — a one-line "install VLC for in-app playback, e.g. `brew install --cask vlc`" link, now that the auto-install-for-you Homebrew buttons are gone (removed 2026-08-19 — didn't pull its weight, and incidentally resolved a separate MAS blocker). **Still not in the wizard** — same "applies to every install" note as Local Network permission above.

Two of four items shipped directly into `FirstRunWizardView` (2026-08-28) rather than waiting on a MAS-track-motivated rewrite — both turned out to be useful for every install, not MAS-specific. Import Config and the VLC pointer remain unstarted; revisit alongside the MAS work above, or sooner if either is wanted for direct-distribution users too.

---

## Code Quality

### `ConfigManager.save`'s disk write runs synchronously on the MainActor — resolved 2026-09-11

Scoped 2026-08-24, following up on the "web guide feels laggy" report in `ISSUES.md`. **Demoted from prime suspect to independently-worth-doing** the same day: further investigation (see `ISSUES.md`'s entry, and the `broadcastGuideChangeEvent` entry above) found and confirmed the actual root cause is the SSE broadcast payload size, not this — real synthetic disk pressure alone measurably did *not* reproduce the reported lag. Still a legitimate finding on its own merits, just not the fix for that report.

`AppState.saveConfig()` → `ConfigManager.save(_:)` did three blocking filesystem calls (remove old `.bak`, copy current config to it, atomic-write the new one) directly on `@MainActor`, called from 26 sites in `AppState.swift` covering essentially every show mutation. `WebServer` hops onto that same actor for nearly every request touching `AppState`, so a slow disk write there stalled every web request queued behind it. Same bug shape as two already-fixed call sites — `writeMetadataSidecar`/`recordedEpisodeTags` (`AppState.swift`, ~line 2826) are deliberately `nonisolated` so a slow-to-wake NAS/external drive can't block the whole app.

**Resolved**: `ConfigManager` gained a private serial `saveQueue` and a new `saveAsync(_:onFailure:)` that runs `save(_:)`'s remove/copy/atomic-write on it instead of the caller's thread — serial so writes stay in call order (no out-of-order concurrent writes leaving a stale snapshot as the final on-disk content). `AppState.saveConfig()` now snapshots `config`/`shows` synchronously (cheap struct copies) and calls `saveAsync`, reacting to a failure by hopping back to `@MainActor` to set `statusMessage`, same user-visible behavior as before. The one open question this entry flagged — whether any of the 26 call sites relies on the save completing before something else happens — turned out to matter for exactly two: the SIGTERM handler in `AppState.startup()` and `teardownForExit()` (behind `quit()`/`relaunchForVLC()`) both call `saveConfig()` immediately before the process exits. Both now call a new `configManager.flushPendingSaves()` (blocks until the serial queue drains) right after, so the final save can't be lost to the process dying before its now-async write lands. `saveConfig()`'s 24 other call sites needed no changes — none of them inspect a save's success/failure to build a response (`WebServer`'s `handleRecord`/`handleEdit`/`handleDelete` all return based on in-memory state only), so fire-and-forget is behaviorally identical to before from their point of view.

**Key files**: `ConfigManager.swift` (`saveAsync(_:onFailure:)`, `flushPendingSaves()`), `AppState.swift` (`saveConfig()`, the SIGTERM handler, `teardownForExit()`), `docs/Config.md` ("Async save"), `Tests/hdhr_VCRTests/AppState/AppStateDiskIOLatencyTests.swift` (still passes — `saveConfig()`'s own wall-clock latency is now lower, not higher, since it no longer waits on disk I/O itself).

---

### `deploy.sh`/`deploy_release.sh`'s favicon-generation heredoc is duplicated verbatim — resolved 2026-09-11

Added to `deploy_release.sh` on 2026-08-07 by copying `deploy.sh`'s existing ~13-line inline `python3` heredoc that builds `favicon.ico` from the iconset's 16×16/32×32 PNGs, rather than factoring it into one shared script. Matches this codebase's existing pattern of keeping the two deploy scripts independently self-contained (the "Deploying resources" `cp` block is duplicated the same way), so not urgent — but a future fix to the ICO-writing logic (wrong byte order, a malformed header, adding more sizes) has to be found and applied in both places, and it's easy to fix one and forget the other.

**Resolved**: extracted to `tools/generate_favicon.py` (`python3 tools/generate_favicon.py <16px.png> <32px.png> <out.ico>`); both deploy scripts now call the one shared script instead of carrying their own copy of the heredoc.

**Key file**: `tools/generate_favicon.py`.

---

### `broadcastGuideChangeEvent`'s SSE payload — gzip shipped 2026-08-31, accept-queue split shipped 2026-09-11, one structural option still open

As of the 2026-08-01 pre-release review, `broadcastGuideChangeEvent` is called from 9+ show-lifecycle sites (add/update/pause/resume/delete/favorite-toggle/duplicate-override-clear), each triggering a full page rebuild (`buildGuideGridHTML` + `buildDevBarHTML` + gzip'd `prebuildPageHTML`) on the main actor. **Confirmed 2026-08-24** (full trail in `ISSUES.md`'s entry) as the actual root cause of a live "web guide feels laggy, feels like it's stuck connecting" report — not disk I/O, not raw TCP connect time (both measured and ruled out). Root mechanism: the event embeds the *entire* guide grid HTML, uncompressed, in the SSE JSON payload — measured at ~2.2MB for one broadcast, pushed to every connected SSE client. `WebServer`'s `NWListener` and every `NWConnection` share one serial `DispatchQueue`, so those large sends compete directly with accepting brand-new connections.

**Option (b), gzip the SSE payload, shipped 2026-08-31** — see `ISSUES.md`'s entry for the full writeup. `broadcastGuideChangeEvent` now gzip+base64's grid/sumph/tdrop (new `gridZ`/`sumphZ`/`tdropZ` keys, falling back to the plain key when compression doesn't help), decoded client-side via the browser's native `DecompressionStream('gzip')`. **Measured live: one real broadcast dropped from 2,252,437 bytes to 211,466 bytes (10.65x)**, confirmed by `WebServerPerfTests.guideChangeBroadcast_isGzipCompressed`, which also round-trips the captured frame through `/usr/bin/gunzip` to catch silently-broken compression, not just "compression turned off." `apiLatency_staysResponsive_duringGuideChangeBurst()` is the regression test for the underlying report itself.

**Option (2), the listener's own accept queue, shipped 2026-09-11** — `WebServer` now runs `NWListener` (and its `stateUpdateHandler`/`stop()` cleanup) on a separate `acceptQueue` (`hdhrVCRplus.webserver.accept`) from `queue` (every accepted connection's own request/response I/O and SSE fan-out sends). Accept latency no longer scales with how many SSE clients are currently being pushed to. Doesn't shrink the payload further (already addressed by gzip) — see `docs/WebServer.md`'s "Connection model" section for the full mechanism.

**Option (1) remains undone** — doesn't touch the shared-serial-queue mechanism at all, only how many bytes move through it per broadcast:
1. Stop embedding the full grid in every SSE push at all — send a lightweight "guide_changed" notification instead, let clients pull `/api/guide-refresh` themselves. Biggest structural fix; changes the SSE contract `guide.js`'s `applyGuidePayload` currently depends on.

With `Series_subfolder_enabled && Skip_recorded_episodes` both on, each rebuild also re-scans every managed series' recording folder — an additional cost stacked on top of the above, not yet separately measured.

**Key file**: `WebServer.swift` → `broadcastGuideChangeEvent`, `broadcastEvent`, `gzipBase64`, `queue`, `acceptQueue`.

---

### RecordingManager/HDHRManager test coverage — seams added 2026-08-13, HDHRManager still has a real gap

Follow-up to the 2026-08-11 coverage-guided pass. Both files got real injection seams this session, same idea as `DiscordNotifier.swift`'s `session: URLSession = .shared` defaulted parameter (0% → 37%):

- **`HDHRManager.swift`: 1.81% → 26.74% line coverage.** Constructor injection (`init(session: URLSession? = nil, dataSession: URLSession = .shared)` — nil still builds the exact original short-timeout `URLSessionConfiguration`) since `session`/`dataSession` were already stored properties rather than per-call params. `fetchDeviceInfo`, `mDNSDiscover`, `cloudDiscover`, `knownHostsDiscover`, `supplementDeviceAuth` were widened from `private` to `internal` (pure visibility change, no behavior change) so `Tests/hdhr_VCRTests/Network/HDHRManagerTests.swift` can exercise them directly against a mocked `URLSession`/`URLProtocol` — success, malformed-JSON, HTTP-error, and network-error cases, plus `setFavorite` and the pure `supplementDeviceAuth` merge logic. **Still genuinely uncovered, and staying that way**: mDNS/UDP broadcast discovery (`udpDiscoverSync`, `subnetBroadcastAddresses`, `udpDiscoverAndFetch`) hits real `getifaddrs`/`socket`/`sendto`/`recvfrom` system calls with no seam — by far the largest remaining chunk of the file's missed lines — and the top-level `discoverDevices(knownHosts:interface:)` orchestrator, which always waits out UDP's ~2s real-broadcast timeout even with mocked HTTP, so it wasn't exercised directly either (would make the test suite slow and network-order-dependent for little unit-level gain over testing its sub-calls directly, which the new tests already do). `tools/mock_hdhr.py` could still support a slower, higher-level integration test of the whole discovery path someday, but wasn't needed for this pass's HTTP-level coverage jump.
- **`RecordingManager.swift`: 7.04% → 89.01% line coverage.** Chose the "mock-curl-script" alternative over a spawn-seam closure: added an injectable `curlExecutablePath` init parameter (default `"/usr/bin/curl"`, unchanged from the old hardcoded literal) rather than touching `spawnDetached`/`posix_spawn` at all. `Tests/hdhr_VCRTests/Recording/RecordingManagerTests.swift` points it at small per-test generated shell scripts that mimic curl's relevant behavior (write the `--dump-header` file, sleep, exit with a controlled code), then drives `start`/`stop`/`stopAll`/`isRunning`/`reattach`/`readHDHRResource`/`readAndClearHDHRError`/`readAndClearExitStatus`/sleep-assertion methods through a **real** spawned-killed-reaped process — an integration-style test (real subprocess, real timing, small `waitUntil` polling helper) rather than a pure unit test, but it exercises the actual `posix_spawn` code path unmodified. **Verbose-curl-logging branch covered 2026-09-11**: three new tests exercise `writeCurlLogHeader`/`rotateCurlVerboseLogIfNeeded` via `verbose: true` and a `curlLogPathOverride`/`rotateCurlVerboseLogIfNeeded(path:)` test seam. Remaining gap is smaller now: the orphaned-after-restart `ECHILD`/`kill(pid,0)` branch in `isRunning`, and a few unexercised `hdhrErrorLabel`/`curlExitLabel` switch cases.

`WebServer.swift` (still ~14-28%) remains the largest raw-uncovered-line file but stays lower priority per the original plan's "blast radius, not raw percentage" framing — heavily orchestration/`@MainActor`-coupled and already exercised indirectly through `GuideStore`/`ManagedGuideMatcher` test suites plus the post-deploy web server smoke/perf suites. `AppState.swift` was 20.34% at the time this note was written but see the entry below — its core scheduling engine specifically got covered 2026-08-15, moving the file to ~39%.

**Key files**: `RecordingManager.swift`, `HDHRManager.swift`, `Tests/hdhr_VCRTests/Recording/RecordingManagerTests.swift`, `Tests/hdhr_VCRTests/Network/HDHRManagerTests.swift`.

---

### AppState's recording-scheduling engine — covered 2026-08-15; `resolveSeriesAir` covered 2026-09-11

`idleLoop()`/`startRecording(index:)`/`stopRecording(index:natural:)`/`scheduleNextAir(index:)` — the
code that actually decides when a recording starts, stops, retries after failure, and reschedules —
had zero coverage despite being the app's central purpose. Blocked by `AppState.recordingManager`
being a hardcoded `let recordingManager = RecordingManager()` with no injection seam, unlike
`configManager`. Fixed the same way as the `HDHRManager`/`RecordingManager` seams above: `AppState`
now takes an optional `recordingManager: RecordingManager? = nil` init parameter (Optional rather
than a defaulted-inline parameter like `configManager`, because `RecordingManager` is `@MainActor`
and a default *parameter value* expression isn't isolated the same way the enclosing init is — the
real instance is constructed inside the init body instead). `Tests/hdhr_VCRTests/Recording/AppStateRecordingEngineTests.swift`
points it at the same mock-curl-script technique `RecordingManagerTests.swift` already used (now
shared via `TestFixtures.swift`'s `writeMockCurlScript`/`waitUntil`), driving real launches/stops/
reschedules through `makeTestAppState`. `AppState.swift`: 20.34% → 39.03% line coverage.

Also found a real, load-bearing bug in the process: `diskOK(for:)`'s `maxDiskPct: Double = 93`
was a `private let` — on a dev machine whose real disk happens to be over 93% used (true for the
machine this was found on), the real app would silently refuse to start every recording, with
`diskOK`'s own fallback-to-true path never triggering since the filesystem stats read succeeds fine.
Widened to `var` (test seam, same "widen for testability" precedent as `HDHRManager`'s methods
above) so tests unrelated to disk-space logic can override it; not a source of the coverage number
above, but a correctness finding worth knowing about. Follow-up requested same day: raised
`Min_disk_free_gb`'s default from 10 GB to 30 GB (see `issues_resolved.md` — the 93%-full check
itself is unchanged and independent, so a drive in the exact situation that surfaced this is still
correctly flagged, just for that reason alone now).

**`scheduleNextAir`'s tier-ordering covered 2026-08-24**: `Tests/hdhr_VCRTests/Recording/AppStateSeriesSchedulingTests.swift`
now exercises the `.seriesChannel`/`.seriesAll` branch's own orchestration directly — which of the
four lookup tiers (`currentEpisode` → `nextEpisode` → `currentEntryByTitle` → `nextEntryByTitle` →
no-match retry-bump) wins when more than one could match, that `seriesChannel` never follows a
same-series match onto a different channel while `seriesAll` does (and updates `show_channel` when
it does), and that a no-match tick re-syncs `show_end` off the bumped `show_next` rather than
leaving it stale. Pre-loads the mocked `GuideStore` via a direct `guideStore.load(for:)` call before
constructing `AppState` (so `isFresh` is already true and `scheduleNextAir` never re-enters its own
guide-fetch branch), a simpler variant of the request-handler-timed-to-an-`await` technique
`AppStateIdleLoopStaleIndexTests.swift` uses.

**`resolveSeriesAir` covered 2026-09-11**: `Tests/hdhr_VCRTests/Recording/AppStateResolveSeriesAirTests.swift`
exercises this separate function (called from the Add Show flow via `applyGuideEntry`, not from
`scheduleNextAir`) directly — its own tier-matching logic over `currentEpisode`/`nextEpisode`/
title-fallback candidates.

Three more gaps found by the 2026-08-16 full-codebase audit — Bonus Time (sports-genre default +
`show_end` padding arithmetic), idle-loop stale-index-across-`await` safety, and `deleteShow`'s
`discordEpisodeSnapshots` cleanup — were resolved the same day; see `issues_resolved.md`.

**Key files**: `AppState.swift`, `Tests/hdhr_VCRTests/Recording/AppStateRecordingEngineTests.swift`, `Tests/hdhr_VCRTests/Recording/AppStateIdleLoopStaleIndexTests.swift`, `Tests/hdhr_VCRTests/Recording/AppStateSeriesSchedulingTests.swift`, `Tests/hdhr_VCRTests/AppState/AppStateDeleteShowCleanupTests.swift`, `Tests/hdhr_VCRTests/TestFixtures.swift`.

---
