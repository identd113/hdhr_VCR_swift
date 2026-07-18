#!/usr/bin/env python3
"""mock_duplicate.py — plant (or remove) a fake "already recorded" file so the web guide's
green "already recorded / will skip" corner flag can be demoed without a real recording.

It reads the running app's live guide to find a real *upcoming* airing of a managed series,
looks up that airing's SxxExx episode number, and drops a >1 MB dummy file named exactly the
way the recorder would — so `recordedEpisodeTags` matches it and the block turns green.

Every mock file is stamped with the date signature 19700101_0000 so --clean can find and
remove them without touching real recordings.

Requires the app to be running (web server on --port, default 1980) with
**Series subfolders** and **Skip already-recorded episodes** enabled.

Usage:
  tools/mock_duplicate.py                 # plant a mock for the soonest upcoming managed airing
  tools/mock_duplicate.py --series "20/20"# plant a mock for a specific series (matches title prefix)
  tools/mock_duplicate.py --list          # list upcoming managed airings you could mock (no changes)
  tools/mock_duplicate.py --clean         # remove every mock duplicate this tool planted
  tools/mock_duplicate.py --port 1980     # web server port (default 1980)
"""
import argparse
import glob
import json
import os
import re
import sys
import time
import urllib.request

SIGNATURE = "19700101_0000"   # date stamp that marks a file as a mock (never a real recording)
STUB_BYTES = 2_000_000         # >1 MB so it clears recordedEpisodeTags' failed-stub floor
REC_EXTS = (".ts", ".m2ts", ".mkv")


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
    """Mirror of Show.toPosix (Models.swift): HFS colon path -> /Volumes/... ."""
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


def http_json(port, path):
    with urllib.request.urlopen(f"http://localhost:{port}{path}", timeout=6) as r:
        return json.load(r)


def future_managed_blocks(port):
    """Parse the live guide grid for upcoming (start>now) managed blocks."""
    grid = http_json(port, "/api/guide-refresh").get("grid", "")
    ws = int(re.search(r'data-winstart="(\d+)"', grid).group(1))
    wsec = int(re.search(r'data-winsec="(\d+)"', grid).group(1))
    now = time.time()
    blocks = []
    for b in re.split(r'(?=<div class="g-prog)', grid):
        if 'data-managed="1"' not in b:
            continue
        st = re.search(r'data-start="(\d+)"', b)
        dev = re.search(r'data-device="([^"]*)"', b)
        num = re.search(r'data-num="([^"]*)"', b)
        sid = re.search(r'data-series="([^"]*)"', b)
        tit = re.search(r'data-title="([^"]*)"', b)
        if not (st and dev and num and tit):
            continue
        if int(st.group(1)) <= now:
            continue
        blocks.append({
            "start": int(st.group(1)), "device": dev.group(1), "channel": num.group(1),
            "series": sid.group(1) if sid else "", "title": tit.group(1),
            "winstart": ws, "winsec": wsec,
        })
    blocks.sort(key=lambda x: x["start"])
    return blocks


def episode_for_block(port, blk):
    """SxxExx for a block, via /api/guide-detail (matched by start time). None if not a full tag."""
    detail = http_json(port, f"/api/guide-detail/{blk['device']}/{blk['channel']}/{blk['winstart']}/{blk['winsec']}")
    items = detail if isinstance(detail, list) else detail.get("entries", [])
    for it in items:
        if int(it.get("start", 0)) == blk["start"]:
            m = re.match(r"(S\d+E\d+)", str(it.get("ep", "")), re.I)
            return m.group(1).upper() if m else None
    return None


def owning_show(shows, blk):
    """Find the managed show (from config) that owns a guide block, by SeriesID then title."""
    cand = [s for s in shows if s.get("show_active") and not s.get("show_paused")
            and (s.get("show_use_seriesid") or s.get("show_use_seriesid_all"))]
    if blk["series"]:
        for s in cand:
            if s.get("show_seriesid") == blk["series"]:
                return s
    for s in cand:
        if blk["title"].startswith(s.get("show_title", "\0")):
            return s
    return None


