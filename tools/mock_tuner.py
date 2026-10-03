#!/usr/bin/env python3
"""
mock_tuner.py — standalone, high-fidelity HDHomeRun tuner emulator.

Unlike tools/mock_hdhr.py (a *proxy* that needs a real device behind it and only swaps a few
discover.json fields), this script IS the device: UDP discovery, the HTTP API on :80, and streams
on :5004 — answering byte-for-byte the way a real EXTEND (HDTC-2US, firmware 20260313) does, per
the ground truth live-captured 2026-10-03 (docs/HDHRFindings.md, "Device Emulation Ground Truth").
No real tuner, no root (macOS lets unprivileged processes bind <1024), no network calls unless you
ask it to --mirror a real device's identity/lineup.

Uses:
  * Test this app against a second "tuner" with full control: tuner count, all-tuners-busy (805),
    unknown channel (801), favorites, channel scans, DeviceAuth rotation.
  * Probe what a third-party client (Channels, the HDHomeRun app, Plex…) actually does: every UDP
    request is decoded TLV-by-TLV and every HTTP request is logged with client IP + User-Agent —
    exactly the visibility that took a packet capture to get on 2026-10-03.
  * `compare` subcommand: diff any two devices' /discover.json, /lineup.json, headers and UDP
    replies field by field (e.g. the real tuner vs. this mock, or vs. the app's FEED relay).

What it reproduces (see HDHRFindings.md for the captures):
  HTTP  Server: HDHomeRun/1.0, Connection: close, charset JSON, no-cache, CORS on every response;
        /discover.json in the real key order with no LocalIP and a port-less BaseURL;
        /lineup.json (+ ?show=found), /lineup.xml, /lineup.m3u in the real formats;
        /lineup_status.json + POST /lineup.post?scan=start|abort with a timed scan
        (ScanInProgress/Progress/Found); /lineup.post?favorite=+N|-N|xN favorite toggles;
        POST /lineup.post with no args → 400; /status.json rows with live occupancy;
        /guide.json → 404; unknown path → 404 text/html; / and /tuners.html stub pages.
  Streams  :5004/auto/v<ch> with the real header (video/mpeg, transferMode.dlna.org);
        801 Unknown Channel; 805 All Tuners In Use (503) when every tuner is streaming;
        ?duration=N honored; ?transcode=<profile> accepted only for HDTC* models.
  UDP   :65001 — replies to every request (like the real device: wrong type, foreign ID, even a
        bad CRC), real TLV order DeviceType, [0x2D when the filter didn't match], DeviceID,
        DeviceAuth, BaseURL "http://<ip>:80", TunerCount, LineupURL.
  DeviceAuth  synthetic 24-char token, rotated every --auth-rotate seconds (real devices rotate
        every few minutes); or pinned with --device-auth; or omitted with --no-auth.

Usage:
  python3 tools/mock_tuner.py                                  # this Mac's LAN IP, :80/:5004/:65001
  python3 tools/mock_tuner.py --ip 127.0.0.1 --http-port 18080 --stream-port 15004 --udp-port 0
  python3 tools/mock_tuner.py --profile flex4k --tuners 4
  python3 tools/mock_tuner.py --mirror 10.0.2.101              # copy a real device's identity+lineup
                                                               # (DeviceID stays the mock's own)
  python3 tools/mock_tuner.py --ts-file rec.ts                 # stream real TS (looped) instead of nulls
  python3 tools/mock_tuner.py --busy                           # every stream → 805 All Tuners In Use
  python3 tools/mock_tuner.py compare 10.0.2.101 10.0.2.100    # field-by-field device diff
  sudo python3 tools/mock_tuner.py --ip 10.0.2.240 --alias     # own LAN address (needs root + free IP)

Ports: :80 is often taken (Caddy on the Mac Mini, or the app's own FEED full-tuner listener while a
FEED is live) — the mock exits with a clear message rather than silently advertising a port it
doesn't own. Use --ip with --alias for a dedicated address, or move ports (clients that ignore
BaseURL's port, like Channels, then won't reach it — see HDHRFindings.md).

Python 3.9+ (stdlib only). Ctrl+C to stop (removes an --alias it added).
"""
from __future__ import annotations

import argparse
import binascii
import json
import os
import random
import re
import signal
import socket
import string
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

# ── Profiles (real models' identity fields) ──────────────────────────────────────────────────────

