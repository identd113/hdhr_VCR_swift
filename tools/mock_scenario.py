#!/usr/bin/env python3
"""mock_scenario.py — plant mock states in the running app to demo/test guide + scheduling
behavior, without needing to wait for real airings.

It reads the app's live guide over the LAN API and creates the artifact that triggers a
behavior — a fake recording file, or scheduled shows — then cleans them up on request.

Subcommands:
  duplicate [--series X]     plant a fake "already recorded" file  -> green skip flag (file-based)
  conflict  [--device X]     schedule overlapping shows on one tuner -> conflict warning
  record-test [--series X]   schedule a now-airing entry, verify it records, then clean up (uses a tuner)
  plant --file X.json        schedule arbitrary custom shows against already-loaded guide entries
  list                       list mockable upcoming managed airings (for `duplicate`)
  clean                      remove everything this tool created (mock files + [MOCK] shows)

Safety markers so `clean` never touches real data:
  * planted files carry the date signature 19700101_0000
  * scheduled shows are titled "[MOCK] ..."

Requires the app running with the web server enabled; `duplicate` also needs Series-subfolders
and Skip-already-recorded on.

`plant` schedules shows by matching (title, and optionally channel/device) against whatever the
app's guide currently has loaded — it does NOT talk to a device directly, so pair it with
tools/mock_hdhr.py's --guide-file to fully control what's actually there (real guide data works
too, e.g. for testing against a currently-airing show, but timing then isn't under your control).
File format: a JSON array of show definitions —
  [{"title": "My Show", "showType": "seriesChannel", "channel": "5.1", "device": "FFFF0001"}]
`title` is required (substring-matched, case-insensitive, against the loaded guide — the mock's
own [MOCK] prefix is added automatically, don't include it). `channel`/`device` narrow an
ambiguous match; omit them to take the earliest matching entry. `showType` is one of
single/dateTime/seriesChannel/seriesAll (default single). Optional passthrough fields: `airDays`
(array of weekday names, for dateTime), `transcode`, `bonusTime` (bool).

  tools/mock_scenario.py <subcommand> [--series X | --device X | --file X.json] [--port 1980]
"""
import argparse
import glob
import json
import os
import re
import sys
import time
import urllib.request

SIGNATURE = "19700101_0000"   # date stamp marking a planted mock file
MOCK_PREFIX = "[MOCK] "        # title prefix marking a tool-scheduled show
STUB_BYTES = 2_000_000
REC_EXTS = (".ts", ".m2ts", ".mkv")


# ── config / paths ────────────────────────────────────────────────────────────
def config_path():
    base = os.path.expanduser("~/Library/Application Support/hdhrVCRplus")
    hits = sorted(glob.glob(os.path.join(base, "hdhr_VCR-*.json")))
    if not hits:
        sys.exit("No config found under ~/Library/Application Support/hdhrVCRplus/")
    return hits[0]


def load_shows():
    with open(config_path()) as f:
        return json.load(f).get("shows", [])


def to_posix(path):
    """Mirror of Show.toPosix (Models.swift)."""
    if not path or path.startswith("/") or ":" not in path:
        return path
    stripped = path[:-1] if path.endswith(":") else path
    return "/Volumes/" + "/".join(stripped.split(":"))


def posix_record_dir(show):
    default = os.path.expanduser("~/Movies/hdhr_videos")
    primary = to_posix(show.get("show_dir") or default)
    fallback = to_posix(show.get("show_temp_dir") or default)
    if primary == fallback:
        return primary
    return primary if os.path.isdir(os.path.dirname(primary)) else fallback


# ── HTTP ──────────────────────────────────────────────────────────────────────
def http_json(port, path):
    with urllib.request.urlopen(f"http://localhost:{port}{path}", timeout=6) as r:
        return json.load(r)


def post_json(port, path, obj):
    req = urllib.request.Request(f"http://localhost:{port}{path}",
                                 data=json.dumps(obj).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)


def device_ip(shows, device_id):
    for s in shows:
        if s.get("hdhr_record") == device_id:
            m = re.search(r"http://([\d.]+):5004", s.get("show_url", ""))
            if m:
                return m.group(1)
    return None


def tuner_count(shows, device_id, default=3):
    ip = device_ip(shows, device_id)
    if ip:
        try:
            with urllib.request.urlopen(f"http://{ip}/discover.json", timeout=4) as r:
                return int(json.load(r).get("TunerCount", default))
        except Exception:
            pass
    return default


