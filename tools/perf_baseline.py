#!/usr/bin/env python3
"""Release-to-release performance baseline for hdhrVCRplus.

  tools/perf_baseline.py run  <app | hdhr_VCR binary | .dmg> --label v2.6.5 [--runs 3] [--no-splash] [--port 1985]
  tools/perf_baseline.py prime <app | binary | .dmg> --label v2.6.5     # once per build: lets macOS ask for Local Network access
  tools/perf_baseline.py compare [--dir docs/perf]            # table of every saved run, change vs the previous row

`run` launches the build in the user's GUI session (`open -n`, so the real launch splash plays) with a throw-away home
folder (`CFFIXED_USER_HOME`): your config, logs and caches are never read or written. The temp config skips the setup
wizard, the donation card and the GitHub update check, and serves the web guide on --port (so a running copy of the app on
:1980 is undisturbed). It uses the tuner on your network read-only (discovery + guide fetch) — run it when nothing is
recording and nothing is due. Each run measures:

  ready_s       launch -> "[Startup] complete" in the app's own log (discovery + lineup + guide done)
  guide_s       launch -> the guide-loaded log line
  cpu_to_ready  CPU-seconds the process used up to ready (the cost of launching, splash included)
  idle_cpu_pct  CPU over 30 s of idle, 10 s after ready (a splash or card still on screen counts — see --no-splash)
  rss_mb        resident memory after that idle window
  web_*_ms      GET / (cold, then median of warm), /api/guide.json, /vertical; web_*_kb the response sizes
  binary_mb     size of the executable

Medians over --runs are saved to docs/perf/<label>.json. Compare builds made the same way (release vs release) on the same
Mac at a similar load: tuner and network timing vary, which is why runs are repeated.
"""
import argparse, glob, json, os, re, shutil, statistics, subprocess, sys, tempfile, time, urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DIR = os.path.join(REPO, "docs", "perf")


def sh(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def resolve_app(path):
    """-> (app_bundle_path, cleanup_fn). Mounts a .dmg read-only and runs the app from the volume."""
    path = os.path.abspath(path)
    if path.endswith(".dmg"):
        mnt = tempfile.mkdtemp(prefix="perf-dmg-")
        r = sh(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mnt, path])
        if r.returncode:
            sys.exit(f"could not mount {path}: {r.stderr.strip()}")
        apps = glob.glob(os.path.join(mnt, "*.app"))
        if not apps:
            sys.exit("no .app on the disk image")
        return apps[0], lambda: (sh(["hdiutil", "detach", mnt, "-force"]), shutil.rmtree(mnt, ignore_errors=True))
    if path.endswith("hdhr_VCR") and "/Contents/MacOS/" in path:
        path = path.split("/Contents/MacOS/")[0]
    if not path.endswith(".app") or not os.path.isdir(path):
        sys.exit(f"not an app bundle: {path}")
    return path, lambda: None


def cputime(pid):
    """CPU seconds from `ps -o time=` ([[dd-]hh:]mm:ss.ss)."""
    out = sh(["ps", "-o", "time=", "-p", str(pid)]).stdout.strip()
    if not out:
        return None
    days = 0
    if "-" in out:
        d, out = out.split("-", 1)
        days = int(d)
    parts = [float(x) for x in out.split(":")]
    secs = 0.0
    for p in parts:
        secs = secs * 60 + p
    return days * 86400 + secs


def rss_mb(pid):
    out = sh(["ps", "-o", "rss=", "-p", str(pid)]).stdout.strip()
    return int(out) / 1024 if out else None


def fetch(url, timeout=30):
    t = time.monotonic()
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            body = r.read()
        return (time.monotonic() - t) * 1000, len(body) / 1024
    except Exception:
        return None, None


def log_has(path, needle):
    try:
        with open(path, "r", errors="replace") as f:
            return needle in f.read()
    except FileNotFoundError:
        return False


def stage_app(app, label):
    """Copies the app to a STABLE path (~/Library/Caches/hdhrVCRplus-perf/<label>/) that looks like a git checkout (a `.git`
    directory) — the app's own exemption from the "Move to Applications?" prompt, which would otherwise hold a DMG copy's whole
    launch. The path is stable on purpose: macOS asks for Local Network permission per app copy, so a new temp copy for every
    run would ask every run. Reused while the binary is unchanged. -> staged app path"""
    root = os.path.expanduser(f"~/Library/Caches/hdhrVCRplus-perf/{re.sub(r'[^A-Za-z0-9._-]+', '_', label)}")
    dest = os.path.join(root, os.path.basename(app))
    src_bin = os.path.join(app, "Contents", "MacOS", "hdhr_VCR")
    dst_bin = os.path.join(dest, "Contents", "MacOS", "hdhr_VCR")
    same = os.path.exists(dst_bin) and os.path.getsize(dst_bin) == os.path.getsize(src_bin) \
        and sh(["cmp", "-s", src_bin, dst_bin]).returncode == 0
    if not same:
        shutil.rmtree(root, ignore_errors=True)
        os.makedirs(os.path.join(root, ".git"))
        r = sh(["ditto", app, dest])
        if r.returncode:
            sys.exit(f"could not copy the app: {r.stderr.strip()}")
    return dest


