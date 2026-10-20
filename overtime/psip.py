#!/usr/bin/env python3
"""ATSC PSIP decoder: turns a captured over-the-air multiplex (MPEG transport stream) into a channel list and a program guide.

Pure Python, no network, no dependencies. Reads the tables every ATSC 1.0 station broadcasts (A/65):
  MGT  (0xC7)  Master Guide Table  - names the PIDs that carry the other tables
  TVCT (0xC8)  Terrestrial Virtual Channel Table - channel names, major.minor numbers, program numbers
  EIT  (0xCB)  Event Information Table - titles, start times, durations (4 tables = about 12 h, more on some stations)
  ETT  (0xCC)  Extended Text Table - longer descriptions (many stations send none)
  STT  (0xCD)  System Time Table - the broadcast clock (GPS seconds) and the GPS-UTC offset

  overtime/psip.py capture.ts            # print channels and guide
  overtime/psip.py capture.ts --json out.json

Capture at least 60-120 s of a multiplex first (tools/band_sweep.py keeps 6 s per channel: enough for channel names, not the guide).
Text strings use the A/65 multiple-string structure; Huffman-compressed strings (rare in the US) are reported as "(compressed)".
"""
import argparse, datetime, json, struct, sys
from collections import defaultdict

PSIP_BASE_PID = 0x1FFB
GPS_EPOCH = datetime.datetime(1980, 1, 6, tzinfo=datetime.timezone.utc)

# ---------------------------------------------------------------- MPEG-2 sections

_CRC_TABLE = []
for _i in range(256):
    _c = _i << 24
    for _ in range(8):
        _c = ((_c << 1) ^ 0x04C11DB7) if _c & 0x80000000 else (_c << 1)
    _CRC_TABLE.append(_c & 0xFFFFFFFF)


def crc32_mpeg(data):
    crc = 0xFFFFFFFF
    for b in data:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ _CRC_TABLE[((crc >> 24) ^ b) & 0xFF]
    return crc


def sections_from_ts(path, wanted_pids=None):
    """Yields (pid, section_bytes) for every complete, CRC-valid section on the wanted PIDs (all PIDs when None)."""
    buffers = {}
    with open(path, "rb") as f:
        while True:
            pkt = f.read(188)
            if len(pkt) < 188:
                return
            if pkt[0] != 0x47:
                # lost sync: resync on the next 0x47 that repeats 188 bytes later
                rest = pkt + f.read(188 * 3)
                i = next((k for k in range(1, len(rest) - 188) if rest[k] == 0x47 and rest[k + 188] == 0x47), None)
                if i is None:
                    continue
                f.seek(-(len(rest) - i), 1)
                continue
            pid = ((pkt[1] & 0x1F) << 8) | pkt[2]
            if wanted_pids is not None and pid not in wanted_pids:
                continue
            if not (pkt[3] & 0x10):   # no payload
                continue
            payload_start = 4
            if pkt[3] & 0x20:
                payload_start += 1 + pkt[4]
            payload = pkt[payload_start:]
            pusi = bool(pkt[1] & 0x40)
            buf = buffers.get(pid)
            if pusi:
                if not payload:
                    continue
                pointer = payload[0]
                if buf is not None and pointer:
                    buf += payload[1:1 + pointer]
                    yield from _drain(pid, buf, buffers)
                buffers[pid] = bytearray(payload[1 + pointer:])
                yield from _drain(pid, buffers[pid], buffers)
            elif buf is not None:
                buf += payload
                yield from _drain(pid, buf, buffers)


def _drain(pid, buf, buffers):
    """Pops every complete section off the front of buf (several can share a packet)."""
    while len(buf) >= 3:
        if buf[0] == 0xFF:   # stuffing
            buf.clear()
            return
        length = 3 + (((buf[1] & 0x0F) << 8) | buf[2])
        if len(buf) < length:
            return
        sec = bytes(buf[:length])
        del buf[:length]
        if crc32_mpeg(sec) == 0:
            yield pid, sec


# ---------------------------------------------------------------- A/65 text and time

def decode_mss(b):
    """Multiple string structure -> first string (any language). Compressed strings are not expanded."""
    if not b:
        return ""
    n = b[0]
    pos = 1
    out = []
    for _ in range(n):
        if pos + 4 > len(b):
            break
        pos += 3                      # ISO 639 language
        segs = b[pos]; pos += 1
        text = ""
        for _ in range(segs):
            if pos + 3 > len(b):
                break
            comp, mode, nbytes = b[pos], b[pos + 1], b[pos + 2]
            pos += 3
            raw = b[pos:pos + nbytes]; pos += nbytes
            if comp != 0:
                text += "(compressed)"
            elif mode == 0:
                text += raw.decode("latin-1", "replace")
            elif mode == 0x3F:
                text += raw.decode("utf-16-be", "replace")
            else:                      # other Unicode ranges: the high byte is the mode
                text += "".join(chr((mode << 8) | c) for c in raw)
        out.append(text)
    return out[0] if out else ""