PROFILES = {
    # Live-captured 2026-10-03 from the project's own EXTEND.
    "extend":  {"FriendlyName": "HDHomeRun EXTEND", "ModelNumber": "HDTC-2US",
                "FirmwareName": "hdhomeruntc_atsc", "FirmwareVersion": "20260313", "TunerCount": 2},
    # Other real models — identity strings per SiliconDust's naming; firmware versions illustrative.
    "connect": {"FriendlyName": "HDHomeRun CONNECT", "ModelNumber": "HDHR5-2US",
                "FirmwareName": "hdhomerun5_atsc", "FirmwareVersion": "20260313", "TunerCount": 2},
    "quatro":  {"FriendlyName": "HDHomeRun CONNECT QUATRO", "ModelNumber": "HDHR5-4US",
                "FirmwareName": "hdhomerun5_atsc", "FirmwareVersion": "20260313", "TunerCount": 4},
    "flex4k":  {"FriendlyName": "HDHomeRun FLEX 4K", "ModelNumber": "HDFX-4K",
                "FirmwareName": "hdhomerun_dvr_atsc3", "FirmwareVersion": "20260313", "TunerCount": 4},
}

DEFAULT_LINEUP = [  # GuideNumber, GuideName, VideoCodec, AudioCodec, HD, Favorite
    ("2.1", "TPT 2", "MPEG2", "AC3", 1, 0), ("4.1", "WCCO-DT", "MPEG2", "AC3", 1, 1),
    ("5.1", "KSTPDT", "MPEG2", "AC3", 1, 1), ("9.1", "KMSP-DT", "MPEG2", "AC3", 1, 0),
    ("11.1", "KARE-HD", "MPEG2", "AC3", 1, 0), ("23.1", "WUCWDT", "MPEG2", "AC3", 1, 0),
    ("29.1", "WFTC-HD", "H264", "AC3", 1, 0), ("45.1", "KSTC-HD", "MPEG2", "AC3", 1, 0),
]

DISCOVER_KEY_ORDER = ["FriendlyName", "ModelNumber", "FirmwareName", "FirmwareVersion", "DeviceID",
                      "DeviceAuth", "BaseURL", "LineupURL", "TunerCount"]
LINEUP_KEY_ORDER = ["GuideNumber", "GuideName", "VideoCodec", "AudioCodec", "HD", "Favorite", "URL"]
STATUS_KEY_ORDER = ["Resource", "VctNumber", "VctName", "Frequency", "SignalStrengthPercent",
                    "SignalQualityPercent", "SymbolQualityPercent", "TargetIP", "NetworkRate"]

TS_PACKET = 188
TS_NULL = bytes([0x47, 0x1F, 0xFF, 0x10]) + bytes([0xFF]) * (TS_PACKET - 4)


def log(msg: str) -> None:
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


# ── DeviceID checksum (libhdhomerun's hdhomerun_discover_validate_device_id) ────────────────────

_ID_LUT = [0xA, 0x5, 0xF, 0x6, 0x7, 0xC, 0x1, 0xB, 0x9, 0x2, 0x8, 0xD, 0x4, 0x3, 0xE, 0x0]


def device_id_is_valid(device_id: int) -> bool:
    c = 0
    for shift, use_lut in ((28, True), (24, False), (20, True), (16, False),
                           (12, True), (8, False), (4, True), (0, False)):
        n = (device_id >> shift) & 0xF
        c ^= _ID_LUT[n] if use_lut else n
    return c == 0


def make_valid_device_id(prefix: str = "10") -> str:
    """Random 8-hex-digit ID passing libhdhomerun's checksum (clients may drop invalid IDs)."""
    while True:
        cand = int(prefix + "".join(random.choice("0123456789ABCDEF") for _ in range(8 - len(prefix))), 16)
        if device_id_is_valid(cand):
            return f"{cand:08X}"


# ── JSON in the real device's shape (ordered keys, unescaped slashes) ───────────────────────────

def ordered(d: dict, order: list[str]) -> dict:
    out = {k: d[k] for k in order if k in d and d[k] is not None}
    out.update({k: v for k, v in sorted(d.items()) if k not in order and v is not None})
    return out


def device_json(obj) -> bytes:
    # json.dumps never escapes "/" and preserves dict insertion order — exactly the real device.
    return json.dumps(obj, separators=(",", ":")).encode()


# ── Device state ─────────────────────────────────────────────────────────────────────────────────

