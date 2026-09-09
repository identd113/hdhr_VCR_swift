# VLC bug report (draft — for manual submission to VideoLAN)

Prepared 2026-09-09 from a live investigation in `hdhr_VCR_swift` (a macOS app that relays a
live-growing HDHomeRun recording over HTTP for remote viewing). Not yet submitted — review and
edit before filing at https://code.videolan.org/videolan/vlc/-/issues (or the bugtracker VideoLAN
currently prefers).

---

## Summary

Playing an open-ended (no `Content-Length`, `Connection: close`) HTTP MPEG-TS stream — backed by a
live-growing local file, served over a real (non-loopback) network hop — intermittently loses its
PCR/program clock reference entirely and freezes the displayed picture for 60–120+ seconds, even
though the underlying TCP connection is delivering bytes continuously and without gaps the whole
time. The same stream, same server code, same client options, played over loopback (`127.0.0.1`)
never reproduces this in 12+ minutes of continuous testing. A modest but real increase in
packet-arrival jitter is present on the network hop during a stall vs. immediately after one, but
its absolute scale (tens of milliseconds, no single gap over 330ms) seems disproportionately small
to explain a 60-120+ second freeze — pointing at an overreaction in VLC's clock/PCR recovery logic
under real-world jitter, not a genuine data-availability problem.

## Environment

- VLC 3.0.23 "Vetinari" (both client and reference build), macOS 26.6.1 (25G76), Apple Silicon (ARM64)
- Loaded via `dlopen`/`libvlc.dylib` from a normal `/Applications/VLC.app` install (not a custom build)
- Two Macs on the same LAN, different `/24` subnets via a router hop; the client machine is on
  real Wi-Fi (802.11ax, 6GHz, 160MHz channel — verified -36dBm signal / -92dBm noise, 2.4Gbps PHY
  rate at the time of a captured stall, i.e. not a weak-signal condition)
- Source: a plain HTTP server (Swift `Network.framework`, not VLC/ffmpeg) reframing a
  live-growing local MPEG-2 TS file (captured via `curl` from a real ATSC 1.0/QAM HDHomeRun tuner)
  as an open-ended HTTP response — `200 OK`, `Content-Type: video/mp2t`, `Connection: close`, no
  `Content-Length`/chunked encoding, bytes forwarded as read off disk with no artificial pacing

## Reproduction

1. Start a real recording of an over-the-air broadcast (any live MPEG-2 TS source will likely do;
   this was reproduced against multiple different real channels/programs).
2. From a second machine, `GET` the growing file from the source's HTTP server as it's being
   written (join at the live edge or an arbitrary offset — reproduced both ways).
3. Play the URL in VLC over a real network path (not loopback). Let it run several minutes.
4. Intermittently (not every session, not at a fixed interval), the displayed picture freezes.
   `libvlc_media_player_get_time()` stops advancing (sometimes it reports a *negative* delta vs.
   the previous poll — the reported time moving backward) while
   `libvlc_media_get_stats().i_demux_read_bytes` keeps climbing normally the whole time.

## What the client log shows during a stall

```
[VLC-core] buffer too late (-88353 us): dropped
[VLC-core] ES_OUT_SET_(GROUP_)PCR  is called too late (jitter of 62085 ms ignored)
[VLC-core] Timestamp conversion failed for 56622507123: no reference clock
[VLC-core] Could not get display date for timestamp 0
[VLC-core] Timestamp conversion failed for 56622507123: no reference clock
[VLC-core] Could not convert timestamp 0 for FFmpeg
[VLC-core] early picture skipped
```

The PCR clock reference is lost outright ("no reference clock"), not just running behind — every
downstream timestamp conversion then fails until it re-syncs. Recovery is eventually logged as a
large catch-up: one recovery was preceded by 27 polls (~81s) frozen, then a single 3-second
sampling window with 869 pictures displayed at once (vs. a normal ~85-90/window) — consistent with
a big backlog of already-decoded-but-unschedulable frames being flushed once the clock reference is
re-established.

## What was ruled out

All of the below were tested with real, live A/B comparisons against the same recording/source:

- **Server-side chunk size**: tested both ~1.5KB and ~37.6KB per-read chunking on the relay side —
  stalls reproduced identically with both. Chunk size at the HTTP layer does not appear to be a factor.
- **An application-level "join N bytes behind the live edge" cushion feature**: tested with and
  without — stalls reproduced with both (removing it reduced apparent frequency somewhat, but did
  not eliminate the underlying issue).
- **Weak Wi-Fi signal**: independently verified excellent signal (see Environment) at the exact
  time of a captured stall.
- **A genuine TCP-level data gap**: a `tcpdump` capture across an entire 118-second stall showed
  continuous, gapless throughput (28KB–122KB/sec) in *every single second* of the stall window —
  matching the server's own application-level logs, which also showed continuous byte delivery
  throughout every observed stall.
