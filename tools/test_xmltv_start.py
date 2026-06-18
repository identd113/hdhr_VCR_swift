#!/usr/bin/env python3
"""
test_xmltv_start.py — probe whether api.hdhomerun.com/api/xmltv honours a Start= parameter.

Usage:
    python3 tools/test_xmltv_start.py <device-ip>
    python3 tools/test_xmltv_start.py <device-ip> --start-offset -3600   # default
    python3 tools/test_xmltv_start.py --auth <DeviceAuth>

Steps:
  1. Fetch DeviceAuth from device /discover.json (skipped if --auth is given)
  2. Fetch XMLTV *without* Start param  → baseline
  3. Fetch XMLTV with Start=now+offset   → experimental
  4. Parse both; compare earliest/latest programme StartTime
  5. Print a clear verdict: honoured / ignored / different size
"""

import argparse
import sys
import time
import urllib.request
import urllib.error
import json
import gzip
import xml.etree.ElementTree as ET
from datetime import datetime, timezone


XMLTV_URL = "https://api.hdhomerun.com/api/xmltv"
DISCOVER_URL = "http://{ip}/discover.json"
DATEFMT = "%Y%m%d%H%M%S %z"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def fetch(url: str, label: str) -> bytes:
    print(f"\n→ GET {url}")
    t0 = time.time()
    req = urllib.request.Request(url, headers={"Accept-Encoding": "gzip"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read()
        enc = resp.headers.get("Content-Encoding", "")
    ms = int((time.time() - t0) * 1000)
    if enc == "gzip" or raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    print(f"  {label}: {len(raw):,} bytes  {ms}ms")
    return raw


def parse_xmltv(data: bytes) -> list[dict]:
    """Return list of {channel, start_epoch, stop_epoch, title} dicts."""
    root = ET.fromstring(data)
    programmes = []
    for p in root.iter("programme"):
        start_str = p.get("start", "")
        stop_str  = p.get("stop", "")
        channel   = p.get("channel", "")
        title_el  = p.find("title")
        title     = title_el.text if title_el is not None else ""
        try:
            start_epoch = int(datetime.strptime(start_str, DATEFMT).timestamp())
            stop_epoch  = int(datetime.strptime(stop_str,  DATEFMT).timestamp())
        except ValueError:
            continue
        programmes.append({"channel": channel, "start": start_epoch,
                            "stop": stop_epoch, "title": title})
    return programmes


def epoch_to_str(epoch: int) -> str:
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


def summarise(label: str, progs: list[dict], now: int, requested_start: int | None = None):
    if not progs:
        print(f"  [{label}] NO PROGRAMMES PARSED")
        return
    earliest = min(progs, key=lambda p: p["start"])
    latest   = max(progs, key=lambda p: p["start"])
    print(f"\n  [{label}]  {len(progs):,} programmes")
    print(f"    earliest start : {epoch_to_str(earliest['start'])}  ({earliest['start']})")
    if requested_start is not None:
        delta = earliest["start"] - requested_start
        sign  = "+" if delta >= 0 else ""
        print(f"    vs requestedStart: {sign}{delta}s  ({'+' if delta >= 0 else ''}{delta // 60} min)")
    delta_now = earliest["start"] - now
    sign_now  = "+" if delta_now >= 0 else ""
    print(f"    vs now           : {sign_now}{delta_now}s  ({sign_now}{delta_now // 60} min)")
    print(f"    latest  start  : {epoch_to_str(latest['start'])}  ({latest['start']})")

    # Show first 3 programmes
    print(f"    first 3 entries:")
    for p in sorted(progs, key=lambda x: x["start"])[:3]:
        print(f"      {epoch_to_str(p['start'])}  {p['title'][:60]}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Test XMLTV Start= param support")
    parser.add_argument("device_ip", nargs="?", help="HDHomeRun device IP (e.g. 10.0.2.101)")
    parser.add_argument("--auth", help="DeviceAuth token (skips discover step)")
    parser.add_argument("--start-offset", type=int, default=-3600,
                        help="Seconds relative to now for the Start= param (default: -3600)")
    args = parser.parse_args()

    if not args.auth and not args.device_ip:
        parser.error("provide a device IP or --auth token")

    # Step 1: get DeviceAuth
    if args.auth:
        device_auth = args.auth
        print(f"Using provided DeviceAuth: {device_auth}")
    else:
        print(f"\nFetching DeviceAuth from {args.device_ip} ...")
        try:
            discover_raw = fetch(DISCOVER_URL.format(ip=args.device_ip), "discover.json")
            info = json.loads(discover_raw)
            device_auth = info.get("DeviceAuth")
            if not device_auth:
                print("ERROR: DeviceAuth not found in discover.json response:")
                print(json.dumps(info, indent=2))
                sys.exit(1)
            print(f"  DeviceAuth: {device_auth}  (DeviceID: {info.get('DeviceID', '?')})")
        except urllib.error.URLError as e:
            print(f"ERROR fetching discover.json: {e}")
            sys.exit(1)

    now = int(time.time())
    requested_start = now + args.start_offset
    print(f"\nnow            = {now}  ({epoch_to_str(now)})")
    print(f"requestedStart = {requested_start}  ({epoch_to_str(requested_start)})  (offset {args.start_offset:+}s)")

    # Step 2: baseline — no Start param
    try:
        baseline_data = fetch(f"{XMLTV_URL}?DeviceAuth={device_auth}", "baseline (no Start)")
        baseline_progs = parse_xmltv(baseline_data)
    except Exception as e:
        print(f"ERROR fetching baseline: {e}")
        sys.exit(1)

    # Step 3: experimental — with Start param
    try:
        exp_data = fetch(f"{XMLTV_URL}?DeviceAuth={device_auth}&Start={requested_start}", "experimental (Start=)")
        exp_progs = parse_xmltv(exp_data)
    except Exception as e:
        print(f"ERROR fetching experimental: {e}")
        sys.exit(1)

    # Step 4: compare
    print("\n" + "=" * 60)
    print("RESULTS")
    print("=" * 60)
    summarise("baseline  ", baseline_progs, now)
    summarise("with Start", exp_progs, now, requested_start)

    # Verdict
    print("\n" + "-" * 60)
    if not baseline_progs or not exp_progs:
        print("VERDICT: could not compare — one or both fetches returned no data")
        return

    b_earliest = min(p["start"] for p in baseline_progs)
    e_earliest = min(p["start"] for p in exp_progs)
    diff = e_earliest - b_earliest

    if abs(diff) < 60:
        print(f"VERDICT: START PARAM IGNORED — earliest times within 60s of each other (diff={diff}s)")
    elif e_earliest < b_earliest:
        print(f"VERDICT: START PARAM HONOURED — experimental is {abs(diff)}s earlier than baseline")
    else:
        print(f"VERDICT: UNEXPECTED — experimental is {diff}s LATER than baseline")

    # Also note whether experimental includes data before now
    if e_earliest < now:
        print(f"  → experimental includes {(now - e_earliest) // 60} min of lookback before now")
    else:
        print(f"  → experimental starts {(e_earliest - now) // 60} min AFTER now (no lookback)")


if __name__ == "__main__":
    main()