class Device:
    def __init__(self, args, identity: dict, lineup: list[dict]):
        self.lock = threading.Lock()
        self.ip = args.ip
        self.http_port = args.http_port
        self.stream_port = args.stream_port
        self.identity = identity            # FriendlyName/ModelNumber/FirmwareName/Version/TunerCount
        self.device_id = args.device_id
        self.lineup = lineup                # list of dicts in LINEUP_KEY_ORDER (URL filled per request)
        self.no_auth = args.no_auth
        self.pinned_auth = args.device_auth
        self.auth_rotate = args.auth_rotate
        self._auth = self.pinned_auth or self._new_auth()
        self._auth_at = time.time()
        self.scan_seconds = args.scan_seconds
        self.scan_started: float | None = None
        self.source = "Antenna"
        self.streams: dict[int, dict] = {}  # tuner index → {channel, client, started, bytes}
        self.busy = args.busy

    # identity ------------------------------------------------------------------------------------
    @staticmethod
    def _new_auth() -> str:
        return "".join(random.choice(string.ascii_letters + string.digits + "_") for _ in range(24))

    def device_auth(self) -> str | None:
        if self.no_auth:
            return None
        with self.lock:
            if not self.pinned_auth and self.auth_rotate > 0 and time.time() - self._auth_at >= self.auth_rotate:
                self._auth, self._auth_at = self._new_auth(), time.time()
                log(f"[auth] DeviceAuth rotated → {self._auth[:6]}…")
            return self._auth

    @property
    def tuner_count(self) -> int:
        return int(self.identity.get("TunerCount", 2))

    def base_url(self) -> str:
        return f"http://{self.ip}" if self.http_port == 80 else f"http://{self.ip}:{self.http_port}"

    def stream_url(self, ch: str) -> str:
        return f"http://{self.ip}:{self.stream_port}/auto/v{ch}"

    def discover(self) -> dict:
        d = dict(self.identity)
        d.update({"DeviceID": self.device_id, "DeviceAuth": self.device_auth(),
                  "BaseURL": self.base_url(), "LineupURL": f"{self.base_url()}/lineup.json"})
        return ordered(d, DISCOVER_KEY_ORDER)

    # lineup ------------------------------------------------------------------------------------
    def lineup_entries(self) -> list[dict]:
        with self.lock:
            rows = [dict(e) for e in self.lineup]
        for e in rows:
            e["URL"] = self.stream_url(e["GuideNumber"])
            if not e.get("HD"): e.pop("HD", None)
            if not e.get("Favorite"): e.pop("Favorite", None)
        return [ordered(e, LINEUP_KEY_ORDER) for e in rows]

    def channel(self, num: str) -> dict | None:
        with self.lock:
            return next((dict(e) for e in self.lineup if e["GuideNumber"] == num), None)

    def set_favorite(self, num: str, op: str) -> bool:
        with self.lock:
            for e in self.lineup:
                if e["GuideNumber"] == num:
                    e["Favorite"] = 1 if op == "+" else 0 if op == "-" else (0 if e.get("Favorite") else 1)
                    return True
        return False

    # scan --------------------------------------------------------------------------------------
    def lineup_status(self) -> dict:
        with self.lock:
            if self.scan_started is not None:
                elapsed = time.time() - self.scan_started
                if elapsed < self.scan_seconds:
                    pct = int(elapsed / self.scan_seconds * 100)
                    return {"ScanInProgress": 1, "Progress": pct, "Found": len(self.lineup) * pct // 100}
                self.scan_started = None
                log(f"[scan] complete — {len(self.lineup)} channels")
            return {"ScanInProgress": 0, "ScanPossible": 1, "Source": self.source,
                    "SourceList": ["Antenna", "Cable"]}

    # tuners ------------------------------------------------------------------------------------
    def allocate(self, ch: str, client: str) -> int | None:
        with self.lock:
            if self.busy:
                return None
            for i in range(self.tuner_count):
                if i not in self.streams:
                    self.streams[i] = {"channel": ch, "client": client, "started": time.time(), "bytes": 0}
                    return i
        return None

    def release(self, i: int) -> None:
        with self.lock:
            self.streams.pop(i, None)

    def status(self) -> list[dict]:
        rows = []
        with self.lock:
            for i in range(self.tuner_count):
                s = self.streams.get(i)
                if not s:
                    rows.append({"Resource": f"tuner{i}"})
                    continue
                ch = next((e for e in self.lineup if e["GuideNumber"] == s["channel"]), {})
                secs = max(0.001, time.time() - s["started"])
                rows.append(ordered({
                    "Resource": f"tuner{i}", "VctNumber": s["channel"], "VctName": ch.get("GuideName"),
                    "Frequency": 473000000 + 6000000 * (abs(hash(s["channel"])) % 60),
                    "SignalStrengthPercent": 94, "SignalQualityPercent": 88, "SymbolQualityPercent": 100,
                    "TargetIP": s["client"], "NetworkRate": int(s["bytes"] * 8 / secs),
                }, STATUS_KEY_ORDER))
        return rows


DEVICE: Device | None = None
ARGS = None


# ── HTTP: API (:80) and streams (:5004) share one handler, like the real device ────────────────

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "HDHomeRun/1.0"
    sys_version = ""

    def log_message(self, fmt, *args):  # replaced by our own per-request line
        pass

    # raw responses in the real device's exact header order -----------------------------------
    def _raw(self, status: str, headers: list[tuple[str, str]], body: bytes = b"") -> None:
        head = f"HTTP/1.1 {status}\r\nServer: HDHomeRun/1.0\r\nConnection: close\r\n"
        head += "".join(f"{k}: {v}\r\n" for k, v in headers)
        head += f"Date: {self.date_time_string()}\r\n\r\n"
        try:
            self.wfile.write(head.encode() + body)
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True

    def _json(self, obj) -> None:
        body = device_json(obj)
        self._raw("200 OK", [("Content-Type", 'application/json; charset="utf-8"'),
                             ("Content-Length", str(len(body))), ("Cache-Control", "no-cache"),
                             ("Access-Control-Allow-Origin", "*")], body)

    def _text(self, status: str, ctype: str, text: str) -> None:
        body = text.encode()
        self._raw(status, [("Content-Type", ctype), ("Content-Length", str(len(body))),
                           ("Cache-Control", "no-cache"), ("Access-Control-Allow-Origin", "*")], body)

    def _not_found(self) -> None:
        self._text("404 Not Found", 'text/html; charset="utf-8"',
                   "<html><head><title>404 Not Found</title></head><body><h1>404 Not Found</h1></body></html>")

    def _req_log(self, extra: str = "") -> None:
        ua = self.headers.get("User-Agent", "-")
        log(f"[http:{self.server.server_address[1]}] {self.client_address[0]} {self.command} {self.path}"
            f"  UA={ua!r}{('  ' + extra) if extra else ''}")

    # routing -------------------------------------------------------------------------------------
    def do_GET(self):
        dev = DEVICE
        url = urlsplit(self.path)
        path, q = url.path, parse_qs(url.query)
        stream_port = self.server.server_address[1] == dev.stream_port and dev.stream_port != dev.http_port
        if path.startswith("/auto/v"):
            return self._stream(path[len("/auto/v"):], q)
        if stream_port:
            self._req_log("→ 404 (stream port serves /auto/v only)")
            return self._not_found()
        self._req_log()
        if path == "/discover.json":
            return self._json(dev.discover())
        if path == "/lineup.json":
            return self._json(dev.lineup_entries())
        if path == "/lineup.xml":
            fields = LINEUP_KEY_ORDER
            progs = ["<Program>" + "".join(f"<{f}>{_xml(e[f])}</{f}>" for f in fields if f in e) + "</Program>"
                     for e in dev.lineup_entries()]
            return self._text("200 OK", 'text/xml; charset="utf-8"',
                              '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<Lineup>'
                              + "\n".join(progs) + "</Lineup>\n")
        if path == "/lineup.m3u":
            lines = ["#EXTM3U"]
            for e in dev.lineup_entries():
                n, name = e["GuideNumber"], e["GuideName"]
                lines += [f'#EXTINF:-1 channel-id="{n}" channel-number="{n}" tvg-name="{name}",{n} {name}', e["URL"]]
            return self._text("200 OK", "text/plain", "\n".join(lines) + "\n")
        if path == "/lineup_status.json":
            return self._json(dev.lineup_status())
        if path == "/status.json":
            return self._json(dev.status())
        if path in ("/", "/index.html", "/tuners.html", "/system.html"):
            d = dev.discover()
            return self._text("200 OK", 'text/html; charset="utf-8"',
                              f"<html><head><title>{d['FriendlyName']}</title></head><body>"
                              f"<h1>{d['FriendlyName']}</h1><p>{d['ModelNumber']} · {d['DeviceID']} · "
                              f"{d['FirmwareVersion']} (mock_tuner.py)</p></body></html>")
        return self._not_found()   # incl. /guide.json — a real device has none

    def do_POST(self):
        dev = DEVICE
        url = urlsplit(self.path)
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        self._req_log()
        if url.path != "/lineup.post":
            return self._not_found()
        q = parse_qs(url.query)
        if "scan" in q:
            op = q["scan"][0]
            with dev.lock:
                if op == "start":
                    dev.scan_started = time.time()
                    dev.source = q.get("source", [dev.source])[0]
                elif op == "abort":
                    dev.scan_started = None
            log(f"[scan] {op} (source={dev.source})")
            return self._text("200 OK", "text/plain", "")
        if "favorite" in q:
            fav = q["favorite"][0].replace(" ", "+")   # '+' arrives as space in a query
            if fav[:1] in "+-x" and dev.set_favorite(fav[1:], fav[0]):
                log(f"[favorite] {fav}")
                return self._text("200 OK", "text/plain", "")
        return self._text("400 Bad Request", 'text/html; charset="utf-8"',
                          "<html><head><title>400 Bad Request</title></head><body><h1>400 Bad Request</h1></body></html>")

    # streams -------------------------------------------------------------------------------------
    def _stream(self, ch: str, q: dict) -> None:
        dev = DEVICE
        client = self.client_address[0]
        if dev.channel(ch) is None:
            self._req_log("→ 404 801 Unknown Channel")
            return self._raw("404 Not Found", [("Content-Length", "0"), ("Cache-Control", "no-cache"),
                                               ("X-HDHomeRun-Error", "801 Unknown Channel")])
        transcode = q.get("transcode", [None])[0]
        if transcode and transcode != "none" and not dev.identity.get("ModelNumber", "").startswith("HDTC"):
            self._req_log("→ 400 transcode unsupported on this model")
            return self._raw("400 Bad Request", [("Content-Length", "0"), ("Cache-Control", "no-cache")])
        tuner = dev.allocate(ch, client)
        if tuner is None:
            self._req_log("→ 503 805 All Tuners In Use")
            return self._raw("503 Service Unavailable", [("Content-Length", "0"), ("Cache-Control", "no-cache"),
                                                          ("X-HDHomeRun-Error", "805 All Tuners In Use")])
        duration = None
        try:
            duration = int(q["duration"][0]) if "duration" in q else None
        except ValueError:
            pass
        self._req_log(f"→ 200 on tuner{tuner}" + (f" duration={duration}s" if duration else "")
                      + (f" transcode={transcode}" if transcode else ""))
        head = ("HTTP/1.1 200 OK\r\nServer: HDHomeRun/1.0\r\nConnection: close\r\nContent-Type: video/mpeg\r\n"
                "Cache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\ntransferMode.dlna.org: Streaming\r\n"
                f"Date: {self.date_time_string()}\r\n\r\n")
        sent, start = 0, time.time()
        bytes_per_sec = ARGS.bitrate_mbps * 1_000_000 / 8
        chunk = TS_PACKET * 7                      # 1316 bytes — a typical RTP/UDP-sized TS burst
        try:
            self.wfile.write(head.encode())
            src = open(ARGS.ts_file, "rb") if ARGS.ts_file else None
            try:
                while True:
                    if duration and time.time() - start >= duration:
                        break
                    if src:
                        data = src.read(chunk)
                        if len(data) < chunk:      # loop the file
                            src.seek(0)
                            data += src.read(chunk - len(data))
                    else:
                        data = TS_NULL * 7
                    self.wfile.write(data)
                    sent += len(data)
                    with dev.lock:
                        if tuner in dev.streams:
                            dev.streams[tuner]["bytes"] = sent
                    # real-time pacing, like a broadcast (no backlog to burst)
                    ahead = sent / bytes_per_sec - (time.time() - start)
                    if ahead > 0:
                        time.sleep(ahead)
            finally:
                if src:
                    src.close()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            dev.release(tuner)
            log(f"[stream] tuner{tuner} ch {ch} → {client} closed after {sent / 1_048_576:.1f} MB")
        self.close_connection = True


def _xml(v) -> str:
    return str(v).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


# ── UDP discovery (:65001) ───────────────────────────────────────────────────────────────────────

def parse_tlvs(payload: bytes) -> list[tuple[int, bytes]]:
    out, i = [], 0
    while i + 2 <= len(payload):
        tag, ln = payload[i], payload[i + 1]
        if ln & 0x80:                             # 2-byte length form (libhdhomerun varlen)
            if i + 3 > len(payload):
                break
            ln = (ln & 0x7F) | (payload[i + 2] << 7)
            i += 1
        out.append((tag, payload[i + 2:i + 2 + ln]))
        i += 2 + ln
    return out


def build_reply(dev: Device, add_multitype: bool) -> bytes:
    def tlv(tag: int, val: bytes) -> bytes:
        return bytes([tag, len(val)]) + val
    base = f"http://{dev.ip}:{dev.http_port}"      # real UDP form spells out :80
    p = tlv(0x01, struct.pack(">I", 1))
    if add_multitype:
        p += tlv(0x2D, struct.pack(">I", 1))
    p += tlv(0x02, struct.pack(">I", int(dev.device_id, 16)))
    auth = dev.device_auth()
    if auth:
        p += tlv(0x2B, auth.encode()[:255])
    p += tlv(0x2A, base.encode()[:255])
    p += tlv(0x10, bytes([dev.tuner_count & 0xFF]))
    p += tlv(0x27, f"{base}/lineup.json".encode()[:255])
    pkt = struct.pack(">HH", 0x0003, len(p)) + p
    return pkt + struct.pack("<I", binascii.crc32(pkt) & 0xFFFFFFFF)


def udp_loop(dev: Device, port: int) -> None:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, "SO_REUSEPORT"):
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    try:
        s.bind(("", port))
    except OSError as e:
        log(f"[udp] cannot bind :{port} ({e}) — UDP discovery disabled")
        return
    log(f"[udp] discovery responder on :{port}")
    names = {0x01: "DeviceType", 0x02: "DeviceID", 0x2D: "MultiType", 0x2B: "DeviceAuth"}
    my_id = int(dev.device_id, 16)
    while True:
        data, addr = s.recvfrom(2048)
        if len(data) < 4 or data[:2] != b"\x00\x02":
            continue
        plen = struct.unpack(">H", data[2:4])[0]
        body = data[4:4 + plen]
        crc_ok = len(data) >= 8 + plen and \
            struct.unpack("<I", data[4 + plen:8 + plen])[0] == binascii.crc32(data[:4 + plen]) & 0xFFFFFFFF
        tlvs = parse_tlvs(body)
        desc, mismatch = [], False
        for tag, val in tlvs:
            if tag in (0x01, 0x02) and len(val) == 4:
                v = struct.unpack(">I", val)[0]
                desc.append(f"{names[tag]}={v:08X}")
                if tag == 0x01 and v not in (1, 0xFFFFFFFF):
                    mismatch = True
                if tag == 0x02 and v not in (my_id, 0xFFFFFFFF):
                    mismatch = True
            elif tag == 0x2D:
                types = [struct.unpack(">I", val[i:i + 4])[0] for i in range(0, len(val) - 3, 4)]
                desc.append(f"MultiType={types}")
            else:
                desc.append(f"{tag:#04x}[{len(val)}]")
        # Real device: replies to everything; inserts 0x2D when the filter didn't match it.
        s.sendto(build_reply(dev, add_multitype=mismatch), addr)
        log(f"[udp] {addr[0]}:{addr[1]} {' '.join(desc) or '(no TLVs)'}{'' if crc_ok else ' BAD-CRC'}"
            f" → replied{' (+0x2D, filter mismatch)' if mismatch else ''}")


