#!/usr/bin/env python3
"""Continuously mirrors a FEED URL to disk while tagging wall-clock time to
byte offset, so a later stall (read from the app log) can be sliced back out
of the exact bytes that were arriving at that moment.

Run this as a SECOND, independent reader against the same FEED URL VLC is
already watching -- the growing-file relay is built to support N independent
HTTP readers of one file (docs/VirtualTunerService.md), so this doesn't
disturb VLC's own connection or occupy a second tuner.

Usage:
    python3 feed_capture_tagger.py --url http://<source-mac>:1980/auto/v5.1?dev=<id> \\
        --out /tmp/feed_capture.ts --offsets /tmp/feed_capture.offsets.tsv

Stop with Ctrl-C once you've captured through a stall (or a few).
"""
import argparse
import sys
import time
import urllib.request


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True, help="FEED URL to mirror (same one VLC is watching)")
    parser.add_argument("--out", required=True, help="Path to write the raw captured bytes")
    parser.add_argument("--offsets", required=True, help="Path to write <epoch>\\t<cumulative_bytes> checkpoints")
    parser.add_argument("--tag-interval", type=float, default=1.0, help="Seconds between offset checkpoints (default 1s)")
    parser.add_argument("--chunk-size", type=int, default=64 * 1024, help="Read chunk size in bytes")
    args = parser.parse_args()

    # Mirrors the real HDHomeRun-shaped User-Agent path other consumers use,
    # so the source relay treats this exactly like a real client, not a bot.
    req = urllib.request.Request(args.url, headers={"User-Agent": "hdhr_VCR-feed-diagnostic/1.0"})

    cumulative = 0
    last_tag = 0.0

    with urllib.request.urlopen(req) as resp, \
            open(args.out, "wb") as out_f, \
            open(args.offsets, "w", buffering=1) as off_f:
        # First row anchors epoch 0 to byte 0 -- without this the first
        # interpolation in extract_window.py has nothing to bracket against.
        start = time.time()
        off_f.write(f"{start}\t0\n")
        print(f"[capture] started {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(start))}, writing to {args.out}", file=sys.stderr)

        try:
            while True:
                chunk = resp.read(args.chunk_size)
                if not chunk:
                    print("[capture] source closed the connection", file=sys.stderr)
                    break
                out_f.write(chunk)
                cumulative += len(chunk)

                now = time.time()
                if now - last_tag >= args.tag_interval:
                    off_f.write(f"{now}\t{cumulative}\n")
                    last_tag = now
        except KeyboardInterrupt:
            pass
        finally:
            # Always write a final checkpoint on exit so a stall right at the
            # end of the capture window still has a real bracketing offset.
            off_f.write(f"{time.time()}\t{cumulative}\n")
            print(f"[capture] stopped, {cumulative} bytes captured", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
