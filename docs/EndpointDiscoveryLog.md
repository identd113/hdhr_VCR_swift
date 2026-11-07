# Endpoint Discovery Log

Running log of HDHomeRun endpoints probed for gaps (2026-10-28 session). Each entry is appended as found.
Baseline: `docs/HDHRFindings.md` ("Endpoints Currently Used", "Endpoints Not Yet Used", "Broader Endpoint Sweep").
Legend: NEW = not in HDHRFindings.md; KNOWN = already documented; 404/403 = dead.

## NEW — `GET /lineup.json?tuning` (local device, port 80) — found 2026-10-28
Same 112 channels as `/lineup.json`, but each entry also carries the RF tuning data, with no scan needed:
`TransportStreamID` (e.g. 1605), `Modulation` (`8vsb`), `Frequency` (Hz, e.g. 593000000), `ProgramNumber` (e.g. 3).
Live on 105404BE (HDTC-2US EXTEND): 17 distinct frequencies (189 / 473–605 MHz); 16 channels share 515 MHz.
`?tuning` also works on `/lineup.xml?tuning` (36 KB, same extra fields); `/lineup.m3u?tuning` is identical to plain.
`?tuning` is ignored by `/discover.json` and `/status.json`. `show=found|demo|disabled|hidden|all` and `?foo` return the plain lineup.
Nothing in Sources/ or docs/ mentions `?tuning` or `TransportStreamID`.
Why it could help: frequency + program per lineup channel is what an air-tuned (`LineupEntry.isAirTuned`) channel needs; it could
seed the OTA scanner, group channels by RF channel (shared-tuner-aware scheduling) and validate the OTA-only merge.

## KNOWN (re-verified, no new info)
`/lineup_status.json` (`SourceList: Antenna, Cable`), `/lineup.xml`, `/lineup.m3u`, `/log.html`, `/system.html`, `/tuners.html`, `/lineup.html`, `/transcode.html`, `/style.css`, `/favicon.ico`.

## Dead (404) on this device, 2026-10-28
`/status.xml /tuner0* /tunerN/vstatus /transcode.json /recorded_files.json /sys/* /ir /upgrade /version /info /health /ping /metrics /debug /scan* /channels.json /epg /guide.json /guide.xml /rss /tuners.json /network.* /settings.html /signal.* /system.json /api /cgi-bin/ /lineup_status.xml /auto` and ports 4999/443/8000/8080 (closed). Port 5004 root = 404.

## NEW — `GET https://api.hdhomerun.com/api/recording_rules?DeviceAuth=<auth>` — found 2026-10-28
`200`, body `[]` on this account (no DVR subscription/rules). `400` without DeviceAuth-style params variants (`Cmd=list`, `V=2` also `[]`/`400`),
`403` with no params. This is the account's SiliconDust cloud recording-rule list; the only doc mention is the `RecordingRules`
field inside `episodes?V=2`. Untested: what a populated list looks like (needs a DVR-subscribed account) and whether `Cmd=change`
adds/removes rules. Not worth using unless the app ever interoperates with SiliconDust's DVR.

## KNOWN cloud, re-verified 2026-10-28 (all `200` with DeviceAuth)
`api/guide`, `api/xmltv`, `api/up_next`, `api/account` (`AccountEmail: null`, `AccountDeviceIDs: [105404BE]`), `api/episodes?SeriesID=`,
`api/search?Search=`, `api/suggest?Category=`, `api.hdhomerun.com/discover?DeviceID=` (same as `/discover`; `v=2` ignored).
Dead (404): `api/{recorded_files,recording_rule,rules,series,channels,lineup(403)}`.
