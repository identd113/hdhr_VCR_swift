# EpisodeSchedule

`Sources/hdhr_VCR/EpisodeSchedule.swift` — the series' own schedule from SiliconDust's cloud `api/episodes`, used so a SeriesID show is found before its airing reaches the 28 h guide window. Endpoint details: `docs/HDHRFindings.md`, "Cloud API — api/episodes".

## What it does

- **Fetch** — `GET https://api.hdhomerun.com/api/episodes?DeviceAuth=…&SeriesID=…` returns a flat JSON array of airings (a week to ~17 days ahead), or a literal `null` when nothing is upcoming. `decode` drops rows without times or a channel; `null` is an empty schedule, not a failure; any other body is a failure.
- **Horizon** — only airings starting within the next `horizon` (72 h) are used (`isInHorizon`). Later ones are ignored until a refresh brings them inside, so a show's next air time does not jump a week out.
- **Matching** — `matches` keeps one `GuideStore.SeriesMatch` per recordable device whose lineup carries the airing's channel number. The entry is a `GuideEntry` with `fromEpisodes = true` (no genre tags, so `AppState` keeps the show's known genre only for these).
- **Merging** — `GuideStore.setEpisodeAirings` stores them per series; `seriesCandidates` adds them to the guide's candidates. A guide listing wins wherever it covers the same device + channel + time (an episodes airing before the guide's first listing, or after its last, is added; one inside the span is ignored).

## Timing (all in `AppState.refreshEpisodeAirings`)

| What | Value |
|---|---|
| Refresh a series | every 3 h (`refreshInterval`) |
| Retry after a failure | 30 min (`retryInterval`) |
| Drop airings of a series that keeps failing | 6 h without a success (`staleAfter`) |
| Park a show with no airing | 1 h past the guide data; 24 h when `api/episodes` listed nothing inside the horizon (`parkPad`) |
| On-demand lookups for a series no show uses | 20 per hour (`takeOnDemandSlot`); only for series the app already knows |

One task per series; a later caller waits on the fetch already running. A guide invalidation (`invalidationEpoch`) resets the bookkeeping, and an answer that arrives after it is discarded and may be retried at once. The web endpoint `/api/airings/{seriesId}` waits at most 3 s (`waitAtMost`).

## Failures

Every failure leaves the guide-only behaviour in place and is counted as a fall-back for `series.episodes` (`docs/FeatureTracker.md`). An empty answer, or one with nothing inside the horizon, is a *use*, logged `[INFO]`.

Tests: `Tests/hdhr_VCRTests/OTAGuide/EpisodeScheduleTests.swift`.
