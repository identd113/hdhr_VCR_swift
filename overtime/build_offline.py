#!/usr/bin/env python3
"""Build an offline channel lineup and program guide from the air: no Silicondust cloud, no internet.

For each RF channel that has signal: capture the whole multiplex from an IDLE tuner for --seconds, decode its PSIP tables
(overtime/psip.py), then merge every multiplex into
  lineup.json  same shape as the tuner's /lineup.json (GuideNumber, GuideName, HD, VideoCodec, AudioCodec, URL) plus Frequency / ProgramNumber / RF
  guide.json   same shape as the cloud guide the app already reads (GuideStore / GuideChannel / GuideEntry): a list of
               {GuideNumber, GuideName, Guide:[{StartTime, EndTime, Title, Synopsis, ...}]}, times in epoch seconds
  rf<N>.json   the raw decode of each multiplex

  overtime/build_offline.py --ip 10.0.2.101                          # RF channels with signal from the latest sweep report
  overtime/build_offline.py --ip 10.0.2.101 --rf 31,32 --seconds 90  # just these
  overtime/build_offline.py --ip 10.0.2.101 --compare                # afterwards: compare with the tuner's real lineup

Uses one idle tuner at a time and waits when both are busy, so it never takes a tuner from a recording.
What the air does not carry: SeriesID, genre tags, episode titles/numbers, images. Everything else the app's guide needs is there.
"""
import argparse, concurrent.futures, datetime, glob, json, os, sys, threading, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
import psip                                   # noqa: E402
import band_sweep as bs                       # noqa: E402


_reserved, _lock = set(), threading.Lock()


def claim_idle_tuner(ip, patience=900):
    """An idle tuner nobody (including another worker of ours) is using; marks it ours until release_tuner."""
    end = time.time() + patience
    while time.time() < end:
        try:
            rows = bs.get_json(f"http://{ip}/status.json")
        except Exception:
            rows = []
        with _lock:
            for row in rows:
                t = row["Resource"]
                if "VctNumber" not in row and "Frequency" not in row and "TargetIP" not in row and t not in _reserved:
                    _reserved.add(t)
                    return t
        time.sleep(15)
    return None


def release_tuner(t):
    with _lock:
        _reserved.discard(t)


def rf_list_from_report(path):
    rows = json.load(open(path))
    return [r["rf"] for r in rows if r.get("state") == "signal" and r.get("programs") and r.get("mbps", 0) > 10]


def capture_and_decode(ip, rf, seconds, out):
    tuner = claim_idle_tuner(ip)
    if not tuner:
        return None, "no idle tuner"
    ts = os.path.join(out, f"rf{rf}.ts")
    try:
        total, st, err = bs.capture(ip, tuner, bs.rf_to_hz(rf), seconds, ts)
        if total < 1_000_000:
            return None, err or "no signal"
        info = bs.summarize_programs(bs.probe(ts))
        try:
            d = psip.decode_capture(ts)
        except SystemExit as e:
            return None, str(e)
        d["rf"], d["mhz"], d["signal"], d["pmt_programs"] = rf, bs.rf_to_hz(rf) // 1_000_000, {
            k: st.get(k) for k in ("SignalStrengthPercent", "SignalQualityPercent")}, info
        with open(os.path.join(out, f"rf{rf}.json"), "w") as f:
            json.dump(d, f, indent=1)
        return d, None
    finally:
        release_tuner(tuner)
        if os.path.exists(ts):
            os.remove(ts)   # a capture is about 200 MB; only the decode is kept


def merge(decodes, ip):
    lineup, guide = [], []
    for d in decodes:
        by_prog = {p["program"]: p for p in d.get("pmt_programs", [])}
        by_src = {}
        for e in d["events"]:
            by_src.setdefault(e["source_id"], []).append(e)
        for ch in d["channels"]:
            if ch["service_type"] not in (2, 3):   # 2 = TV, 3 = audio; skip data services
                continue
            p = by_prog.get(ch["program"], {})
            v = p.get("video", "")
            height = int(v.split("x")[-1]) if "x" in v and v.split("x")[-1].isdigit() else 0
            lineup.append({
                "GuideNumber": ch["number"], "GuideName": ch["name"], "HD": 1 if height >= 720 else 0,
                "VideoCodec": v.split(" ")[0].upper().replace("MPEG2VIDEO", "MPEG2") if v else "",
                "AudioCodec": p.get("audio", "").split(",")[0].upper(),
                "URL": f"http://{ip}:5004/auto/v{ch['number']}",
                "RF": d["rf"], "Frequency": d["mhz"] * 1_000_000, "ProgramNumber": ch["program"],
                "Hidden": ch["hidden"], "Protected": ch["access_controlled"],
                "SignalStrengthPercent": d["signal"].get("SignalStrengthPercent"),
            })
            entries = []
            for e in by_src.get(ch["source_id"], []):
                start = int(datetime.datetime.fromisoformat(e["start_utc"]).timestamp())
                entry = {"StartTime": start, "EndTime": start + e["length_s"], "Title": e["title"] or "(untitled)"}
                if e["description"]:
                    entry["Synopsis"] = e["description"]
                if e["rating"]:
                    entry["Rating"] = e["rating"]
                entries.append(entry)
            entries.sort(key=lambda x: x["StartTime"])
            guide.append({"GuideNumber": ch["number"], "GuideName": ch["name"], "Guide": entries})
    key = lambda c: tuple(int(x) for x in c["GuideNumber"].split("."))
    return sorted(lineup, key=key), sorted(guide, key=key)