# ── Setup helpers ────────────────────────────────────────────────────────────────────────────────

def default_lan_ip() -> str | None:
    r = subprocess.run(["route", "-n", "get", "default"], capture_output=True, text=True)
    m = re.search(r"interface:\s*(\S+)", r.stdout)
    if not m:
        return None
    r = subprocess.run(["ipconfig", "getifaddr", m.group(1)], capture_output=True, text=True)
    return r.stdout.strip() or None


def default_iface() -> str | None:
    r = subprocess.run(["route", "-n", "get", "default"], capture_output=True, text=True)
    m = re.search(r"interface:\s*(\S+)", r.stdout)
    return m.group(1) if m else None


def fetch_json(url: str, timeout: float = 4):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read())


def mirror_from(ip: str) -> tuple[dict, list[dict]]:
    d = fetch_json(f"http://{ip}/discover.json")
    identity = {k: d[k] for k in ("FriendlyName", "ModelNumber", "FirmwareName", "FirmwareVersion", "TunerCount") if k in d}
    lineup = [{k: e[k] for k in LINEUP_KEY_ORDER if k in e and k != "URL"} for e in fetch_json(f"http://{ip}/lineup.json")]
    log(f"[mirror] {ip}: {identity.get('FriendlyName')} {identity.get('ModelNumber')} — {len(lineup)} channels "
        f"(DeviceID/DeviceAuth NOT copied)")
    return identity, lineup


