#!/usr/bin/env python3
"""Sweep an HDHomeRun's ATSC band by raw frequency, list what is on the air, and find what the lineup does not show.

Read-only for the app: talks to the tuner directly, never touches hdhrVCRplus's config or lineup. Uses one IDLE tuner
(it refuses to start if both are busy, and skips a channel the moment the tuner reports busy), a few seconds per channel.

  tools/band_sweep.py --ip 10.0.2.101                   # sweep RF 2-51, print a table, write report.json
  tools/band_sweep.py --ip 10.0.2.101 --channels 29-35  # just these RF channels
  tools/band_sweep.py --ip 10.0.2.101 --analyze         # also look at every program with ffmpeg and keep clips of interesting ones

Frequencies use the ATSC plan (centre of each 6 MHz channel): RF 2-4 = 57/63/69 MHz, 5-6 = 79/85, 7-13 = 177..213, 14-51 = 473..803.
Raw-tune URL: http://<ip>:5004/tunerN/ch<frequency in Hz>  (gives the whole multiplex; program numbers are the tuner's own).
The analysis uses the Apple Silicon ffmpeg (VideoToolbox decode where the codec allows; clips are stream-copied, not re-encoded).
Docs: docs/Tools.md "band_sweep.py".
"""
import argparse, json, os, re, subprocess, sys, tempfile, threading, time, urllib.request, urllib.error

# Minneapolis-St. Paul market, from northpine.com (2023-08) and RabbitEars: RF channel -> stations carried on it.
# (WUCW and KTCI share other stations' channels; KMSP is on RF 9, the market's only VHF station.)
KNOWN = {
    9:  "KMSP-TV 9.x (Fox, VHF)",
    16: "KPXM 41.x (Ion)",
    23: "KTCI-TV 2.x",
    29: "WFTC 9.x (+ WUCW Comet/Antenna)",
    30: "KSTC-TV 5.x (45TV, MeTV, getTV)",
    31: "KARE 11.x (NBC, + WUCW Rewind)",
    32: "WCCO-TV 4.x (CBS, + WUCW Charge)",
    34: "KTCA-TV 2.x (PBS)",
    35: "KSTP-TV 5.x (ABC, + WUCW CW)",
}


def rf_to_hz(ch):
    if 2 <= ch <= 4:   return (54 + 6 * (ch - 2) + 3) * 1_000_000
    if 5 <= ch <= 6:   return (76 + 6 * (ch - 5) + 3) * 1_000_000
    if 7 <= ch <= 13:  return (174 + 6 * (ch - 7) + 3) * 1_000_000
    if 14 <= ch <= 51: return (470 + 6 * (ch - 14) + 3) * 1_000_000
    raise ValueError(ch)


def parse_channels(spec):
    out = []
    for part in spec.split(","):
        a, _, b = part.partition("-")
        out += list(range(int(a), int(b or a) + 1))
    return [c for c in out if c != 37]   # 37 is radio astronomy


def get_json(url, timeout=6):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.load(r)


def idle_tuner(ip):
    for row in get_json(f"http://{ip}/status.json"):
        if "VctNumber" not in row and "Frequency" not in row and "TargetIP" not in row:
            return row["Resource"]
    return None


def capture(ip, tuner, hz, seconds, path):
    """Streams the raw frequency for `seconds` into path. Returns (bytes, status row read mid-capture, error)."""
    status = {}

    def poll():
        time.sleep(min(2.0, seconds / 2))
        try:
            for row in get_json(f"http://{ip}/status.json", 3):
                if row.get("Resource") == tuner:
                    status.update(row)
        except Exception:
            pass

    t = threading.Thread(target=poll, daemon=True)
    t.start()
    total = 0
    try:
        with urllib.request.urlopen(f"http://{ip}:5004/{tuner}/ch{hz}", timeout=seconds + 6) as r, open(path, "wb") as f:
            end = time.time() + seconds
            while time.time() < end:
                chunk = r.read(65536)
                if not chunk:
                    break
                f.write(chunk)
                total += len(chunk)
    except urllib.error.HTTPError as e:
        return total, status, f"HTTP {e.code}"
    except Exception as e:
        if total == 0:
            return total, status, type(e).__name__
    t.join(timeout=3)
    return total, status, None


