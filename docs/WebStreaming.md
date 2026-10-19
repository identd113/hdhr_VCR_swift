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
| Playback in Chrome via hls.js | **Not verified from the automation tab** (a hidden tab never starts playback). Open the test page in a visible browser. |

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

## Decision

Phase 1 ships on **software x264 + AAC → HLS** (works today, shared per show). The VideoToolbox/AVAssetWriter encoder stays a later optimization, built only if measured CPU on the Mini justifies it. Tuner hardware transcode (H.264 from the tuner, AC-3→AAC only) is the live-TV fast path in Phase 2.
