# FEED / Relay code review — 2026-09-07

Full review of all FEED-relay-related work from the 2026-09-06/07 investigation, covering commits
`3e45b82`..`HEAD` (FEED join-offset TS alignment through today's tick-diagnostics/pacing-revert
work) plus the current uncommitted working tree (relay delivery-cadence fix + VLC option tuning
from this session). Scope: `WebServer.swift` (relay/virtual-tuner routes), `VLCBridge.swift`
(playback/stall diagnostics), `VirtualTunerService.swift` (discovery).

Written incrementally, section by section, so partial progress survives if this session runs out
of budget before finishing. Findings get a verdict inline; anything real gets filed to `ISSUES.md`
at the end (or fixed directly if trivial and in-scope).

**Status: COMPLETE, all three actionable findings fixed same day.** `VirtualTunerService.stop()`'s
self-filter now keys off a dedicated `lastBroadcastDeviceID` instead of the state `stop()` itself
clears; `TranscodeProxyDelegate`'s normal-completion path now hops onto `targetQueue` like its
sibling; `streamGrowingFile`/`pumpGrowingFile`/`handleGrowingFileChunk` now pick a per-connection
chunk size (large while draining a real backlog, small once caught up to the live edge) instead of
one size for both cases. All three verified: `swift build` clean, and the chunk-size fix additionally
verified live with the raw-socket sampler against both a fresh FEED session (cadence unchanged from
the original fix) and a real Watch Now backlog (fast catch-up, still zero gaps over 200ms). See
`issues_resolved.md`'s matching entries for the full writeup. The `--prefetch-buffer-size`
unverified-effectiveness item and the two cosmetic findings were left as-is — not filed, not fixed.

---

## `handleWatchRecording` (line 596) — clean

Local Watch Now relay entry point. `show_recording` + non-empty `show_recording_path` gate is
correct (prevents replaying a finished recording's still-guessable show_id indefinitely — the
comment explains why). MainActor-only for the in-memory lookup, `fileIOQueue` for the
`fileExists` check and all real I/O — correct isolation, matches the file's stated pattern
elsewhere. No findings.

## `handleVirtualTunerStream` (line 683) — clean, one soft observation