def probe(path):
    p = subprocess.run(["ffprobe", "-v", "quiet", "-show_programs", "-show_streams", "-of", "json", path],
                       capture_output=True, text=True)
    try:
        return json.loads(p.stdout)
    except Exception:
        return {}


def summarize_programs(info):
    progs = []
    for pr in info.get("programs", []):
        v = [s for s in pr.get("streams", []) if s.get("codec_type") == "video"]
        a = [s for s in pr.get("streams", []) if s.get("codec_type") == "audio"]
        progs.append({
            "program": pr.get("program_num"),
            "name": (pr.get("tags") or {}).get("service_name", ""),
            "video": (f'{v[0].get("codec_name")} {v[0].get("width")}x{v[0].get("height")}' if v else ""),
            "audio": ",".join(sorted({s.get("codec_name", "?") for s in a})),
            "audio_only": bool(a) and not v,
        })
    return progs


def lineup_frequencies(ip):
    """Which frequency does each lineup channel sit on? Tunes the first channel of every major number (about 3 s each) through
    the normal /auto/ URL and reads the tuner's reported Frequency. Returns {frequency_hz: [lineup majors]}."""
    seen, out = set(), {}
    for c in get_json(f"http://{ip}/lineup.json", 10):
        major = c["GuideNumber"].split(".")[0]
        if major in seen:
            continue
        seen.add(major)
        found = {}

        def poll():
            time.sleep(2.0)
            try:
                for row in get_json(f"http://{ip}/status.json", 3):
                    if row.get("VctNumber") == c["GuideNumber"]:
                        found["hz"] = row.get("Frequency")
            except Exception:
                pass

        t = threading.Thread(target=poll, daemon=True)
        t.start()
        try:
            with urllib.request.urlopen(c["URL"], timeout=8) as r:
                end = time.time() + 3.2
                while time.time() < end and r.read(65536):
                    pass
        except Exception:
            pass
        t.join(timeout=3)
        if found.get("hz"):
            out.setdefault(found["hz"], []).append(major)
    return out


# ---------------------------------------------------------------- analysis (ffmpeg)

def run_ffmpeg_filters(path, program, seconds):
    """One pass over `seconds` of one program with black/freeze/silence/scene/loudness detectors. Returns raw stderr."""
    cmd = ["ffmpeg", "-hide_banner", "-nostats", "-hwaccel", "videotoolbox", "-t", str(seconds), "-i", path,
           "-filter_complex",
           f"[0:p:{program}:v:0]blackdetect=d=0.5:pix_th=0.1,freezedetect=n=0.003:d=2,"
           f"select='gt(scene,0.35)',showinfo[v];"
           f"[0:p:{program}:a:0]silencedetect=n=-45dB:d=2,ebur128=metadata=0[a]",
           "-map", "[v]", "-map", "[a]", "-f", "null", "-"]
    return subprocess.run(cmd, capture_output=True, text=True).stderr


def metrics_from(log, seconds):
    def total(pattern):
        return sum(float(x) for x in re.findall(pattern, log))
    scenes = len(re.findall(r"Parsed_showinfo", log))
    m = {
        "scene_changes_per_min": round(scenes * 60 / seconds, 1),
        "black_pct": round(100 * total(r"black_duration:([\d.]+)") / seconds, 1),
        "frozen_pct": round(100 * total(r"freeze_duration: ([\d.]+)") / seconds, 1),
        "silent_pct": round(100 * total(r"silence_duration: ([\d.]+)") / seconds, 1),
    }
    lra = re.findall(r"LRA:\s+([\d.]+) LU", log)
    loud = re.findall(r"I:\s+(-?[\d.]+) LUFS", log)
    m["loudness_range_lu"] = float(lra[-1]) if lra else None
    m["loudness_lufs"] = float(loud[-1]) if loud else None
    return m


