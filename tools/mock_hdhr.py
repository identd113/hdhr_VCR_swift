#!/usr/bin/env python3
"""
mock_hdhr.py — Mock HDHomeRun device for testing hdhr_VCR with multiple tuners.

Appears on 127.0.0.2 as a second device, cloning all metadata from the real device
but advertising a different DeviceID and appending "(Mock)" to the model name.

Two servers are started:
  Port 80   — HTTP API (discover, lineup, guide, sys/*, tuner/*, etc.)
  Port 5004 — Streaming proxy (relays MPEG-TS from the real device)

/lineup.json stream URLs are rewritten from http://<real-ip>:5004 to
http://127.0.0.2:5004 so recordings scheduled against the mock device route
through the streaming proxy rather than going directly to the real device.

All other port-80 endpoints except /discover.* are transparently proxied to the
real device, preserving the real Content-Type header. New firmware endpoints work
automatically without updating this script.

Requirements:
  - Python 3 (ships with macOS)
  - Must run as root (port 80 + loopback alias setup)

Usage:
    sudo python3 tools/mock_hdhr.py --real-ip 192.168.x.x

Stop with Ctrl+C — the loopback alias is removed automatically on exit.
"""

import argparse
import json
import os
import signal
import socket
import struct
import subprocess
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

MOCK_IP        = "127.0.0.2"
CONTROL_PORT   = 80
STREAM_PORT    = 5004
MOCK_DEVICE_ID = "FFFF0001"
DISCOVER_PORT  = 65001
STREAM_CHUNK   = 65536   # 64 KB read chunks for stream proxy


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    """HTTPServer that handles each request in its own thread.
    Required for the stream server: a single active stream would otherwise
    block all other requests on that port."""
    daemon_threads = True


# ── CRC-32 (ISO 3309, matching HDHomeRun's checksum) ─────────────────────────

def crc32(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xEDB88320 if (crc & 1) else crc >> 1
    return (~crc) & 0xFFFFFFFF


# ── UDP discovery responder ───────────────────────────────────────────────────

def build_discover_reply() -> bytes:
    """DISCOVER_REPLY TLV packet advertising the mock device ID."""
    device_id = int(MOCK_DEVICE_ID, 16)
    payload = bytes([0x02, 0x04]) + struct.pack(">I", device_id)
    header  = struct.pack(">HH", 0x0003, len(payload))   # type = DISCOVER_REPLY
    pkt     = header + payload
    return pkt + struct.pack("<I", crc32(pkt))


def udp_thread():
    """Receive HDHomeRun UDP discovery broadcasts and reply as the mock device."""
    reply_pkt = build_discover_reply()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    try:
        sock.bind(("", DISCOVER_PORT))
    except OSError as e:
        print(f"[UDP] Cannot bind :{DISCOVER_PORT}: {e}")
        print("[UDP] UDP discovery disabled")
        return

    print(f"[UDP] Listening on :{DISCOVER_PORT}, responding as {MOCK_DEVICE_ID}")
    while True:
        try:
            data, addr = sock.recvfrom(1024)
            # DISCOVER_REQUEST starts with type 0x00 0x02
            if len(data) >= 4 and data[0] == 0x00 and data[1] == 0x02:
                print(f"[UDP] Discovery request from {addr[0]}")
                reply_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                reply_sock.bind((MOCK_IP, 0))   # source IP must be MOCK_IP
                reply_sock.sendto(reply_pkt, addr)
                reply_sock.close()
        except Exception as e:
            print(f"[UDP] Error: {e}")


# ── Port 5004 — streaming proxy ───────────────────────────────────────────────

class StreamHandler(BaseHTTPRequestHandler):
    real_ip: str = ""

    def log_message(self, fmt, *args):
        print(f"[Stream] {fmt % args}")

    def do_GET(self):
        """Proxy the MPEG-TS stream from the real device in 64 KB chunks."""
        url = f"http://{self.real_ip}:{STREAM_PORT}{self.path}"
        print(f"[Stream] → {url}")
        try:
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req, timeout=30) as resp:
                content_type = resp.headers.get("Content-Type", "video/mpeg")
                self.send_response(200)
                self.send_header("Content-Type", content_type)
                self.end_headers()
                while True:
                    chunk = resp.read(STREAM_CHUNK)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass   # client disconnected (recording stopped)
        except Exception as e:
            print(f"[Stream] proxy error: {e}")
            try:
                self.send_response(502)
                self.end_headers()
            except Exception:
                pass


# ── Port 80 — control / API ───────────────────────────────────────────────────

