# OTAScanView

Small floating window ("Over-the-Air Scan", id `ota-scan`, 380×460, title bar, `.floating` level via `WindowAction`) that opens when an OTA scan
starts (`AppState.otaWindowRequest`; a scheduled scan opens it without taking focus). Deliberately not a modal: a blocking modal would stop
the web server and recording start/stop (the "No blocking dialogs" invariant); a floating window stays in front but the app keeps running.

- **Header:** counts of multiplexes (RF channels with a station), channels, and listings (listings hidden for a lineup-only scan).
- **Progress bar + status line:** RF channels finished / total, and which RF channels the tuners are on.
- **Tuners pulldown** (`AppState.otaTunerLimit`, 1…tuner count; id `ota-scan-tuners`): read between channels by the scanner. Lowering it
  lets the capture in progress finish and then idles that worker; raising it starts the idle worker within a second.
- **List:** one row per multiplex, ordered by RF. The one being read shows its sub-channels (spinner each, listing count beside it);
  when it finishes the sub-channels collapse and the row gets a green check. Orange = a station that announces or sends no guide.
  Sub-channels of one multiplex are read together from one stream, so they finish together.
- **Footer:** count of RF channels with no signal; Cancel Scan while running, Close when done.
- **Progress bar:** RF channels finished of total, with a rough "about N min left" (average time per channel so far × channels to go; shown after 3 channels).