def interest(prog, m):
    """Plain-language reasons a stream is worth a look, and a score. Deliberately simple and explainable."""
    why, score = [], 0
    if prog.get("audio_only"):
        why.append("audio only (a radio-style service)"); score += 3
    if m["black_pct"] > 60:
        why.append(f'mostly black ({m["black_pct"]}%) - a placeholder or idle service'); score += 1
    if m["frozen_pct"] > 60:
        why.append(f'picture frozen {m["frozen_pct"]}% of the time - a still image or slide (often with audio: music/announcements)'); score += 2
    if m["silent_pct"] > 60 and m["frozen_pct"] < 40 and m["black_pct"] < 60:
        why.append(f'moving picture with {m["silent_pct"]}% silence - possibly a camera feed, test pattern or a muted loop'); score += 3
    if m["scene_changes_per_min"] > 12:
        why.append(f'{m["scene_changes_per_min"]} cuts a minute - fast edited content (sports, music video, ads)'); score += 2
    if m["scene_changes_per_min"] < 0.5 and m["frozen_pct"] < 40 and m["black_pct"] < 60:
        why.append("almost no cuts but live motion - a single locked camera (weather, traffic, council or surveillance style)"); score += 2
    if m["loudness_range_lu"] is not None and m["loudness_range_lu"] > 15:
        why.append(f'very wide loudness range ({m["loudness_range_lu"]} LU) - dynamic content like film or live events'); score += 1
    return score, why


