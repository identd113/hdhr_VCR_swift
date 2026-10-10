# Live UI tests (opt-in, drive the real app)

Two suites exercise the **running app** through the macOS Accessibility API. They have real on-screen side effects
(windows open, move and close) and start real recordings, so they never run in a plain `swift test` — each test
returns immediately unless `RUN_WINDOW_NAV_TESTS=1` is set, the app is running and Accessibility is trusted.
Every skip path prints *why* to stderr (a silent skip once let a broken run "pass" — see below).

| Suite | File | What it is |
|---|---|---|
| `WindowNavigationTests` | `Tests/hdhr_VCRTests/Views/WindowNavigationTests.swift` | Smoke test: every window opens/navigates/closes; `pipFullWorkoutOverLiveRecording` is the end-to-end PiP workout (start a recording, open it as primary, add a live PiP, move it through all four corners, change the PiP's channel, swap, change the primary's channel, swap back, change the PiP again). |
| `PiPTunerChurnTests` | `Tests/hdhr_VCRTests/Views/PiPTunerChurnTests.swift` | Soak: a seeded random walk over the player window + PiP that checks **tuner state after every step**. Built to *catch something happening* (leaks, phantom counts, stale badges), not to prove one path. |

Shared AppleScript building blocks live in `Tests/hdhr_VCRTests/Views/PiPAXHelpers.swift`; the right-click/key helper is
`tools/ui_events.swift` (see CLAUDE.md's Tools table).

```bash
RUN_WINDOW_NAV_TESTS=1 swift test --filter pipFullWorkoutOverLiveRecording
RUN_WINDOW_NAV_TESTS=1 swift test --filter PiPTunerChurnTests                      # both churn tests, ~5 min
RUN_WINDOW_NAV_TESTS=1 HDHR_CHURN_STEPS=30 HDHR_CHURN_SEED=1791333818 swift test --filter feedFromTheMiniShowsOnTheLaptop   # replay
```

## `PiPTunerChurnTests`

**The walk.** Operations: open the player on the in-progress recording (a disk relay — costs no tuner) or on a FEED; add a
live-channel PiP or a FEED PiP; close the PiP; swap primary↔PiP; change the PiP's channel (its right-click Channel
submenu); change the primary's channel (toolbar picker); move the PiP between corners; move/resize the player window;
close the player. A scripted prefix always runs the key transitions first, then the walk is random from a seed printed on
every run (`HDHR_CHURN_SEED`, `HDHR_CHURN_STEPS`, default 30).

**The model.** Each state (`player`, `primary`, `pip` ∈ none/rec/live/feed) implies how many real tuners should be held:
`base` (whatever was locked before the first step — the mock recording) `+` one per **live OTA** stream in either slot.
A recording relay or FEED costs none. The walk only issues an op whose precondition holds (e.g. no live PiP when
`expected == total`).

**Checked after every step** (polled up to 35 s until all agree, the settle time is reported):
- the **hardware** count — tuners with a channel locked in the HDHomeRun's own `status.json`;
- the **app's** count — the `"a"` the web guide embeds for the device (`AppState.activeTunerCount`), read from the *viewing* Mac's
  own page (and, in the FEED test, also the recording Mac's page as `peer=`);
- UI geometry — a PiP thumbnail is on screen **iff** the model has a PiP and lies inside the player window; the player window
  is on-screen; ≤1 player window; the PiP-picker window isn't left open.
At the end: with everything closed the counts must return to `base` (leak check), and the app log(s) are scanned for
`[ERROR]` lines and "all tuners busy" refusals. The step trail is always printed, pass or fail (timestamps, model state, counts,
settle time, and every per-second sample when a settle was slow).

**Two tests**
- `churnWhileTheMiniIsRecording` — the mini records and its own player is driven.
- `feedFromTheMiniShowsOnTheLaptop` — the **mini records and feeds** (its Recording FEED relay), and the **laptop's** player is
  driven over `ssh laptop osascript -`. The laptop watches that FEED as primary/PiP mixed with live PiPs. A FEED must never cost a
  tuner on either Mac. It first measures how long the laptop's tuner count takes to notice the mini's recording (5–10 s).
  Direction matters: a shared tuner only ever has one Mac's FEED relay (the first recorder keeps it), so the recording Mac must be the one
  whose relay is on.

## Prerequisites

- **Tuners idle.** Both must be free of *everyone* (no real recording, nothing watching on any device) — the test needs a free tuner for its
  own mock recording and live PiPs, and a baseline it can trust. Check: `curl -s http://<device>/status.json`, or
  `hdhomerun_config <device-ip> get /tuner0/status` (use the IP; discovery by device ID can fail). A client that vanished without closing its
  stream (e.g. a laptop that changed Wi-Fi address) can leave a **stale lock** (`TargetIP` of a dead address, `NetworkRate` 0) that clears on
  its own after ~25 min; `hdhomerun_config <device-ip> set /tuner1/channel none` clears it immediately.
- **Accessibility** granted to whatever hosts the shell that runs `swift test` (on the Mac mini that is the `claude` process — a plain
  Terminal grant was not enough; `AXIsProcessTrusted` must report `true`). Screen Recording is only needed for screenshots.
- **FEED test:** `ssh laptop` with key auth; Accessibility granted to the laptop's ssh session; the app running there (this repo's code
  deployed); the laptop kept awake (`caffeinate -d` — it drops off the network otherwise); on the **mini**, Settings → Sharing →
  Recording FEED on (`Virtual_tuner_relay_enabled`, default off).

