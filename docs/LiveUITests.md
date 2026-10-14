# Live UI tests (opt-in, drive the real app)

Two suites exercise the **running app** through the macOS Accessibility API. They have real on-screen side effects
(windows open, move and close) and start real recordings, so they never run in a plain `swift test` — each test
returns immediately unless `RUN_WINDOW_NAV_TESTS=1` is set, the app is running and Accessibility is trusted.
Every skip path prints *why* to stderr (a silent skip once let a broken run "pass" — see below).

| Suite | File | What it is |
|---|---|---|
| `WindowNavigationTests` | `Tests/hdhr_VCRTests/Views/WindowNavigationTests.swift` | Smoke test: every window opens/navigates/closes; `pipFullWorkoutOverLiveRecording` is the end-to-end PiP workout (start a recording, open it as primary, add a live PiP, move it through all four corners, change the PiP's channel, swap, change the primary's channel, swap back, change the PiP again). |
| `PiPTunerChurnTests` | `Tests/hdhr_VCRTests/Views/PiPTunerChurnTests.swift` | Soak: a seeded random walk over the player window + PiP that checks **tuner state after every step**. Built to *catch something happening* (leaks, phantom counts, stale badges), not to prove one path. |

Shared AppleScript building blocks live in `Tests/hdhr_VCRTests/Views/PiPAXHelpers.swift` (`findWhere` is fast: `tools/ax_query.swift` locates the element natively and returns its child-index path, which is walked with `UI element N of …`; the old recursive System Events walk is only the `findWhereSlow` fallback); the right-click/key helper is
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

- **A pending system dialog silently breaks the synthetic input.** The Local Network "Allow hdhrVCRplus…?" prompt (every ad-hoc deploy is a new identity) and any `SecurityAgent` window hold focus / secure input, so `ui_events` right-clicks and keys go nowhere: PiP corners all land on one spot, menus never open, and screen capture fails ("could not create image from display"). Check `ioreg -l | grep kCGSSessionSecureInputPID` (empty = fine) and `/tmp/…/winlist`-style CGWindowList for a `SecurityAgent`/`UserNotificationCenter` window before a live run. The PiP's hover-only close button is absent from the AX tree until the pointer is over the PiP — use `ui_events move X Y` first.