def season_subfolder(safe_title, tag):
    m = re.match(r"S(\d+)E\d+$", tag, re.I)
    if m:
        return os.path.join(safe_title, f"Season {int(m.group(1)):02d}")
    return safe_title


def mock_path(show, blk, tag):
    safe = show.get("show_title", "").replace("/", "-")
    base = posix_record_dir(show)
    folder = os.path.join(base, season_subfolder(safe, tag))
    fname = f"{safe}_{tag}_{blk['channel']}_{SIGNATURE}.ts"
    return os.path.join(folder, fname)


def do_list(port, shows):
    blocks = future_managed_blocks(port)
    if not blocks:
        print("No upcoming managed airings in the guide window.")
        return
    print(f"Upcoming managed airings you could mock ({len(blocks)}):")
    for blk in blocks:
        tag = episode_for_block(port, blk)
        when = time.strftime("%a %-I:%M %p", time.localtime(blk["start"]))
        show = owning_show(shows, blk)
        note = "" if (tag and show) else "   (no S..E.. tag or unresolved show — not mockable)"
        print(f"  {blk['title'][:34]:34} ch {blk['channel']:>5}  {when}  {tag or '—'}{note}")


def do_plant(port, shows, series):
    blocks = future_managed_blocks(port)
    if series:
        blocks = [b for b in blocks if series.lower() in b["title"].lower()]
    for blk in blocks:
        tag = episode_for_block(port, blk)
        show = owning_show(shows, blk)
        if not tag or not show:
            continue
        path = mock_path(show, blk, tag)
        if os.path.exists(path):
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.seek(STUB_BYTES - 1)
            f.write(b"\0")
        when = time.strftime("%a %-I:%M %p", time.localtime(blk["start"]))
        print(f"Planted mock duplicate:\n  {path}")
        print(f"  → {blk['title']}  ch {blk['channel']}  {when}  ({tag})")
        try:
            http_json(port, "/api/guide-refresh")  # nudge a rebuild so the flag appears
        except Exception:
            pass
        print("\nOpen the guide (http://localhost:%d/) — that airing now shows the green" % port)
        print("'already recorded / will skip' corner flag. Run --clean to undo.")
        return
    msg = f' matching "{series}"' if series else ""
    sys.exit(f"No mockable upcoming managed airing found{msg} (need a future block with a full SxxExx tag).")


def do_clean(port, shows):
    removed = 0
    roots = {posix_record_dir(s) for s in shows}
    for root in roots:
        if not root or not os.path.isdir(root):
            continue
        for ext in REC_EXTS:
            for path in glob.glob(os.path.join(root, "**", f"*_{SIGNATURE}{ext}"), recursive=True):
                try:
                    os.remove(path)
                    removed += 1
                    print(f"removed {path}")
                    d = os.path.dirname(path)
                    if not os.listdir(d):
                        os.rmdir(d)
                except OSError as e:
                    print(f"could not remove {path}: {e}")
    print(f"\nRemoved {removed} mock duplicate(s).")
    if removed:
        try:
            http_json(port, "/api/guide-refresh")
        except Exception:
            pass


def main():
    ap = argparse.ArgumentParser(description="Plant/remove a mock 'already recorded' file to demo the guide skip flag.")
    ap.add_argument("--series", help="only mock a series whose title contains this text")
    ap.add_argument("--list", action="store_true", help="list mockable upcoming managed airings, make no changes")
    ap.add_argument("--clean", action="store_true", help="remove every mock duplicate this tool planted")
    ap.add_argument("--port", type=int, default=1980, help="web server port (default 1980)")
    args = ap.parse_args()

    shows = load_shows()
    try:
        if args.clean:
            do_clean(args.port, shows)
        elif args.list:
            do_list(args.port, shows)
        else:
            do_plant(args.port, shows, args.series)
    except urllib.error.URLError:
        sys.exit(f"Could not reach the app's web server on port {args.port}. Is the app running with the web server enabled?")


if __name__ == "__main__":
    main()
