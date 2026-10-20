# Web streaming (watch in a browser) — status and spike results

Status: **in progress on branch `feature/web-streaming-hls`** (off by default, `Web_streaming_enabled`; designed so the whole feature can be removed by deleting the branch/new files and the few hooks).

## Spike results (2026-10-19, Mac Mini M2, VLC 3.0.24)

Source: a real OTA recording (`FOX 9 … .ts`): MPEG-2 720p60 progressive, AC-3 5.1 + stereo audio.

| Question | Result |
|---|---|
| Can VLC write HLS itself? | **Yes.** `std{access=livehttp{seglen=4,…},mux=ts{use-key-frames},dst=…}` writes `live.m3u8` + `seg-########.ts`, and ends the playlist with `#EXT-X-ENDLIST` when the input ends. |
| Segment contents | H.264 High, 1280×720, yuv420p, level 3.2, 59.94 fps + AAC-LC stereo. First packet of a segment is a keyframe (with `--sout-x264-keyint=30 --sout-x264-min-keyint=30`). `ffmpeg -i live.m3u8 -f null -` decodes the whole playlist with no errors. |
| AAC encoding | Works (`acodec=mp4a`, ~128 kb/s). |
| Audio tracks | Both source audio programs are transcoded, so segments carry **two AAC tracks** (5.1→stereo and the stereo one). A single audio track must be selected for the web output. |
| VideoToolbox H.264 encoder in VLC | **Not available.** `Encoder 'h264_videotoolbox' not found` (`cannot create video chain`). A bare `venc=` without `vcodec=` silently passes the original MPEG-2 video through — a false positive to avoid. So a hardware encode needs our own AVAssetWriter route, not VLC's sout. |
| Software x264 cost | About 62 CPU-seconds for 45 s of 720p60 video at 2.5 Mb/s (≈1.4 cores per stream; it ran ~4× faster than real time using ~5 cores). |
| Segments left after exit | VLC deletes old segments by default (`delsegs`); the running session must own the folder and its cleanup. |
| Playback in browsers | See "Browser playback" below (the first attempt used a hidden automation tab, which never starts playback). |

## Spike 2: VideoToolbox outside VLC (AVFoundation), 2026-10-19

`avconvert --source <MPEG-2 .ts> --preset Preset1280x720 --duration 10` (AVFoundation + VideoToolbox) on the same recording:

