# Offline mode: how it would fit in the app

Scope from the research: build the channel list and guide from the air when the cloud guide is not available (or not wanted).

## Why this is a small change on the reading side
`offline/guide.json` is already the app's own model: a JSON array of `GuideChannel` with `Guide: [GuideEntry]`
(`StartTime`/`EndTime` epoch seconds, `Title`, `Synopsis`, extra keys ignored). `GuideStore` decodes the cloud guide and the XMLTV
guide into the same `[GuideChannel]` and then indexes it; a third source only has to produce that array
(`GuideStore.loadXMLTV` at `GuideStore.swift:164` is the pattern: fetch, parse to `[GuideChannel]`, hand to the same install step).

## Pieces
1. **Setting:** `Guide_source` = cloud (default) / xml / over-the-air, or a `Guide_use_ota` Bool next to `Guide_use_xml` (`Models.swift:558`,
   `CodingKeys`, `init(from:)` fallback, `docs/Config.md`). Also: automatic fallback to the on-air guide when the cloud fetch fails
   (`needsRecovery`, the existing "newest on-disk guide" fallback is the natural place).
2. **Parser (Swift port of `psip.py`):** `PSIPParser`, pure and unit-tested with captured fixtures (a few seconds of RF 32 trimmed to the
   PSIP PIDs is a few hundred KB). Sections, CRC, MGT/TVCT/EIT/ETT/STT, multiple-string structure, GPS time. About 300 lines.
3. **Scanner (actor, off the main thread):** raw-tunes `http://<tuner>:5004/tunerN/ch<Hz>` with `URLSession`, reading only the PSIP PIDs
   as it goes (no need to store a 200 MB capture: filter packets on PID 0x1FFB and the EIT/ETT PIDs from the MGT), about 75 s per
   multiplex. Rules it must follow: **tuner occupancy** (`AppState.tunersFull(for:)`: use only an idle tuner, never one a recording or
   viewer holds; stop at once on a 503 with the tuner in use), `recordableDevices` only (never the virtual relay), run when idle
   (nightly, and when the cloud guide fails), cancel on quit.
4. **Lineup:** same scan gives channel names/numbers; use it to fill a lineup for a device whose own scan is empty, and to flag
   channels on the air that the tuner's lineup lacks (19.1-19.7 here). Do not replace the tuner's lineup silently.
5. **Storage:** `~/Library/Application Support/hdhrVCRplus/ota/<DeviceID>/guide.json` + `lineup.json`, written atomically; pruned by
   `CachePruner` rules (older than 36 h is stale, as for the cloud guide).
6. **UI:** a Settings row (source, last scan time, channels/events found), and a "from the air" note on the guide.

## Known gaps to design around
- No `SeriesID`: series recording by series ID cannot work; rely on the title fallback (`GuideStore` title scans). Say so in Settings.
- No genre `Filter`: genre dimming and Bonus Time's sports default need another source (title/rating heuristics, or none).
- No images: use channel icons.
- Some stations send no guide (RF 14, 21, 26 here) or no PSIP at all (RF 36): the offline guide has holes; the cloud guide has them filled.
- Guide depth varies: WCCO about 3 days, others about 12-24 hours.

## Order of work
1. **Done (2026-10-20):** Swift `PSIPDecoder` (streaming: feed it bytes in any chunk size) and `OTAGuideConverter` (to `[GuideChannel]`) in `Sources/hdhr_VCR/OTAGuide/`, with a 742 KB fixture and 7 passing tests (`Tests/hdhr_VCRTests/OTAGuide/`); output cross-checked against `overtime/psip.py`. Not wired into the app.
2. Scanner actor + a developer-only Settings button ("Scan the air now").
3. `GuideStore` source and the setting; fallback when the cloud fails.
4. Lineup comparison view.