# ── guide parsing ───────────────────────────────────────────────────────────────
def guide_blocks(port, future_only=False, airing_now=False):
    grid = http_json(port, "/api/guide-refresh").get("grid", "")
    ws = int(re.search(r'data-winstart="(\d+)"', grid).group(1))
    wsec = int(re.search(r'data-winsec="(\d+)"', grid).group(1))
    now = time.time()
    out = []
    for b in re.split(r'(?=<div class="g-prog)', grid):
        st = re.search(r'data-start="(\d+)"', b)
        en = re.search(r'data-end="(\d+)"', b)
        dev = re.search(r'data-device="([^"]*)"', b)
        num = re.search(r'data-num="([^"]*)"', b)
        tit = re.search(r'data-title="([^"]*)"', b)
        mgd = 'data-managed="1"' in b
        if not (st and en and dev and num and tit):
            continue
        s, e = int(st.group(1)), int(en.group(1))
        if future_only and s <= now:
            continue
        if airing_now and not (s <= now < e):
            continue
        out.append({"start": s, "end": e, "device": dev.group(1), "channel": num.group(1),
                    "title": tit.group(1), "managed": mgd, "winstart": ws, "winsec": wsec})
    return out


def episode_for_block(port, blk):
    detail = http_json(port, f"/api/guide-detail/{blk['device']}/{blk['channel']}/{blk['winstart']}/{blk['winsec']}")
    items = detail if isinstance(detail, list) else detail.get("entries", [])
    for it in items:
        if int(it.get("start", 0)) == blk["start"]:
            m = re.match(r"(S\d+E\d+)", str(it.get("ep", "")), re.I)
            return m.group(1).upper() if m else None
    return None


# ── duplicate (file-based skip flag) ──────────────────────────────────────────
def owning_show(shows, blk):
    cand = [s for s in shows if s.get("show_active") and not s.get("show_paused")
            and (s.get("show_use_seriesid") or s.get("show_use_seriesid_all"))]
    for s in cand:
        if blk["title"].startswith(s.get("show_title", "\0")):
            return s
    return None


def do_list(port, shows):
    blocks = sorted([b for b in guide_blocks(port, future_only=True) if b["managed"]], key=lambda x: x["start"])
    if not blocks:
        print("No upcoming managed airings in the guide window.")
        return
    print(f"Mockable upcoming managed airings ({len(blocks)}):")
    for blk in blocks:
        tag = episode_for_block(port, blk)
        show = owning_show(shows, blk)
        when = time.strftime("%a %-I:%M %p", time.localtime(blk["start"]))
        ok = tag and show
        print(f"  {blk['title'][:34]:34} ch {blk['channel']:>5}  {when}  {tag or '—'}"
              + ("" if ok else "   (not mockable)"))


def do_duplicate(port, shows, series):
    blocks = sorted([b for b in guide_blocks(port, future_only=True) if b["managed"]], key=lambda x: x["start"])
    if series:
        blocks = [b for b in blocks if series.lower() in b["title"].lower()]
    for blk in blocks:
        tag = episode_for_block(port, blk)
        show = owning_show(shows, blk)
        if not tag or not show:
            continue
        safe = show["show_title"].replace("/", "-")
        m = re.match(r"S(\d+)E\d+$", tag, re.I)
        sub = os.path.join(safe, f"Season {int(m.group(1)):02d}") if m else safe
        path = os.path.join(posix_record_dir(show), sub, f"{safe}_{tag}_{blk['channel']}_{SIGNATURE}.ts")
        if os.path.exists(path):
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.seek(STUB_BYTES - 1)
            f.write(b"\0")
        when = time.strftime("%a %-I:%M %p", time.localtime(blk["start"]))
        print(f"Planted duplicate: {path}\n  → {blk['title']}  ch {blk['channel']}  {when}  ({tag})")
        nudge(port)
        print(f"\nOpen the guide (http://localhost:{port}/) — that airing shows the green skip flag. `clean` to undo.")
        return
    sys.exit("No mockable upcoming managed airing found (need a future block with a full SxxExx tag).")