class ControlHandler(BaseHTTPRequestHandler):
    real_ip:   str  = ""
    real_info: dict = {}

    def log_message(self, fmt, *args):
        print(f"[HTTP] {fmt % args}")

    def do_GET(self):
        path = self.path.split("?")[0]

        if path == "/discover.json":
            self._send_json(self._mock_discover())
        elif path == "/discover.xml":
            self._proxy_discover_xml()
        elif path == "/lineup.json":
            self._proxy_lineup_rewrite()
        else:
            self._proxy("GET")

    def do_POST(self):
        self._proxy("POST")

    # ── Mock identity responses ───────────────────────────────────────────────

    def _mock_discover(self) -> dict:
        """Real device metadata with DeviceID, name, and URLs replaced.
        BaseURL uses the .local hostname so the response matches what a real
        device returns — callers that extract LocalIP from BaseURL get the
        hostname rather than the raw IP, which is the standard HDHomeRun behaviour."""
        d = dict(self.real_info)
        hostname = mdns_hostname(MOCK_DEVICE_ID)
        d["DeviceID"]     = MOCK_DEVICE_ID
        d["FriendlyName"] = d.get("FriendlyName", "HDHomeRun") + " (Mock)"
        d["ModelNumber"]  = d.get("ModelNumber",  "HDHR")       + "-MOCK"
        d["BaseURL"]      = f"http://{hostname}"
        d["LineupURL"]    = f"http://{hostname}/lineup.json"
        # DeviceAuth is intentionally kept from the real device so the app
        # can reach the SiliconDust cloud guide API for both devices.
        return d

    def _proxy_discover_xml(self):
        """Proxy /discover.xml, substituting the real DeviceID with the mock one."""
        real_id = self.real_info.get("DeviceID", "")
        try:
            with urllib.request.urlopen(
                f"http://{self.real_ip}/discover.xml", timeout=10
            ) as resp:
                text = resp.read().decode("utf-8", errors="replace")
            if real_id:
                text = text.replace(real_id, MOCK_DEVICE_ID)
            body = text.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/xml")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except Exception as e:
            print(f"[HTTP] proxy discover.xml: {e}")
            self.send_response(502)
            self.end_headers()

    def _proxy_lineup_rewrite(self):
        """Proxy /lineup.json and rewrite stream URLs to point to the mock's port 5004.

        Without this, shows scheduled against the mock device would have stream URLs
        pointing directly at the real device (e.g. http://192.168.x.x:5004/auto/v5.1).
        After rewriting they point to http://127.0.0.2:5004/auto/v5.1, which goes
        through the streaming proxy and keeps the mock's traffic self-contained.
        """
        try:
            with urllib.request.urlopen(
                f"http://{self.real_ip}{self.path}", timeout=10
            ) as resp:
                entries = json.loads(resp.read())

            real_base = f"http://{self.real_ip}:{STREAM_PORT}"
            mock_base = f"http://{MOCK_IP}:{STREAM_PORT}"
            for entry in entries:
                if isinstance(entry.get("URL"), str):
                    entry["URL"] = entry["URL"].replace(real_base, mock_base)

            self._send_json(entries)
        except Exception as e:
            print(f"[HTTP] lineup rewrite: {e}")
            self.send_response(502)
            self.end_headers()

    # ── Transparent proxy (all other endpoints) ───────────────────────────────

    def _proxy(self, method: str):
        """Forward any request to the real device, preserving Content-Type."""
        url = f"http://{self.real_ip}{self.path}"
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

        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            self.end_headers()
        except Exception as e:
            print(f"[HTTP] proxy {method} {url}: {e}")
            self.send_response(502)
            self.end_headers()

    def _send_json(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


# ── Loopback alias management ─────────────────────────────────────────────────

def add_loopback_alias():
    r = subprocess.run(["ifconfig", "lo0", "alias", MOCK_IP], capture_output=True)
    if r.returncode == 0:
        print(f"[Setup] Added loopback alias {MOCK_IP}")
    else:
        print(f"[Setup] {r.stderr.decode().strip() or f'{MOCK_IP} already configured'}")


def remove_loopback_alias():
    subprocess.run(["ifconfig", "lo0", "-alias", MOCK_IP], capture_output=True)
    print(f"[Teardown] Removed loopback alias {MOCK_IP}")


# ── mDNS registration via dns-sd ──────────────────────────────────────────────

def mdns_hostname(device_id: str) -> str:
    return f"hdhomerun-{device_id.lower()}.local"


def register_mdns(device_id: str, friendly_name: str, ip: str) -> subprocess.Popen:
    """Register <device_id>.local → ip via dns-sd proxy.

    dns-sd -P registers a Bonjour proxy service which causes mDNSResponder to:
      1. Advertise the _hdhomerun._tcp service so Bonjour browsers find the mock
      2. Create an A record so hdhomerun-<id>.local resolves to the mock IP
    """
    hostname = mdns_hostname(device_id)
    proc = subprocess.Popen(
        [
            "dns-sd", "-P",
            friendly_name,      # service instance name
            "_hdhomerun._tcp",  # HDHomeRun Bonjour service type
            "local",            # domain
            str(CONTROL_PORT),  # port
            hostname,           # target hostname (gets the A record)
            ip,                 # IP address for the A record
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    print(f"[mDNS] Registered {hostname} → {ip}")
    return proc


def unregister_mdns(proc: subprocess.Popen):
    proc.terminate()
    proc.wait()
    print(f"[mDNS] Unregistered {mdns_hostname(MOCK_DEVICE_ID)}")


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(
        description="Mock HDHomeRun — multi-tuner testing for hdhr_VCR",
        epilog=(
            "Examples:\n"
            "  sudo python3 tools/mock_hdhr.py --real-ip 192.168.1.100\n"
            "\n"
            "The mock advertises itself as device FFFF0001 on 127.0.0.2.\n"
            "Both mDNS (hdhomerun-ffff0001.local) and UDP discovery are registered\n"
            "so the app finds it alongside the real device on the next Refresh Guide.\n"
            "\n"
            "All lineup and guide data is proxied live from the real device.\n"
            "Stream URLs in lineup.json are rewritten to route through the mock's\n"
            "port-5004 proxy, so recordings scheduled against the mock stay\n"
            "self-contained and show up in logs as the mock device ID.\n"
            "\n"
            "Ctrl+C cleans up the loopback alias and mDNS registration automatically."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--real-ip", required=True, metavar="IP",
                    help="IP address of the real HDHomeRun device to proxy")
    args = ap.parse_args()

    if os.geteuid() != 0:
        print("Error: must run as root (sudo) to bind port 80 and manage the loopback alias.")
        print(f"\n  sudo python3 {sys.argv[0]} --real-ip {args.real_ip}")
        sys.exit(1)

    # Fetch real device metadata once at startup
    try:
        url = f"http://{args.real_ip}/discover.json"
        print(f"Fetching real device info from {url} …")
        with urllib.request.urlopen(url, timeout=5) as resp:
            real_info = json.loads(resp.read())
        print(f"  {real_info.get('FriendlyName', '?')}  "
              f"ID={real_info.get('DeviceID', '?')}  "
              f"DeviceAuth={'present' if real_info.get('DeviceAuth') else 'absent'}")
    except Exception as e:
        print(f"Warning: could not reach {args.real_ip} ({e}) — serving minimal discover.json")
        real_info = {}

    friendly = real_info.get("FriendlyName", "HDHomeRun") + " (Mock)"

    ControlHandler.real_ip   = args.real_ip
    ControlHandler.real_info = real_info
    StreamHandler.real_ip    = args.real_ip

    add_loopback_alias()
    mdns_proc = register_mdns(MOCK_DEVICE_ID, friendly, MOCK_IP)

    def shutdown(sig=None, frame=None):
        print()
        unregister_mdns(mdns_proc)
        remove_loopback_alias()
        sys.exit(0)

    signal.signal(signal.SIGINT,  shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    threading.Thread(target=udp_thread, daemon=True).start()

    # Stream server (threaded — each active stream runs in its own thread)
    try:
        stream_server = ThreadedHTTPServer((MOCK_IP, STREAM_PORT), StreamHandler)
    except OSError as e:
        print(f"Failed to bind stream server {MOCK_IP}:{STREAM_PORT}: {e}")
        remove_loopback_alias()
        sys.exit(1)
    threading.Thread(target=stream_server.serve_forever, daemon=True).start()

    # Control server (also threaded for consistent behaviour)
    try:
        control_server = ThreadedHTTPServer((MOCK_IP, CONTROL_PORT), ControlHandler)
    except OSError as e:
        print(f"Failed to bind control server {MOCK_IP}:{CONTROL_PORT}: {e}")
        remove_loopback_alias()
        sys.exit(1)

    print(f"\nMock HDHomeRun ready:")
    print(f"  Device ID : {MOCK_DEVICE_ID}")
    print(f"  Name      : {friendly}")
    print(f"  Control   : http://{MOCK_IP}:{CONTROL_PORT}/")
    print(f"  Streaming : http://{MOCK_IP}:{STREAM_PORT}/")
    print(f"  Proxying  : http://{args.real_ip}/")
    print(f"\nCtrl+C to stop and remove the loopback alias.\n")

    control_server.serve_forever()


if __name__ == "__main__":
    main()
