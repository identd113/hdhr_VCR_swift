# overtime

Research for an **offline-capable** hdhrVCRplus: one that can build its own channel list and program guide from what is
on the air, with no Silicondust cloud guide and no internet. Started 2026-10-20 as a side quest from the web-streaming
work. Nothing here is wired into the app yet.

Branch: `feature/overtime` (off `main`). The sweep tool is `tools/band_sweep.py`.

## What was proven (2026-10-20, Mini + HDHomeRun EXTEND HDTC-2US at 10.0.2.101)

| Question | Answer | How it was checked |
|---|---|---|
| Can the tuner be tuned to a raw frequency? | **Yes.** `http://<ip>:5004/tunerN/ch<frequency in Hz>` | Tuned 581 and 587 MHz on the idle tuner1 while tuner0 recorded |
| Do we get the whole multiplex from one tuner? | **Yes.** One RF channel (6 MHz, about 19.4 Mb/s) arrives as one transport stream with every sub-channel in it | 7–16 programs per multiplex at 19.4–19.5 Mb/s |
| Does the lineup hide anything? | **No.** `lineup.json` and `lineup.json?show=found` both list 112 channels, none flagged audio-only | Compared the two lists |
| Is the over-the-air guide (PSIP) in the raw stream? | **Yes.** The Master Guide Table, Virtual Channel Table and system time table repeat on PID `0x1FFB` | Counted table ids in a 6 s capture of RF 32 (WCCO): 40 MGT, 15 TVCT, 6 STT |
| Is the program listing (EIT) in a short capture? | **Not reliably.** The EIT/ETT tables sit on other PIDs named in the MGT and repeat slowly; plan on a minute or two per multiplex | Not yet captured |
| Can ffmpeg (Apple Silicon build, VideoToolbox) analyse the streams? | **Yes** for video/audio; it does **not** decode PSIP tables, so a small PSIP parser is needed | `ffmpeg -hwaccels` lists videotoolbox; `h264/hevc/prores_videotoolbox` encoders exist |

A tuner can only receive **one RF channel at a time**, but everything on that RF channel comes with it, so recording the
multiplex once serves every sub-channel on it (about 8.7 GB an hour).

## Band plan used (ATSC 1.0, centre frequency of each 6 MHz channel)

- RF 2–4: 57 / 63 / 69 MHz; RF 5–6: 79 / 85 MHz; RF 7–13: 177 … 213 MHz; RF 14–51: 473 … 803 MHz (RF 37 skipped, radio astronomy).
- After the 2020 repack, stations are on RF 2–36 (plus a few on higher channels that have not moved). The sweep covered RF 2–51: nothing above RF 36.

## Twin Cities stations by RF channel (from public listings, 2023-08)

| RF | Station(s) |
|---|---|
| 9 | KMSP 9.x (Fox), the market's only VHF station |
| 16 | KPXM 41.x (Ion) |
| 23 | KTCI 2.x per one listing; another lists it as hosted on KTCA's RF 34. RF 23 showed no signal in the sweep |
| 29 | WFTC 9.x (+ WUCW Comet, Antenna TV) |
| 30 | KSTC 5.x (45TV, MeTV, getTV) |
| 31 | KARE 11.x (+ WUCW Rewind) |
| 32 | WCCO 4.x (+ WUCW Charge) |
| 34 | KTCA 2.x |
| 35 | KSTP 5.x (+ WUCW CW) |