# ── conflict (schedule overlapping shows on one tuner) ────────────────────────
def do_conflict(port, shows, device):
    blocks = guide_blocks(port, future_only=True)
    if not blocks:
        sys.exit("No future guide blocks available.")
    device = device or blocks[0]["device"]
    dev_blocks = [b for b in blocks if b["device"] == device]
    if not dev_blocks:
        sys.exit(f"No future blocks on device {device}.")
    tc = tuner_count(shows, device)
    need = tc + 1
    target = int(time.time()) + 2 * 3600           # ~2h out: future so nothing actually records
    spanning = [b for b in dev_blocks if b["start"] <= target < b["end"]]
    by_ch = {}
    for b in sorted(spanning, key=lambda x: x["start"]):
        by_ch.setdefault(b["channel"], b)
    picks = list(by_ch.values())[:need]
    if len(picks) < need:
        sys.exit(f"Need {need} overlapping channels on {device} (tuner count {tc}) but only found {len(picks)}.")
    print(f"Device {device} has {tc} tuner(s); scheduling {need} overlapping shows to force a conflict:")
    for blk in picks:
        r = post_json(port, "/api/record", {
            "deviceId": device, "guideNumber": blk["channel"], "startTime": blk["start"],
            "showType": "single", "title": MOCK_PREFIX + blk["title"],
        })
        when = time.strftime("%a %-I:%M %p", time.localtime(blk["start"]))
        print(f"  {'ok' if r.get('ok') else 'FAIL'}  {(MOCK_PREFIX + blk['title'])[:40]:40} ch {blk['channel']:>5}  {when}")
    nudge(port)
    print(f"\n{need} overlapping [MOCK] shows scheduled on a {tc}-tuner device → conflict.")
    print("See the menu-bar dropdown (⚠️ on the conflicting shows) and Up Next. `clean` to remove them.")


# ── record-test (schedule a now-airing entry and verify it records) ───────────
def do_record_test(port, shows, series):
    airing = guide_blocks(port, airing_now=True)
    if series:
        airing = [b for b in airing if series.lower() in b["title"].lower()]
    if not airing:
        sys.exit("No currently-airing guide entry found to record-test.")
    blk = airing[0]
    title = MOCK_PREFIX + blk["title"]
    print(f"Scheduling now-airing single: {title}  (dev {blk['device']} ch {blk['channel']})")
    r = post_json(port, "/api/record", {
        "deviceId": blk["device"], "guideNumber": blk["channel"], "startTime": blk["start"],
        "showType": "single", "title": title,
    })
    if not r.get("ok"):
        sys.exit(f"Schedule failed: {r.get('error')}")
    if r.get("tunerFull"):
        print("  ! tuner full — recording won't start. Cleaning up.")
        cleanup_mock_shows(port, [s for s in load_shows() if s.get("show_title") == title])
        sys.exit("record-test inconclusive (no free tuner).")
    print("  scheduled; waiting up to 40s for the recorder to write bytes…")
    ok, path = False, None
    for _ in range(20):
        time.sleep(2)
        show = next((s for s in load_shows() if s.get("show_title") == title), None)
        if show and show.get("show_recording") and show.get("show_recording_path"):
            path = show["show_recording_path"]
            if os.path.exists(path) and os.path.getsize(path) > 0:
                ok = True
                break
    if ok:
        print(f"  PASS — recording is writing: {path} ({os.path.getsize(path)//1024} KB and growing)")
    else:
        print("  FAIL — no growing recording file appeared within 40s")
    print("  cleaning up (stop + delete + remove partial file)…")
    cleanup_mock_shows(port, [s for s in load_shows() if s.get("show_title") == title])
    if path and os.path.exists(path):
        try:
            os.remove(path)
            print(f"  removed partial file {path}")
        except OSError as e:
            print(f"  could not remove {path}: {e}")
    sys.exit(0 if ok else 1)