## macOS 27 / environment gotchas (all hit while building these)

- **`entire contents of <window>` returns an empty list** (for every app) while a recursive walk over `UI elements` works — all scripts use
  `findWhere`/`findById`. The older tests in `WindowNavigationTests` still use `entire contents` and can therefore pass by skipping.
- **A direct `window "Name"` specifier can fail on the laptop** for a window that plainly exists; `windowNamed(nm)` walks `windows` instead,
  and every `name of w` loop is wrapped in `try` (a window can vanish mid-loop, e.g. the picker dismissing itself).
- **The PiP's right-click menu is a native `NSMenu` that AX can't see or trigger** — `tools/ui_events.swift` sends a real right-click and
  arrow keys to the app's pid (the app is an accessory process, never frontmost, so HID-level keys would land in the terminal).
- **`osascript -` over ssh reads stdin as non-UTF-8**: literal `—` (the FEED menu item's separator) and `…` ("Watch Now…") arrive mangled.
  `asciiSafe` rewrites any string literal with non-ASCII characters into `("ab" & (character id 8212) & "cd")` before sending.
- **AppleScript reserved words** that bit: `which`, `named`, `pick`, `th`, `before`.
- The menu-bar item's **title changes with state**; never cache a reference to its menu across an action — re-fetch `menu 1 of menu bar item 1 of menu bar 2`.
- Adding a live PiP uses the player's right-click → "Add Picture-in-Picture…" → the picker's **last** add button (the Live TV section comes
  after Recording Now and FEED; they share one `pip-picker-add-button` id), falling back to Watch Now's per-row "Watch alongside (PiP)" button.
  On the laptop the `Watch Now…` menu item doesn't reliably open the Watch Now window while a player is up (open item in `ISSUES.md`).
- Picking the channel that is being recorded makes the app play it **from disk** (no tuner) — the churn's channel picks skip it so the model holds.

## Running them as a full release gate (2026-10-09 run)

Run back-to-back (`WindowNavigationTests` ≈ 22 min, then `PiPTunerChurnTests`) on the Mac mini with the laptop reachable, the results were: 15/16 navigation tests, with `pipFullWorkoutOverLiveRecording` failing in the suite (`NO_RECORDING_TO_WATCH`, after 425 s) but **passing alone in 66 s**; and both churn tests failing at step 1 — then `churnWhileTheMiniIsRecording` passing all 30 steps on its own (final tuner counts back to base, no leaks). So a failure at step 1 of a full-suite run is leftover window/player state from the earlier tests, not the app: **re-run the failing test alone on an idle app before treating it as real.** `feedFromTheMiniShowsOnTheLaptop` still fails alone with `NO_PLAYER_WINDOW` — the laptop's menu offers the FEED ("Recording on <show> — woodflix.local → Watch") but an Accessibility `click` on it does nothing (no log line, no stream request on the mini), the same class as the open "`Watch Now…` doesn't reliably open on the laptop" item in `ISSUES.md`; watching a FEED by hand on the laptop works. Slow settles worth knowing about: adding a live PiP settled in 18–25 s usually but 80–85 s twice in three runs, and the app's tuner count lags the hardware count by 12–15 s after a stream opens/closes (it reads `status.json` on a poll). A scripted `set position` of a window with System Events can persist a bad frame (`NSWindow Frame watch-now`, 1873 wide) that blows the Watch Now posters up on the next launch — reset it, don't chase it as an app bug.

## What it has found

- **Stuck FEED relay after deleting a recording** (fixed `2f2869e`): `deleteShow` never re-ran `updateVirtualTunerPresence()`; see `docs/VirtualTunerService.md`.
- **Tuner badge lag** (fixed `aa5c6aa`): the cheap `tuner_update` push shared the grid rebuild's 15 s cooldown; see `docs/AppState.md` / `docs/WebServer.md`.
- A *silent-pass* trap in the older live tests (a skip sentinel returning early): the new tests fail loudly or print why they skipped.

## Extending

Add a case to `Op`, its precondition to `allowed()`, its model transition to `apply()`, and an AppleScript body to `script(for:)` (handlers
from `pipAXHandlers` + `churnHandlers` are prepended by `wrap`). Keep every op ending in `OK` on success — anything else aborts the walk
with the op named in the failure.