Sources: [northpine.com Twin Cities lineup](https://northpine.com/2023/08/16/twin-cities-minneapolis-st-paul-digital-tv-channel-lineup/),
[RabbitEars Minneapolis market](https://RabbitEars.info/market.php?mktid=20),
[northpine.com on the KARE move to RF 31](https://northpine.com/2019/09/05/twin-cities-stations-frequency-change-comes-with-new-transmitter-antenna/).
(A search for the Eden Prairie cable plan found no technical frequency list; the area's cable is Comcast under a city franchise, and the tuner here receives over-the-air only.)

## Sweep result (RF 2–51, 6 s per channel; full data in `sweep-2026-10-20.json`)

Signal on 20 channels (strength / quality in %):

| RF | MHz | ss/sq | Programs | Note |
|---|---|---|---|---|
| 9 | 189 | 77/59 | 6 | KMSP, VHF. The lineup's 9.x is WFTC's simulcast on RF 29, so KMSP's own channel is not in the lineup |
| 14 | 473 | 75/90 | 4 | lineup 14 |
| 15 | 479 | 55/60 | 7 | lineup 15 |
| 16 | 485 | 56/66 | 8 | KPXM (lineup 41) |
| 17 | 491 | 48/51 | 4 | lineup 17 |
| **19** | **503** | 57/67 | 7 | **not in the lineup, not in the known station list** |
| 20 | 509 | 77/78 | 7 | lineup 43 |
| 21 | 515 | 74/85 | 16 | lineup 21 |
| 24 | 533 | 24/0 | 0 | too weak to decode |
| 25 | 539 | 81/90 | 0 | lineup 25, no decodable programs in 6 s |
| 26 | 545 | 55/65 | 3 | lineup 62 |
| 27 | 551 | 25/43 | 0 | too weak to decode |
| 29 | 563 | 96/98 | 6 | WFTC |
| 30 | 569 | 100/100 | 5 | KSTC |
| 31 | 575 | 100/100 | 8 | KARE |
| 32 | 581 | 100/90 | 7 | WCCO |
| 33 | 587 | 76/76 | 8 | lineup 33 (infomercials, Bellator MMA with a fubo Sports logo, NTD News: see `rf33-sample-frames.jpg`) |
| 34 | 593 | 81/81 | 5 | KTCA |
| 35 | 599 | 95/98 | 4 | KSTP |
| 36 | 605 | 56/42 | 0 | lineup 49, no decodable programs in 6 s |

Caveats: the "NOT IN YOUR LINEUP" flag in the tool maps only the first channel of each major number (5.1, 9.1…), so it
over-reports (KSTC on RF 30 was wrongly flagged). Run it with a mapping of every lineup channel before trusting it.
KTCI (RF 23) was expected but gave no signal. Program numbers on some multiplexes are the tuner's own (1001…), not the station's.

## What an offline app needs (nothing built yet)

1. **Channel list without the cloud:** sweep the band, read each multiplex's Virtual Channel Table (names, `major.minor`
   numbers, program numbers). Replaces the lineup scan; also finds channels the tuner's own scan skips.
2. **Guide without the cloud:** decode the EIT (titles, start times, durations, ratings) for the next ~12 hours, and ETT where
   a station sends descriptions. Expect sparse text and no images; quality varies by station. Would feed `GuideStore` as another
   source, the way `XmltvParser` does (`Guide_use_xml`).
3. **Recording by multiplex:** record an RF channel once and split programs afterwards (ffmpeg), so several shows on one RF
   channel use one tuner. The app currently records one program per `/auto/v<channel>` URL.
4. **Parts that still need a network:** show art, channel logos, Discord, updates. Decide what degrades quietly.
5. **Time:** the system time table (STT) gives the broadcast clock, usable when the Mac has no network time.

## Tool: `tools/band_sweep.py`

```
tools/band_sweep.py --ip 10.0.2.101                       # sweep RF 2-51, table + report.json
tools/band_sweep.py --ip 10.0.2.101 --channels 29-35      # just these channels
tools/band_sweep.py --ip 10.0.2.101 --map-lineup          # also find which frequency each lineup major is on (about 1 min)
tools/band_sweep.py --ip 10.0.2.101 --analyze             # re-capture 30 s, ffmpeg detectors, keep clips of interesting programs
```

- Uses one **idle** tuner only; stops if another client takes it (a 503 with the tuner now in use). Never touches the app's config or lineup.
- `--analyze` runs black / freeze / silence / scene-cut / loudness detectors per program and writes a plain-language reason when a
  program looks interesting (audio-only, frozen picture with audio, silent moving picture, a single locked camera, very fast cuts).
  The cut-rate check needs the 30 s window; 6 s windows give meaningless numbers. It keeps a stream-copied clip and a contact sheet
  for anything that scores 3 or more. The reasons are heuristics, not judgement: look at the contact sheet.
- Decoding uses VideoToolbox where the codec allows (MPEG-2 usually falls back to software); clips are copied, not re-encoded.

## Next steps (in order)

1. Run `--map-lineup` so the lineup flags are right; then `--analyze` on RF 19 and any other multiplex outside the lineup.
2. PSIP decoder (pure Python, offline): VCT first, then EIT/ETT from the PIDs the MGT names; test on RF 32 and RF 31.
3. Compare the decoded guide with the cloud guide for the same hours to see how much is missing.
4. Decide whether offline mode is a second guide source in `GuideStore` or a separate mode, and write the plan in `docs/`.