# ── plant (schedule arbitrary custom shows from a JSON file) ──────────────────
def do_plant(port, file):
    try:
        with open(file) as f:
            scenario = json.load(f)
    except FileNotFoundError:
        sys.exit(f"Scenario file not found: {file}")
    except json.JSONDecodeError as e:
        sys.exit(f"Scenario file is not valid JSON: {e}")
    if not isinstance(scenario, list):
        sys.exit("Scenario file must be a JSON array of show definitions — see the module docstring.")

    # Union of future and currently-airing blocks — a scenario show can target either. De-duped
    # since a block airing right now can appear in both queries.
    seen, blocks = set(), []
    for b in guide_blocks(port, future_only=True) + guide_blocks(port, airing_now=True):
        key = (b["device"], b["channel"], b["start"])
        if key not in seen:
            seen.add(key)
            blocks.append(b)
    if not blocks:
        sys.exit("No guide entries currently loaded — nothing to match against. "
                  "See tools/mock_hdhr.py --guide-file, then Update Guides Now in the app.")

    print(f"Planting {len(scenario)} show(s) from {file}:")
    ok_count = 0
    for i, want in enumerate(scenario):
        title = (want.get("title") or "").strip()
        if not title:
            print(f"  [{i}] SKIP — missing required \"title\"")
            continue
        candidates = [b for b in blocks if title.lower() in b["title"].lower()]
        if want.get("channel"):
            candidates = [b for b in candidates if b["channel"] == want["channel"]]
        if want.get("device"):
            candidates = [b for b in candidates if b["device"] == want["device"]]
        if not candidates:
            print(f"  [{i}] FAIL — no loaded guide entry matches title={title!r}"
                  + (f" channel={want['channel']}" if want.get("channel") else "")
                  + (f" device={want['device']}" if want.get("device") else ""))
            continue
        blk = sorted(candidates, key=lambda b: b["start"])[0]
        payload = {
            "deviceId": blk["device"], "guideNumber": blk["channel"], "startTime": blk["start"],
            "showType": want.get("showType", "single"),
            "title": MOCK_PREFIX + blk["title"],
        }
        for passthrough in ("airDays", "transcode", "bonusTime"):
            if passthrough in want:
                payload[passthrough] = want[passthrough]
        r = post_json(port, "/api/record", payload)
        when = time.strftime("%a %-I:%M %p", time.localtime(blk["start"]))
        status = "ok" if r.get("ok") else f"FAIL ({r.get('error', '?')})"
        print(f"  [{i}] {status:20} {(MOCK_PREFIX + blk['title'])[:40]:40} ch {blk['channel']:>5}  {when}")
        if r.get("ok"):
            ok_count += 1
    nudge(port)
    print(f"\n{ok_count}/{len(scenario)} show(s) planted. `clean` to remove them.")
    sys.exit(0 if ok_count == len(scenario) else 1)


# ── clean ─────────────────────────────────────────────────────────────────────
def cleanup_mock_shows(port, mock_shows):
    for s in mock_shows:
        try:
            post_json(port, "/api/delete", {
                "showId": s.get("show_id", ""),
                "deviceId": s.get("hdhr_record", ""),
                "guideNumber": s.get("show_channel", ""),
                "title": s.get("show_title", ""),
            })
            print(f"  deleted show {s.get('show_title')}")
        except Exception as e:
            print(f"  could not delete {s.get('show_title')}: {e}")


def do_clean(port, shows):
    mocks = [s for s in load_shows() if s.get("show_title", "").startswith(MOCK_PREFIX)]
    if mocks:
        print(f"Removing {len(mocks)} [MOCK] show(s):")
        cleanup_mock_shows(port, mocks)
    removed = 0
    roots = {posix_record_dir(s) for s in shows} | {posix_record_dir(s) for s in mocks}
    for root in roots:
        if not root or not os.path.isdir(root):
            continue
        for ext in REC_EXTS:
            for pat in (f"*_{SIGNATURE}{ext}", f"{MOCK_PREFIX}*{ext}"):
                for path in glob.glob(os.path.join(root, "**", pat), recursive=True):
                    try:
                        os.remove(path)
                        removed += 1
                        print(f"  removed file {path}")
                        d = os.path.dirname(path)
                        if d != root and not os.listdir(d):
                            os.rmdir(d)
                    except OSError as e:
                        print(f"  could not remove {path}: {e}")
    print(f"\nDone. {len(mocks)} show(s), {removed} file(s) removed.")
    nudge(port)


def nudge(port):
    try:
        http_json(port, "/api/guide-refresh")
    except Exception:
        pass


# ── main ──────────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(description="Plant/remove mock app states to demo or test guide + scheduling behavior.")
    ap.add_argument("cmd", choices=["duplicate", "conflict", "record-test", "plant", "list", "clean"],
                    help="scenario to mock (or list/clean)")
    ap.add_argument("--series", help="restrict to a series whose title contains this text")
    ap.add_argument("--device", help="device id for `conflict` (default: first device in the guide)")
    ap.add_argument("--file", help="scenario JSON file for `plant` — see the module docstring for the format")
    ap.add_argument("--port", type=int, default=1980, help="web server port (default 1980)")
    args = ap.parse_args()

    if args.cmd == "plant" and not args.file:
        sys.exit("`plant` requires --file <scenario.json>")

    shows = load_shows()
    try:
        if args.cmd == "list":
            do_list(args.port, shows)
        elif args.cmd == "duplicate":
            do_duplicate(args.port, shows, args.series)
        elif args.cmd == "conflict":
            do_conflict(args.port, shows, args.device)
        elif args.cmd == "record-test":
            do_record_test(args.port, shows, args.series)
        elif args.cmd == "plant":
            do_plant(args.port, args.file)
        elif args.cmd == "clean":
            do_clean(args.port, shows)
    except urllib.error.URLError:
        sys.exit(f"Could not reach the app's web server on port {args.port}. Is the app running with the web server enabled?")


if __name__ == "__main__":
    main()
