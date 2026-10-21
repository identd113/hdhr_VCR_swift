# Over-the-air guide (beta)

A channel list and program guide built from what stations broadcast with their TV signal (ATSC 1.0 PSIP), so the app works with no
SiliconDust guide service and no internet. Research and findings: `overtime/` (README.md, APP_PLAN.md). Code: `Sources/hdhr_VCR/OTAGuide/`.

## What it does
- **`PSIPDecoder`** (pure, streaming): decodes the Master Guide Table, Virtual Channel Table (names, `major.minor`, program numbers),
  Event Information Tables (titles, start times, lengths, TV ratings), Extended Text Tables (descriptions) and the System Time Table
  from transport-stream bytes fed in any chunk size. Every section's CRC is checked; garbage is dropped. Unit-tested with a 742 KB
  fixture of WCCO's tables (`Tests/hdhr_VCRTests/OTAGuide/`).
- **`OTAGuideConverter`**: decoded tables → `[GuideChannel]` (the model the cloud and XMLTV guides produce). Data services are not
  channels. The air carries no `SeriesID`, genre `Filter`, episode titles/numbers or images: those stay nil.
- **`OTAScanner`** (actor, off the main thread): raw-tunes `http://<tuner>:5004/tunerN/ch<Hz>` for each ATSC RF channel (2–36, 38–51),
  feeding the decoder as bytes arrive (nothing is stored). Up to `TunerCount` channels at a time. Ends a channel early on no signal
  (under 100 KB after 3 s), no guide tables after 12 s, or a station that announces no guide (15 s); otherwise 90 s (a longer capture means a deeper guide: the tables repeat, and the later ones arrive last).
- **`OTAStore`**: saves `ota/<DeviceID>/guide.json`, `lineup.json` and `scan.json` under Application Support/hdhrVCRplus, atomically.
  A scan that finds nothing never replaces an earlier one.
- **`AppState.startOTAScan` / `cancelOTAScan`** (`AppState+OTA.swift`): the app side; `otaScanStatus` is the status line.
- **`GuideStore.loadOTA(deviceId:)`**: indexes the saved guide like any other. Its load timestamp is the file's own, so an old scan
  never counts as fresh. It is used (1) first when `Guide_use_ota` is on, and (2) as the fallback when the cloud fetch fails and the
  device has no guide in memory (before the older on-disk cloud copy). Scans older than 36 h are ignored.

## Tuner rules (never regress)
The scan runs on every free tuner and gives way to anything else, so nothing needs to be predicted ahead of time:
- It uses only tuners the hardware reports idle and that this scan does not already hold, and never more than are free after the app's own
  recordings and in-app player (`appBusyTuners`). If another device in the house has taken a tuner, the scan simply works with the other one.
- Tuners the scan holds do **not** count as occupied for the app (`AppState.otaHeldResources`, `activeTunerCount`): `tunersFull` stays false
  while the scan is the only thing in the way.
- The app asks the scan to step aside before it tunes: live Watch / PiP / the in-window channel picker (`tunerAvailable` →
  `yieldOTAScan`, waits up to ~6 s) and a recording start (`startRecording` → `requestOTAYield`, starts on a later tick). The scan drops its
  captures (checked every second), takes no tuner for 12 s, and **puts the interrupted channels back at the front of its queue**
  (`paused`, not skipped); once the app's stream is up it carries on with whatever tuner is still free.
- A recording due within 20 s also makes the scan let go and wait. Cancelling the task closes the stream, which frees the tuner.
The scan uses `recordableDevices` only (never the virtual relay), and is off the main actor throughout.

## Where to run it
- Settings → General → Guide: **Use the guide from the air (beta)** (`Guide_use_ota`).
- Settings → Advanced → **Over-the-Air Guide**: *Scan the Air Now* / *Cancel Scan*, with the status line.
- Web API (LAN, like the other routes): `POST /api/ota-scan` with `{"rf":[31,32],"seconds":90,"lineupOnly":true}` (all optional), `{"tuners":1}` (sets the running scan's tuner allowance) or `{"cancel":true}`;
  `GET /api/ota-status` → `{"status","running","finished","total","multiplexes","channels","listings","tuners","tunersMax","secondsLeft"}` (`secondsLeft` -1 = unknown).

## Known gaps
No series IDs (series recording falls back on titles), no genre tags (genre dimming and the sports Bonus Time default have nothing to
read), no images. Some stations send no guide (RF 14, 21 and 26 in the Twin Cities test) or no PSIP at all. Depth varies, from about
12 hours to 3 days. 

## Quick lineup scan and schedule
- **Scan Channel List Only** (Settings → Advanced; `startOTAScan(lineupOnly: true)`): reads just the Virtual Channel Table, which repeats
  several times a second, so a channel ends after about 1.5 s (10 s cap; 3 s with no signal). A whole band takes a couple of minutes. It writes
  `lineup.json`, and `guide.json` only if none exists yet (channels with no listings); it never replaces an earlier guide or `scan.json`.
- **Rescan automatically** (`OTA_scan_hour`, Settings → Advanced; -1 = never): `AppState.startScheduledOTAScanIfDue()`, called from the idle
  loop, starts a full scan once a day from that hour on if the last scan is older than today's mark. One attempt per day. It uses the same
  tuner rules above, so it waits for idle tuners and yields to recordings and the player.
- **A full scan is two passes** (whole band, not an explicit `rf` list): pass 1 reads every RF channel's channel list (as above, about 3 min) and saves
  it at once; pass 2 reads the guide (full `seconds`) of only the stations pass 1 found that announce a guide. Stations pass 2 skips or loses keep
  their pass 1 result. A scan cancelled in pass 2 keeps the saved channel list and leaves the earlier guide untouched. (Why: on the Twin Cities test
  the air lineup matched SiliconDust's closely, so the list is worth having early; 32 of 49 RF channels carry nothing and need no guide pass.)
- **Source in the web guide:** each tuner's dropdown shows the guide source and age (`GuideStore.sourceLine`), see `docs/WebServer.md`. The channel list is still the tuner's own; the saved air `lineup.json` is not used as one yet.
- **SeriesID:** the air guide has none, so the SeriesID type is dimmed for a tuner whose guide has no series IDs (`GuideStore.guideHasNoSeriesIDs`; native form, web Type row, and `/api/record` rejects it).
- **Air lineup (developer only):** Settings → Developer can use the saved scan as the lineup (`OTAStore.lineupEntries`, tuned with `/auto/ch<Hz>-<program>`). Debug builds only; the tuner's own lineup is always used in release builds. The web guide's tuner dropdown names the lineup source.
