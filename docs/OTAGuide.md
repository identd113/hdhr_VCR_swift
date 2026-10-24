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
  never counts as fresh. It is used (1) first when the air is the source (`OTA_always_use`, Settings → Over the Air), and (2) as the fallback (only while `OTA_enabled`) when the cloud fetch fails and the
  device has no guide in memory (before the older on-disk cloud copy). Scans older than 36 h are ignored.

## Tuner rules (never regress)
The scan runs on every free tuner and gives way to anything else, so nothing needs to be predicted ahead of time:
- It uses only tuners the hardware reports idle and that this scan does not already hold, and never more than are free after the app's own
  recordings and in-app player (`appBusyTuners`). If another device in the house has taken a tuner, the scan simply works with the other one.
- Tuners the scan holds do **not** count as occupied for the app (`AppState.otaHeldResources`, `activeTunerCount`): `tunersFull` stays false
  while the scan is the only thing in the way.
- The app asks the scan to step aside before it tunes: live Watch / PiP / the in-window channel picker (`tunerAvailable` →
  `yieldOTAScan`, waits up to ~6 s) and a recording start (`startRecording` → `requestOTAYield`, starts on a later tick). The scan drops its
  captures (checked every second), takes no tuner for 25 s, and **puts the interrupted channels back at the front of its queue**
  (`paused`, not skipped); once the app's stream is up it carries on with whatever tuner is still free.
- A recording due within 20 s also makes the scan let go and wait. Cancelling the task closes the stream, which frees the tuner.
The scan uses `recordableDevices` only (never the virtual relay), and is off the main actor throughout.

## Where to run it
- Settings → **Over the Air** (see "Scan OTA for Lineup and Guide" below): the switch, the source, the channel-list rescan, *Scan the Air Now* / *Cancel Scan*, with the status line.
- Web API (LAN): `GET /api/ota-status` → `{"status","running","finished","total","multiplexes","channels","listings","tuners","tunersMax","secondsLeft"}` (`secondsLeft` -1 = unknown). **There is no route that starts, changes or cancels a scan** (the old `POST /api/ota-scan` was removed 2026-10-24): scans are started from the app only, and the web guide shows the air data without being able to request it.

## Known gaps
No series IDs (series recording falls back on titles), no genre tags (genre dimming and the sports Bonus Time default have nothing to
read), no images. Some stations send no guide (RF 14, 21 and 26 in the Twin Cities test) or no PSIP at all. Depth varies, from about
12 hours to 3 days. 

## Quick lineup scan and schedule
- **Scan Channel List Only** (Settings → Advanced; `startOTAScan(lineupOnly: true)`): reads just the Virtual Channel Table, which repeats
  several times a second, so a channel ends after about 1.5 s (10 s cap; 3 s with no signal). A whole band takes a couple of minutes. It writes
  `lineup.json`, and `guide.json` only if none exists yet (channels with no listings); it never replaces an earlier guide or `scan.json`.
