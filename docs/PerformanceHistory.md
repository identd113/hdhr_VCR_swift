# Performance history — release to release

Measured with `tools/perf_baseline.py` (see its docstring): each build is launched in the user's GUI session with a throw-away home
folder (your config is never touched), against the real tuner on the network, three times; the table shows medians. Release builds
only — a debug build from `deploy.sh` is not comparable. Results live in `docs/perf/<label>.json` (all runs, plus a log excerpt for
any run where the guide did not load); regenerate this table with `tools/perf_baseline.py compare`.

**How to take a baseline for a release** (do it on the same Mac each time, nothing recording or due soon):
1. `tools/perf_baseline.py prime <dmg> --label vX.Y.Z` — once per build. macOS asks for Local Network permission per app copy
   (the harness keeps each build at a stable path under `~/Library/Caches/hdhrVCRplus-perf/<label>/` so it asks once); click Allow.
   Without it every request to the tuner fails with "The Internet connection appears to be offline" (error 50) and the web guide
   comes up empty — that is the permission prompt, not an app bug.
2. `tools/perf_baseline.py run <dmg> --label vX.Y.Z --runs 3` (and again with `--no-splash` to separate the launch splash's cost).
3. `tools/perf_baseline.py compare` and paste the table here.

## v2.6.5 vs v2.6.0 (2026-10-16, MacBook "mwmbair", macOS 27.0.1, HDHomeRun 105404BE, 3 runs each)

| build | host | ready s | guide s | launch CPU s | idle CPU % | RSS MB | GET / cold ms | GET / warm ms | guide.json ms | /vertical ms | binary MB |
|---|---|---|---|---|---|---|---|---|---|---|---|
| v2.6.0 | mwmbair | 3.5 | 3.5 | 1.1 | 0.1 | 205 | 5 | 3 | 31 | 65 | 11.1 |
| v2.6.5 | mwmbair | 6.3 (+81%) | 6.3 (+81%) | 3.1 (+179%) | 0.1 (+0%) | 220 (+7%) | 4 (-19%) | 3 (-0%) | 29 (-7%) | 64 (-2%) | 11.4 (+3%) |
| v2.6.5 (no splash) | mwmbair | 3.6 (-43%) | 3.6 (-43%) | 1.1 (-64%) | 0.1 (-0%) | 200 (-9%) | 6 (+47%) | 3 (+9%) | 28 (-6%) | 64 (+0%) | 11.4 (+0%) |

| column | what it is |
|---|---|
| ready s / guide s | launch → `[Startup] complete` / guide loaded (the two coincide: the guide is the last startup step) |
| launch CPU s | CPU-seconds the process used up to that point |
| idle CPU % | CPU over 30 s, starting 10 s after ready |
| RSS MB | resident memory 40 s after ready |
| GET / cold / warm | the web guide page, first request and the median of three more |
| guide.json / vertical | `/api/guide.json` and the phone layout |

**Reading it.**
- **With the splash off, 2.6.5 is the same as 2.6.0** — startup time, launch CPU, idle CPU, memory and every web timing are within
  run-to-run noise. Nothing the release changed made the app slower or heavier.
- **With the splash on, startup finishes about 3 s later and uses about 2 extra CPU-seconds.** That is by design: the rest of the
  app's launch (tuner discovery and the guide's network calls) waits for the poster fly-in so the animation is smooth
  (`LaunchSplashController.waitForFlyIn`, docs/LaunchSplash.md), and the splash itself decodes and animates the posters. It is a
  one-off at launch; idle CPU afterwards is identical, and memory settles about 15 MB higher while the splash images are released.
- **Idle CPU is about 0.1 %** in every build (`ps` resolution is 0.01 CPU-seconds, so 0.10–0.13 are the same number).
- Not measured: the Mac mini, a recording in progress, FEED playback, the GUI frame rate of the fly-in (that was tuned from `sample`
  traces, not a number — see docs/LaunchSplash.md), or a first launch with an unanswered Local Network prompt.