def load_lineup_file(path: str) -> list[dict]:
    raw = json.load(open(path))
    return [{k: e[k] for k in LINEUP_KEY_ORDER if k in e and k != "URL"} for e in raw]


# ── compare subcommand ───────────────────────────────────────────────────────────────────────────

def _http(host: str, path: str):
    req = urllib.request.Request(f"http://{host}{path}")
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()
    except Exception as e:
        return None, {}, str(e).encode()


def _udp_probe(ip: str) -> dict:
    p = bytes([0x01, 4, 0, 0, 0, 1, 0x02, 4, 0xFF, 0xFF, 0xFF, 0xFF])
    pkt = struct.pack(">HH", 0x0002, len(p)) + p
    pkt += struct.pack("<I", binascii.crc32(pkt) & 0xFFFFFFFF)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(2)
    try:
        s.sendto(pkt, (ip.split(":")[0], 65001))
        data, _ = s.recvfrom(2048)
    except Exception as e:
        return {"error": str(e)}
    order, vals = [], {}
    for tag, val in parse_tlvs(data[4:-4]):
        order.append(f"{tag:#04x}")
        vals[f"{tag:#04x}"] = val.hex() if tag in (0x01, 0x02, 0x10, 0x2D) else val.decode(errors="replace")
    return {"order": order, **vals}


