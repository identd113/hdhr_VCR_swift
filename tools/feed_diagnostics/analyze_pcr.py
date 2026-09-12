#!/usr/bin/env python3
"""Parses a raw MPEG-TS byte window (from extract_window.py) and reports
every PCR value and continuity-counter transition it contains, flagging
anything that would explain VLC's
'ES_OUT_SET_(GROUP_)PCR is called too late' / 'no reference clock' cascade.

This answers ISSUES.md's still-open "next step 3": is a genuine PCR
discontinuity baked into the bytes at a stall's location, or is the content
clean and the jitter purely a live-delivery-timing artifact?

Usage:
    python3 analyze_pcr.py /tmp/feed_stall_window.ts
"""
import sys

TS_PACKET_SIZE = 188
TS_SYNC_BYTE = 0x47
PCR_CLOCK_HZ = 27_000_000

# A real broadcast PCR should arrive at least every ~100ms (spec max is
# 100ms per ISO/IEC 13818-1); anything close to or beyond that gap on the
# same PID, or a PCR that moves backward, is a genuine discontinuity --
# not just "PCR is naturally sparse compared to every TS packet".
MAX_EXPECTED_PCR_GAP_SECONDS = 0.5


def find_first_sync(data: bytes) -> int:
    for i in range(len(data) - TS_PACKET_SIZE * 3):
        if (data[i] == TS_SYNC_BYTE
                and data[i + TS_PACKET_SIZE] == TS_SYNC_BYTE
                and data[i + TS_PACKET_SIZE * 2] == TS_SYNC_BYTE):
            return i
    return -1


def parse_packets(data: bytes):
    """Yields (offset, pid, continuity_counter, pcr_seconds_or_None, discontinuity_indicator) per packet."""
    start = find_first_sync(data)
    if start < 0:
        return
    offset = start
    while offset + TS_PACKET_SIZE <= len(data):
        pkt = data[offset:offset + TS_PACKET_SIZE]
        if pkt[0] != TS_SYNC_BYTE:
            # Lost sync (shouldn't happen after find_first_sync, but a
            # corrupt/truncated capture could still drift) -- rescan from here.
            resync = find_first_sync(data[offset:])
            if resync < 0:
                break
            offset += resync
            continue

        pid = ((pkt[1] & 0x1F) << 8) | pkt[2]
        adaptation_field_control = (pkt[3] >> 4) & 0x3
        continuity_counter = pkt[3] & 0xF

        pcr_seconds = None
        discontinuity_indicator = False
        # adaptation_field_control 2 or 3 means an adaptation field is present.
        if adaptation_field_control in (2, 3):
            adaptation_length = pkt[4]
            if adaptation_length > 0:
                flags = pkt[5]
                discontinuity_indicator = bool(flags & 0x80)
                pcr_flag = bool(flags & 0x10)
                if pcr_flag and adaptation_length >= 7:
                    b = pkt[6:12]
                    pcr_base = (b[0] << 25) | (b[1] << 17) | (b[2] << 9) | (b[3] << 1) | (b[4] >> 7)
                    pcr_ext = ((b[4] & 0x1) << 8) | b[5]
                    pcr_ticks = pcr_base * 300 + pcr_ext
                    pcr_seconds = pcr_ticks / PCR_CLOCK_HZ

        yield offset, pid, continuity_counter, pcr_seconds, discontinuity_indicator
        offset += TS_PACKET_SIZE


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <window.ts>", file=sys.stderr)
        return 2

    with open(sys.argv[1], "rb") as f:
        data = f.read()

    last_pcr_by_pid = {}  # pid -> (offset, seconds)
    last_cc_by_pid = {}  # pid -> (offset, continuity_counter)
    findings = []
    pcr_count = 0

    for offset, pid, cc, pcr_seconds, disc_flag in parse_packets(data):
        if disc_flag:
            findings.append(f"offset={offset} pid={pid}: discontinuity_indicator=1 set in adaptation field")

        if pcr_seconds is not None:
            pcr_count += 1
            prev = last_pcr_by_pid.get(pid)
            if prev is not None:
                prev_offset, prev_seconds = prev
                delta = pcr_seconds - prev_seconds
                if delta < 0:
                    findings.append(
                        f"offset={offset} pid={pid}: PCR went BACKWARD by {-delta*1000:.1f}ms "
                        f"(prev {prev_seconds:.6f}s @ offset={prev_offset} -> now {pcr_seconds:.6f}s)"
                    )
                elif delta > MAX_EXPECTED_PCR_GAP_SECONDS:
                    findings.append(
                        f"offset={offset} pid={pid}: PCR jumped forward {delta*1000:.1f}ms "
                        f"(prev {prev_seconds:.6f}s @ offset={prev_offset} -> now {pcr_seconds:.6f}s) "
                        f"-- exceeds {MAX_EXPECTED_PCR_GAP_SECONDS*1000:.0f}ms spec max gap"
                    )
            last_pcr_by_pid[pid] = (offset, pcr_seconds)

        # Continuity counter should increment by exactly 1 mod 16 per packet
        # carrying a payload on a given PID; a bigger jump means dropped
        # packets, a repeat means a legitimate retransmit/stuffing case.
        prev_cc = last_cc_by_pid.get(pid)
        if prev_cc is not None:
            prev_offset, prev_val = prev_cc
            expected = (prev_val + 1) % 16
            if cc != expected and cc != prev_val:
                findings.append(
                    f"offset={offset} pid={pid}: continuity counter jumped {prev_val} -> {cc} "
                    f"(expected {expected}) -- likely dropped packet(s)"
                )
        last_cc_by_pid[pid] = (offset, cc)

    print(f"Parsed window: {len(data)} bytes, {pcr_count} PCR values across {len(last_pcr_by_pid)} PID(s)")
    if not findings:
        print("No PCR discontinuities or continuity-counter anomalies found in this window.")
        print("-> the bytes on disk are clean here; the jitter is not baked into the content itself.")
    else:
        print(f"\n{len(findings)} anomaly(ies) found:")
        for line in findings:
            print(f"  {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