- **`entire contents of <window>` returns an empty list** (for every app) while a recursive walk over `UI elements` works — all scripts use
  `findWhere`/`findById`. Since 2026-10-10 `runAppleScript` rewrites `entire contents of window "Watch Now" / playerWin / pipWin` into the same recursive walk (`axCompatible` → `axAll`), so those tests really search; the Add Show web view and Settings scripts still use plain `entire contents` (the web view's thousands of tiles would make a walk crawl). Before the rewrite the Watch Now / player / PiP tests each burned ~111 s retrying an empty list and then passed vacuously on a "nothing to watch" return — the suite took ~20 min; it now takes ~5 min.
- **One shared `[MOCK]` recording** (`MockRecording.ensure()` → `tools/mock_scenario.py ensure`, idempotent) serves every recording-dependent test; stopping and starting between tests is fine. The last test, `stopRecordingFromTheMenu`, stops it the way a user does (the recording's submenu → Skip), checks it stops within 20 s (`mock_scenario.py status`), and always `clean`s.
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

## Environment pitfalls (found 2026-10-11)

- **A locked laptop screen** (`CGSSessionScreenIsLocked`) makes Accessibility see zero windows, so `feedFromTheMiniShowsOnTheLaptop` fails `NO_PLAYER_WINDOW` even though playback runs. Unlock it and keep it awake (`caffeinate -d` stops display sleep, not an idle lock — lengthen the lock delay for a test session).
- **A fast pass is a skip.** The churn tests print "skipped: nothing airing / no free tuner" on stderr and report *passed* when another client or a real recording holds a tuner. Read stderr, or check the duration.
- **A foreign client changes hardware counts mid-run** (another device streaming from the same HDHomeRun — it showed up as a third IP on `status.json`). Counts then disagree with the baseline through no fault of the app; re-run when the tuners are quiet.
- **Overlays steal synthetic clicks.** A Spotlight/clipboard popup parked over the player's centre swallowed the right-click `ui_events` posts at the window centre; the PiP picker opened fine when the click landed elsewhere. Clear the screen before a run.
- **Fixed 2026-10-11 — slow Accessibility walks.** The recursive System Events walks (`axAll`, one Apple event per element) took minutes on Watch Now / the PiP picker. `tools/ax_query.swift` (native `AXUIElement`, compiled once per test process as `axQueryPath`; `axShell(...)` builds the call) finds an element by `id=`/`help^=`/`role=`/`title=` with an early exit in ~0.07 s, and `--press` presses it, `--last` takes the final match (the PiP picker's Live TV button), `count` and `text` (any element whose value/title/description equals a string — section headers are headings, not static texts) round it out. The Watch Now recording button, the picker's add button and its "Live TV"/"Now Playing" checks use it. `WindowNavigationTests` dropped from ~22 min to ~5 min. The player-context-menu step now tries `AXShowMenu` briefly and falls back to a real right-click + Return (left/below centre), which fixed `pipPickerOpensFromPlayerContextMenu`'s cold-session flake. Every test also starts with `closeStrayWindows()` — the "…opens and closes" tests assert zero windows afterwards and failed on a window an earlier test left open. Other `entire contents` walks (small windows) still go through `axAll` and are fine.
- **A mock tuner doubles every lineup list.** `mock_tuner.py --mirror` copies the real lineup, so Watch Now and the PiP picker list hundreds of rows twice. The tests' recursive Accessibility walks (`axAll`, `entire contents` rewritten to it) then take minutes per call and a run can look hung. Stop the mock for the navigation suite; keep it for `CrossDevicePiPTests` only. Stale `osascript`/`swift-test` processes from a killed run pile up and make it worse — `pkill osascript; pkill -f swift-test` before re-running.
- **The mock must stream to be a PiP target.** Start it with `--ts-file <real .ts clip>` (a ~40 MB slice cut from a recording on a 188-byte boundary, loops); without it the device is reachable but has no video, and live-PiP steps aimed at it fail. It needs sudo (port 80) and mints a new random DeviceID on each start, so the previous one lingers as an unreachable stale device until the app forgets it.
- **Resolved 2026-10-13 (was "still failing", 13/17):** `addingLiveChannelAsPipSecondaryShowsAndRemovesThumbnail` failed because the PiP's close button is hover-only and absent from the AX tree otherwise — the test now hovers first (`ui_events move`). `pipCornerMenuOffersAllFourCornersAndRepositions` and `pipChannelMenuSwitchesSecondaryChannel` were **deleted**: they read the thumbnail's right-click menu through `AXShowMenu`, which cannot see the native `NSMenu` it became; `pipFullWorkoutOverLiveRecording` covers corners and Channel changes through real right-clicks. Earlier runs of the other tests here were partly vacuous (see above), so a "pass" before 2026-10-10 proves little.

## Test-source choices

- `feedFromTheMiniShowsOnTheLaptop` feeds from a recording **already running** on the Mini (a FEED costs no tuner); it starts a `[MOCK]` one only when nothing is recording. A mock started on top of a real recording usually lands on the same channel → two relay rows with identical URLs (`dev=` only disambiguates devices), one without a Watch submenu. The menu script tries every relay row until one yields Watch.
- The churn soak picks the first device whose own `status.json` answers (a stale mock must not become the device under test), ignores `[ERROR]` lines tagged with a different device's ID, and splits window names on `|` (titles can contain `;`). `CrossDevicePiPTests` finds devices by their `"surl"` key — key order inside the embedded tuner object is not stable.