FEED passthrough entry point. Channel/device matching, transcode-capability gating, and the
live-edge `startOffset = currentSize` (not 0) are all correct and already extensively commented
with the reasoning (avoids the byte-0 backlog-burst behavior that caused the original "beat then
stall" report). The `guard let currentSize = ... else { refuse }` (no `?? 0` fallback) is a good
defensive choice — explicitly refuses rather than silently reintroducing the exact bug it exists
to prevent.

**Soft observation, not a bug**: `sourceIsAlreadyModernCodec` and the transcode-path decision run
on `fileIOQueue` (correct — the PAT/PMT probe is real disk I/O), but `Task { @MainActor in
self.beginTranscodeRelay(...) }` and the raw-passthrough path's `Task { @MainActor in
state.relayRawViewerConnected() }` are separate, independent MainActor hops fired without waiting
for each other — order between "relayRawViewerConnected fires" and "streamGrowingFile's own first
log line" is not guaranteed relative to each other. Cosmetic only (affects log line interleaving,
not correctness — `relayRawViewerConnected`/`streamGrowingFile` don't share mutable state that
depends on ordering). Not filing.

---

## `streamGrowingFile` / `pumpGrowingFile` / `handleGrowingFileChunk` (lines 1103-1330)

**Poll-skip logic correctness (today's new code, lines 1245-1290)**: traced the `waitStreak %
stillRecordingCheckEveryNPolls == 0` branch carefully for off-by-ones and missed-cancellation
risk.
- `waitStreak == 0` on the very first call → `0 % 25 == 0` → always takes the MainActor
  still-recording check on the *first* poll, matching the old code's behavior (always checked
  immediately on reaching the live edge). Correct.
- The 24 "skip" polls in between never re-check `conn.state`/cancellation directly, but the very
  next `pumpGrowingFile` call (which every skip-branch reschedule leads back into) re-checks
  `conn.state` at its own top — so a cancelled connection is still caught within one 20ms tick,
  not stalled for up to 500ms. No missed-cancellation bug.
- `waitStreak` resets cleanly to 0 the moment real data arrives (line 1326) — confirmed the
  skip-counter can't drift out of sync with "how long has it actually been waiting."
- **No bug found in this new logic.**

**Real finding — chunk-size shrink (200→8 TS packets) adds per-byte dispatch overhead on the
*backlog-catch-up* path, not just the live-edge path this was designed for.** `watchRecordingChunkSize`
now applies unconditionally to every `pumpGrowingFile` read, not just the live-edge polling case —
including `handleWatchRecording`'s native Watch Now relay, which *can* have a large backlog to
drain quickly (e.g. right after a scrub-bar seek to an old position, or a fresh Watch Now session
joining a recording already well underway when `startOffset` matches historical, not live, bytes —
unlike `handleVirtualTunerStream`'s FEED path, which always joins at the live edge with zero
backlog by construction). With 1504-byte reads instead of 37.6KB, draining the same backlog now
takes ~23x more `fileIOQueue.async` (read) → `queue.async` (send) → `queue.async` (next pump)
round-trips — each cheap individually, but the multiplier is real and untested. The existing
"200 vs 2000 packets, no throughput difference" test cited in this size constant's own comment
tested making chunks *larger*, never smaller, and was run only against the live-edge case, not a
backlog catch-up — so it doesn't cover this scenario.
- **Impact, unverified**: likely a few hundred ms of extra dispatch overhead catching up a
  multi-MB backlog, probably not user-perceptible, but not measured either.
- **Verdict: PLAUSIBLE, not confirmed** — flagging for `ISSUES.md` rather than fixing blind; a
  30-second Watch Now seek-then-measure-catch-up-time test (old chunk size vs new) would confirm
  or clear this cheaply if it's ever suspected of causing a real regression.
- **Not filing as urgent** — the actual bug this whole day's work targeted (FEED live-edge
  cadence) doesn't touch this path at all; this is a side effect of a shared constant being reused
  across two functionally different scenarios (steady-state trickle vs. catch-up burst) that
  probably deserve different chunk sizes.

---

## `beginTranscodeRelay` / `TranscodeProxyDelegate` / `pumpTranscodeProxy` (lines 796-1009)

Not touched by today's live-cadence fix (that's the raw-passthrough path only), but was touched
earlier in this investigation window (`17ecf33`, the bounded-retry hardening) — reviewed as part
of the same feature area per the "all FEED/relay work" scope.

**Retry/backoff logic (`connectAttempt`, lines 930-972)**: traced for off-by-ones — `connectAttempt`
starts at 0, increments *before* the ceiling check (`connectAttempt += 1; guard connectAttempt <
maxConnectAttempts`), so with `maxConnectAttempts = 5` the actual attempt count allowed is
correct: the first failure increments to 1 (1 < 5, retries), ... the fourth failure increments to
4 (4 < 5, retries), the fifth failure increments to 5 (5 < 5 is false, gives up) — 5 total
`startAttempt()` calls (1 initial + 4 retries) before giving up, matching the doc comment's "up to
4 * 0.5s = 2s more" claim exactly. Correct.

**Real finding — `TranscodeProxyDelegate.urlSession(_:task:didCompleteWithError:)`'s normal-completion
branch calls `cleanup()` off `queue`, inconsistent with this same file's own stated threading
discipline.** Line ~909: the `else { finishOnce() }` branch (taken on a clean stream end, or a
real error *after* data had already started flowing) calls `onFinished` (=`cleanup`, defined in
`pumpTranscodeProxy`) directly from whatever thread URLSession's own delegate queue runs on
(`delegateQueue: nil` → a private serial `OperationQueue`, not `self.queue`) — no `queue.async`
hop. Its sibling branch two lines above (`onFailedBeforeAnyData`, called when `error != nil &&
!hadData`) *does* explicitly hop: `self.queue.async { ... }` before touching `connectAttempt`/
`conn.state`, with a comment explaining why ("TranscodeProxyDelegate's own callbacks run on
URLSession's private delegate queue, not `queue` — hop over before touching..."). The normal-
completion path never got the same treatment.
- **What `cleanup()` actually touches off-queue**: `urlSession?.invalidateAndCancel()` (a
  closure-captured local `var`, single-assigned then read-only — theoretically a data race by
  Swift's memory model for an unsynchronized cross-thread read of a `var`, though `URLSession`
  reference reads don't tear in practice on Apple's platforms), `conn.cancel()` (Apple docs:
  `NWConnection` methods are safe to call from any thread), and `Task { @MainActor in ... }` (safe
  to spawn from anywhere). **No crash risk and no shared-mutable-app-state race** — every API
  actually touched here is independently thread-safe.
- **Verdict: CONFIRMED as a real inconsistency, PLAUSIBLE-but-low-severity in impact** — doesn't
  match the file's own documented invariant, and is asymmetric with its sibling branch three lines
  up for no stated reason (most likely just an oversight when `17ecf33` added the sibling branch,
  not a deliberate choice) — but doesn't appear to cause any observable bug given what it actually
  touches is already safe cross-thread.
- **Fix, if picked up**: wrap the `else { finishOnce() }` branch in the same `self.queue.async { }`
  the sibling branch uses, for consistency and to stop relying on incidental thread-safety of the
  APIs it happens to call today.


## `VLCBridge.tickController()` (lines 698-848) — the stall-diagnostic engine this whole investigation relied on

**Confirms today's diagnosis via a mechanism I hadn't connected until reading this closely**:
`tickController()` already has an *independent*, pre-existing auto-recovery path — `guard
corruptDelta > 15 else { return }` → `catchUpToLive()` (lines 842-847) — that fires whenever
libvlc's own `i_demux_corrupted` stat jumps by more than 15 in a 3-second tick window, and logs
`"[VLC] stream corruption detected (i_demux_corrupted delta=N) — catching up to live"` when it
does. **None of today's live test sessions ever logged that line**, even during the long (20-33s)
stalls seen before today's relay-cadence fix. Since `recordingShowId` is only ever set by
`beginRecordingSeek` (called exclusively from the local `/api/watch-recording` Watch Now path —
confirmed by reading its own guard clause, line 154: `url.contains("/api/watch-recording")`), it
stays `nil` for every FEED session (`/auto/vX` URLs), so this guard (`recordingShowId == nil`)
never disarms the corruption check for FEED — it was live and watching the whole time. That the
stalls never tripped a >15-corrupted-packet threshold is corroborating evidence *against* "the
recording file itself contains genuinely corrupt/garbled TS packets" and *for* "VLC's clock-sync
logic was confused by delivery timing, not by bad bytes" — consistent with the PCR-jitter
diagnosis this whole investigation converged on. Worth keeping in mind if this ever needs
revisiting: the existing corruption-triggered auto-catchup is a different, already-working
mechanism from what was broken here.

**Minor/cosmetic finding — negative `posDeltaMs` renders as a confusing double-sign in the log.**
Lines 793/798/809: `posDeltaMs` is computed as `nowMs - lastMs` with no lower bound, and was
observed live and repeatedly during today's testing going genuinely negative (e.g. `pos=+-2992ms/
3000ms`, `pos=+-3055ms/3000ms`, `pos=+-1884ms/3000ms` — real log lines from today's session,
meaning libvlc's own reported player time actually moved *backward* between ticks, itself an
interesting corroborating data point for a PCR/clock discontinuity). The log line's format string
hardcodes a literal `"+"` before the value (`"pos=+\(posDeltaMs)ms"`), so a negative value prints
as the confusing `+-2992ms` rather than a clean `-2992ms`. Purely cosmetic — the stall-detection
logic itself handles negative values correctly (any negative value is trivially `< 0.6 *
expectedMs`, so it's correctly flagged as a stall; no crash, no wraparound risk since `Int64`
subtraction of two small millisecond timestamps can't overflow) — but it's a real, reproduced log
artifact that could confuse a future reader grepping/parsing these lines, or make someone think
it's a formatting bug in the diagnostic itself rather than a genuine signal about libvlc's clock.
- **Fix, if picked up**: drop the hardcoded `+` and let `\(posDeltaMs)` supply its own sign (Swift
  prints negative `Int64`s with a leading `-` automatically), or use `String(format: "%+d",
  posDeltaMs)` if the explicit `+` on positive values is wanted for readability. Same fix applies
  to the two other `"+\(...)"`-templated fields on the same line (`bytesDelta`, `displayDelta`,
  `lostDelta`) for consistency, though none of those were observed going negative today.

**Everything else in this function reads correctly** — state-machine handling (`libvlc_Error`/
`libvlc_Ended`/`libvlc_Playing`), the fill-phase ramp gating (`minRate >= 1.0 || currentRate >=
0.999` before ever computing stall deltas — correctly avoids flagging the ramp's own intentionally-
slower-than-realtime playback as a stall), and the `lastTickTimeMs`/`lastDisplayedPictures`/
`lastLostPictures` bookkeeping (always updated at the bottom of the `if isPlaying...` block,
unconditionally, so a skipped tick — no `mp`, no `_mpGetTime` — can't leave stale deltas for the
*next* real tick to compute against) are all sound.


## `rampedFillRate` (lines 659-672) — clean

Pure linear interpolation, correctly bounded (`newLagSec` clamped to `maxLagSec`, `fillRatio`
therefore always in `[0,1]`, `newRate` therefore always in `[minRate, 1.0]`). Matches its own
unit tests (`VLCBridgeRateRampTests.swift`, not re-run today due to the `swift test` environment
issue noted above, but the math is simple enough to verify by inspection). No findings.

## `play(url:)`'s per-media option list (lines 460-504) — one real open question

**Real finding — `--prefetch-buffer-size` is applied via `libvlc_media_add_option()` (per-media),
the exact same mechanism this file's own `--clock-jitter` attempt just demonstrated can be silently
ignored for some VLC core options** (this file's own comment, a few lines above at the
`libvlc_new()` global argv: "this codebase already found once that some core/global VLC options
are silently ignored when passed per-media and only take effect from `libvlc_new()`'s global argv"
— referring to the x264 keyint precedent, and now also `--clock-jitter` itself, moved there today
after its per-media form measurably did nothing). **`--prefetch-buffer-size` was never tested in
isolation** — it went live bundled together with the relay chunk-size/poll-interval fix in the
same build, and that combined test is what showed 78+ seconds of clean playback. There is no
direct evidence that `--prefetch-buffer-size` (still per-media, never moved to global argv) is
actually taking effect at all, as opposed to being silently ignored the same way `--clock-jitter`
was per-media — the relay-cadence fix alone might be the entire explanation, with this option
contributing nothing.
- **Verdict: PLAUSIBLE gap in verification, not a functional bug** — the option is harmless either
  way (a smaller prefetch buffer, if applied, is a reasonable a setting on its own merits; if
  silently ignored, it's simply inert code, not incorrect code).
- **Not filing as urgent** — doesn't affect correctness of anything shipped today; flagging so a
  future cleanup pass knows this is an open question, not a confirmed-working option. The
  `issues_resolved.md` entry for today's fix already flags this same uncertainty at the "three
  VLC-side tuning options... not confirmed unnecessary in combination" level; this is the sharper,
  file-level version of that same gap.
- **How to resolve, if ever picked up**: `VLC --longhelp --advanced` confirms `prefetch-buffer-size`
  is a `prefetch` stream_filter module option, not a core/instance-level one like `clock-jitter` —
  module options are conventionally demux/stream-filter-scoped and *should* work per-media (unlike
  the core input options this file already found the counterexample for), but "should" isn't
  "confirmed." A clean isolation test (this option alone, clock-jitter/relay-fix both reverted)
  against a real FEED session, checking VLC's own `--file-logging` output for the configured
  buffer size actually appearing, would settle it directly.


## `VirtualTunerService.swift` — near-real-time FEED discovery push (`3e45b82`)

Adds unsolicited `broadcastAnnounce()` on start/stop (instead of waiting for the next periodic
poll) and a passive `beginPassiveListening()` mode so other instances get near-instant FEED
appear/disappear notifications, self-filtered by DeviceID so a broadcast that loops back to the
sender's own socket isn't misread as a genuine remote announce.

**Real finding — `stop()`'s own "goodbye" broadcast is not correctly self-filtered if it loops
back, because the state the self-filter depends on is mutated in the wrong order relative to
`start()`'s.** Traced the exact sequencing in both functions (`VirtualTunerService.swift:89-105`
and `:169-186`):
- **`start()`** (line 100 → 104): `isAdvertising = true` is set, **then** `broadcastAnnounce()`
  sends the packet. If it loops back to this same socket, `handleReadable()`'s self-filter
  (`guard !(isAdvertising && announcedID == advertisedDeviceID) else { return }`) correctly sees
  `isAdvertising == true` and `advertisedDeviceID` still matching — filtered out as expected.
- **`stop()`** (line 176 → 177): `broadcastAnnounce()` sends the "goodbye" packet **first**, using
  the still-live `isAdvertising`/`advertisedDeviceID` at send time — but then **immediately**
  clears `isAdvertising = false` (and zeroes `advertisedDeviceID`) in the very next line, all
  still inside the same serial `queue.async` closure with no suspension point in between. Since
  `queue` is strictly serial and `DispatchSource`'s read-event callback for the looped-back packet
  can only run as a *separate*, later dispatch onto that same queue, by the time
  `handleReadable()` actually processes the loopback, `isAdvertising` is already `false` and
  `advertisedDeviceID` is already `0`. The self-filter's guard (`isAdvertising && announcedID ==
  advertisedDeviceID`) evaluates to `false && ...` → `false`, so `!(false)` → `true` → **the
  guard does NOT return early** — this instance's own just-sent "goodbye" packet is processed as
  if it were a genuine unsolicited announce from *another* instance, firing `onFeedAnnounce?(hex)`
  for the DeviceID of the relay that just stopped.
- **Confirmed reproducible on the same machine's own loopback** — the code's own comment already
  states "a broadcast can loop back to the sender's own socket on some setups," which is exactly
  the condition needed to trigger this; not a hypothetical.
- **Impact**: `onFeedAnnounce` is wired (per its own doc comment) to trigger an immediate
  `probeForNewDevices()` in `AppState` rather than waiting for the next idle-loop tick. A spurious
  fire right as a relay stops would trigger one extra out-of-cycle device probe for a device that's
  already gone — self-correcting (the probe would find nothing new, since the device really is
  gone) and not silently wrong, but it's a real logic inversion from the intended "ignore my own
  broadcasts" behavior, and burns one avoidable probe cycle exactly when a relay is tearing down.
- **Verdict: CONFIRMED bug, low severity (self-healing, no data corruption)**.
- **Fix, if picked up**: reorder `stop()` to clear the advertised state *after* a brief delay (or
  after confirming no loopback arrived), or — simpler and more robust — snapshot
  `advertisedDeviceID` into a local `let` before calling `broadcastAnnounce()` in `stop()` and use
  a dedicated "was this the ID I most recently stopped advertising" check instead of relying on
  `isAdvertising` (a boolean that's necessarily already flipped by the time a delayed loopback
  packet arrives). The cleanest fix is probably to keep `isAdvertising`/`advertisedDeviceID` set
  during `stop()`'s own `broadcastAnnounce()` call, and only clear them on the *next* `queue.async`
  tick (`self.queue.async { self.isAdvertising = false; ... }`) rather than synchronously in the
  same closure — that reintroduces a small window where a genuine incoming discovery *request*
  would still get an (accurate, if now-stale-by-one-tick) reply, which is likely an acceptable
  trade given the alternative is this self-filter bug.

---

# Summary

Reviewed the full FEED/relay work from `3e45b82` (FEED join-offset TS alignment) through today's
uncommitted relay-cadence fix, across `WebServer.swift` (raw-passthrough relay, transcode relay),
`VLCBridge.swift` (playback/stall diagnostics, rate ramp, per-media/global VLC options), and
`VirtualTunerService.swift` (discovery push). Six findings, ranked by severity:

1. **CONFIRMED, real bug** — `VirtualTunerService.stop()`'s self-filter fails against its own
   looped-back "goodbye" broadcast (state cleared before the loopback can arrive). Self-healing,
   low real-world impact, but a genuine logic inversion. **Filed to `ISSUES.md`.**
2. **CONFIRMED, low-severity inconsistency** — `TranscodeProxyDelegate`'s normal-completion path
   calls `cleanup()` off the file's own designated `queue`, unlike its sibling branch three lines
   up. No observed crash risk (everything it touches is independently thread-safe), but violates
   the file's own stated discipline. **Filed to `ISSUES.md`.**
3. **PLAUSIBLE, unverified** — shrinking `watchRecordingChunkSize` from 200→8 TS packets (today's
   fix) also affects the Watch Now backlog-catch-up path, not just the FEED live-edge path it was
   designed for — up to ~23x more dispatch round-trips draining a large backlog. Impact unmeasured.
   **Filed to `ISSUES.md`.**
4. **PLAUSIBLE, unverified** — `--prefetch-buffer-size` (kept from earlier today's tuning attempts)
   is applied per-media, the same mechanism `--clock-jitter` just demonstrated can be silently
   ignored for some VLC core options; never isolated from today's relay fix to confirm it's doing
   anything. Not filed as a separate `ISSUES.md` entry — already covered by the equivalent caveat
   in `issues_resolved.md`'s own write-up of today's fix.
5. **Cosmetic** — negative `posDeltaMs` values (observed live, repeatedly, today) render as a
   confusing `pos=+-2992ms` due to a hardcoded `+` in the log format string. Trivial; not filed.
6. **Cosmetic** — a benign MainActor-hop ordering nondeterminism in `handleVirtualTunerStream`
   (log-line interleaving only). Not filed.

Everything else read cleanly: `handleWatchRecording`, `handleVirtualTunerStream`'s core
matching/gating logic, the new poll-skip cadence-decoupling logic in `handleGrowingFileChunk`,
`beginTranscodeRelay`'s retry/backoff arithmetic, `tickController`'s state-machine and stall-delta
bookkeeping, and `rampedFillRate`'s math were all correct on close inspection.
