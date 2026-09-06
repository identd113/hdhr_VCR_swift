# Pre-release deep audit — v2.3.0 candidate (v2.2.0..HEAD)

Started 2026-09-04. Scope: 44 commits / 58 files / +5740/-690 since the v2.2.0 tag —
the full unreleased span, not just the most recent partial-diff review.

Per docs/Distribution.md's "Release Checklist" step 0: review → docs → full test suite
(incl. UI tests) → fix → re-verify, BEFORE touching deploy_release.sh. This session
does NOT run deploy_release.sh, publish a release, or touch RELEASES.md/README.md's
release sections — explicitly asked to start the process, not finish it.

Running 5 parallel review agents (general bug-hunt, invariants-reviewer,
swift-quality-reviewer, docs-auditor, security-focused) against v2.2.0..HEAD,
then the full local test suite + opt-in UI test suite.

---
## Agent: docs-auditor (v2.2.0..HEAD) — COMPLETE

**3 findings (all "Relay" leftover from the rename, missed by 2fac77c) + 1 missing-doc gap:**

1. **WRONG — `docs/VirtualTunerService.md:13`**: says menu header row is `"Relay: N watching"`. Actual code (`MenuContent.swift:112`) renders `"FEED: N watching"` — `docs/MenuContent.md` already has this right; only `VirtualTunerService.md` was missed by the rename commit.
2. **WRONG — `docs/VirtualTunerService.md:31,41`**: says `FriendlyName` is `"<source>-Relay"` / fallback `"hdhrVCRplus (Recording Relay)"`. Actual code (`WebServer.swift:2826`) produces `"<source>-FEED"` / `"hdhrVCRplus (Recording FEED)"` — a literal string a real third-party HDHomeRun client would see.
3. **WRONG (minor) — `docs/VirtualTunerService.md:3`**: "shipped 2026-09-01" — actual commit `5238644` is dated 2026-09-02, off by one day.
4. **Missing-doc gap**: `docs/AppState.md` never mentions the new `relayRawViewerCount`/`transcodeViewerCount` fields at all.

Everything else (wire protocol, `relayDeviceID`/`makeDeviceID`, GOP tightening keyint=30, AC-3 codec, port range, `?duration=`, already-modern-codec skip, Guardrails list, and 8 other docs checked symbol-by-symbol) confirmed accurate and internally coherent — "despite being one of the most heavily-rewritten docs this cycle, it reads as one coherent final-state document, not a journal of superseded designs."

## Agent: invariants-reviewer (v2.2.0..HEAD) — COMPLETE