def analyze(rec, ts_path, seconds, outdir):
    """Looks at every program in one capture; keeps a stream-copied clip + a contact sheet of the ones that score."""
    results = []
    for prog in rec["programs"]:
        log = run_ffmpeg_filters(ts_path, prog["program"], seconds)
        m = metrics_from(log, seconds)
        score, why = interest(prog, m)
        item = {"program": prog["program"], "metrics": m, "score": score, "why": why}
        if score >= 3:
            base = os.path.join(outdir, f'rf{rec["rf"]}_p{prog["program"]}')
            subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", ts_path, "-map", f"0:p:{prog['program']}", "-c", "copy",
                            "-t", str(seconds), base + ".ts"])
            subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-hwaccel", "videotoolbox", "-i", ts_path,
                            "-map", f"0:p:{prog['program']}:v:0", "-vf", f"fps=4/{seconds},scale=480:-1,tile=4x1", "-frames:v", "1", base + ".jpg"])
            item["clip"], item["sheet"] = base + ".ts", base + ".jpg"
        results.append(item)
    return results


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ip", required=True, help="HDHomeRun address")
    ap.add_argument("--tuner", help="tuner0 / tuner1 (default: first idle one)")
    ap.add_argument("--channels", default="2-51", help="RF channels, e.g. 2-51 or 29-35,9 (default 2-51)")
    ap.add_argument("--seconds", type=float, default=6, help="capture per channel (default 6)")
    ap.add_argument("--map-lineup", action="store_true", help="first find which frequency every lineup channel is on (needs a free tuner, ~1 min), then flag channels with signal that are NOT in the lineup")
    ap.add_argument("--analyze", action="store_true", help="re-capture each channel that has signal for --analyze-seconds, run ffmpeg detectors on every program, keep clips of interesting ones")
    ap.add_argument("--analyze-seconds", type=float, default=30, help="capture length used for the analysis (default 30; short windows give meaningless cut rates)")
    ap.add_argument("--out", help="output folder (default: a new temp folder)")
    a = ap.parse_args()

    out = a.out or tempfile.mkdtemp(prefix="band_sweep_")
    os.makedirs(out, exist_ok=True)
    tuner = a.tuner or idle_tuner(a.ip)
    if not tuner:
        sys.exit("Both tuners are busy (a recording or viewer is using them). Try again when one is free.")
    print(f"Using {tuner} on {a.ip}; output in {out}\n")

    lineup_hz = {}
    if a.map_lineup:
        lineup_hz = lineup_frequencies(a.ip)
        print("Lineup channels sit on: " + ", ".join(f"{hz // 1_000_000} MHz = {'/'.join(v)}" for hz, v in sorted(lineup_hz.items())) + "\n")
    report = []
    for ch in parse_channels(a.channels):
        hz = rf_to_hz(ch)
        ts = os.path.join(out, f"rf{ch}.ts")
        for attempt in range(3):   # a 503 right after another request is the tuner still letting go: retry before giving up
            total, st, err = capture(a.ip, tuner, hz, a.seconds, ts)
            if not (err and err.startswith("HTTP 503")):
                break
            time.sleep(2)
        rec = {"rf": ch, "mhz": hz // 1_000_000, "known": KNOWN.get(ch, ""), "bytes": total, "error": err}
        if err and err.startswith("HTTP 503"):
            # The tuner answers 503 both when someone else took it and when a channel will not lock. Only stop in the first case.
            row = next((r for r in get_json(f"http://{a.ip}/status.json") if r.get("Resource") == tuner), {})
            if row.get("TargetIP") and row.get("TargetIP") != "":
                print(f"RF {ch:>2}: {tuner} is now in use by {row['TargetIP']} - stopping so it is not disturbed"); break
            total, err = 0, None
        if total < 200_000:
            rec["state"] = "no signal"
            os.path.exists(ts) and os.remove(ts)
        else:
            rec["state"] = "signal"
            rec["signal"] = {k: st.get(k) for k in ("SignalStrengthPercent", "SignalQualityPercent", "SymbolQualityPercent")}
            rec["programs"] = summarize_programs(probe(ts))
            rec["mbps"] = round(total * 8 / a.seconds / 1e6, 1)
            if a.analyze:
                ats = os.path.join(out, f"rf{ch}_long.ts")
                n, _, _ = capture(a.ip, tuner, hz, a.analyze_seconds, ats)
                if n > 200_000:
                    rec["analysis"] = analyze(rec, ats, a.analyze_seconds, out)
        report.append(rec)
        if rec["state"] == "signal":
            sig = rec["signal"]
            rec["lineup"] = lineup_hz.get(hz, [])
            if lineup_hz:
                flag = "" if rec["lineup"] else "   <-- NOT IN YOUR LINEUP"
                rec["known"] = rec["known"] or ("lineup " + "/".join(rec["lineup"]) if rec["lineup"] else "")
            else:
                flag = ""
            print(f'RF {ch:>2} {rec["mhz"]:>3} MHz  ss={sig["SignalStrengthPercent"]}% sq={sig["SignalQualityPercent"]}%  '
                  f'{rec["mbps"]} Mb/s  {len(rec["programs"])} programs  {rec["known"]}{flag}')
            for p in rec["programs"]:
                print(f'      p{p["program"]}: {p["video"] or "(no video)"} {p["audio"]}{"  AUDIO ONLY" if p["audio_only"] else ""}')
            for r in rec.get("analysis", []):
                if r["why"]:
                    print(f'      p{r["program"]} score {r["score"]}: ' + "; ".join(r["why"]))
        else:
            print(f'RF {ch:>2} {rec["mhz"]:>3} MHz  -' + (f'  {rec["known"]} (expected, no signal!)' if rec["known"] else ""))
    with open(os.path.join(out, "report.json"), "w") as f:
        json.dump(report, f, indent=1)
    print(f"\nReport: {os.path.join(out, 'report.json')}")


if __name__ == "__main__":
    main()