- **Packet loss / retransmission as the direct trigger**: `tshark`'s `tcp.analysis.retransmission`/
  `tcp.analysis.out_of_order` counters were statistically indistinguishable between a stalled
  118-second window and a healthy 97-second window immediately following it on the *same*
  connection (~28% of frames flagged either way — too high to be real loss on a link otherwise
  sustaining normal throughput; likely a NIC-offload capture artifact rather than a genuine signal,
  and in any case not correlated with when the stall actually occurred).
- **`--no-ts-trust-pcr`** (stop trusting the stream's embedded PCR, derive one from packet arrival
  timing instead): made things categorically worse, not better — a fresh connection never produced
  a single displayed frame in 6+ minutes, stuck in a perpetually climbing "Buffering NN%" state.
- **`--stream-filter=record`** (exclude the "prefetch" stream_filter module from the chain
  entirely, rather than tuning its buffer size): identical failure mode to the above — 57%
  buffering, zero displayed frames, 50+ seconds, instead of the normal few-second ramp to first frame.

## What was found

- **Loopback vs. real network hop is the actual differentiator.** The identical server code,
  identical client options, playing the identical growing file via `127.0.0.1` on the source
  machine itself ran perfectly clean for 12+ continuous minutes (six manually-verified checkpoints,
  each matching real elapsed wall-clock time almost exactly, CPU actively decoding throughout, zero
  stalls). At the same time, on the same recording, a second VLC instance viewing it over the real
  cross-machine Wi-Fi hop stalled repeatedly during that identical window (an 81s stall, then a
  stall with a negative clock delta, then a sustained freeze culminating in the "no reference
  clock" log excerpt above) — a genuine simultaneous side-by-side comparison, not just sequential
  tests at different times.
- **A real but modest jitter increase during stalls.** Comparing packet-arrival inter-delta
  statistics between a 118s stall window and the 97s healthy window right after it (same
  connection): stdev 19.1ms vs. 13.2ms, 33 vs. 13 packet gaps over 100ms, no single gap over 330ms
  either way. Real, but small in absolute terms relative to the 60-120+ second freezes it appears
  to trigger — suggesting VLC's recovery from a lost PCR reference, once triggered, takes far
  longer than the network condition that triggered it, rather than the network condition itself
  being severe enough to explain the outage on its own.
- **Two independent 5-second `sample <pid>` stack captures**, taken squarely mid-stall (confirmed
  via the app's own tick log showing zero displayed frames immediately before and after each
  capture), both show the network-read thread
  (`vlc_stream_ReadPartial` → `vlc_tls_Read` → `poll`) and the "prefetch" stream_filter's own
  consumer thread (`_pthread_cond_wait`) >99% idle/blocked for the *entire* sampled window, despite
  the server's own log confirming continuous byte delivery throughout the same window.

## Hypothesis

Under real-world (non-zero, non-loopback) network jitter — even modest jitter on the order of tens
of milliseconds — VLC 3.0.23's TS demux PCR handling and/or the "prefetch" stream_filter's internal
buffering logic can enter a state where the derived PCR/program clock reference is lost outright
("no reference clock"), and recovery from that state takes vastly longer than the jitter event that
triggered it, rather than riding through it gracefully the way `ts-pcr-offsetfix`/`PCRFixHandle`
appear designed to do. This may be specific to an open-ended (no `Content-Length`, `Connection:
close`) HTTP MPEG-TS stream backed by a live-growing file joined mid-stream — as opposed to a real
broadcast tuner's own native stream, or a stream with a normal `Content-Length`/known duration —
since that's the one shape common to every reproduction and absent from the clean loopback case
only in its *network path*, not its content or framing.

## Evidence available on request (not attached — large files)

- Full `--verbose=2` VLC debug logs from multiple live episodes (routed through this app's own
  `libvlc_log_set` callback)
- Two `tcpdump` packet captures (~290MB each) spanning the exact stall episodes referenced above,
  one from each endpoint
- Two 5-second `sample <pid>` stack captures from the client machine, taken mid-stall

## Not yet tried (would strengthen this report before filing)

- A live `lldb -p <pid>` backtrace attached at the exact moment a stall begins (the `sample`
  captures above are statistical profiles over 5 seconds, not a single precise backtrace at the
  trigger instant)
- Extracting the actual PCR values from the TS bytes at the point in the recording file
  corresponding to a stall's start, to check whether the source content itself carries a genuine
  broadcast PCR discontinuity there (ad break, program boundary) that this specific delivery shape
  fails to smooth over, vs. the discontinuity being purely a symptom of network jitter with no
  correlate in the actual content
