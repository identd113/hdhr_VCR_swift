#!/usr/bin/env python3
"""Slices a byte range out of a feed_capture_tagger.py capture, using its
offsets sidecar to convert a wall-clock [start,end] window (e.g. the span of
a real [VLC] STALL) into a byte range -- then aligns that range to real TS
packet boundaries so analyze_pcr.py can parse it cleanly.

Usage:
    python3 extract_window.py --src /tmp/feed_capture.ts --offsets /tmp/feed_capture.offsets.tsv \\
        --start-epoch 1757993350 --end-epoch 1757993389 --pad 3 --out /tmp/feed_stall_window.ts
"""
import argparse
import sys

TS_PACKET_SIZE = 188
TS_SYNC_BYTE = 0x47


def load_offsets(path: str):
    rows = []
    with open(path) as f:
        for line in f:
            epoch_str, bytes_str = line.strip().split("\t")
            rows.append((float(epoch_str), int(bytes_str)))
    rows.sort(key=lambda r: r[0])
    return rows


def epoch_to_byte_offset(rows, epoch: float) -> int:
    # Linear interpolation between the two checkpoints bracketing `epoch` --
    # checkpoints land every ~1s (feed_capture_tagger.py's --tag-interval),
    # so straight-line interpolation over that span is accurate enough to
    # land within a TS packet or two, which the boundary-snap below fixes up.
    if epoch <= rows[0][0]:
        return rows[0][1]
    if epoch >= rows[-1][0]:
        return rows[-1][1]
    for (t0, b0), (t1, b1) in zip(rows, rows[1:]):
        if t0 <= epoch <= t1:
            if t1 == t0:
                return b0
            frac = (epoch - t0) / (t1 - t0)
            return int(b0 + frac * (b1 - b0))
    return rows[-1][1]


def snap_to_packet_boundary(f, approx_offset: int) -> int:
    # A byte offset computed from wall-clock interpolation almost never lands
    # exactly on a 188-byte TS packet boundary. Scan forward up to one full
    # packet length for a real sync byte that also has two more sync bytes
    # exactly 188 and 376 bytes later -- three-in-a-row rules out a stray
    # 0x47 that just happens to appear inside payload data.
    f.seek(max(0, approx_offset - TS_PACKET_SIZE))
    window = f.read(TS_PACKET_SIZE * 3)
    for i in range(len(window) - TS_PACKET_SIZE * 2):
        if (window[i] == TS_SYNC_BYTE
                and window[i + TS_PACKET_SIZE] == TS_SYNC_BYTE
                and window[i + TS_PACKET_SIZE * 2] == TS_SYNC_BYTE):
            return max(0, approx_offset - TS_PACKET_SIZE) + i
    # Fell through -- just trust the unaligned offset; analyze_pcr.py will
    # still resync on its own first real sync byte.
    return approx_offset


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--src", required=True)
    parser.add_argument("--offsets", required=True)
    parser.add_argument("--start-epoch", type=float, required=True)
    parser.add_argument("--end-epoch", type=float, required=True)
    parser.add_argument("--pad", type=float, default=3.0, help="Extra seconds of context on each side")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    rows = load_offsets(args.offsets)
    start_byte = epoch_to_byte_offset(rows, args.start_epoch - args.pad)
    end_byte = epoch_to_byte_offset(rows, args.end_epoch + args.pad)

    with open(args.src, "rb") as f:
        start_byte = snap_to_packet_boundary(f, start_byte)
        end_byte = snap_to_packet_boundary(f, end_byte)
        if end_byte <= start_byte:
            print(f"[extract] empty/invalid range ({start_byte}..{end_byte}) -- capture may not cover this window", file=sys.stderr)
            return 1

        f.seek(start_byte)
        data = f.read(end_byte - start_byte)

    with open(args.out, "wb") as out_f:
        out_f.write(data)

    print(f"[extract] wrote {len(data)} bytes (file offsets {start_byte}..{end_byte}) to {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
