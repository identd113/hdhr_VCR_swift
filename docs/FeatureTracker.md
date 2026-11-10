# FeatureTracker

`Sources/hdhr_VCR/FeatureTracker.swift` — counts, in memory, how often each newer data source was used and how often the app fell back to the older method, with the last reason. Counts restart with the app.

## Keys

| Key | Newer source | Falls back to |
|---|---|---|
| `lineup.tuning` | `/lineup.json?tuning` (frequency and program per channel) | the plain lineup |
| `lineup.status` | `/lineup_status.json` (is the tuner scanning) | not asking |
| `scan.skipCovered` | the daily air scan skips RF channels the lineup already covers | scanning every RF channel |
| `scan.signalByFrequency` | one signal tune per frequency | one tune per channel |
| `series.episodes` | `api/episodes` for series scheduling | guide-only scheduling |

An answer that is valid but empty (a series with nothing upcoming, a tuner not answering at all) is not a fall-back; see `docs/EpisodeSchedule.md` and `HDHRManager.fetchTuningLineup`.

## Output

- `FeatureTracker.shared.used(key)` / `.fellBack(key, reason)`; thread-safe (`NSLock`).
- Each fall-back logs `[WARN] [Features] <key> fell back to the older method (<reason>) — used N×, fell back M×` — the first three times, then one in ten, so a persistent problem shows without flooding.
- `GET /api/feature-stats` returns the counts, last fall-back time and reason per key.

A rising fall-back rate means the newer method is failing.