def one_run(app, port, splash):
    home = tempfile.mkdtemp(prefix="perfhome-")
    support = os.path.join(home, "Library", "Application Support", "hdhrVCRplus")
    logs = os.path.join(home, "Library", "Logs")
    os.makedirs(support)
    os.makedirs(logs)
    cfg = {"config": {"First_run_wizard_shown": True, "Donation_unlocked": True, "Check_for_updates": False,
                      "Web_server_enabled": True, "Web_server_port": port, "Show_launch_splash": splash},
           "shows": []}
    with open(os.path.join(support, "hdhr_VCR-perf.json"), "w") as f:
        json.dump(cfg, f)
    logfile = os.path.join(logs, "hdhrVCRplus.log")
    before = set(sh(["pgrep", "-x", "hdhr_VCR"]).stdout.split())
    t0 = time.monotonic()
    sh(["open", "-n", "--env", f"CFFIXED_USER_HOME={home}", app])      # `app` is the staged copy (see stage_app)
    pid = None
    for _ in range(100):
        now = set(sh(["pgrep", "-x", "hdhr_VCR"]).stdout.split()) - before
        if now:
            pid = int(sorted(now, key=int)[-1])
            break
        time.sleep(0.1)
    if pid is None:
        shutil.rmtree(home, ignore_errors=True)
        return None
    res = {}
    try:
        guide_at = None
        deadline = t0 + 90
        while time.monotonic() < deadline:
            if guide_at is None and log_has(logfile, "[Startup] guide:"):
                guide_at = time.monotonic() - t0
            if log_has(logfile, "[Startup] complete"):
                res["ready_s"] = time.monotonic() - t0
                res["cpu_to_ready"] = cputime(pid)
                break
            time.sleep(0.05)
        if "ready_s" not in res:
            return None
        res["guide_s"] = guide_at if guide_at is not None else res["ready_s"]
        try:
            text = open(logfile, "r", errors="replace").read()
        except OSError:
            text = ""
        m = re.search(r"\[Startup\] guide: (\d+) channels", text)
        res["guide_channels"] = int(m.group(1)) if m else 0
        if res["guide_channels"] == 0:       # keep the evidence: what the app logged around startup
            res["_log"] = "\n".join(l for l in text.splitlines()
                                   if any(k in l for k in ("[Startup]", "Guide", "guide", "[Discovery]", "[Splash]", "ERROR", "WARN")))[-4000:]
        time.sleep(10)
        c1 = cputime(pid)
        time.sleep(30)
        c2 = cputime(pid)
        res["idle_cpu_pct"] = (c2 - c1) / 30 * 100 if c1 is not None and c2 is not None else None
        res["rss_mb"] = rss_mb(pid)
        base = f"http://127.0.0.1:{port}"
        cold, kb = fetch(base + "/")
        warm = [fetch(base + "/")[0] for _ in range(3)]
        warm = [w for w in warm if w is not None]
        res["web_root_cold_ms"], res["web_root_kb"] = cold, kb
        res["web_root_warm_ms"] = statistics.median(warm) if warm else None
        res["web_guide_json_ms"], res["web_guide_json_kb"] = fetch(base + "/api/guide.json")
        res["web_vertical_ms"], _ = fetch(base + "/vertical")
    finally:
        sh(["kill", str(pid)])
        time.sleep(1.5)
        sh(["kill", "-9", str(pid)])
        shutil.rmtree(home, ignore_errors=True)
    return res


def cmd_run(a):
    app, cleanup = resolve_app(a.target)
    try:
        info = os.path.join(app, "Contents", "Info")
        ver = sh(["defaults", "read", info, "CFBundleShortVersionString"]).stdout.strip()
        binary = os.path.join(app, "Contents", "MacOS", "hdhr_VCR")
        runs = []
        staged = stage_app(app, a.label)
        for i in range(a.runs):
            print(f"run {i + 1}/{a.runs} …", flush=True)
            r = one_run(staged, a.port, not a.no_splash)
            if r is None:
                print("  (no result — the app did not reach startup-complete)")
                continue
            print("  " + "  ".join(f"{k}={v:.2f}" for k, v in r.items() if v is not None and not k.startswith("_")), flush=True)
            if r.get("guide_channels") == 0:
                print("  !! the guide did not load in this run (0 channels) — log excerpt saved in the JSON", flush=True)
            runs.append(r)
        if not runs:
            sys.exit("no successful runs")
        keys = sorted({k for r in runs for k in r if not k.startswith("_")})
        med = {k: statistics.median([r[k] for r in runs if r.get(k) is not None]) for k in keys
               if any(r.get(k) is not None for r in runs)}
        med["binary_mb"] = os.path.getsize(binary) / 1048576
        out = {"label": a.label, "version": ver, "splash": not a.no_splash, "runs": len(runs),
               "host": sh(["hostname", "-s"]).stdout.strip(), "date": time.strftime("%Y-%m-%d %H:%M"),
               "median": med, "all": runs}
        os.makedirs(a.dir, exist_ok=True)
        path = os.path.join(a.dir, re.sub(r"[^A-Za-z0-9._-]+", "_", a.label) + ".json")
        with open(path, "w") as f:
            json.dump(out, f, indent=2)
        print(f"saved {path}")
    finally:
        cleanup()


