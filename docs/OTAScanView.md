# OTAScanView

The over-the-air scan window ("Over-the-Air Scan", id `ota-scan`, 520×700, title bar, `.floating` level via `WindowAction`). It opens when an
OTA scan starts (`AppState.otaWindowRequest`; a scheduled or API-started scan opens it without taking focus). Deliberately not a modal: a
blocking modal would stop the web server and recording start/stop (the "No blocking dialogs" invariant); a floating window stays in front
but the app keeps running. Fed by `OTAScanEvent`s through `OTAScanProgress` (`OTAGuide/OTAScanProgress.swift`).

![The scan window part-way through a scan](screenshots/ota-scan-window.png)
(Rendered from a test fixture, so the data rate and clock readings are not real; the lane bars read 0 s because it is a still frame.)

## Layout, top to bottom
1. **Overview card.** A title ("Scanning the air", "Reading the channel list" for a lineup-only scan; "Scan complete" / "Scan cancelled" afterwards),
   a *Pass 1 of 2 · channel lists* / *Pass 2 of 2 · guides* chip for a full scan, and the time estimate at the right ("about 6 min left";
   "estimating…" until there is something to go on; "took 14:20" afterwards). **One progress bar** (`ota-scan-progress`, value "N of M RF
   channels" / "stations"): stations finished **plus the part-way reads on each tuner**, so it moves smoothly rather than in steps of one
   station (`OTAScanProgress.fraction`). Under it the count and elapsed time, then running totals: stations found, channels, episodes.
   The estimate is the time so far scaled by that fraction (`estimatedSecondsRemaining`); it restarts with each pass.
2. **Tuner lanes.** A *Tuners* row with the **use N** pulldown (`ota-scan-tuners`, 1…tuner count; lowering it lets the read in progress finish and
   then idles that tuner, raising it starts the other within a second) and, at the right, why nothing is being read when that is so
   (`progress.note`: "Stepped aside: a tuner is needed…", "Waiting for a free tuner"). Then **one card per tuner** (`ota-scan-lane-<n>`), each in its own
   colour (teal, indigo, pink, brown):
   - a **light**: green and pulsing while reading, yellow and pulsing while locking on, orange when stepped aside for the app, grey when idle,
     "not in use" when the pulldown leaves it out, "done" when the scan has ended;
   - the station it is on (`RF 32`, `581 MHz`), a **progress bar for that read** (`ota-scan-lane-progress-<n>`: time so far against the longest it can take,
     "31 s of up to 60 s"; a read often ends sooner, so it may jump to full), and live readings (data rate, the tuner's signal %, "locking on…" first).
   A lane's state and percentage are in its accessibility value.
3. **Stations.** Tabs across the top, one per station found, in RF order, scrolling sideways (`ota-scan-tab-<RF>`): state marker (dashed circle =
   waiting for its guide, spinner = being read, green check = done, orange = sends no guide), "RF 32", channel count, and **a dot in the colour
   of each tuner currently reading it**, so a lane above and its tab match. The tab for the station being worked on is selected automatically
   and scrolled into view; click another to look at it (a **Follow** button, `ota-scan-follow`, goes back to the scan).
   The **panel** for the selected station: title with state chip and the tuner's signal (bars + quality %, `ota-scan-signal`); three tiles
   (`ota-scan-tile-channels|episodes|guide`: how many channels it carries, how many episodes are listed, **how far ahead its guide reaches**,
   or "none sent" when it announces no listing tables, "reading…" while it is still coming in); the **channel table** (`ota-scan-sub-<number>`:
   number, name, a speaker icon for audio-only channels, episodes listed, how far ahead that channel reaches, a spinner / green check per
   channel while the station is read, "no guide" when it has none); and a small footnote (`ota-scan-facts`) with the data rate over the read
   (a full multiplex is about 19.4 Mbit/s), listing tables announced, and the station's broadcast clock against this Mac's.
4. **Footer.** Count of RF channels with no signal; Cancel Scan while running, Close when done.

Channels of one station are read together from one stream, so they finish together.

## Data
`OTAScanEvent`: `queued`, `started(rf, tuner, expectedSeconds)` (puts a station on a tuner's lane), `update` / `finished` (the decode so far, bytes, seconds),
`signal` (the tuner's own reading, taken about two seconds in), `paused` (a read interrupted because a tuner was needed; it goes back in the queue),
`skipped`, `note`. `OTAScanLane` (station, start time, expected length) is what a lane draws from; `OTAMuxInfo` holds a station's facts.

## Automation
Accessibility identifiers: `ota-scan-window`, `ota-scan-progress`, `ota-scan-count`, `ota-scan-time-left`, `ota-scan-status`, `ota-scan-tuners`,
`ota-scan-lane-<n>` / `ota-scan-lane-progress-<n>`, `ota-scan-multiplexes` / `-channels` / `-listings` (label + value), `ota-scan-tab-<RF>`,
`ota-scan-mux-<RF>` (the selected station's panel), `ota-scan-follow`, `ota-scan-signal`, `ota-scan-tile-*`, `ota-scan-facts`, `ota-scan-sub-<number>`,
`ota-scan-cancel`, `ota-scan-close`. Settings: `settings-ota-scan`, `settings-ota-lineup-scan`, `settings-ota-cancel`, `settings-ota-schedule`.
Without the UI: `POST /api/ota-scan` / `GET /api/ota-status` (docs/OTAGuide.md).
