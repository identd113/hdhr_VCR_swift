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
  (under 100 KB after 3 s), no guide tables after 12 s, or a station that announces no guide (15 s); otherwise 75 s.
- **`OTAStore`**: saves `ota/<DeviceID>/guide.json`, `lineup.json` and `scan.json` under Application Support/hdhrVCRplus, atomically.
  A scan that finds nothing never replaces an earlier one.
- **`AppState.startOTAScan` / `cancelOTAScan`** (`AppState+OTA.swift`): the app side; `otaScanStatus` is the status line.
- **`GuideStore.loadOTA(deviceId:)`**: indexes the saved guide like any other. Its load timestamp is the file's own, so an old scan
  never counts as fresh. It is used (1) first when `Guide_use_ota` is on, and (2) as the fallback when the cloud fetch fails and the
  device has no guide in memory (before the older on-disk cloud copy). Scans older than 36 h are ignored.

## Tuner rules (never regress)
Only tuners the hardware reports idle and this scan does not already hold; never more tuners than are free after the app's own
recordings and in-app player (`appBusyTuners`); no capture starts when a recording starts within the capture time + 30 s, and a running
one is abandoned when a recording is due within 20 s or the app takes a tuner; cancelling the task closes the stream, which frees the
tuner. The scan uses `recordableDevices` only (never the virtual relay), and is off the main actor throughout.

## Where to run it
- Settings → General → Guide: **Use the guide from the air (beta)** (`Guide_use_ota`).
- Settings → Advanced → **Over-the-Air Guide**: *Scan the Air Now* / *Cancel Scan*, with the status line.
- Web API (LAN, like the other routes): `POST /api/ota-scan` with `{"rf":[31,32],"seconds":75}` (both optional) or `{"cancel":true}`;
  `GET /api/ota-status` → `{"status":"…","running":true|false}`.

## Known gaps
No series IDs (series recording falls back on titles), no genre tags (genre dimming and the sports Bonus Time default have nothing to
read), no images. Some stations send no guide (RF 14, 21 and 26 in the Twin Cities test) or no PSIP at all. Depth varies, from about
12 hours to 3 days. Not scheduled yet: a scan runs only when asked.