def compare(ip, lineup, guide):
    real = bs.get_json(f"http://{ip}/lineup.json", 10)
    real_nums = {c["GuideNumber"]: c for c in real}
    ours = {c["GuideNumber"]: c for c in lineup}
    print(f"\nLineup: the tuner lists {len(real)} channels; the air gave {len(ours)} TV/audio channels.")
    print(f"  in both: {len(set(real_nums) & set(ours))}")
    print(f"  only on the air (not in your lineup): {sorted(set(ours) - set(real_nums), key=lambda n: tuple(map(int, n.split('.'))))}")
    print(f"  only in the lineup (not found on the air): {sorted(set(real_nums) - set(ours), key=lambda n: tuple(map(int, n.split('.'))))}")
    names_differ = [(n, real_nums[n]["GuideName"], ours[n]["GuideName"]) for n in set(real_nums) & set(ours)
                    if real_nums[n]["GuideName"].strip().lower() != ours[n]["GuideName"].strip().lower()]
    if names_differ:
        print("  names that differ (lineup vs air):", sorted(names_differ)[:12])
    now = time.time()
    horizon = [max((e["EndTime"] for e in g["Guide"]), default=0) for g in guide]
    with_guide = sum(1 for g in guide if g["Guide"])
    print(f"\nGuide: {with_guide} of {len(guide)} channels have listings; "
          f"median coverage {sorted((h - now) / 3600 for h in horizon)[len(horizon) // 2]:.0f} hours ahead.")
    events = [e for g in guide for e in g["Guide"]]
    print(f"  {len(events)} events; {sum(1 for e in events if e.get('Synopsis'))} with a description, "
          f"{sum(1 for e in events if e.get('Rating'))} with a rating.")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ip", required=True, help="HDHomeRun address")
    ap.add_argument("--rf", help="RF channels to capture, e.g. 31,32 (default: the ones with signal in the latest sweep report)")
    ap.add_argument("--seconds", type=float, default=75, help="capture per multiplex (default 75; the guide tables repeat within about a minute)")
    ap.add_argument("--out", default=os.path.join(HERE, "offline"), help="output folder (default overtime/offline)")
    ap.add_argument("--workers", type=int, default=2, help="captures at once, one per idle tuner (default 2: both tuners of an HDTC-2US)")
    ap.add_argument("--compare", action="store_true", help="compare the result with the tuner's real lineup")
    ap.add_argument("--redo", action="store_true", help="capture again even when rf<N>.json already exists")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    if a.rf:
        rfs = [int(x) for x in a.rf.split(",")]
    else:
        reports = sorted(glob.glob(os.path.join(HERE, "sweep-*.json")))
        if not reports:
            sys.exit("No sweep report found: pass --rf or run tools/band_sweep.py first.")
        rfs = rf_list_from_report(reports[-1])
    print("RF channels:", rfs)
    decodes = {}

    def work(rf):
        cached = os.path.join(a.out, f"rf{rf}.json")
        if os.path.exists(cached) and not a.redo:
            print(f"RF {rf}: using saved {cached}", flush=True)
            return rf, json.load(open(cached))
        d, err = capture_and_decode(a.ip, rf, a.seconds, a.out)
        print(f"RF {rf}: " + (f'{len(d["channels"])} channels, {len(d["events"])} events' if d else f"skipped ({err})"), flush=True)
        return rf, d

    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, a.workers)) as pool:
        for rf, d in pool.map(work, rfs):
            if d:
                decodes[rf] = d
    decodes = [decodes[rf] for rf in sorted(decodes)]
    lineup, guide = merge(decodes, a.ip)
    json.dump(lineup, open(os.path.join(a.out, "lineup.json"), "w"), indent=1)
    json.dump(guide, open(os.path.join(a.out, "guide.json"), "w"), indent=1)
    print(f"\nWrote {len(lineup)} channels to {a.out}/lineup.json and {a.out}/guide.json")
    if a.compare:
        compare(a.ip, lineup, guide)


if __name__ == "__main__":
    main()