| Question | Result |
|---|---|
| Can AVFoundation read the MPEG-2 / AC-3 transport stream? | **Yes**, on macOS 27.0.1 on both the Mini (M2) and the laptop (M4). Output: H.264 Main 1280×720 59.94 fps + AAC (both audio programs, 5.1 and stereo). |
| Cost | ~0.8 s CPU for 10 s of video (0.5 s on the M4), ~4 s wall including startup. Software x264 used ~14 CPU-s for the same 10 s. |
| Not yet known | macOS 15 (the app's minimum) may not read MPEG-2 TS; a still-growing file (AVAsset reads a snapshot); live tuner streams (AVFoundation does not read raw TS over HTTP); 1080i deinterlacing; the preset's bitrate (≈10 Mb/s, not tuned). |

Wider check on more recordings (10 s each, `avconvert --start 120 --duration 10`):

| Source | Output | CPU for 10 s |
|---|---|---|
| WCCO News, 1080i MPEG-2 (`field_order=tt`) → 1080p preset | H.264 1920×1080 **progressive**, 29.97 fps, AAC 5.1 + stereo; `idet` finds 201/201 frames progressive | 0.6 s user |
| same → 720p preset | H.264 1280×720 progressive, 29.97 fps | 0.4 s |
| MTV Awards, 1080i → 720p preset | H.264 1280×720 progressive | 0.8 s |
| Svengoolie, 720×480 interlaced → 640×480 preset | H.264 640×352 (16:9 kept) progressive, AAC stereo | 0.2 s |

So AVFoundation **deinterlaces 1080i/480i automatically** (the earlier "deinterlacing needed" gap is covered on this path) and handled every MPEG-2 file tried.

### Scenario tests (2026-10-19)

| Scenario | Result |
|---|---|
| Local `.ts` file, `AVAssetReader` | Works: opens in 0.1 s, decodes 300 frames of 720p60 in 0.2 s. |
| **Growing file** (a writer appends ~16 Mb/s while we convert) | Works as a **snapshot**: each pass converts whatever is on disk at open (24 s at 29 MB, then 68 s at 80 MB), no errors. A growing recording can be followed in repeated passes (re-open, read from the last timestamp). Seamless joins between passes not yet verified. |
| Plain `.ts` over HTTP (static server) | **Fails** (`byte range length mismatch`): AVFoundation needs a server that honors `Range` requests. |
| **Live tuner stream** (`http://<EXTEND>:5004/auto/v9.1`) | **Fails** (`byte range and no content length`): AVFoundation cannot read an unbounded stream. Tuner was released immediately (0/2). |
| macOS 15 | **Untestable here** (both Macs run 27.0.1). Needs a macOS 15 machine/VM before the app's minimum can be claimed. |

So the AVFoundation pipeline must read from a **local growing file**, not a URL. Live TV works the same way: spool the tuner stream into a rolling temp `.ts` (a recording that is never saved) and treat it like a growing recording. (Alternative: an `AVAssetResourceLoader` delegate that answers `Range` requests from a buffer.)

Implication: a native AVAssetReader → AVAssetWriter (H.264 hardware + AAC, HLS segment output) pipeline needs no VLC.app and is ~15× cheaper than x264, but it is file-based and must be proven for growing recordings and on older macOS. VLC remains the fallback for sources AVFoundation cannot read.

### Seamless joins between passes (2026-10-19)

A 1080i recording was written to disk at ~16 Mb/s while a follower re-opened it every 6 s and read only from just after the last frame it had (`AVAssetReader.timeRange`, stopping 1.5 s short of the snapshot end). Over 7 passes (97 s of video):

- 2817 video frames, **max timestamp gap 0.033 s (one frame at 29.97 fps), 0 duplicates**: no frame lost or repeated at any join.
- A single read of the finished file over the same span gave 2811 frames (the follower is not missing any).
- Audio blocks arrive in fixed ~0.17 s buffers (8192 samples at 48 kHz), so the 0.17 s "max gap" is one block, not a hole.

So following a growing recording in passes is sound. Keeping the last 1.5 s unread per pass avoids a half-written tail at the cost of ~1.5 s added delay.

## Browser playback (2026-10-19)

The converter's own output (1080i source → 1080p H.264 High 4 Mb/s + AAC, 40 s, fMP4 HLS) was served over plain HTTP and opened in a visible window of each browser. The page reported its state back to the server:

| Browser | Path | Result |
|---|---|---|
| Chrome (macOS 27) | hls.js 1.5.17 | Plays 1920×1080, `readyState` 4, **0 dropped frames**, 40 s buffered; no hls.js errors. |
| Safari (macOS 27) | native HLS (`video.src = index.m3u8`) | Plays 1920×1080, `readyState` 4, **0 dropped frames**. |

Audio was started muted (autoplay rules), so sound itself is unconfirmed by ear. Firefox, Edge and phones are untested (they use the same hls.js path as Chrome).

## Built so far (branch `feature/web-streaming-hls`)

- `Sources/hdhr_VCR/WebStreaming/HLSConverter.swift`: `HLSConverter.convert(input:outputDir:options:)` reads a transport-stream file with `AVAssetReader` and writes `init.mp4`, `seg-NNNNN.m4s` and `index.m3u8` (fMP4 HLS, hardware H.264 High + stereo AAC, keyframe at least every 2 s). No VLC. Interlaced video comes out progressive (checked: a 1080i WCCO clip, 301/301 frames interlaced in, 297/301 progressive out). Prototype timing: 40 s of 1080i in 6.7 s using 1.7 s CPU.
- `HLSPlaylist.swift`: pure playlist text (VOD or EVENT) and `isServableName` (the only file names the web server will ever serve).
- Tests: `HLSPlaylistTests`, `HLSConverterTests` (a 6 s synthetic MPEG-2 + AC-3 sample, `Fixtures/sample-mpeg2-ac3.ts`).
- `HLSFollower.swift`: follows a transport-stream file that is still growing (a recording, or a spooled live stream) and produces HLS as it grows: one long-lived writer, a short read pass every few seconds, the last 1.5 s of each snapshot held back, a live (EVENT) playlist while growing and the final VOD playlist when `isGrowing()` turns false. Real 1080i recording written at 2 MB/s for 40 s: finished 4.3 s after the last byte, 20 segments, 2304 frames (= 76.9 s at 29.97 fps), **0 duplicate or missing frames**, max gap one frame, audio continuous, no decode errors, progressive output. Two bugs found by this and fixed: the reader returns the previous pass's last frame again with its timestamp clamped to the range start (dropped by a half-frame margin), and `requestMediaDataWhenReady` can be called only once per writer input (so inputs are fed in timestamp order by a polling loop instead).
- Opt-in real-recording test: `HLS_REAL_SOURCE=/path/to/recording.ts swift test --filter realRecordingFollowedAtLiveSpeed` (`HLS_REAL_OUT=` keeps the output).
- Not hooked to the web server, settings or any UI yet. Nothing changes for users.

## Live test on the Mini with a real tuner (2026-10-19)

Branch build deployed, `Web_streaming_enabled` set in the config, and `tools/mock_scenario.py start` recorded channel 2.5 (720p60 MPEG-2, mono + stereo AC-3) from the EXTEND to disk.

| Check | Result |
|---|---|
| `GET /api/hls/<show>/index.m3u8` | 200 in ~2.5 s, `application/vnd.apple.mpegurl`, `Cache-Control: no-store`, EVENT playlist; init and segments `video/mp4`; `..%2F` paths, short names and unknown shows all 404 |
| Chrome (hls.js) and Safari (native) playing the live recording | Both play 1280×720 while it records; Chrome dropped ~1.4% of frames while another browser and the encoder ran |
| App CPU while streaming | ~14% at peak, ~0.4% between segments (hardware encode) |
| Stream length over a 2+ minute recording | Grows continuously (28 segments at 130 s); **found and fixed two stalls**, below |
| Recording stopped while watched | Playlist became VOD with `#EXT-X-ENDLIST` within 5 s (36 segments); `ffmpeg` decodes it over HTTP with no errors: 140 s, 8402 frames, max gap 0.018 s (one frame at 59.94 fps), 0 duplicates, AAC stereo |
| Idle cleanup | 30 s after the last request the session stopped and `Caches/hdhrVCRplus/stream/` was empty |

Stalls found by this test (neither shows up with the 6 s synthetic file, both with a real channel):
1. The writer holds one track back until the other has caught up. A loop that insisted on offering the earlier-timestamp track waited forever while the writer waited for the other one (video "not ready", audio never offered). Now it offers whichever track the writer is ready for and waits only when neither is, for a bounded time, resuming on the next pass.
2. A recording whose audio ends before its video (or lags it) left the writer holding the video back at the end: the final pass now finishes audio first, then drains the video. Regression test `finishesWhenAudioEndsBeforeVideo` (30 s timeout; fails on the old code).

Also found: a writer that has failed never becomes ready again, so every pass would wait for nothing; the follower now checks the writer's status and reports the error. Latency is ~15–18 s behind the recording (hold-back + 3 s pass interval + 4 s segments + encoder buffering); tuning is still to do.

## Test log (2026-10-19/20, Mini M2 + laptop M4, Chrome on the laptop, real tuner recordings)

Chrome on the laptop played streams served by the Mini (the laptop's Chrome first needed the macOS Local Network permission; until then only a proxy on the laptop could reach the Mini).

| # | Scenario | Result |
|---|---|---|
| 1 | HLS of a recording in progress, Chrome (hls.js) | Plays 1280×720, 0.4–0.6% dropped frames over minutes, playlist keeps growing, seek to live edge works |
| 2 | Same show, two viewers at once | One session ("started" logged once), both play with 0 dropped frames, same segment count |
| 3 | Raw recording bytes (`/api/watch-recording`) | Valid TS (sync byte every 188 B), MPEG-2 (0x02) + AC-3 (0x81); Chrome `canPlayType('video/mp2t')` is empty: **raw cannot play in a browser** |
| 4 | Raw FEED (`/auto/v5.1`) | Same: valid TS, MPEG-2 + AC-3, not playable in a browser |
| 5 | FEED H.264 (`/auto/v5.1?transcode=mobile`, software x264 in VLC) | Valid TS, stream type 0x1b (H.264) + AC-3 as private data; first bytes in 1.8 s. Still a TS, so not browser-playable; the browser path reads the recording file instead |
| 6 | Bad requests | `..%2F`, short/long/unknown names, wrong extension, NUL, 11-digit segment, unknown/traversal show ids: all 404; POST: 403 |
| 7 | Live OTA spooled to a file, raw (software path), 40 s at live speed | 13 segments, finished 3.1 s after the last byte; output H.264 1920×1080 + AAC, decodes with no ffmpeg errors |
| 8 | Live OTA with the EXTEND's hardware transcode (`?transcode=mobile`), spooled | AVFoundation reads it (H.264 1280×540 + AC-3); 13 segments, finished 1.5 s after the last byte; H.264 + AAC out, no decode errors. Video is still re-encoded (see open items) |
| 9 | Finished recording (Star Trek, 704×480) | Streams as a complete video from the start, converted at about 11× real time |
| 10 | Recording in progress joined late (NFL, 45 min in) | Joins about 2 minutes behind its end instead of converting the whole backlog |

### Bugs found and fixed
1. **Playlist timeout on a long recording**: `index.m3u8` was written only when a pass ended; the first pass over a 40-minute recording (520 MB, 268 segments) took longer than the browser's 15 s wait. Now the playlist is published as each segment lands (`SegmentSink.startPublishing`).
2. **Whole backlog converted for a late joiner** (and stored): a viewer joining a long recording now starts 2 minutes behind its end (`startBehindLive`, `StreamSessions.joinBehindLive`).
3. **Unbounded disk use**: segments were never deleted, so a 3-hour game would have written about 3 GB to Caches. A rolling window keeps the last 450 segments (30 minutes); the playlist's media sequence follows, and a playlist that has dropped its start is no longer EVENT/VOD.
4. **Finished recordings returned 404**: only shows with `show_recording` true streamed. Now the last recording file streams, converted whole from the start (no window).
5. **Log noise**: a stop was logged as "read pass failed (CancellationError)"; now silent.
6. **Fixed 4 Mb/s for every picture size** (a 704×480 show was stored like 720p): bitrate now scales with pixel count, 4 Mb/s at 720p and above, down to 1.2 Mb/s.
7. Earlier (see "Live test on the Mini"): writer deadlock, audio-ends-first stall, failed-writer detection.

8. **Chrome's built-in HLS player rejected the first live playlist** (found through the real Watch Now! button; intermittent, about 3 of 5 cold starts): a live playlist with fewer than 3 segments gives `DEMUXER_ERROR_COULD_NOT_PARSE` after about 30 ms. Segment bytes were complete and decodable, and every offline variant (7 join points of a 1080i capture, 6 of 720p60 football) played. The cause was found by serving hand-made playlists with 1, 2 and 3 segments (1 and 2 fail, 3 plays; `EXT-X-START` does not help). A live playlist is now withheld until it lists 3 segments (`HLSPlaylist.minLiveSegments`); three cold starts since: 8.7 s, 4.1 s and 3.5 s to first picture, no errors. Chrome 149 reports `maybe` for native HLS on desktop, so the Watch Now! player uses the native path there.

### Open / not built
- **Live TV from a tuner** is not wired into the app: only tested by spooling to a file and following it (rows 7–8).
- **Hardware-transcode input is re-encoded**: the tuner already gives H.264, so the cheapest path is copying that video and converting only AC-3 to AAC. The AVAssetWriter route always encodes video.
- **Watch Now! (web guide)** now exists for a recording in progress: button in the summary panel, player modal, `/api/hls-status`. The show editor (tuner dropdown → a show recording now) has the same button, reusing the row's `data-recording`. Watch Now! is for shows airing right now only; a finished recording is not offered. Still to do: a quality choice, the status bar and Record menu of the native player, live TV from a tuner.
- **Late joiners start 2 minutes behind live** and cannot seek earlier; a finished recording is only reachable once converted (about 11× real time).
- **Not tested**: audible audio, Safari/Firefox/Edge/phones on this build, macOS 15, a recording that ends while watched on the rolling-window build, two different shows at once under load.
- **Audio-only twin (built 2026-10-20):** every session also writes `audio.m3u8` (`a-init.mp4`, `a-seg-NNNNN.m4s`): the same AAC audio, no picture (about 115 kb/s), made by a second writer fed the same samples; the recording on disk is unchanged. The player registers the show name, episode and art with the Media Session API; when the page is hidden it warms up the audio stream, and Play on the iOS lock screen / Control Center starts it (coming back to the page returns to the picture). Checked on the Mini with `ffprobe` (AAC stereo 48 kHz); **not yet tested on an iPhone**. Control Center details (2026-10-20): the player builds a square 512 px JPEG data URL for the artwork itself (poster fetched through `GET /api/art?u=`, which only allows `https://img.hdhomerun.com/…`, so iOS never fetches an image), and sets `mediaSession.setPositionState` from the show's own start and end (a timeline of the show, refreshed every 5 s; from the guide tile's start/end, or from the editor row's `data-next` + `data-length` while it is airing). Still not built: audio-only *sources* (radio channels), because the converter needs a video track.
- **Edge: audio and video out of sync (reported 2026-10-20, not reproduced):** the served segments are in sync (37 segments checked, audio/video within 0.11 s, no gaps or drift), so the cause is likely Edge's handling of the audio start offset. Still needed: whether audio is early or late, constant or growing, and cold start or joining an existing session.

## Decision

Build the web stream on **AVFoundation (AVAssetReader → hardware H.264 + AAC → HLS segments)**, reading from a local growing file (a recording, or a rolling temp spool of a live tuner stream). VLC x264 stays as the fallback for sources AVFoundation cannot read, and for macOS versions where it cannot (macOS 15 unverified). Tuner hardware transcode (H.264 from the tuner, AC-3→AAC only) remains a possible live-TV shortcut, but the spool-and-convert path works for every tuner, so it is not required.