def cmd_prime(a):
    """Launch a build once so macOS can ask for Local Network permission, wait for the click, then quit it."""
    app, cleanup = resolve_app(a.target)
    try:
        staged = stage_app(app, a.label)
        home = tempfile.mkdtemp(prefix="perfprime-")
        support = os.path.join(home, "Library", "Application Support", "hdhrVCRplus")
        os.makedirs(support)
        os.makedirs(os.path.join(home, "Library", "Logs"))
        with open(os.path.join(support, "hdhr_VCR-perf.json"), "w") as f:
            json.dump({"config": {"First_run_wizard_shown": True, "Donation_unlocked": True, "Check_for_updates": False,
                                  "Web_server_enabled": True, "Web_server_port": a.port, "Show_launch_splash": False},
                       "shows": []}, f)
        before = set(sh(["pgrep", "-x", "hdhr_VCR"]).stdout.split())
        sh(["open", "-n", "--env", f"CFFIXED_USER_HOME={home}", staged])
        pid = None
        for _ in range(100):
            now = set(sh(["pgrep", "-x", "hdhr_VCR"]).stdout.split()) - before
            if now:
                pid = int(sorted(now, key=int)[-1])
                break
            time.sleep(0.1)
        if pid is None:
            sys.exit("the app did not start")
        print(f"{a.label}: started — if macOS asks to allow Local Network access, click Allow (waiting up to {a.wait}s) …", flush=True)
        ok = False
        deadline = time.monotonic() + a.wait
        while time.monotonic() < deadline:
            time.sleep(3)
            _, kb = fetch(f"http://127.0.0.1:{a.port}/api/guide.json", timeout=5)
            if kb and kb > 10:
                ok = True
                break
        sh(["kill", str(pid)])
        time.sleep(1.5)
        sh(["kill", "-9", str(pid)])
        shutil.rmtree(home, ignore_errors=True)
        print(f"{a.label}: " + ("local network access works — ready for unattended runs" if ok else "NOT confirmed (no click, or the tuner is unreachable)"))
        sys.exit(0 if ok else 2)
    finally:
        cleanup()


COLS = [("ready_s", "ready s", "{:.1f}"), ("guide_s", "guide s", "{:.1f}"), ("cpu_to_ready", "launch CPU s", "{:.1f}"),
        ("idle_cpu_pct", "idle CPU %", "{:.1f}"), ("rss_mb", "RSS MB", "{:.0f}"),
        ("web_root_cold_ms", "GET / cold ms", "{:.0f}"), ("web_root_warm_ms", "GET / warm ms", "{:.0f}"),
        ("web_guide_json_ms", "guide.json ms", "{:.0f}"), ("web_vertical_ms", "/vertical ms", "{:.0f}"),
        ("binary_mb", "binary MB", "{:.1f}")]


def cmd_compare(a):
    files = sorted(glob.glob(os.path.join(a.dir, "*.json")), key=os.path.getmtime)
    rows = [json.load(open(f)) for f in files]
    if not rows:
        sys.exit(f"no results in {a.dir}")
    print("| build | host | " + " | ".join(c[1] for c in COLS) + " |")
    print("|---|---|" + "---|" * len(COLS))
    prev = None
    for r in rows:
        m = r["median"]
        cells = []
        for key, _, fmt in COLS:
            v = m.get(key)
            if v is None:
                cells.append("–")
                continue
            s = fmt.format(v)
            p = prev["median"].get(key) if prev else None
            if p not in (None, 0):
                d = (v - p) / p * 100
                s += f" ({d:+.0f}%)"
            cells.append(s)
        tag = r["label"] + ("" if r.get("splash", True) else " (no splash)")
        print(f"| {tag} | {r.get('host', '')} | " + " | ".join(cells) + " |")
        prev = r


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("target")
    r.add_argument("--label", required=True)
    r.add_argument("--runs", type=int, default=3)
    r.add_argument("--no-splash", action="store_true")
    r.add_argument("--port", type=int, default=1985)
    r.add_argument("--dir", default=DEFAULT_DIR)
    pr = sub.add_parser("prime")
    pr.add_argument("target")
    pr.add_argument("--label", required=True)
    pr.add_argument("--port", type=int, default=1985)
    pr.add_argument("--wait", type=int, default=120)
    c = sub.add_parser("compare")
    c.add_argument("--dir", default=DEFAULT_DIR)
    args = ap.parse_args()
    {"run": cmd_run, "prime": cmd_prime, "compare": cmd_compare}[args.cmd](args)