def gps_to_utc(gps_seconds, leap_seconds):
    return GPS_EPOCH + datetime.timedelta(seconds=gps_seconds - leap_seconds)


# ---------------------------------------------------------------- tables

def parse_mgt(sec):
    """-> list of (table_type, pid, version, number_bytes)."""
    n = (sec[9] << 8) | sec[10]
    pos, out = 11, []
    for _ in range(n):
        ttype = (sec[pos] << 8) | sec[pos + 1]
        pid = ((sec[pos + 2] & 0x1F) << 8) | sec[pos + 3]
        version = sec[pos + 4] & 0x1F
        nbytes = struct.unpack(">I", sec[pos + 5:pos + 9])[0]
        dlen = ((sec[pos + 9] & 0x0F) << 8) | sec[pos + 10]
        out.append((ttype, pid, version, nbytes))
        pos += 11 + dlen
    return out


def parse_tvct(sec):
    n = sec[9]
    pos, out = 10, []
    for _ in range(n):
        name = sec[pos:pos + 14].decode("utf-16-be", "replace").rstrip("\x00")
        major = ((sec[pos + 14] & 0x0F) << 6) | (sec[pos + 15] >> 2)
        minor = ((sec[pos + 15] & 0x03) << 8) | sec[pos + 16]
        modulation = sec[pos + 17]
        freq = struct.unpack(">I", sec[pos + 18:pos + 22])[0]
        tsid = (sec[pos + 22] << 8) | sec[pos + 23]
        program = (sec[pos + 24] << 8) | sec[pos + 25]
        flags = (sec[pos + 26] << 8) | sec[pos + 27]
        source_id = (sec[pos + 28] << 8) | sec[pos + 29]
        dlen = ((sec[pos + 30] & 0x03) << 8) | sec[pos + 31]
        out.append({
            "name": name, "major": major, "minor": minor, "number": f"{major}.{minor}",
            "modulation": modulation, "tsid": tsid, "program": program, "source_id": source_id,
            "service_type": flags & 0x3F,   # 2 = digital TV, 3 = audio, 4 = data
            "hidden": bool(flags & 0x1000), "access_controlled": bool(flags & 0x2000), "hide_guide": bool(flags & 0x0200),
        })
        pos += 32 + dlen
    return out


def parse_eit(sec):
    """-> (source_id, [event dicts with start as GPS seconds])."""
    source_id = (sec[3] << 8) | sec[4]
    n = sec[9]
    pos, out = 10, []
    for _ in range(n):
        event_id = ((sec[pos] & 0x3F) << 8) | sec[pos + 1]
        start = struct.unpack(">I", sec[pos + 2:pos + 6])[0]
        length = ((sec[pos + 6] & 0x0F) << 16) | (sec[pos + 7] << 8) | sec[pos + 8]
        tlen = sec[pos + 9]
        title = decode_mss(sec[pos + 10:pos + 10 + tlen])
        pos += 10 + tlen
        dlen = ((sec[pos] & 0x0F) << 8) | sec[pos + 1]
        rating = _rating_from(sec[pos + 2:pos + 2 + dlen])
        pos += 2 + dlen
        out.append({"event_id": event_id, "start_gps": start, "length_s": length, "title": title, "rating": rating})
    return source_id, out


def _rating_from(descriptors):
    """Content advisory descriptor (0x87): returns the first rating value's abbreviated text if present, else ''."""
    pos = 0
    while pos + 2 <= len(descriptors):
        tag, ln = descriptors[pos], descriptors[pos + 1]
        body = descriptors[pos + 2:pos + 2 + ln]
        if tag == 0x87 and body:
            regions = body[0] & 0x3F
            p = 1
            for _ in range(regions):
                if p + 2 > len(body):
                    break
                dims = body[p + 1]
                p += 2
                for _ in range(dims):
                    if p + 2 > len(body):
                        break
                    p += 2
                if p < len(body):
                    dlen = body[p]; p += 1
                    text = decode_mss(body[p:p + dlen])
                    if text:
                        return text
                    p += dlen
        pos += 2 + ln
    return ""


