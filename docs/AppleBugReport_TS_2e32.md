# Apple Feedback draft — AVAssetReader stops early on an MPEG-TS whose timestamps cross 2^32

Ready to paste into Feedback Assistant (feedbackassistant.apple.com). Attach `make_samples.sh` and `read_samples.swift` from `tools/apple_bug_repro/` (the generated test streams are 48 MB each, so attach the script, not the files).

**Area:** AVFoundation → AVAssetReader / MPEG-2 transport stream
**Type:** Incorrect/unexpected behavior
**Regression:** unknown (first seen on the OS below)

## Title

AVAssetReader returns only ~3 frames, with no error, for an MPEG-TS whose PTS/DTS cross 2^32 (47,721.86 s on the 90 kHz clock)

## Summary

A valid MPEG-2 transport stream whose 90 kHz timestamps cross 2^32 = 4,294,967,296 partway through the file is read incorrectly by `AVURLAsset` / `AVAssetReader`: the reader delivers about 3 video frames for any time range, then reports `status == .completed` with `error == nil`. The same bytes read correctly when the timestamps are shifted by a constant so they do not cross 2^32, and when the file is entirely below or entirely above 2^32. ffprobe and ffmpeg read the original file without trouble, so the stream is valid; the PTS field is 33 bits wide and wraps only at 2^33.

This is not an exotic file: HDHomeRun network tuners (and other broadcast receivers) stamp frames with a clock that runs from power-on, so a recording that is started within a few minutes before the clock reaches 47,721.86 s (about 13.25 h after power-on, and again every 26.5 h) hits this. Our app converts such recordings to HLS with AVAssetReader/AVAssetWriter and the conversion silently produces nothing.

## Steps to reproduce

1. `tools/apple_bug_repro/make_samples.sh` (needs ffmpeg only to generate a test pattern) creates three 60-second 1280×720 59.94 fps MPEG-2 + AC-3 transport streams that differ only in their starting timestamp:
   - `before.ts` — starts at 47600 s; timestamps stay below 2^32 for the whole file
   - `across.ts` — starts at 47692 s; crosses 2^32 at 47,721.86 s, 29 s into the file
   - `after.ts` — starts at 47730 s; above 2^32 for the whole file
2. `swiftc -o read_samples read_samples.swift && ./read_samples <file>` for each file. It loads the tracks, then reads the video track with `AVAssetReader` + `AVAssetReaderTrackOutput` (NV12) for 5 s at the start and 5 s near the end and prints the frame counts.

## Expected

About 300 frames for each 5-second window (59.94 fps), for all three files.

## Actual

| file | frames, first 5 s | frames, last 5 s | reader status / error |
|---|---|---|---|
| before.ts | 300 | 300 | completed / nil |
| **across.ts** | **3** | **3** | **completed / nil** |
| after.ts | 300 | 300 | completed / nil |

The failure is not limited to the part of the file after the crossing: the first 5 seconds (29 s before the crossing) also return 3 frames. `asset.load(.duration)` is correct (59.98 s). No error is reported anywhere, so the caller cannot tell a truncated read from a real end of stream.

## What else we established (real-world file, 3.4 GB, 62 minutes of ATSC 1280×720 MPEG-2 + AC-3, first timestamp 47,535.2 s)

- Cutting the file into a piece before the crossing and a piece after it: both read correctly. A piece that spans the crossing fails (3 frames).
- Remuxing the same elementary streams with ffmpeg (timestamps rebased to start near 0): reads correctly. The program tables (PMT) are identical to a recording from the day before that reads fine; packet sync, continuity counters and PCR were checked and are clean.
- Subtracting one constant from every PTS, DTS and PCR in the original transport stream, byte for byte, with nothing else changed, makes it read correctly (600 MB spanning the crossing: 281–301 frames per 5 s window at the start, middle and end). That is the workaround we ship.

## Not isolated / other observations

- We have not found which AVFoundation component truncates the read (the TS demuxer or the sample cursor) and have not tested a wrap at 2^33 (95,443.7 s) with a proper before/after window; the 33-bit wrap is the legitimate one, so it should be checked as well.
- Separate, smaller issue seen on the same real-world file: `AVAssetTrack.load(.timeRange)` throws `AVFoundationErrorDomain -11800` (underlying `NSOSStatusErrorDomain -12990`) while `.naturalSize` and `.nominalFrameRate` load fine. The recording starts mid-GOP (57 leading frames with no sequence header). Cutting the file at the first sequence header makes `timeRange` load. We could not reproduce this one with a generated file, so it is not part of this report's reproduction.

## System

- macOS 27.2 (build 26B123), Apple silicon (arm64), Xcode command-line tools Swift toolchain
- Also observed with the same files through `AVAssetWriter`-based conversion in a shipping app (`hdhrVCRplus`)

## Workaround in our app

`Sources/hdhr_VCR/WebStreaming/TSRebaser.swift` rewrites the timestamps (PTS, DTS, PCR) by a constant before AVFoundation reads the file; details in `docs/WebStreaming.md` "Timestamp rebasing".
