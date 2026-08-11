# Issue Log

Historical record of bugs encountered during development. Used as a "don't repeat this" reference during code reviews. Unrelated bugs found during work go here rather than fixed inline — note the resolving commit when done. Deferred features go in `TODO.md`.

**This file holds only what's still open, or accepted as-is (won't-fix / by-design / too marginal to schedule).** Once something is actually fixed, its entry moves to [`issues_resolved.md`](issues_resolved.md) rather than staying here — that file is the "how was X fixed" archive, this one is "what still needs attention." Findings about *technique* (things tried repeatedly and abandoned, independent of any specific still-open bug) live in [`FAILED_APPROACHES.md`](FAILED_APPROACHES.md) instead of either issue file.

**Format**: each issue has a status (`OPEN` or `ACCEPTED`), a brief description, root cause, and a fix note if one's been scoped but not done.

---

## Open

- **OPEN — `WebServer.swift` `isLocalAddress` treats non-loopback IPv6 as loopback** — the loopback fast-path uses `testIP.hasPrefix("::1")`, which matches any IPv6 address *beginning* "::1" (`::1234:5678`, `::123`, `::1:2:3` — the deprecated IPv4-compatible `::/96` space), granting those sources the loopback bypass past the subnet check entirely. Exploitability is low (those addresses are effectively unroutable from the public internet, and TCP spoofing is impractical), but the check is simply wrong as written. **Fix note**: exact-match `testIP == "::1"` (the IPv4-mapped `::ffff:127.0.0.1` case is already normalized to `127.0.0.1` by the strip above it). One-line fix. Found 2026-08-11 web-server security pass.

---

## Accepted — flagged, not scheduled (marginal / by-design)

First four re-verified against current code 2026-08-10 — all still accurate. Fifth added 2026-08-11.

- **`RecordingManager.swift:161`** — orphaned-recording liveness uses `kill(pid,0)`, which tests PID existence not identity; PID reuse could report a dead recording as running. Astronomically low probability (slow PID cycling); accept.
- **`Models.swift`** (`GuideEntry`) — `==`/`hash`/`id` are StartTime-only, unsafe for cross-channel `Set`/`ForEach(id:)`. Already documented (`WatchNowView.swift`) and every call site deliberately uses `\.GuideNumber` — latent trap, no live bug.
- **`WebServer.swift`** — `stateCallback`/`activePort`/`listener` are unsynchronized under `@unchecked Sendable` (benign word writes); a dropped SSE conn lingers in `sseConns` up to 25 s until the keepalive prunes it (self-heals). Neither observed to misbehave.
- **`VLCBridge.swift`** (~line 55-60 at time of writing) — a CoreAudio device-change callback already in flight during `stopDeviceChangeMonitoring()` teardown could read a freed context. Very edge; related listener-lifecycle issue (double-registration) is fixed — see `issues_resolved.md` — this is a narrower residual case that wasn't.
- **`WebServer.swift` — LAN-trust hardening notes (2026-08-11 security pass)** — three related accepts, all requiring a hostile or misbehaving device *already on the trusted network*: (1) the subnet check matches any local interface's subnet, **including VPN tunnels** (utun) — a connected VPN with a wide netmask admits all VPN-side peers as "local"; inherent to the subnet-trust design, worth knowing when running a VPN on the host Mac. (2) **No cap on concurrent SSE connections** — `sseConns` grows per open `/api/events` connection with no limit; dead ones prune via the 25 s keepalive but a client holding thousands open exhausts file descriptors (degradation, not crash). (3) **`handleEdit`/`handleRecord` accept unbounded `title` strings** — bounded only by the 128 KB request cap; a ~100 KB title bloats config/page builds, and embedded newlines pass into `glog` lines (log-line injection). All three accepted as marginal on a home LAN; revisit if the trust model ever widens.
- **`src/HDHomeRunKit/`** — ~1,000 lines of dead player code (`HDHomeRunPlayerView`, `HDHomeRunPlayerViewModel`, `DVRBufferManager`, etc.) sitting in the working directory from an earlier player exploration. Gitignored (`/src` in `.gitignore`) and not referenced by `Package.swift`, so it can't affect the build or the repo — but it *does* show up in filesystem-wide searches (`find`/`grep` over the checkout without a `.build`-style exclusion), where its similarly-named types can mislead a code search or an automated audit into reading it as live code. Local-only clutter, zero runtime risk; accept unless/until it confuses something, in which case just delete the directory (it exists nowhere else — confirm nothing in it is worth salvaging first). Found during 2026-08-11 lean code audit.