def parse_ett(sec):
    """-> (source_id, event_id, text) for an event ETT (ETM id with low bits 10); None for a channel ETT."""
    etm = struct.unpack(">I", sec[9:13])[0]
    if etm & 0x3 != 2:
        return None
    return (etm >> 16) & 0xFFFF, (etm >> 2) & 0x3FFF, decode_mss(sec[13:-4])


def parse_stt(sec):
    return struct.unpack(">I", sec[9:13])[0], sec[13]   # GPS seconds, GPS-UTC offset


# ---------------------------------------------------------------- driver

def decode_capture(path):
    # Pass 1: the base PID tells us where everything else lives.
    base = {"mgt": None, "tvct": {}, "stt": None}
    for _pid, sec in sections_from_ts(path, {PSIP_BASE_PID}):
        tid = sec[0]
        if tid == 0xC7 and base["mgt"] is None:
            base["mgt"] = parse_mgt(sec)
        elif tid == 0xC8:
            for ch in parse_tvct(sec):
                base["tvct"][ch["source_id"]] = ch
        elif tid == 0xCD and base["stt"] is None:
            base["stt"] = parse_stt(sec)
    if base["mgt"] is None:
        raise SystemExit("No Master Guide Table found: capture too short, or not an ATSC 1.0 multiplex.")
    leap = base["stt"][1] if base["stt"] else 18
    eit_pids = {pid for t, pid, _v, _n in base["mgt"] if 0x0100 <= t <= 0x017F}
    ett_pids = {pid for t, pid, _v, _n in base["mgt"] if 0x0200 <= t <= 0x027F}
    # Pass 2: guide tables.
    events = {}      # (source_id, event_id) -> dict
    seen_sections = set()
    descr = {}
    for pid, sec in sections_from_ts(path, eit_pids | ett_pids):
        key = (pid, sec[0], sec[3], sec[4], sec[5], sec[6], sec[7])   # same table, same version, same section: once
        if key in seen_sections:
            continue
        seen_sections.add(key)
        if sec[0] == 0xCB:
            sid, evs = parse_eit(sec)
            for e in evs:
                events[(sid, e["event_id"])] = dict(e, source_id=sid)
        elif sec[0] == 0xCC:
            r = parse_ett(sec)
            if r:
                descr[(r[0], r[1])] = r[2]
    for k, e in events.items():
        e["start_utc"] = gps_to_utc(e["start_gps"], leap).isoformat()
        e["description"] = descr.get(k, "")
    channels = sorted(base["tvct"].values(), key=lambda c: (c["major"], c["minor"]))
    return {
        "gps_utc_offset": leap,
        "broadcast_time_utc": gps_to_utc(base["stt"][0], leap).isoformat() if base["stt"] else None,
        "tables": {"eit_pids": sorted(eit_pids), "ett_pids": sorted(ett_pids), "mgt_entries": len(base["mgt"])},
        "channels": channels,
        "events": sorted(events.values(), key=lambda e: (e["source_id"], e["start_gps"])),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture", help="transport stream file (a raw multiplex capture)")
    ap.add_argument("--json", help="write the full result here")
    a = ap.parse_args()
    d = decode_capture(a.capture)
    print(f'Broadcast clock: {d["broadcast_time_utc"]} UTC (GPS-UTC offset {d["gps_utc_offset"]} s)')
    print(f'Guide tables: {len(d["tables"]["eit_pids"])} EIT PIDs, {len(d["tables"]["ett_pids"])} ETT PIDs\n')
    by_src = defaultdict(list)
    for e in d["events"]:
        by_src[e["source_id"]].append(e)
    for ch in d["channels"]:
        evs = by_src.get(ch["source_id"], [])
        span = ""
        if evs:
            span = f'  {len(evs)} events, {evs[0]["start_utc"][11:16]} to {(datetime.datetime.fromisoformat(evs[-1]["start_utc"]) + datetime.timedelta(seconds=evs[-1]["length_s"])).strftime("%m-%d %H:%MZ")}'
        flags = "".join([" HIDDEN" if ch["hidden"] else "", " PROTECTED" if ch["access_controlled"] else "",
                         "" if ch["service_type"] == 2 else f' type{ch["service_type"]}'])
        print(f'{ch["number"]:>6}  {ch["name"]:<9} program {ch["program"]:<5}{flags}{span}')
    if a.json:
        with open(a.json, "w") as f:
            json.dump(d, f, indent=1)
        print(f"\nWrote {a.json}")


if __name__ == "__main__":
    main()
