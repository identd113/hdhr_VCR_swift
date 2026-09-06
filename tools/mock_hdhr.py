#!/usr/bin/env python3
"""
mock_hdhr.py — Mock HDHomeRun device for testing hdhr_VCR with multiple tuners.

By default appears on loopback (127.0.0.2) — visible only to processes on this
same Mac, never to other devices on the LAN. Pass --lan to instead advertise the
mock at this Mac's own real LAN address, so it's discoverable by anything on the
network the way a genuine second HDHomeRun would be (another machine, the
official HDHomeRun apps, etc.) — no new IP is claimed, since this machine already
legitimately owns that address. Pass --lan-ip to instead alias a distinct address
(verified free via ping + ARP first) if you specifically want the mock to answer
at an IP of its own rather than sharing this Mac's.

All API requests are proxied to the real device. Only /discover.json has
fields swapped (DeviceID, name, URLs) so the app treats it as a separate
tuner. DeviceAuth is kept from the real device so the cloud guide API works
identically.

Requirements:
  - Python 3 (ships with macOS)
  - Must run as root (port 80 + interface alias setup)

Usage:
    sudo python3 tools/mock_hdhr.py                       # loopback-only (default)
    sudo python3 tools/mock_hdhr.py --lan                 # LAN-visible, at this Mac's own IP
    sudo python3 tools/mock_hdhr.py --lan --lan-ip 10.0.2.240  # LAN-visible, distinct pinned IP
    sudo python3 tools/mock_hdhr.py --bad-tuner            # returns 404 for lineup + guide
    sudo python3 tools/mock_hdhr.py --real-ip 192.168.x.x  # override device IP

Fault-injection flags simulate specific failure modes:
  --bad-lineup  /lineup.json + /lineup_status.json → 404 (no channel list)
  --bad-guide   /guide.json → 500 (no EPG data)
  --bad-tuner   both of the above combined

--guide-file PATH serves that file's exact contents for /guide.json instead of proxying to the
real device or SiliconDust cloud — full control over what the app sees for scheduling tests
(custom SeriesIDs, titles, air times), independent of what's actually airing right now. The file
is re-read on every request, so editing it takes effect on the app's next guide refresh with no
restart needed. Forces DeviceAuth off on this mock's /discover.json response (even if the real
device being mirrored has one), since GuideStore only ever fetches a device's own /guide.json —
never this mock's — when DeviceAuth is present; a cloud/EXTEND-style device's guide always goes
straight to api.hdhomerun.com instead, bypassing this flag entirely. File format: a JSON array of
HDHomeRun guide.json channel objects, e.g.:
  [{"GuideNumber": "5.1", "GuideName": "Test Channel", "Guide": [
      {"StartTime": 1700000000, "EndTime": 1700003600, "Title": "My Show",
       "SeriesID": "test123", "EpisodeNumber": "S01E01"}
  ]}]
Pair with tools/mock_scenario.py's `plant` subcommand to schedule shows against these exact
guide entries once the app has loaded them (Settings → Update Guides Now, or wait for the hourly
auto-refresh).

/discover.json always responds normally so the device remains discoverable.

Stop with Ctrl+C — the interface alias is removed automatically on exit.

── FEED mode ─────────────────────────────────────────────────────────────────
--feed-file PATH switches this script entirely into mocking a REMOTE hdhrVCRplus instance's
Recording FEED (virtual tuner relay) instead of a real tuner — for testing this app's own "Watch a
recording on another Mac" consumer flow (MenuContent's "Recording on Another Mac" submenu,
AppState.watchRemoteRelay, VLCPlayerView's remote-FEED playback) without needing a second physical
Mac. Advertises itself over UDP discovery with the exact same TLV set/order (DeviceType, DeviceID,
BaseURL, TunerCount, LineupURL) VirtualTunerService.buildDiscoverReply sends — ground truth captured
from a real EXTEND's own reply, see that Swift function's own doc comment — and serves
/discover.json + /lineup.json with the same non-standard HdhrVCRplusVirtualRelay/
HdhrVCRplusShowTitle markers this app's own HDHRDevice/LineupEntry decoders recognize. /auto/v<channel>
streams the given file's real bytes from disk with the exact same header shape the real relay uses
(no Content-Length, Connection: keep-alive — EOF-terminated, matching WebServer.streamGrowingFile).

No root needed for FEED mode (unlike the real-device-mock mode above) — it binds an unprivileged
port and adds no interface alias, just reusing this Mac's own already-legitimate LAN address.

Usage:
    python3 tools/mock_hdhr.py --feed-file /path/to/recording.ts
    python3 tools/mock_hdhr.py --feed-file rec.ts --feed-channel 5.1 --feed-title "Mock Show"
    python3 tools/mock_hdhr.py --feed-file rec.ts --feed-growing   # keep polling for new bytes
                                                                    # at EOF instead of closing —
                                                                    # point at a real file that's
                                                                    # still actively being written
                                                                    # (e.g. a genuine in-progress
                                                                    # recording) to mimic the real
                                                                    # relay's live-growth behavior
    python3 tools/mock_hdhr.py --feed-file rec.ts --feed-from-live-edge  # start at the file's
                                                                    # *current* size instead of
                                                                    # byte 0 — matches a real
                                                                    # relay's "no backlog" behavior
                                                                    # for a viewer tuning in live

Every other flag above (--lan, --guide-file, --bad-tuner, etc.) belongs to the real-device-mock
mode and is ignored once --feed-file is given.
"""

