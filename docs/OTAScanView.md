# OTAScanView

Small floating window ("Over-the-Air Scan", id `ota-scan`, 480×600, title bar, `.floating` level via `WindowAction`) that opens when an OTA scan
starts (`AppState.otaWindowRequest`; a scheduled scan opens it without taking focus). Deliberately not a modal: a blocking modal would stop
the web server and recording start/stop (the "No blocking dialogs" invariant); a floating window stays in front but the app keeps running.

- **Header:** counts of multiplexes (RF channels with a station), channels, and listings (listings hidden for a lineup-only scan).
- **Progress bar + status line:** RF channels finished / total, and which RF channels the tuners are on.
- **Tuners pulldown** (`AppState.otaTunerLimit`, 1…tuner count; id `ota-scan-tuners`): read between channels by the scanner. Lowering it
  lets the capture in progress finish and then idles that worker; raising it starts the idle worker within a second.
- **Two passes (full scan):** the progress line reads "Pass 1 of 2, channel lists: N of 49 RF channels", then "Pass 2 of 2, guides: N of M stations"; the bar and time estimate restart for each pass. After pass 1 every station row shows a dashed circle (waiting for its guide) until pass 2 reaches it.
- **Tabs (top):** one per station found, in RF order, scrolling sideways (`ota-scan-tab-<RF>`): the state marker (dashed circle = waiting for its guide, spinner = being read, green check = done, orange = sends no guide or failed), "RF 32" and the channel count. **The tab for the station being worked on is selected automatically** and scrolled into view as the scan moves on; click any tab to look at another one instead, and a **Follow** button (`ota-scan-follow`) appears to go back to the scan.
- **Station panel (selected tab):** a title (`RF 32 · 581 MHz`, state) and a two-column grid of facts about the station (ids `ota-scan-fact-<name>`):
  *Carries* (channel count, the major numbers such as 4.x, 23.x, audio-only count), *Guide* (episode count and how far ahead it reaches, or "none sent" when the station announces no listing tables), *Oldest listing* (start of the earliest program), *Listing tables* (how many the station announced), *Signal* (the tuner's own strength/quality % read a couple of seconds in), *Data rate* (average Mbit/s over the read; a full multiplex is about 19.4) and *Station clock* (its broadcast clock vs this Mac's). Below it, **each channel** (`4.1  WCCO-DT`) with "103 episodes · from Tue 1:00 PM" (episode count and the start of its earliest listing), a spinner while it is being read, "no guide" when it has none. Sub-channels of one multiplex are read together from one stream, so they finish together.
- **Footer:** count of RF channels with no signal; Cancel Scan while running, Close when done.
- **Progress bar:** RF channels finished of total, with a rough "about N min left" (average time per channel so far × channels to go; shown after 3 channels).

## Automation
Accessibility identifiers: `ota-scan-window`, `ota-scan-progress` (value "N of M RF channels"), `ota-scan-count`, `ota-scan-time-left`, `ota-scan-status`,
`ota-scan-tuners` (the pulldown), `ota-scan-cancel`, `ota-scan-close`, `ota-scan-multiplexes` / `-channels` / `-listings` (label + value), per-row
`ota-scan-tab-<RF>` / `ota-scan-mux-<RF>` (the selected station's panel; label "RF 32, 7 channels, scanning|done|no guide: …"), `ota-scan-follow`, `ota-scan-fact-*` and `ota-scan-sub-<major.minor>`. Settings: `settings-ota-scan`,
`settings-ota-lineup-scan`, `settings-ota-cancel`, `settings-ota-schedule`. Without the UI: `POST /api/ota-scan` / `GET /api/ota-status` (docs/OTAGuide.md).

## Automation
Accessibility identifiers: `ota-scan-window`, `ota-scan-progress` (value "N of M RF channels"), `ota-scan-count`, `ota-scan-time-left`, `ota-scan-status`,
`ota-scan-tuners` (the pulldown), `ota-scan-cancel`, `ota-scan-close`, `ota-scan-multiplexes` / `-channels` / `-listings` (label + value), per-row
`ota-scan-tab-<RF>` / `ota-scan-mux-<RF>` (the selected station's panel; label "RF 32, 7 channels, scanning|done|no guide: …"), `ota-scan-follow`, `ota-scan-fact-*` and `ota-scan-sub-<major.minor>`. Settings: `settings-ota-scan`,
`settings-ota-lineup-scan`, `settings-ota-cancel`, `settings-ota-schedule`. Without the UI: `POST /api/ota-scan` / `GET /api/ota-status` (docs/OTAGuide.md).

## Channels and episodes
A station's channels (number and name) are listed as soon as they are known: while it is being read, and while it waits for its guide after the channel-list pass. A finished station folds them away; the chevron (`ota-scan-expand-<RF>`) unfolds them. Each channel line reads "103 episodes · from Tue 1:00 PM": the count of programs listed for it and the start of the earliest one (usually the show on the air when it was read). A channel with no listings says "no guide". The header counts "episodes" (id `ota-scan-listings`, unchanged).

![The scan window part-way through a scan](screenshots/ota-scan-window.png)
(Rendered with a test fixture: its data rate and station clock are not real readings.)