def compare(a: str, b: str) -> None:
    """Field-by-field diff of two devices (host or host:port for HTTP; UDP always :65001)."""
    def line(label, va, vb):
        mark = "  " if va == vb else "≠ "
        print(f"{mark}{label:28s} {str(va)[:60]:62s} {str(vb)[:60]}")
    print(f"{'':30s}{a:62s} {b}")
    for path in ("/discover.json", "/lineup.json", "/lineup_status.json", "/status.json", "/lineup.xml",
                 "/lineup.m3u", "/guide.json"):
        sa, ha, ba = _http(a, path)
        sb, hb, bb = _http(b, path)
        print(f"\n── {path}")
        line("status", sa, sb)
        for h in ("Server", "Content-Type", "Connection", "Cache-Control", "Access-Control-Allow-Origin"):
            line(f"hdr {h}", ha.get(h), hb.get(h))
        if path == "/discover.json" and sa == 200 and sb == 200:
            ja, jb = json.loads(ba), json.loads(bb)
            line("key order", list(ja), list(jb))
            for k in sorted(set(ja) | set(jb)):
                line(k, "<auth>" if k == "DeviceAuth" and k in ja else ja.get(k),
                     "<auth>" if k == "DeviceAuth" and k in jb else jb.get(k))
            line("escaped slashes", b"\\/" in ba, b"\\/" in bb)
        elif path == "/lineup.json" and sa == 200 and sb == 200:
            la, lb = json.loads(ba), json.loads(bb)
            line("entries", len(la), len(lb))
            if la and lb:
                line("first entry keys", list(la[0]), list(lb[0]))
                line("first URL", la[0].get("URL"), lb[0].get("URL"))
    print("\n── UDP discovery reply (:65001)")
    ua, ub = _udp_probe(a), _udp_probe(b)
    for k in sorted(set(ua) | set(ub)):
        line(k, "<auth>" if k == "0x2b" and k in ua else ua.get(k), "<auth>" if k == "0x2b" and k in ub else ub.get(k))


