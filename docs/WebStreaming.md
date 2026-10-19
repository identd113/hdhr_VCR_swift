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

## Decision

Phase 1 ships on **software x264 + AAC → HLS** (works today, shared per show). The VideoToolbox/AVAssetWriter encoder stays a later optimization, built only if measured CPU on the Mini justifies it. Tuner hardware transcode (H.264 from the tuner, AC-3→AAC only) is the live-TV fast path in Phase 2.