import argparse
import ipaddress
import json
import os
import re
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

MOCK_IP        = "127.0.0.2"   # overwritten at startup when --lan is passed
MOCK_INTERFACE = "lo0"         # overwritten at startup when --lan is passed
CONTROL_PORT   = 80
DISCOVER_PORT  = 65001
MOCK_DEVICE_ID = "FFFF0001"

# Paths that return errors in --bad-tuner mode
LINEUP_PATHS = {"/lineup.json", "/lineup_status.json"}
GUIDE_PATHS  = {"/guide.json"}


def log(msg: str):
    print(f"{time.strftime('%m-%d %H:%M:%S')} {msg}")


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


# ── CRC-32 (ISO 3309, matching HDHomeRun's checksum) ─────────────────────────

def crc32(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xEDB88320 if (crc & 1) else crc >> 1
    return (~crc) & 0xFFFFFFFF


# ── Real device auto-discovery ────────────────────────────────────────────────

def discover_real_device_ip() -> str | None:
    """Find the first real HDHomeRun on the LAN via UDP broadcast.

    Sends a DISCOVER_REQUEST to 255.255.255.255:65001 and returns the source IP
    of the first reply that isn't the mock device itself. Falls back to mDNS
    hostname probes if UDP yields nothing.
    """
    payload = bytes([0x01, 0x04, 0xFF, 0xFF, 0xFF, 0xFF])
    header  = struct.pack(">HH", 0x0002, len(payload))
    pkt     = header + payload
    pkt    += struct.pack("<I", crc32(pkt))

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.settimeout(2)
    try:
        sock.sendto(pkt, ("255.255.255.255", DISCOVER_PORT))
        while True:
            try:
                _, addr = sock.recvfrom(1024)
                ip = addr[0]
                if not ip.startswith("127."):
                    return ip
            except socket.timeout:
                break
    except Exception as e:
        log(f"[Discovery] UDP error: {e}")
    finally:
        sock.close()

    for hostname in ("hdhomerun.local", "hdhr.local"):
        try:
            ip = socket.gethostbyname(hostname)
            if not ip.startswith("127."):
                log(f"[Discovery] Resolved {hostname} → {ip}")
                return ip
        except socket.gaierror:
            pass

    return None


# ── UDP discovery responder ───────────────────────────────────────────────────

def build_discover_reply() -> bytes:
    device_id = int(MOCK_DEVICE_ID, 16)
    payload   = bytes([0x02, 0x04]) + struct.pack(">I", device_id)
    header    = struct.pack(">HH", 0x0003, len(payload))
    pkt       = header + payload
    return pkt + struct.pack("<I", crc32(pkt))


def build_feed_discover_reply(device_id_hex: str, base_url: str, tuner_count: int = 1) -> bytes:
    """Mirrors VirtualTunerService.buildDiscoverReply's exact TLV set/order (DeviceType, DeviceID,
    BaseURL, TunerCount, LineupURL) byte-for-byte — ground truth captured from a real EXTEND's own
    reply, see that Swift function's own doc comment. The BaseURL TLV (0x2A) is what lets a real
    hdhrVCRplus instance learn this relay lives on a non-standard port instead of assuming 80 —
    without it the client's own follow-up GET (HDHRManager.fetchDeviceInfo) would guess wrong and
    silently fail against this mock the same way it would against a real, unadvertised-port relay."""
    device_id = int(device_id_hex, 16)
    payload  = bytes([0x01, 0x04, 0x00, 0x00, 0x00, 0x01])               # DeviceType = tuner
    payload += bytes([0x02, 0x04]) + struct.pack(">I", device_id)        # DeviceID
    base_url_bytes = base_url.encode()[:255]
    payload += bytes([0x2A, len(base_url_bytes)]) + base_url_bytes       # BaseURL
    payload += bytes([0x10, 0x01, tuner_count & 0xFF])                   # TunerCount
    lineup_url_bytes = f"{base_url}/lineup.json".encode()[:255]
    payload += bytes([0x27, len(lineup_url_bytes)]) + lineup_url_bytes   # LineupURL
    header = struct.pack(">HH", 0x0003, len(payload))
    pkt = header + payload
    return pkt + struct.pack("<I", crc32(pkt))


def udp_thread(reply_pkt: bytes | None = None, device_label: str | None = None):
    if reply_pkt is None:
        reply_pkt = build_discover_reply()
    if device_label is None:
        device_label = MOCK_DEVICE_ID
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    try:
        sock.bind(("", DISCOVER_PORT))
    except OSError as e:
        log(f"[UDP] Cannot bind :{DISCOVER_PORT}: {e} — UDP discovery disabled")
        return

    log(f"[UDP] Listening on :{DISCOVER_PORT}, responding as {device_label}")
    while True:
        try:
            data, addr = sock.recvfrom(1024)
            if len(data) >= 4 and data[0] == 0x00 and data[1] == 0x02:
                log(f"[UDP] Discovery request from {addr[0]}")
                reply_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                reply_sock.bind((MOCK_IP, 0))
                reply_sock.sendto(reply_pkt, addr)
                reply_sock.close()
        except Exception as e:
            log(f"[UDP] Error: {e}")


# ── DeviceAuth background refresh ────────────────────────────────────────────

def auth_refresh_loop(interval: int):
    """Periodically re-fetch DeviceAuth from the real device.

    Keeps the fallback cache in ControlHandler.real_info current so a temporary
    real-device outage doesn't cause the mock to serve an expired token."""
    log(f"[DeviceAuth] Background refresh every {interval}s")
    while True:
        time.sleep(interval)
        ControlHandler.refresh_real_info()


# ── mDNS registration ─────────────────────────────────────────────────────────

def mdns_hostname(device_id: str) -> str:
    return f"hdhomerun-{device_id.lower()}.local"


def register_mdns(device_id: str, friendly_name: str, ip: str) -> subprocess.Popen:
    hostname = mdns_hostname(device_id)
    proc = subprocess.Popen(
        ["dns-sd", "-P", friendly_name, "_hdhomerun._tcp", "local",
         str(CONTROL_PORT), hostname, ip],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    log(f"[mDNS] Registered {hostname} → {ip}")
    return proc


def unregister_mdns(proc: subprocess.Popen):
    proc.terminate()
    proc.wait()
    log(f"[mDNS] Unregistered {mdns_hostname(MOCK_DEVICE_ID)}")


# ── Interface alias (loopback or real LAN interface) ─────────────────────────
# Loopback mode (default) aliases 127.0.0.2 onto lo0 — visible only on this Mac.
# --lan mode aliases a real IP onto the machine's LAN-facing interface instead,
# so the mock answers ARP/UDP/mDNS on the actual network like a genuine device.

def add_interface_alias(interface: str, ip: str, prefixlen: int | None = None):
    cmd = ["ifconfig", interface, "alias", ip]
    if prefixlen is not None:
        cmd.append(f"/{prefixlen}")
    r = subprocess.run(cmd, capture_output=True)
    if r.returncode == 0:
        log(f"[Setup] Added {interface} alias {ip}")
    else:
        log(f"[Setup] {r.stderr.decode().strip() or f'{ip} already configured on {interface}'}")


def remove_interface_alias(interface: str, ip: str):
    subprocess.run(["ifconfig", interface, "-alias", ip], capture_output=True)
    log(f"[Teardown] Removed {interface} alias {ip}")


# ── LAN interface + free-IP discovery (for --lan) ────────────────────────────

def default_lan_interface() -> str | None:
    """The interface macOS would route a normal outbound connection through —
    same interface a real second HDHomeRun would show up on."""
    r = subprocess.run(["route", "-n", "get", "default"], capture_output=True, text=True)
    m = re.search(r"interface:\s*(\S+)", r.stdout)
    return m.group(1) if m else None


def interface_ipv4_network(interface: str) -> "tuple[ipaddress.IPv4Address, ipaddress.IPv4Network] | None":
    """This interface's own IPv4 address and subnet, parsed from `ifconfig`."""
    r = subprocess.run(["ifconfig", interface], capture_output=True, text=True)
    m = re.search(r"inet (\d+\.\d+\.\d+\.\d+) netmask (0x[0-9a-fA-F]+)", r.stdout)
    if not m:
        return None
    addr = ipaddress.IPv4Address(m.group(1))
    mask = ipaddress.IPv4Address(int(m.group(2), 16))
    net  = ipaddress.IPv4Network(f"{addr}/{mask}", strict=False)
    return addr, net


def ip_appears_free(ip: str) -> bool:
    """Best-effort liveness check: a real ping reply means definitely in use.
    Otherwise, check whether the OS still learned a MAC via ARP for it — even a
    host that silently drops ICMP still answers ARP on the same L2 segment, so
    a resolved (non-"incomplete") ARP entry also means in use. Only treat the
    address as free when neither signal found anything."""
    ping = subprocess.run(["ping", "-c", "1", "-t", "1", ip], capture_output=True)
    if ping.returncode == 0:
        return False
    arp = subprocess.run(["arp", "-n", ip], capture_output=True, text=True)
    return "incomplete" in arp.stdout or "no entry" in arp.stdout




# ── HTTP control server ───────────────────────────────────────────────────────

class ControlHandler(BaseHTTPRequestHandler):
    real_ip:    str  = ""
    real_info:  dict = {}
    bad_lineup: bool = False
    bad_guide:  bool = False
    guide_file: str | None = None   # path to a custom guide.json; served as-is instead of proxying
    _info_lock  = threading.Lock()   # guards real_info dict replacement

    @classmethod
    def refresh_real_info(cls) -> bool:
        """Re-fetch /discover.json from the real device and update the fallback cache.
        Returns True if DeviceAuth changed (token rotation detected)."""
        try:
            with urllib.request.urlopen(
                f"http://{cls.real_ip}/discover.json", timeout=5
            ) as resp:
                fresh = json.loads(resp.read())
            with cls._info_lock:
                old_auth = cls.real_info.get("DeviceAuth", "")
                new_auth = fresh.get("DeviceAuth", "")
                cls.real_info = fresh
            if new_auth != old_auth:
                status = "changed" if old_auth else "acquired"
                log(f"[DeviceAuth] Refreshed from {cls.real_ip} — token {status}")
                return True
            return False
        except Exception as e:
            log(f"[DeviceAuth] Background refresh failed: {e}")
            return False

    def log_message(self, fmt, *args):
        log(f"[HTTP] {fmt % args}")

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/discover.json":
            self._send_json(self._mock_discover())
        elif self.bad_lineup and path in LINEUP_PATHS:
            self._send_error(404, f"bad-lineup: {path} not available")
        elif self.bad_guide and path in GUIDE_PATHS:
            self._send_error(500, f"bad-guide: {path} not available")
        elif self.guide_file and path in GUIDE_PATHS:
            self._serve_guide_file()
        elif path in GUIDE_PATHS:
            self._proxy_guide()
        else:
            self._proxy("GET")

    def do_POST(self):
        self._proxy("POST")

    def _mock_discover(self) -> dict:
        """Real device info with DeviceID, name, and URLs swapped for the mock.
        DeviceAuth is fetched live from the real device on every request so it
        never goes stale. Falls back to the background-refreshed cache on error."""
        try:
            with urllib.request.urlopen(
                f"http://{self.real_ip}/discover.json", timeout=3
            ) as resp:
                live_info = json.loads(resp.read())
        except Exception:
            with ControlHandler._info_lock:
                live_info = dict(ControlHandler.real_info)  # background-refreshed cache
        d        = dict(live_info)
        hostname = mdns_hostname(MOCK_DEVICE_ID)
        d["DeviceID"]     = MOCK_DEVICE_ID
        d["FriendlyName"] = d.get("FriendlyName", "HDHomeRun") + " (Mock)"
        d["ModelNumber"]  = d.get("ModelNumber",  "HDHR")       + "-MOCK"
        d["BaseURL"]      = f"http://{hostname}"
        d["LineupURL"]    = f"http://{hostname}/lineup.json"
        if self.guide_file:
            # GuideStore.guideURL only ever fetches a device's own /guide.json (this mock's local
            # endpoint, which --guide-file intercepts below) when DeviceAuth is absent — a device
            # WITH DeviceAuth has its guide fetched straight from api.hdhomerun.com instead, which
            # this mock can't intercept. Drop it here so --guide-file actually takes effect even
            # when mirroring a real EXTEND-capable device.
            d.pop("DeviceAuth", None)
        if self.bad_lineup and self.bad_guide:
            d["FriendlyName"] += " [BAD]"
        elif self.bad_lineup:
            d["FriendlyName"] += " [NO-LINEUP]"
        elif self.bad_guide:
            d["FriendlyName"] += " [NO-GUIDE]"
        elif self.guide_file:
            d["FriendlyName"] += " [GUIDE-FILE]"
        return d

    def _proxy_guide(self):
        """Proxy /guide.json — uses the cloud API when DeviceAuth is present (EXTEND devices),
        otherwise falls back to the real device's local endpoint."""
        with ControlHandler._info_lock:
            device_auth = ControlHandler.real_info.get("DeviceAuth", "")

        # Preserve any query params the caller sent (e.g. Duration=N)
        query = self.path.split("?", 1)[1] if "?" in self.path else ""

        if device_auth:
            # EXTEND / cloud-guide device — forward to SiliconDust cloud API
            cloud_q = f"DeviceAuth={device_auth}"
            if query:
                cloud_q += f"&{query}"
            url = f"https://api.hdhomerun.com/api/guide.php?{cloud_q}"
            log(f"[Proxy] → GET /guide.json (cloud) DeviceAuth={device_auth[:6]}…")
        else:
            # Local-guide device — proxy directly to the real device
            url = f"http://{self.real_ip}{self.path}"
            log(f"[Proxy] → GET /guide.json (local) → {url}")

        try:
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req, timeout=30) as resp:
                data         = resp.read()
                content_type = resp.headers.get("Content-Type", "application/json")
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except BrokenPipeError:
            pass  # client disconnected mid-transfer; nothing to send back
        except urllib.error.HTTPError as e:
            log(f"[Proxy] ✗ guide → HTTP {e.code}")
            try:
                self.send_response(e.code)
                self.end_headers()
            except BrokenPipeError:
                pass
        except Exception as e:
            log(f"[Proxy] ✗ guide: {e}")
            try:
                self.send_response(502)
                self.end_headers()
            except BrokenPipeError:
                pass

    def _serve_guide_file(self):
        """Serve --guide-file's contents verbatim for /guide.json. Re-read from disk on every
        request (not cached at startup) so editing the file takes effect on the app's next guide
        refresh without needing to restart this mock."""
        try:
            with open(self.guide_file, "rb") as f:
                data = f.read()
            json.loads(data)  # fail loudly here, not as a confusing parse error inside the app
        except FileNotFoundError:
            log(f"[GuideFile] ✗ {self.guide_file} not found")
            self._send_error(500, f"--guide-file not found: {self.guide_file}")
            return
        except json.JSONDecodeError as e:
            log(f"[GuideFile] ✗ {self.guide_file} is not valid JSON: {e}")
            self._send_error(500, f"--guide-file is not valid JSON: {e}")
            return
        log(f"[GuideFile] → GET /guide.json served from {self.guide_file} ({len(data)} bytes)")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _proxy(self, method: str):
        url  = f"http://{self.real_ip}{self.path}"
        path = self.path.split("?")[0]
        # Log forwarding of important device API paths so it's visible in the terminal.
        if path in LINEUP_PATHS | GUIDE_PATHS | {"/status.json", "/lineup_status.json"}:
            log(f"[Proxy] → {method} {self.path}")
        try:
            body = None
            if method == "POST":
                length = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(length) if length > 0 else b""

            req = urllib.request.Request(url, data=body, method=method)
            with urllib.request.urlopen(req, timeout=10) as resp:
                data         = resp.read()
                content_type = resp.headers.get("Content-Type", "application/octet-stream")

            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        except BrokenPipeError:
            pass  # client disconnected mid-transfer
        except urllib.error.HTTPError as e:
            log(f"[Proxy] ✗ {method} {url} → HTTP {e.code}")
            try:
                self.send_response(e.code)
                self.end_headers()
            except BrokenPipeError:
                pass
        except Exception as e:
            log(f"[Proxy] ✗ {method} {url}: {e}")
            try:
                self.send_response(502)
                self.end_headers()
            except BrokenPipeError:
                pass

    def _send_json(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_error(self, code: int, message: str):
        body = message.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


# ── FEED mode: mocks a REMOTE hdhrVCRplus instance's virtual-tuner relay ─────

class FeedHandler(BaseHTTPRequestHandler):
    feed_file: str = ""
    feed_channel: str = "5.1"
    feed_title: str = "Mock FEED Recording"
    feed_device_id: str = "FEEDC0DE"
    feed_base_url: str = ""
    feed_local_ip: str = ""
    feed_growing: bool = False
    feed_from_live_edge: bool = False

    def log_message(self, fmt, *args):
        log(f"[FEED-HTTP] {fmt % args}")

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/discover.json":
            self._send_json(self._mock_discover())
        elif path == "/lineup.json":
            self._send_json(self._mock_lineup())
        elif path == "/status.json":
            self._send_json(self._mock_status())
        elif path.startswith("/auto/v"):
            self._serve_stream(path[len("/auto/v"):])
        else:
            self._send_error(404, f"{path} not found on mock FEED relay")

    def _mock_discover(self) -> dict:
        """Shape mirrors WebServer.buildVirtualTunerDiscoverJSON — DeviceID/FriendlyName/ModelNumber/
        BaseURL/LineupURL/TunerCount/LocalIP plus the same HdhrVCRplusVirtualRelay marker
        HDHRDevice.isVirtualRelay decodes from."""
        return {
            "DeviceID": self.feed_device_id,
            "FriendlyName": f"{self.feed_title} (Mock FEED)",
            "ModelNumber": "HDVR-RELAY",
            "BaseURL": self.feed_base_url,
            "LineupURL": f"{self.feed_base_url}/lineup.json",
            "TunerCount": 1,
            "LocalIP": self.feed_local_ip,
            "HdhrVCRplusVirtualRelay": True,
        }

    def _mock_lineup(self) -> list:
        """Shape mirrors WebServer.buildVirtualTunerLineupJSON — one entry, URL pointing back at
        this same mock's /auto/v<channel>, HdhrVCRplusShowTitle carrying the show title a generic
        HDHomeRun lineup entry has no room for (what lets MenuContent's "Recording on Another Mac"
        submenu say "Recording on <title>" instead of just a channel number)."""
        return [{
            "GuideNumber": self.feed_channel,
            "GuideName": self.feed_channel,
            "URL": f"{self.feed_base_url}/auto/v{self.feed_channel}?dev={self.feed_device_id}",
            "HdhrVCRplusShowTitle": self.feed_title,
        }]

    def _mock_status(self) -> list:
        return [{"Resource": "tuner0", "VctNumber": self.feed_channel, "TargetIP": ""}]

    def _serve_stream(self, channel: str):
        """Streams feed_file's real bytes from disk — same header shape (no Content-Length,
        Connection: keep-alive, EOF-terminated) WebServer.streamGrowingFile sends, and the same
        188-byte-TS-packet-aligned chunk size (188*200) it reads/sends with. Starts at byte 0 by
        default (plain playback of whatever's on disk); --feed-from-live-edge starts at the file's
        *current* size instead, matching a real relay's "no backlog" behavior for a viewer tuning in
        live. At EOF: closes by default (a static/already-finished file), or polls every 0.5s for
        more data with --feed-growing (point this at a file still being actively written — e.g. a
        genuine in-progress recording — to mimic the real relay's live-growth behavior indefinitely).
        """
        if not os.path.isfile(self.feed_file):
            self._send_error(404, "feed file not found")
            return
        start_offset = os.path.getsize(self.feed_file) if self.feed_from_live_edge else 0
        log(f"[FEED] /auto/v{channel} → 200 streaming {self.feed_file} from offset {start_offset}"
            + (" (growing)" if self.feed_growing else ""))
        header = "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        chunk_size = 188 * 200
        sent = 0
        try:
            self.wfile.write(header.encode())
            with open(self.feed_file, "rb") as f:
                f.seek(start_offset)
                while True:
                    chunk = f.read(chunk_size)
                    if chunk:
                        self.wfile.write(chunk)
                        sent += len(chunk)
                        continue
                    if not self.feed_growing:
                        break
                    time.sleep(0.5)   # caught up — poll for more data, same as the real relay
        except BrokenPipeError:
            pass
        except Exception as e:
            log(f"[FEED] /auto/v{channel} error after {sent} bytes: {e}")
        log(f"[FEED] /auto/v{channel} connection closed after {sent} bytes")

    def _send_json(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_error(self, code: int, message: str):
        body = message.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def run_feed_mode(args):
    """Entirely separate from the real-device-mock flow below — a FEED relay has no real device to
    proxy, needs no root (unprivileged port, no interface alias), and ignores every --lan/
    --guide-file/--bad-* flag."""
    global MOCK_IP

    if not os.path.isfile(args.feed_file):
        print(f"Error: --feed-file {args.feed_file} does not exist.")
        sys.exit(1)

    iface = default_lan_interface()
    if not iface:
        print("Error: could not determine the default-route LAN interface.")
        sys.exit(1)
    own_addr, _ = interface_ipv4_network(iface) or (None, None)
    if not own_addr:
        print(f"Error: could not determine {iface}'s own IPv4 address.")
        sys.exit(1)
    MOCK_IP = str(own_addr)

    device_id = args.feed_device_id.upper()
    base_url  = f"http://{MOCK_IP}:{args.feed_port}"

    FeedHandler.feed_file           = args.feed_file
    FeedHandler.feed_channel        = args.feed_channel
    FeedHandler.feed_title          = args.feed_title
    FeedHandler.feed_device_id      = device_id
    FeedHandler.feed_base_url       = base_url
    FeedHandler.feed_local_ip       = MOCK_IP
    FeedHandler.feed_growing        = args.feed_growing
    FeedHandler.feed_from_live_edge = args.feed_from_live_edge

    reply_pkt = build_feed_discover_reply(device_id, base_url, tuner_count=1)
    threading.Thread(target=udp_thread, args=(reply_pkt, device_id), daemon=True).start()

    try:
        server = ThreadedHTTPServer((MOCK_IP, args.feed_port), FeedHandler)
    except OSError as e:
        print(f"Failed to bind FEED server {MOCK_IP}:{args.feed_port}: {e}")
        sys.exit(1)

    def shutdown(sig=None, frame=None):
        print()
        sys.exit(0)
    signal.signal(signal.SIGINT,  shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    print(f"\nMock FEED relay ready:")
    print(f"  Device ID      : {device_id}")
    print(f"  Channel        : {args.feed_channel}  ({args.feed_title})")
    print(f"  Source file    : {args.feed_file}" + (" (growing — polls for new bytes at EOF)" if args.feed_growing else " (static — closes at EOF)"))
    print(f"  Start offset   : {'live edge (current file size)' if args.feed_from_live_edge else 'byte 0'}")
    print(f"  Base URL       : {base_url}")
    print(f"  Stream URL     : {base_url}/auto/v{args.feed_channel}?dev={device_id}")
    print(f"\nNo root needed — port {args.feed_port} is unprivileged and no interface alias is used.")
    print(f"A real hdhrVCRplus instance on this LAN should discover this within a few seconds and\n"
          f"list it under \"Recording on Another Mac.\" Ctrl+C to stop.\n")

    server.serve_forever()


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    global MOCK_IP, MOCK_INTERFACE

    ap = argparse.ArgumentParser(
        description="Mock HDHomeRun — multi-tuner testing for hdhr_VCR",
        epilog=(
            "Examples:\n"
            "  sudo python3 tools/mock_hdhr.py                              # loopback-only\n"
            "  sudo python3 tools/mock_hdhr.py --lan                        # LAN-visible, this Mac's own IP\n"
            "  sudo python3 tools/mock_hdhr.py --lan --lan-ip 10.0.2.240    # LAN-visible, distinct pinned IP\n"
            "  sudo python3 tools/mock_hdhr.py --bad-lineup                 # lineup → 404\n"
            "  sudo python3 tools/mock_hdhr.py --bad-guide                  # guide → 500\n"
            "  sudo python3 tools/mock_hdhr.py --bad-tuner                  # both\n"
            "  sudo python3 tools/mock_hdhr.py --real-ip 192.168.1.100      # explicit IP\n"
            "  sudo python3 tools/mock_hdhr.py --auth-refresh 300           # refresh DeviceAuth every 5m\n"
            "  sudo python3 tools/mock_hdhr.py --guide-file my_guide.json   # serve custom EPG data\n"
            "\n"
            "The mock advertises itself as device FFFF0001, on 127.0.0.2 (loopback, default) or a\n"
            "real LAN address (--lan). Ctrl+C cleans up the interface alias and mDNS registration.\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--real-ip", metavar="IP", default=None,
                    help="IP of the real HDHomeRun (auto-discovered if omitted)")
    ap.add_argument("--lan", action="store_true",
                    help="Make the mock discoverable on the real LAN instead of loopback-only "
                         "(defaults to this Mac's own address on the default-route interface)")
    ap.add_argument("--lan-ip", metavar="IP", default=None,
                    help="Use this distinct address instead of the Mac's own IP (verified free "
                         "via ping+ARP first)")
    ap.add_argument("--bad-lineup", action="store_true",
                    help="/lineup.json + /lineup_status.json → 404")
    ap.add_argument("--bad-guide", action="store_true",
                    help="/guide.json → 500")
    ap.add_argument("--bad-tuner", action="store_true",
                    help="Shorthand for --bad-lineup --bad-guide")
    ap.add_argument("--auth-refresh", metavar="SECS", type=int, default=1800,
                    help="How often to re-fetch DeviceAuth from the real device (default: 1800s)")
    ap.add_argument("--guide-file", metavar="PATH", default=None,
                    help="Serve this file's contents for /guide.json instead of proxying — full "
                         "control over guide data for scheduling tests. Re-read on every request. "
                         "Forces DeviceAuth off on this mock so the app actually fetches from it "
                         "(see the module docstring for why, and the expected JSON shape).")
    ap.add_argument("--feed-file", metavar="PATH", default=None,
                    help="Switch entirely into FEED mode: mock a REMOTE hdhrVCRplus instance's "
                         "Recording FEED (virtual tuner relay), streaming this real file from disk "
                         "on /auto/v<channel> — see the module docstring's 'FEED mode' section. "
                         "Every other flag above is ignored once this is given.")
    ap.add_argument("--feed-channel", metavar="NUM", default="5.1",
                    help="FEED mode: channel number to advertise/serve (default: 5.1)")
    ap.add_argument("--feed-title", metavar="STR", default="Mock FEED Recording",
                    help="FEED mode: show title advertised for the mock recording")
    ap.add_argument("--feed-device-id", metavar="ID", default="FEEDC0DE",
                    help="FEED mode: 8-hex-char DeviceID to advertise (default: FEEDC0DE)")
    ap.add_argument("--feed-port", metavar="PORT", type=int, default=8090,
                    help="FEED mode: HTTP port to serve on — unprivileged, no root needed (default: 8090)")
    ap.add_argument("--feed-growing", action="store_true",
                    help="FEED mode: poll for new bytes at EOF instead of closing — point at a "
                         "file still being actively written (e.g. a real in-progress recording) to "
                         "mimic the real relay's live-growth behavior indefinitely")
    ap.add_argument("--feed-from-live-edge", action="store_true",
                    help="FEED mode: start streaming at the file's *current* size instead of byte "
                         "0 — matches a real relay's 'no backlog' behavior for a viewer tuning in live")
    args = ap.parse_args()

    if args.feed_file:
        run_feed_mode(args)
        return

    bad_lineup = args.bad_lineup or args.bad_tuner
    bad_guide  = args.bad_guide  or args.bad_tuner

    if args.guide_file and not os.path.isfile(args.guide_file):
        print(f"Error: --guide-file {args.guide_file} does not exist.")
        sys.exit(1)

    if os.geteuid() != 0:
        print("Error: must run as root (sudo) to bind port 80 and manage the interface alias.")
        flags = []
        if bad_lineup and bad_guide: flags.append("--bad-tuner")
        elif bad_lineup: flags.append("--bad-lineup")
        elif bad_guide:  flags.append("--bad-guide")
        if args.real_ip: flags.append(f"--real-ip {args.real_ip}")
        if args.lan: flags.append("--lan")
        if args.lan_ip: flags.append(f"--lan-ip {args.lan_ip}")
        if args.guide_file: flags.append(f"--guide-file {args.guide_file}")
        suffix = (" " + " ".join(flags)) if flags else ""
        print(f"\n  sudo python3 {sys.argv[0]}{suffix}")
        sys.exit(1)

    if args.lan_ip and not args.lan:
        print("Error: --lan-ip requires --lan.")
        sys.exit(1)

    mock_needs_alias = True   # loopback default: 127.0.0.2 doesn't exist until we add it
    if args.lan:
        iface = default_lan_interface()
        if not iface:
            print("Error: could not determine the default-route LAN interface for --lan.")
            sys.exit(1)
        own_addr, _ = interface_ipv4_network(iface) or (None, None)
        if args.lan_ip and args.lan_ip != str(own_addr):
            # Explicit distinct address requested — verify nothing else on the LAN already
            # answers for it before claiming it as a new alias.
            if not ip_appears_free(args.lan_ip):
                print(f"Error: --lan-ip {args.lan_ip} appears to already be in use on the LAN "
                      f"(it answered a ping or ARP) — pick a different address.")
                sys.exit(1)
            MOCK_IP = args.lan_ip
        elif own_addr:
            # Default --lan behavior: just reuse the Mac's own LAN address. It's already
            # legitimately assigned to this interface, so there's nothing to scan for or
            # collide with, and no alias to add/remove — mDNS/UDP replies are simply sourced
            # from the address this machine already has.
            MOCK_IP = str(own_addr)
            mock_needs_alias = False
        else:
            print(f"Error: could not determine {iface}'s own IPv4 address for --lan.")
            sys.exit(1)
        MOCK_INTERFACE = iface
        note = "this Mac's own address, no alias needed" if not mock_needs_alias else "new alias"
        log(f"[Setup] --lan: using {MOCK_IP} on {MOCK_INTERFACE} ({note})")

    real_ip = args.real_ip
    if not real_ip:
        print("No --real-ip given — scanning for HDHomeRun on the LAN …")
        real_ip = discover_real_device_ip()
        if not real_ip:
            print("Error: no HDHomeRun device found. Connect the device or pass --real-ip.")
            sys.exit(1)
        log(f"[Discovery] Found device at {real_ip}")

    try:
        url = f"http://{real_ip}/discover.json"
        print(f"Fetching real device info from {url} …")
        with urllib.request.urlopen(url, timeout=5) as resp:
            real_info = json.loads(resp.read())
        print(f"  {real_info.get('FriendlyName', '?')}  "
              f"ID={real_info.get('DeviceID', '?')}  "
              f"DeviceAuth={'present' if real_info.get('DeviceAuth') else 'absent'}")
    except Exception as e:
        print(f"Warning: could not reach {real_ip} ({e}) — serving minimal discover.json")
        real_info = {}

    friendly = real_info.get("FriendlyName", "HDHomeRun") + " (Mock)"
    if bad_lineup and bad_guide: friendly += " [BAD]"
    elif bad_lineup:             friendly += " [NO-LINEUP]"
    elif bad_guide:              friendly += " [NO-GUIDE]"
    elif args.guide_file:        friendly += " [GUIDE-FILE]"

    ControlHandler.real_ip    = real_ip
    ControlHandler.real_info  = real_info
    ControlHandler.bad_lineup = bad_lineup
    ControlHandler.bad_guide  = bad_guide
    ControlHandler.guide_file = args.guide_file
    if args.guide_file:
        log(f"[Setup] --guide-file: serving {args.guide_file} for /guide.json (DeviceAuth forced off)")

    if mock_needs_alias:
        prefixlen = None
        if args.lan:
            info = interface_ipv4_network(MOCK_INTERFACE)
            if info:
                prefixlen = info[1].prefixlen
        add_interface_alias(MOCK_INTERFACE, MOCK_IP, prefixlen)
    mdns_proc = register_mdns(MOCK_DEVICE_ID, friendly, MOCK_IP)

    threading.Thread(
        target=auth_refresh_loop, args=(args.auth_refresh,), daemon=True
    ).start()

    def shutdown(sig=None, frame=None):
        print()
        unregister_mdns(mdns_proc)
        if mock_needs_alias:
            remove_interface_alias(MOCK_INTERFACE, MOCK_IP)
        sys.exit(0)

    signal.signal(signal.SIGINT,  shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    threading.Thread(target=udp_thread, daemon=True).start()

    try:
        control_server = ThreadedHTTPServer((MOCK_IP, CONTROL_PORT), ControlHandler)
    except OSError as e:
        print(f"Failed to bind control server {MOCK_IP}:{CONTROL_PORT}: {e}")
        if mock_needs_alias:
            remove_interface_alias(MOCK_INTERFACE, MOCK_IP)
        sys.exit(1)

    blocked = sorted((LINEUP_PATHS if bad_lineup else set()) | (GUIDE_PATHS if bad_guide else set()))
    mode    = "normal (proxying all requests)" if not blocked else f"fault injection: {', '.join(blocked)}"
    proxied = "/lineup.json, /guide.json, /status.json, /lineup_status.json (+ all others)"
    visibility = f"LAN ({MOCK_INTERFACE})" if args.lan else "loopback-only (this Mac only)"
    print(f"\nMock HDHomeRun ready:")
    print(f"  Device ID      : {MOCK_DEVICE_ID}")
    print(f"  Name           : {friendly}")
    print(f"  Mode           : {mode}")
    print(f"  Visibility     : {visibility}")
    print(f"  Control        : http://{MOCK_IP}:{CONTROL_PORT}/")
    print(f"  Proxying to    : http://{real_ip}/")
    print(f"  Forwarding     : {proxied}")
    print(f"  DeviceAuth     : {'present' if real_info.get('DeviceAuth') else 'absent'} (refresh every {args.auth_refresh}s)")
    cleanup_note = f"remove the {MOCK_INTERFACE} alias" if mock_needs_alias else "unregister mDNS"
    print(f"\nCtrl+C to stop and {cleanup_note}.\n")

    control_server.serve_forever()


if __name__ == "__main__":
    main()