**No violations found** — deep trace of every `state.devices`/`recordableDevices` call site, the `ShowRuntimeState` refactor's `deleteShow` cleanup, the FEED signal feature's `deviceTunerOccupancy`-only sourcing (never touches `ChannelSignalStore`), both VLC relay-coupling match sites, and the served `guide.js` output (`node --check`'d). Notes this span already contains 3 dedicated self-review/guardrail-fixup commits (`58c2682`, part of `af78b57`, `d1ca8c5`).

Independently rediscovered (but already tracked, not new):
- `TODO.md`: `updateVirtualTunerPresence()` + 3 WebServer JSON builders use bare `shows.filter { $0.show_recording }` instead of canonical `recordingShows` (misses the `show_end`-passed exclusion window) — state-mismatch bug, not a guardrail bypass.
- `TODO.md`: `usableDeviceIDs` isn't itself filtered through `recordableDevices` — harmless today (every caller filters separately) but a latent trap.
- `ISSUES.md`: port-capture race, uncached per-connection PAT/PMT re-scan, uncached `getifaddrs()` — all already scoped, efficiency-only.

Confirmed the new viewer-count counters are event-driven, not timer-polled, so they don't reintroduce the "menu rebuild churn" bug class.
## Agent: security-focused review (v2.2.0..HEAD) — COMPLETE

Input validation on `dev=`/`duration=`/`transcode=`/channel confirmed solid — never string-interpolated into filesystem/shell, transcode profile always comes from server config not client string, no path traversal found (paths always looked up server-side by show_id/channel match).

**1. Resource exhaustion — unbounded transcode-viewer fan-out per show (Medium).** `startTranscodeSession` caps *distinct concurrent transcodes* at 10 (port range), but nothing caps how many times ONE show's session can be *joined*. Every join still spins up a full `URLSession`+`TranscodeProxyDelegate`+`dataTask`+a self-rescheduling 30s liveness-probe timer. A malicious LAN device could open thousands of concurrent connections to one currently-recording channel — each accepted (same-subnet check trivially passes) — multiplying real sockets/threads/timers with zero limit. The viewer-count fields only count for UI display, they gate nothing. Requires an active recording (opportunistic window, not always-on).
2. **Resource exhaustion — no backpressure on transcode proxy (Low-Medium, lower confidence).** `TranscodeProxyDelegate` forwards every chunk to `conn.send` with no read-rate check and no stall timeout comparable to `streamGrowingFile`'s. A client that connects then never reads could accumulate real memory across many stalled connections. Distinct code path from the already-tracked SSE-payload queue-starvation issue.
3. **Log-forging via unescaped newline (Low, informational).** `channel` is percent-decoded before unescaped interpolation into `glog(...)` — `/auto/v5%0A[FAKE]...` could inject fake-looking lines into the log file. No code-exec/auth-bypass impact, just a log-integrity nuisance.

No path traversal, no shell/SQL injection, no unexpected disclosure beyond the already-accepted no-auth-by-design surface.

## Agent: general-purpose deep bug hunt (v2.2.0..HEAD) — COMPLETE — 1 REAL REGRESSION FOUND

**1. CONFIRMED REGRESSION — double-decrement of `AppState.transcodeViewerCount` across concurrent shows, introduced by this session's own commit `d1ca8c5`.**
`teardownRecordingState`/`skipRecording` call `transcodeViewersCleared(stopAllTranscodeSessions(showId:))` — a correct bulk-subtract of that show's full ref-count. But `WebServer.swift`'s two `pumpTranscodeProxy`/`beginTranscodeRelay` cleanup closures (fired later, whenever each already-force-cleared viewer's own connection notices the killed httpd) **unconditionally** call `appState?.transcodeViewerDisconnected()` regardless of whether `stopTranscodeSession` found anything left to decrement (it won't — already removed by the bulk clear, guard silently no-ops). Since `transcodeViewerCount` is a single flat app-wide Int (not per-show), this extra decrement bleeds into OTHER concurrently-recording shows' counts. Concrete repro: Show A (1 viewer) + Show B (1 viewer) both recording (count=2); Show A stops → bulk-clears to 1 (correct); Show A's stale connection teardown fires moments later → count drops to 0, even though Show B's viewer is still watching. `max(0,...)` only prevents negative, not this cross-show under-count. **No test exercises this at all** — shipped unverified.
**Fix shape**: have `stopTranscodeSession` report whether it actually removed a reference (return Bool), only call `transcodeViewerDisconnected()` when true.
**Impact**: cosmetic only (the "FEED: N watching" menu row), but concrete and easily reproducible on the ordinary stop-recording path with 2+ concurrent transcoding shows.

2. **Minor, pre-existing — `updateVirtualTunerPresence()` gates on `isRecording` (raw filter) but reads `recordingShows` (canonical, excludes past-show_end) for tunerCount/source-device.** Narrow window after `show_end` passes but before idle loop flips `show_recording` false: `isRecording`=true, `recordingShows`=empty → `relayDeviceID` falls back to fully random ID instead of stable per-source ID, relay advertised with TunerCount:0. Self-corrects next idle tick. Same class of bug CLAUDE.md warns about (bare filter vs. canonical property).

3. **Minor — `relayDeviceID` derives from only last 4 hex digits of source DeviceID.** Two real devices sharing the same last-4-hex (1-in-65536 per pair, plausible with 2+ tuners) would produce the SAME relay DeviceID for two unrelated recordings, clobbering one instance's discovered relay entry with the other's. Needs a real coincidental collision to trigger.

No crashes/data-loss/actor races found beyond already-tracked items — this cycle's prior passes held up under re-reading. Finding #1 was missed because it was introduced in the SAME commit that fixed the staleness bug it's adjacent to.
## Agent: swift-quality-reviewer, full-span pass (v2.2.0..HEAD) — COMPLETE

**No findings, release-blocking or otherwise.** Traced exactly which commits prior same-cycle passes actually covered (via CODE_NOTES.md history) and did a full verification pass rather than trusting them blindly — confirmed the tail two commits (GOP tighten, doc correction) were genuinely unreviewed-by-name until now, both clean. Also spot-checked: `concurrentMap` helper replaced (not triplicated) the prior duplicated `DispatchQueue.concurrentPerform` blocks; every new `asyncAfter`/`Task.sleep` across the whole span is a genuine bounded timeout with a live-caught-failure justification, not a disguised race; all `nonisolated(unsafe)`/`@unchecked Sendable` sites carry explicit justification comments; zero new `print(`/`Process()`/`.plist`/`.entitlements` changes (no sandbox/notarization scope escalation).

---

## ALL 5 AGENTS COMPLETE — summary

| Agent | Result |
|---|---|
| General bug hunt | **1 confirmed regression** (transcodeViewerCount double-decrement, introduced by d1ca8c5) + 2 minor pre-existing (both low severity, already same-class as tracked items) |
| Invariants | Clean — no violations |
| Swift quality (diff-scoped, dadf7c9..HEAD, earlier pass) | 3 findings, all fixed same-day |
| Swift quality (full-span, this pass) | Clean — no new findings |
| Docs-auditor | 3 wrong (stale "Relay" text missed by rename in VirtualTunerService.md) + 1 missing-doc gap |
| Security | 2 real findings (Medium: unbounded transcode-viewer fan-out; Low-Medium: no backpressure on transcode proxy) + 1 informational (log-forging via unescaped newline) |

**Confirmed release-blocking**: none of the above are crashes/data-loss/security-critical. The transcodeViewerCount bug is cosmetic (menu display only). The security findings are real DoS-shaped concerns worth fixing but require an active recording + a malicious device already on the trusted LAN (same threat model this app has always operated under, no auth by design) — not exploitable by a random remote attacker.

---

## Fixes applied

1. **Fixed the confirmed regression**: `VLCBridge.stopTranscodeSession`/`stopAllTranscodeSessions` now report whether they actually released a reference (`Bool`/`Int`), and `WebServer`'s two cleanup call sites only decrement `AppState.transcodeViewerCount` when true — closing the cross-show double-decrement. Added regression tests (`Tests/hdhr_VCRTests/VLC/VLCBridgeTranscodeSessionTests.swift`, 2 new) covering the exact "nothing was running" contract that caused the bug — no VLC install needed for these two.
2. **Fixed the 3 stale "Relay" doc mentions** in `docs/VirtualTunerService.md` (menu row text, FriendlyName format ×2) missed by the 2fac77c rename commit, plus the 1-day-off ship date.
3. **Fixed the log-forging finding**: `channel` (client-controlled, LAN-reachable, no auth) is now sanitized (newlines/control chars stripped) before every `glog(...)` call in `handleVirtualTunerStream` — a crafted request could otherwise inject fake-looking lines into `hdhrVCRplus.log`. Real `channel` value used for matching logic is untouched.
4. **Filled the missing-doc gap**: `docs/AppState.md`'s Web Server table now documents `relayRawViewerCount`/`transcodeViewerCount`.

Build clean, full suite 410/410 passing (408 + 2 new regression tests).

## Reported, not fixed — needs a judgment call, not release-blocking

- **Security finding #1 (Medium)**: unbounded transcode-viewer fan-out per show — no cap on how many times one show's transcode session can be joined, each join spins up a real socket+timer. Needs a chosen connection-cap value, a real design decision.
- **Security finding #2 (Low-Medium)**: no backpressure/stall timeout on the transcode proxy's outbound chunk forwarding — a client that connects then never reads could accumulate memory. Needs a chosen stall-timeout value, comparable to `streamGrowingFile`'s existing one.
- **2 minor pre-existing bugs** found independently by both the bug-hunt and invariants agents: `updateVirtualTunerPresence()`'s `isRecording`/`recordingShows` inconsistency (self-corrects within one idle tick), and `relayDeviceID`'s last-4-hex-digit collision risk (needs a real coincidence to trigger). Both low severity, candidates for `TODO.md` rather than an immediate fix.

## Pre-release checklist status (docs/Distribution.md's Release Checklist, step 0)

- [x] 0.1 Code review unreleased commits — done, 5 parallel deep-audit agents against v2.2.0..HEAD (44 commits)
- [x] 0.2 Update documentation — done, all confirmed doc bugs fixed
- [x] 0.3a Full local test suite (`swift build && swift test`) — 410/410 passing
- [ ] 0.3b UI/window-navigation suite (`RUN_WINDOW_NAV_TESTS=1`) — running
- [x] 0.4 Fix findings, commit — regression + docs fixed, not yet committed pending UI test result
- [ ] NOT done, per explicit instruction: `deploy_release.sh`, `RELEASES.md`, GitHub Release, `README.md` — release itself

## UI/window-navigation suite — COMPLETE, all pass

Initial full-suite run appeared to hang (no test-completion output within 150s). Diagnosed by running all 9 tests individually first — every single one passed on its own (times ranged 0.2s–60s). Root cause: not a hang, just insufficient timeout budget — the 9 tests run serialized (`.serialized` trait, confirmed correct/intentional) and their combined real-world AppleScript/window-interaction time (~125-195s, dominated by `vlcPlayerControlsAreAccessible`'s real VLC start+buffer wait) exceeds the 120-150s ceiling used on the first two attempts. Re-ran with a 300s ceiling — full suite passed clean:

```
✔ Test run with 9 tests in 1 suite passed after 194.317 seconds.
```

All 9: donationNagReachableAndCloses, guideSourceToggleDoesNotBreakWindows, infoButtonSpacingIsConsistentAcrossTabs, addShowOpensAndCloses, addShowGuideSearchBoxIsAccessibleAndTypingDoesNotAutoSelect (previously flagged in the test's own comment as "unverified until run live" — now confirmed working), watchNowOpensAndCloses, watchNowRowButtonsAreAccessible, editShowOpensAndCloses, vlcPlayerControlsAreAccessible.

## Pre-release checklist — ALL COMPLETE (docs/Distribution.md step 0)

- [x] 0.1 Code review unreleased commits — 5 parallel deep-audit agents against v2.2.0..HEAD (44 commits)
- [x] 0.2 Update documentation — all confirmed doc bugs fixed
- [x] 0.3a Full local test suite — 410/410 passing
- [x] 0.3b UI/window-navigation suite — 9/9 passing (confirmed real pass, not a timeout artifact)
- [x] 0.4 Fix findings, commit — see below
- [ ] NOT done, per explicit instruction: `deploy_release.sh`, `RELEASES.md`, GitHub Release, `README.md` — release itself, deliberately not started

## Post-commit sanity check

One flaky run post-commit (2 tests: `readAndClearHDHRError_mapsKnownCodeAndDeletesFile`,
`backToBackTriggers_atLaunch_doNotRaceASecondBind`) — both pass individually and two
subsequent full-suite runs were clean (410/410 both times). Same class of parallel-execution/
system-load flakiness already noted earlier this session (unrelated to any code in this
audit — a port-bind race test and a file-timing test, neither touched today). Not a regression.

---

# AUDIT COMPLETE — v2.3.0 candidate ready for release-process to begin

Summary: 5 parallel deep-audit agents covering the full v2.2.0..HEAD span (44 commits) found
1 real regression (now fixed + regression-tested), 1 real security hardening (now fixed),
4 doc-drift items (now fixed), and 4 lower-priority items reported but deliberately not
fixed (2 resource-exhaustion findings needing a design decision on cap values, 2 pre-existing
minor edge cases). Full local suite 410/410, UI suite 9/9, both stable across repeat runs.

Per explicit instruction, `deploy_release.sh`/`RELEASES.md`/GitHub Release/`README.md` were
NOT touched — the release itself has not been started.

---

# FOLLOW-UP REVIEW — 2026-09-04, post-wizard-redesign

Scope: `dfd9823..HEAD` (4 new commits: animated FEED diagram, animated Sharing screens split into
3 steps w/ defaults-to-off, Sharing→Web LAN rename + revert-to-Sharing-for-the-tab correction) PLUS
a dedicated functional walkthrough of the whole FEED feature (not diff-scoped) per explicit ask:
"make sure FEED works as expected and we have no gaps in operation." Also an efficiency/"less
heavy" pass, particularly on the new continuously-animating diagram views.

Running 4 parallel agents: FEED functional-gaps walkthrough, invariants (guardrails focus, third
pass on this exact area per project history), efficiency/animation-cost focus, docs-auditor on the
4 new commits.

## Agent: docs-auditor (dfd9823..HEAD, rename-then-revert focus) — COMPLETE

**Clean.** The rename-then-revert was fully and consistently executed — zero "Settings → Web LAN → X" stray references anywhere in docs or source (grepped the literal pattern). All checked docs correctly read "Settings → Sharing → Enable Web LAN" / "...→ Terminal Guide" / "...→ Recording FEED". Wizard step enum/titles in code match doc numbering exactly.

**1 minor finding**: `Sources/hdhr_VCR/Models.swift:427` comment still says "see FirstRunWizardView's **Sharing step**" (singular) — stale from before the 3-way split (`077e6a7`). Not a doc contradiction (internal code comment only). Low severity, will fix.

## Agent: invariants-reviewer (dfd9823..HEAD) — COMPLETE

**Clean, no violations found.** Confirmed:
- New diagram views (`WebLANDiagram`/`TerminalTypingDiagram`/`NetworkFlowDiagram`) have zero references to `state.devices`/`recordableDevices`/`isVirtualRelay` — purely decorative, no real device enumeration.
- Both `true`→`false` default changes are consistent across property default AND decode fallback (`Models.swift:428,436` + `532-533`), with docs/hdhr_guide updated to match. The one remaining `true` default elsewhere (`GuideDTOs.swift`'s wire-protocol back-compat fallback for an old server predating the field) is intentional/pre-existing, unrelated.
- All 3 new diagrams only ever instantiated from `FirstRunWizardView.swift` — never reachable from `MenuContent.swift` or any frequently-rebuilt view, so `TimelineView(.animation)` can't reintroduce menu-churn.
- Wizard `finish()`'s config-commit logic correctly mirrors `SettingsView.save()`'s changed-value-gated pattern; the Web LAN/Terminal Guide cross-step edge case (disable Web LAN after having enabled Terminal Guide) is explicitly documented as accepted, matching pre-existing SettingsView behavior.

## Agent: swift-quality-reviewer, efficiency/"less heavy" pass (dfd9823..HEAD) — COMPLETE

**Nothing significant beyond what's already tracked.** This range is genuinely light (3 decorative diagram views + a label rename + a default flip).

- Reduce Motion gating already correctly present and working on all 3 diagrams (skips `TimelineView` entirely).
- Only one diagram is ever mounted at a time (wizard's `switch step`) — no concurrent animation loops accumulate.
- One real-but-trivial item: `TerminalTypingDiagram.swift:71-77` recomputes a `String(prefix:)` + rebuilds a 3-segment `Text` concatenation every frame even during the ~67% of each cycle where only the cursor blinks — command is a 10-char literal, waste is negligible, not worth adding a diffing/cache layer for a decorative wizard-only view. Recorded in CODE_NOTES so it isn't re-flagged later, not fixed.
- Confirmed via `git diff --stat` that `WebServer.swift`/`VLCBridge.swift` (FEED's actual server/transcode hot paths) have ZERO changes in this range — nothing there to review, confirmed rather than assumed.

## Agent: general-purpose, FEED end-to-end functional walkthrough — COMPLETE

**No new gaps found.** Traced the full lifecycle against actual code (not just docs):

1. **Start paths**: all 4 real triggers (`startRecording`, `teardownRecordingState`, `skipRecording`, `reattachRecordings`) call `updateVirtualTunerPresence()`. Every place that sets `show_recording = false` in `AppState.swift` reaches it — a silent-skip stop path isn't currently possible. `deleteShow` and the idle-loop process-death path both correctly route through `teardownRecordingState`.
2. **Multi-show growth**: `updateVirtualTunerPresence()` re-derives `tunerCount` and calls `virtualTuner.start(...)` again (in-place TLV update) every invocation — correct.
3. **Stop paths**: fail-threshold pause, manual stop, natural stop, delete all funnel through `teardownRecordingState`. Auto-pause-tuner-missing only touches non-recording shows; manual `pauseShow` isn't wired to recording shows — no bypass of the stop path.
4. **Viewer counting**: confirmed the earlier-fixed `stopTranscodeSession` double-decrement fix holds at both call sites; no sibling gap in `relayRawViewerConnected`/`Disconnected` (symmetric across header-failure/client-disconnect/duration-elapsed exits).
5. **Recording ends with viewers connected**: raw path re-checks `show_recording` on EOF and force-closes; transcode path's teardown cascades through the proxy delegate to close external connections too — no dangling viewer.
6. **Guardrails re-audited a 3rd time against the last 4 commits**: new diagrams are purely decorative, no device data touched. `handleRecord`/`handleToggleFavorite` still check `.isVirtualRelay` correctly.
7. **Settings/wizard toggle paths**: both `SettingsView.save()` and `FirstRunWizardView.finish()` correctly compute the changed-flag before mutating config, then mutate before calling `updateVirtualTunerPresence()`.

Assessment: "FEED's operation is solid end-to-end — this is a heavily-audited feature (two prior full passes plus this one), and every call site I traced already reflects those fixes."

---

# FOLLOW-UP REVIEW COMPLETE — all 4 agents clean

Summary: FEED's operation confirmed solid end-to-end, no new gaps. Invariants/guardrails hold. Efficiency is a non-issue in this range (confirmed WebServer.swift/VLCBridge.swift have zero diff — nothing heavy was touched). Docs/rename fully consistent.

**Only 1 fix applied**: stale internal comment in `Models.swift:427` ("see FirstRunWizardView's Sharing step" — no longer exists as one combined step, split into 3 by commit `077e6a7`).
