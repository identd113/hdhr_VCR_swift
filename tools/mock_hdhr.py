#!/usr/bin/env python3
"""
mock_hdhr.py — Mock HDHomeRun device for testing hdhr_VCR with multiple tuners.

Appears on 127.0.0.2 as a second device. All API requests are proxied to the
real device. Only /discover.json has fields swapped (DeviceID, name, URLs) so
the app treats it as a separate tuner. DeviceAuth is kept from the real device
so the cloud guide API works identically.

Requirements:
  - Python 3 (ships with macOS)
  - Must run as root (port 80 + loopback alias setup)

Usage:
    sudo python3 tools/mock_hdhr.py              # auto-discovers the attached HDHomeRun
    sudo python3 tools/mock_hdhr.py --real-ip 192.168.x.x  # override with a specific IP

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
DISCOVER_PORT  = 65001
MOCK_DEVICE_ID = "FFFF0001"


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
        print(f"[Discovery] UDP error: {e}")
    finally:
        sock.close()

    for hostname in ("hdhomerun.local", "hdhr.local"):
        try:
            ip = socket.gethostbyname(hostname)
            if not ip.startswith("127."):
                print(f"[Discovery] Resolved {hostname} → {ip}")
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


def udp_thread():
    reply_pkt = build_discover_reply()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    try:
        sock.bind(("", DISCOVER_PORT))
    except OSError as e:
        print(f"[UDP] Cannot bind :{DISCOVER_PORT}: {e} — UDP discovery disabled")
        return

    print(f"[UDP] Listening on :{DISCOVER_PORT}, responding as {MOCK_DEVICE_ID}")
    while True:
        try:
            data, addr = sock.recvfrom(1024)
            if len(data) >= 4 and data[0] == 0x00 and data[1] == 0x02:
                print(f"[UDP] Discovery request from {addr[0]}")
                reply_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                reply_sock.bind((MOCK_IP, 0))
                reply_sock.sendto(reply_pkt, addr)
                reply_sock.close()
        except Exception as e:
            print(f"[UDP] Error: {e}")


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
    print(f"[mDNS] Registered {hostname} → {ip}")
    return proc


def unregister_mdns(proc: subprocess.Popen):
    proc.terminate()
    proc.wait()
    print(f"[mDNS] Unregistered {mdns_hostname(MOCK_DEVICE_ID)}")


# ── Loopback alias ────────────────────────────────────────────────────────────

def add_loopback_alias():
    r = subprocess.run(["ifconfig", "lo0", "alias", MOCK_IP], capture_output=True)
    if r.returncode == 0:
        print(f"[Setup] Added loopback alias {MOCK_IP}")
    else:
        print(f"[Setup] {r.stderr.decode().strip() or f'{MOCK_IP} already configured'}")


def remove_loopback_alias():
    subprocess.run(["ifconfig", "lo0", "-alias", MOCK_IP], capture_output=True)
    print(f"[Teardown] Removed loopback alias {MOCK_IP}")


# ── HTTP control server ───────────────────────────────────────────────────────

class ControlHandler(BaseHTTPRequestHandler):
    real_ip:   str  = ""
    real_info: dict = {}

    def log_message(self, fmt, *args):
        print(f"[HTTP] {fmt % args}")

    def do_GET(self):
        if self.path.split("?")[0] == "/discover.json":
            self._send_json(self._mock_discover())
        else:
            self._proxy("GET")

    def do_POST(self):
        self._proxy("POST")

    def _mock_discover(self) -> dict:
        """Real device info with DeviceID, name, and URLs swapped for the mock.
        DeviceAuth is kept from the real device so the cloud guide API works."""
        d        = dict(self.real_info)
        hostname = mdns_hostname(MOCK_DEVICE_ID)
        d["DeviceID"]     = MOCK_DEVICE_ID
        d["FriendlyName"] = d.get("FriendlyName", "HDHomeRun") + " (Mock)"
        d["ModelNumber"]  = d.get("ModelNumber",  "HDHR")       + "-MOCK"
        d["BaseURL"]      = f"http://{hostname}"
        d["LineupURL"]    = f"http://{hostname}/lineup.json"
        return d

    def _proxy(self, method: str):
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


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(
        description="Mock HDHomeRun — multi-tuner testing for hdhr_VCR",
        epilog=(
            "Examples:\n"
            "  sudo python3 tools/mock_hdhr.py                          # auto-discover\n"
            "  sudo python3 tools/mock_hdhr.py --real-ip 192.168.1.100  # explicit IP\n"
            "\n"
            "The mock advertises itself as device FFFF0001 on 127.0.0.2.\n"
            "All API requests are proxied to the real device; only /discover.json\n"
            "has DeviceID/name/URL fields swapped. DeviceAuth is kept so the\n"
            "cloud guide API works for both devices.\n"
            "\n"
            "Ctrl+C cleans up the loopback alias and mDNS registration automatically."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--real-ip", metavar="IP", default=None,
                    help="IP of the real HDHomeRun (auto-discovered if omitted)")
    args = ap.parse_args()

    if os.geteuid() != 0:
        print("Error: must run as root (sudo) to bind port 80 and manage the loopback alias.")
        suffix = f" --real-ip {args.real_ip}" if args.real_ip else ""
        print(f"\n  sudo python3 {sys.argv[0]}{suffix}")
        sys.exit(1)

    real_ip = args.real_ip
    if not real_ip:
        print("No --real-ip given — scanning for HDHomeRun on the LAN …")
        real_ip = discover_real_device_ip()
        if not real_ip:
            print("Error: no HDHomeRun device found. Connect the device or pass --real-ip.")
            sys.exit(1)
        print(f"[Discovery] Found device at {real_ip}")

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

    ControlHandler.real_ip   = real_ip
    ControlHandler.real_info = real_info

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
    print(f"  Proxying  : http://{real_ip}/")
    print(f"\nCtrl+C to stop and remove the loopback alias.\n")

    control_server.serve_forever()


if __name__ == "__main__":
    main()
