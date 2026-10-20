# OTAScanView

Small floating window ("Over-the-Air Scan", id `ota-scan`, 380×460, title bar, `.floating` level via `WindowAction`) that opens when an OTA scan
starts (`AppState.otaWindowRequest`; a scheduled scan opens it without taking focus). Deliberately not a modal: a blocking modal would stop
the web server and recording start/stop (the "No blocking dialogs" invariant); a floating window stays in front but the app keeps running.

- **Header:** counts of multiplexes (RF channels with a station), channels, and listings (listings hidden for a lineup-only scan).
- **Progress bar + status line:** RF channels finished / total, and which RF channels the tuners are on.
- **Tuners pulldown** (`AppState.otaTunerLimit`, 1…tuner count; id `ota-scan-tuners`): read between channels by the scanner. Lowering it
  lets the capture in progress finish and then idles that worker; raising it starts the idle worker within a second.
- **Two passes (full scan):** the progress line reads "Pass 1 of 2, channel lists: N of 49 RF channels", then "Pass 2 of 2, guides: N of M stations"; the bar and time estimate restart for each pass. After pass 1 every station row shows a dashed circle (waiting for its guide) until pass 2 reaches it.
- **List:** one row per multiplex, ordered by RF. The one being read shows its sub-channels (spinner each, listing count beside it);
  when it finishes the sub-channels collapse and the row gets a green check. Orange = a station that announces or sends no guide.
  Sub-channels of one multiplex are read together from one stream, so they finish together.
- **Footer:** count of RF channels with no signal; Cancel Scan while running, Close when done.
- **Progress bar:** RF channels finished of total, with a rough "about N min left" (average time per channel so far × channels to go; shown after 3 channels).

## Automation
Accessibility identifiers: `ota-scan-window`, `ota-scan-progress` (value "N of M RF channels"), `ota-scan-count`, `ota-scan-time-left`, `ota-scan-status`,
`ota-scan-tuners` (the pulldown), `ota-scan-cancel`, `ota-scan-close`, `ota-scan-multiplexes` / `-channels` / `-listings` (label + value), per-row
`ota-scan-mux-<RF>` (label "RF 32, 7 channels, scanning|done|no guide: …") and `ota-scan-sub-<major.minor>`. Settings: `settings-ota-scan`,
`settings-ota-lineup-scan`, `settings-ota-cancel`, `settings-ota-schedule`. Without the UI: `POST /api/ota-scan` / `GET /api/ota-status` (docs/OTAGuide.md).
