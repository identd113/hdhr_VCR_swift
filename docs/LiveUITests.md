# Live UI tests (opt-in, drive the real app)

Several opt-in suites (`WindowNavigationTests` incl. its extension in `DialogsAndWatchNowLiveTests`, `PiPTunerChurnTests`, `CrossDevicePiPTests`, `MultiDeviceTests`) exercise the **running app** through the macOS Accessibility API. They have real on-screen side effects
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

## Dialog / main-thread / Watch Now tests (`DialogsAndWatchNowLiveTests.swift`, 2026-10-15)

Ten tests in extensions of `WindowNavigationTests` (so they are `.serialized` with it), all through the native `ax_query` walker — never `entire contents`:

| Test | What it proves | ~Time |
|---|---|---|
| `watchNowRowGainsRelayButtonsWhenARecordingStartsWithTheWindowOpen` | with Watch Now already open, a recording that starts turns its row into "<title>, recording now" with the two relay buttons within 10 s (guards the stale-row / `.id` fix and the stale-`now` fix) | 8 s |
| `unsavedSettingsPromptIsASheetAndTheWebServerKeepsAnswering` | dirty Settings can't be closed silently; the prompt is a sheet; `GET /` < 1 s while it is up; Cancel keeps the window; flipping the switch back closes cleanly | 5 s |
| `quitPromptDoesNotBlockAndGoBackKeepsTheAppAndTheRecording` | Quit during a recording asks; web server answers meanwhile; a second Quit click doesn't stack a prompt; Go Back leaves app + recording running | 7 s |
| `exportConfigPanelIsASheetAndTheWebServerKeepsAnswering` | the save panel is a sheet, the web server answers, Cancel dismisses it | 4 s |
| `launchSplashPlaysEndsAndLeavesNothingRunning` | Settings → Maintenance → Preview Launch Splash twice: the full-screen splash window appears (CoreGraphics: layer 101, on screen), finishes, the splash window no longer *exists* (destroyed, not just hidden), the app is alive and CPU is back under 5 % each time — so it plays, is released, and a replay builds a fresh one | 41 s |
| `recordingAppWithNoWindowsUsesLittleCPU` | a recording running with no window open stays under 10 % CPU — hidden windows must not re-render on every state change (measured 0.4–2 %) | 19 s |
| `idleAppUsesAlmostNoCPU` | an idle app (nothing recording, no windows) stays under 5 % CPU (`top -l 2`) — guards the hidden-animating-splash bug (21 % → 0 %; mutation-checked) | 10 s |
| `mainThreadStaysResponsive` | `GET /` every 100 ms for 20 s: no unanswered probe, worst < 2.5 s (baseline: the idle tick stalls ~0.6 s every 10 s) | 20 s |
| `zoomTogglesBetweenNativeSizeAndTheEarlierSize` | Window ▸ Zoom snaps the player to the picture's native size and a second Zoom returns to the earlier size | 15 s |
| `statusBarSlidesInBrieflyWhenAStreamOpens` | with the bar off, a new stream pops the bar down (window grows) for ~5 s, then it goes away and the window returns to its first height | 25 s |
| `statusBarToggleShowsTheBarAndResizesTheWindow` | in a real player (a recording-relay session), the status bar toggle draws the bar (`vlc-status-bar`, with its title block `vlc-status-title`) and grows the window by exactly 52 pt; pressing again removes it and the window shrinks back | 13 s |
| `statusBarStaysSizedAfterClosingAndReopeningThePlayer` | with the bar on, closing the player and opening a fresh one gives a window that is the default height plus 52 pt (the window manager is a singleton but the window is recreated at its default size) | 14 s |

Mutation-checked: re-introducing `alert.runModal()` in `quit()` makes `quitPromptDoesNotBlock…` fail with "web server did not answer while the quit prompt was up". `NoBlockingDialogsTests` (unit) bans `runModal()` in the sources.

**Guard against real recordings:** `MockRecording.ensure()` and `churnWhileTheMiniIsRecording` now skip (message on stderr) when a *real* show is recording or due to start within 12 minutes (`MockRecording.realRecordingConflict()`, read from the live config) — a real recording holds a tuner, so the tests used to fail confusingly ("No Tuner Available", `NO_RECORDING_TO_WATCH`) and `stopRecordingFromTheMenu` could have stopped the real show. `feedFromTheMiniShowsOnTheLaptop` is different: it *adopts* a recording that is already running (real or mock), so it can run beside one real recording.

