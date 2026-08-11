# Issue Log

Historical record of bugs encountered during development. Used as a "don't repeat this" reference during code reviews. Unrelated bugs found during work go here rather than fixed inline — note the resolving commit when done. Deferred features go in `TODO.md`.

**This file holds only what's still open, or accepted as-is (won't-fix / by-design / too marginal to schedule).** Once something is actually fixed, its entry moves to [`issues_resolved.md`](issues_resolved.md) rather than staying here — that file is the "how was X fixed" archive, this one is "what still needs attention." Findings about *technique* (things tried repeatedly and abandoned, independent of any specific still-open bug) live in [`FAILED_APPROACHES.md`](FAILED_APPROACHES.md) instead of either issue file.

**Format**: each issue has a status (`OPEN` or `ACCEPTED`), a brief description, root cause, and a fix note if one's been scoped but not done.

---

## Accepted — flagged, not scheduled (marginal / by-design)

Re-verified against current code 2026-08-10 — all four still accurate.

- **`RecordingManager.swift:161`** — orphaned-recording liveness uses `kill(pid,0)`, which tests PID existence not identity; PID reuse could report a dead recording as running. Astronomically low probability (slow PID cycling); accept.
- **`Models.swift`** (`GuideEntry`) — `==`/`hash`/`id` are StartTime-only, unsafe for cross-channel `Set`/`ForEach(id:)`. Already documented (`WatchNowView.swift`) and every call site deliberately uses `\.GuideNumber` — latent trap, no live bug.
- **`WebServer.swift`** — `stateCallback`/`activePort`/`listener` are unsynchronized under `@unchecked Sendable` (benign word writes); a dropped SSE conn lingers in `sseConns` up to 25 s until the keepalive prunes it (self-heals). Neither observed to misbehave.
- **`VLCBridge.swift`** (~line 55-60 at time of writing) — a CoreAudio device-change callback already in flight during `stopDeviceChangeMonitoring()` teardown could read a freed context. Very edge; related listener-lifecycle issue (double-registration) is fixed — see `issues_resolved.md` — this is a narrower residual case that wasn't.