- **No scheduled guide scan** (the old `OTA_scan_hour` is unused; 2026-10-21): the full guide scan starts only after a guide failure, see "Guide failure" below. The channel list is scheduled daily (`OTA_lineup_hour`).
- **A full scan is two passes** (whole band, not an explicit `rf` list): pass 1 reads every RF channel's channel list (as above, about 3 min) and saves
  it at once; pass 2 reads the guide (full `seconds`) of only the stations pass 1 found that announce a guide. Stations pass 2 skips or loses keep
  their pass 1 result. A scan cancelled in pass 2 keeps the saved channel list and leaves the earlier guide untouched. (Why: on the Twin Cities test
  the air lineup matched SiliconDust's closely, so the list is worth having early; 32 of 49 RF channels carry nothing and need no guide pass.)
- **Source in the web guide:** each tuner's info popover shows the guide source and age (`GuideStore.sourceLine`), see `docs/WebServer.md`. The channel list is still the tuner's own; the saved air `lineup.json` is not used as one yet.
- **SeriesID:** the air guide has none, so the SeriesID type is dimmed for a tuner whose guide has no series IDs (`GuideStore.guideHasNoSeriesIDs`; native form, web Type row, and `/api/record` rejects it).
- **Air lineup (developer only):** Settings → Developer can use the saved scan as the lineup (`OTAStore.lineupEntries`, tuned with `/auto/ch<Hz>-<program>`). Debug builds only; the tuner's own lineup is always used in release builds. The web guide's tuner popover names the lineup source.

## Fallback only, and an automatic channel list (2026-10-21)
- **The air guide is only a fallback.** A shipped app never tries it before the SiliconDust guide: `AppConfig.guidePrefersAir` is false outside debug builds, and the old
  General toggle "Use the guide from the air" is gone. `GuideStore` loads the saved air guide only when a guide fetch fails and the device has no guide in memory (and
  the saved one is under 36 h old). (Superseded 2026-10-24: with the air as the source it is preferred; see below.)
- **The channel list is rescanned daily.** `OTA_lineup_hour` (default 3 = 03:00, -1 = never; Settings → Over the Air and the first-run wizard; migrated from the old `OTA_lineup_auto`) → `AppState.startScheduledOTALineupRefreshIfDue`, called from the idle loop: a
  lineup-only scan (a few minutes; the scan window opens without taking focus) once the hour has passed and the saved list is older than today's mark, at most one try a day
  (`AppState.lineupScanDue`, unit-tested). Like every scan it uses idle tuners only and steps aside for a recording or a viewer. The first-run wizard has a step that does the same scan on request.
- **Guide failure** (`AppState.offerAirGuideFallback`, called once per outage from `handleGuideLoadFailure`, only when no saved air guide under 36 h exists and no scan is running): an in-app alert (Scan Now / Not Now) and a Discord message (honors the Guide-error Discord toggle). Scan Now starts a full scan (list, then guide); Not Now ends the offer for this outage; with no answer for an hour the full scan starts by itself. The guide loading again cancels the offer (`endAirGuideFallbackOffer`). The Discord message is one-way: the answer is given in the app.

## Adaptive guide reads (2026-10-22)
A guide read (`OTAScanner.capture`, not the quick channel-list read) ends before its time cap once the picture has stopped growing: at least `OTAReadQuiet.minimum` (20 s) have passed
and the count of channels, listings and descriptions (`OTAReadQuiet.signature`) has not changed for `OTAReadQuiet.quiet` (25 s). The cap (90 s by default) still applies, so a station that keeps
trickling in listings uses all of it. Why: a station's near-term listings come round within seconds and its channel/program tables many times a second, so most stations are done long before the cap
(longer reads rarely add services or reach further; the reach is set by what the station transmits). Unit-tested as `aGuideReadStopsOnceNothingNewArrives`.

## Each multiplex is saved and dated on its own (2026-10-22)
`OTAStore.save` merges per RF channel instead of rewriting the whole saved scan. A scan **replaces** the channels (`lineup.json`) and listings (`guide.json`) of every RF channel it read, **drops** every RF channel it found
with "no signal" **twice in a row** (the first silent scan only records a miss in `mux.json`, `noSignalMisses`, and keeps everything saved; a scan that hears the station again resets the count; the whole multiplex goes together, since one RF channel carries all its sub-channels), and leaves all other multiplexes untouched, so one station can be refreshed alone (the web guide's *Refresh this multiplex's guide*, `POST /api/ota-scan {"rf":[19]}`) and a full scan is just every RF at once.
A lineup-only scan updates channel lists only (it seeds listings for channels that have none and never replaces an earlier guide). **`mux.json`** keeps `[{rf, lineupDate, guideDate, channels, events}]`: the date each multiplex's channel list
and guide were last read to the end (`OTAStore.muxRecords`; a saved scan from before it existed gets the channel-list date from `lineup.json` and no guide date). The scan window shows them under the selected multiplex's header and
the web guide's summary shows "Guide read <date>". `scan.json` (the "a full scan ran" record the wizard lines and schedule read) is still written only by a full scan. The Developer purges clear the matching dates.
Caveat: the fallback guide's 36 h age test (`GuideStore.loadOTA`, `hasFreshGuide`) looks at `guide.json`'s file date, which a one-station refresh also moves, so other multiplexes can be older than that date suggests.

Scan callbacks and saving (`AppState+OTA.swift`): the held-tuner, status-line and event callbacks all check `otaScanGeneration`, so a cancelled scan's late callbacks cannot touch a newer scan's state. Status lines are not written while the menu is open (`menuIsOpen`; the final status always is). `OTAStore.save` runs in a detached task, not on the main actor; state updates hop back after it. `savedLineup` / `lineupEntries` keep one entry per `GuideNumber` (first wins) so list and picker ids are unique.

## Scan OTA for Lineup and Guide (2026-10-24)
One switch in Settings → Over the Air decides whether the app does anything over the air (`AppConfig.OTA_enabled`, **off by default**). Off: `startOTAScan` refuses, no daily channel-list rescan
(`startScheduledOTALineupRefreshIfDue`), no guide-failure offer (`offerAirGuideFallback`), no saved-guide fallback (`GuideStore.airGuideAllowed`), no Air Only rows (`airOnlyChannels`), no gap-fill. On, there are two sources:
- **SiliconDust** (default; `OTA_always_use` false). SiliconDust's lineup and guide stay the source. The toggle **Use OTA to get guide data SiliconDust does not provide** (`OTA_fill_gaps`, default on; `AppConfig.airFillsGaps`)
  fills the gaps: the stations in the saved air lineup that the tuner's lineup lacks (the Air Only rows, watch-only) have their multiplexes read for listings, and nothing else is read.
- **The air (OTA)** (`OTA_always_use` true; `AppConfig.airReplacesSiliconDust`, which also drives `lineupFromAir` and `guidePrefersAir` in every build). The air is the lineup and guide; the fill toggle is not offered. Every saved multiplex is kept fed.

**Keeping listings from running dry** (`AppState.startScheduledOTAGapFillIfDue`, idle loop; pure rule `OTAGapFill`, unit-tested): every `checkEvery` (5 min) it reads how far ahead the saved listings of the wanted channels reach
(`OTAStore.listingCoverage`, off the main actor); each multiplex whose last listing ends within `horizon` (6 h) is read again with a normal rf-list scan (`startOTAScan(rfChannels:)`, scan window shown without focus, idle tuners only, steps aside for recordings and viewers).
Not while a scan runs or every tuner is busy. A multiplex is tried at most once an hour (`retry`); one read to the end less than a day ago that held no listings at all (a station that sends no guide) is left alone for a day (`noGuideRetry`).
It needs a saved channel list, which the daily rescan and the manual scans provide. Saving the switch or the source calls `AppState.airSourceChanged()`.

**Which multiplexes are missing** is worked out by channel number: SiliconDust's lineup has no RF or frequency, so a saved air channel with no SiliconDust match is missing and its own saved `RF`/`Frequency` names the multiplex to read (`OTAStore.airOnly`, `missingMultiplexes`). A multiplex whose channels all match is complete and never scanned; one with any missing channel is read whole (one tuner lock either way). A station the channel-list scan never heard cannot be found; a station SiliconDust numbers differently shows as missing. Listed in Settings → Over the Air → Missing from SiliconDust.

**Scanning one multiplex** is available only in the app: the embedded guide's Air Only selection posts a `scanMultiplex` message (`AddShowView`), which starts that RF channel's scan. The web server never starts a scan.