**Where the time goes (an earlier 20-test run, ~216 s; there are now 33 live tests):** `pipFullWorkoutOverLiveRecording` 49 s (corner moves, four source changes, swaps — verified from the log), `guideSourceToggleDoesNotBreakWindows` 25 s (8 tabs × 2 passes, each waits for the tab title to change), `pipTapToSwap…` 17 s, `addingLiveChannel…` 14 s, `addShowGuideSearchBox…` 13 s. A PiP test's floor is ~7 s: mock ensure 2.5 s + Watch Now row 1.2 s + player start 3.4 s. Replacing the player-start wait's System Events walk with `ax_query` changed nothing measurable — the stream start dominates. The only "large unexpected" waits left are the churn/FEED settle windows (20–35 s on some steps): the *mini's* cached guide page lags the hardware by its 15 s rebuild cooldown + the 10 s poll (ISSUES.md, 2026-10-14); the window is 35 s, so it is tight.

**Not covered live (known gaps):** the OTA scan window (ids are listed in `docs/OTAScanView.md`; needs an isolated instance and a mock tuner serving `/tuner<N>/ch<Hz>`), the first-run wizard walk (isolated instance only), Add Show's details step, Edit Show's Save/Delete and its new inline error captions, the Settings Developer and About tabs, the menu bar item ids (`menu.addShow`, `menu.settings`, `menu.quit`, `menu.show.<id>` - whether System Events surfaces them is unverified), and the Move-to-Applications prompt; the "No Tuner Available" sheet (needs both tuners busy), the Save branch of the unsaved-changes sheet (would change real settings), Edit Show's unsaved prompts, the delete / import-config confirmations, the other file pickers, and the reopen-across-a-:00/:30-boundary case (time-dependent; reproduced by hand, see ISSUES.md).

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
- **One shared `[MOCK]` recording** (`MockRecording.ensure()` → `tools/mock_scenario.py ensure`, idempotent) serves every recording-dependent test; stopping and starting between tests is fine. The last test, `stopRecordingFromTheMenu`, stops it the way a user does (the recording's submenu → Stop & Skip This Airing), checks it stops within 20 s (`mock_scenario.py status`), and always `clean`s.
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

- **Run one live suite at a time, or pass `--no-parallel` (2026-10-17).** Swift Testing runs *different* suites concurrently, and `.serialized` only orders tests *inside* one suite. A combined filter such as `--filter "WindowNavigationTests|PiPTunerChurnTests"` therefore ran the churn soak (which starts a mock recording and opens relay/PiP windows) at the same time as the window-navigation tests, which assert the opposite state: "no relay buttons before a recording", "tuner baseline matches", "idle CPU". Symptoms looked like load or timing flakes (`relay buttons present before anything is recording`, `baseline tuner state disagrees`, `cpu < 10`) but every one passed when the suites ran separately or with `--no-parallel`.
- **The mock recording ends with its airing slot (2026-10-17).** `mock_scenario.py start` used to take the first airing entry; if that slot had ~6 minutes left, the recording ended mid-soak and `feedFromTheMiniShowsOnTheLaptop` reported "a tuner was leaked or a count is stale" at its closing steps (app=0 hw=0, expected 1). `start` now tries the entry with the most time remaining first; if nothing airing has ≥5 minutes left, expect that failure and rerun later.
- **Hardware tuner status trails the app.** After a recording starts, the tuner's `/status.json` can still show 0 for several seconds while the app already counts 1; the churn baseline now waits up to 20 s for the two to agree. `recordingAppWithNoWindowsUsesLittleCPU` likewise waits for the post-start CPU spike (50–80 %) to settle instead of sampling once at 8 s.

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

## Identifier notes (2026-10-22)
- The responsive player toolbar folds controls into the "…" menu below about 700 pt wide. At the default 1080 wide `vlc-channel-picker`, `vlc-catch-up-button`, `vlc-volume-slider` and `vlc-status-bar-toggle` stay on the bar; tests that resize the player narrower must also look for folded items (they keep their `vlc-*` ids inside the "…" menu).
- Watch Now has `watch-now-tuner` (a segmented picker with 1-2 tuners, a pop-up menu with 3+), `watch-now-refresh` and `watch-now-row-<channel.id>`.
- Settings buttons: maintenance Run buttons are `settings-maint-<title>` with the label "Run <title>"; prefer the id over the title `Run`.
- Menu rows: the device row's accessibility label reads "Tuner 105404BE, 1 of 4 in use"; `MultiDeviceTests` accepts either form.