# ── main ─────────────────────────────────────────────────────────────────────────────────────────

def main() -> None:
    global DEVICE, ARGS
    if len(sys.argv) >= 2 and sys.argv[1] == "compare":
        if len(sys.argv) != 4:
            print("usage: mock_tuner.py compare <hostA[:port]> <hostB[:port]>")
            sys.exit(2)
        compare(sys.argv[2], sys.argv[3])
        return

    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ip", help="address to serve/advertise (default: this Mac's LAN IP)")
    ap.add_argument("--alias", action="store_true", help="add --ip as an alias on the default interface (root)")
    ap.add_argument("--http-port", type=int, default=80)
    ap.add_argument("--stream-port", type=int, default=5004)
    ap.add_argument("--udp-port", type=int, default=65001, help="0 disables UDP discovery")
    ap.add_argument("--profile", choices=sorted(PROFILES), default="extend")
    ap.add_argument("--device-id", help="8 hex digits (default: random, checksum-valid)")
    ap.add_argument("--friendly-name"); ap.add_argument("--model"); ap.add_argument("--firmware-name")
    ap.add_argument("--firmware-version"); ap.add_argument("--tuners", type=int)
    ap.add_argument("--mirror", metavar="IP", help="copy identity + lineup from a real device (never its ID/auth)")
    ap.add_argument("--lineup-file", help="JSON array shaped like a real /lineup.json")
    ap.add_argument("--device-auth", help="pin DeviceAuth to this value")
    ap.add_argument("--auth-rotate", type=int, default=300, help="rotate synthetic DeviceAuth every N s (0 = never)")
    ap.add_argument("--no-auth", action="store_true", help="advertise no DeviceAuth (local-guide device)")
    ap.add_argument("--scan-seconds", type=float, default=6)
    ap.add_argument("--ts-file", help="MPEG-TS file to stream (looped); default is paced TS null packets")
    ap.add_argument("--bitrate-mbps", type=float, default=12.0, help="stream pacing rate (default 12)")
    ap.add_argument("--busy", action="store_true", help="every stream request → 503 805 All Tuners In Use")
    ARGS = args = ap.parse_args()

    args.ip = args.ip or default_lan_ip() or "127.0.0.1"
    if args.device_id:
        args.device_id = args.device_id.upper()
        if not re.fullmatch(r"[0-9A-F]{8}", args.device_id):
            sys.exit("--device-id must be 8 hex digits")
        if not device_id_is_valid(int(args.device_id, 16)):
            log(f"[warn] {args.device_id} fails libhdhomerun's DeviceID checksum — some clients ignore such devices")
    else:
        args.device_id = make_valid_device_id()
    if args.ts_file and not os.path.isfile(args.ts_file):
        sys.exit(f"--ts-file not found: {args.ts_file}")

    identity = dict(PROFILES[args.profile])
    lineup = [dict(zip(["GuideNumber", "GuideName", "VideoCodec", "AudioCodec", "HD", "Favorite"], r))
              for r in DEFAULT_LINEUP]
    if args.mirror:
        identity, lineup = mirror_from(args.mirror)
    if args.lineup_file:
        lineup = load_lineup_file(args.lineup_file)
    for k, v in (("FriendlyName", args.friendly_name), ("ModelNumber", args.model),
                 ("FirmwareName", args.firmware_name), ("FirmwareVersion", args.firmware_version),
                 ("TunerCount", args.tuners)):
        if v is not None:
            identity[k] = v

    alias_added = False
    if args.alias:
        iface = default_iface()
        if os.geteuid() != 0 or not iface:
            sys.exit("--alias needs root and a default-route interface")
        if subprocess.run(["ping", "-c", "1", "-t", "1", args.ip], capture_output=True).returncode == 0:
            sys.exit(f"{args.ip} answers ping — already in use")
        subprocess.run(["ifconfig", iface, "alias", args.ip], check=True)
        alias_added = True
        log(f"[setup] added {iface} alias {args.ip}")

    DEVICE = Device(args, identity, lineup)

    servers = []
    for port in sorted({args.http_port, args.stream_port}):
        try:
            srv = ThreadingHTTPServer((args.ip, port), Handler)
        except OSError as e:
            holder = subprocess.run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN"], capture_output=True, text=True).stdout
            name = holder.splitlines()[1].split()[0] if len(holder.splitlines()) > 1 else "?"
            sys.exit(f"cannot bind {args.ip}:{port} ({e.strerror}) — held by {name}. "
                     f"Free it, use --ip/--alias for another address, or move the port.")
        srv.daemon_threads = True
        servers.append(srv)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
    if args.udp_port:
        threading.Thread(target=udp_loop, args=(DEVICE, args.udp_port), daemon=True).start()

    d = DEVICE.discover()
    print(f"\nmock_tuner ready — {d['FriendlyName']} ({d['ModelNumber']}, {d['FirmwareName']} {d['FirmwareVersion']})")
    print(f"  DeviceID   {d['DeviceID']}  (checksum {'ok' if device_id_is_valid(int(d['DeviceID'], 16)) else 'INVALID'})")
    print(f"  API        {DEVICE.base_url()}/discover.json")
    print(f"  Streams    {DEVICE.stream_url('<ch>')}   ({DEVICE.tuner_count} tuners, "
          f"{'TS file ' + args.ts_file if args.ts_file else 'null packets'} @ {args.bitrate_mbps} Mbps)")
    print(f"  UDP        {':' + str(args.udp_port) if args.udp_port else 'disabled'}")
    rot = f"rotates every {args.auth_rotate}s" if args.auth_rotate > 0 else "never rotates"
    print(f"  DeviceAuth {'none' if args.no_auth else ('pinned' if args.device_auth else f'synthetic, {rot}')}")
    print(f"  Lineup     {len(lineup)} channels" + (f" (mirrored from {args.mirror})" if args.mirror else ""))
    print("Ctrl+C to stop.\n")

    def stop(*_):
        print()
        for srv in servers:
            srv.shutdown()
        if alias_added:
            subprocess.run(["ifconfig", default_iface() or "en0", "-alias", args.ip])
            log(f"[setup] removed alias {args.ip}")
        sys.exit(0)
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
