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

## Decision

Build the web stream on **AVFoundation (AVAssetReader → hardware H.264 + AAC → HLS segments)**, reading from a local growing file (a recording, or a rolling temp spool of a live tuner stream). VLC x264 stays as the fallback for sources AVFoundation cannot read, and for macOS versions where it cannot (macOS 15 unverified). Tuner hardware transcode (H.264 from the tuner, AC-3→AAC only) remains a possible live-TV shortcut, but the spool-and-convert path works for every tuner, so it is not required.
