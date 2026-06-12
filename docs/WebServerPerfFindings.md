# Web Server Performance Findings

Investigation into slow guide page load as seen in Chrome DevTools. Six changes were made; this document records what was found, what was changed, and whether the added complexity is worth it.

---

## What we measured

| Endpoint | Before | After |
|---|---|---|
| `GET /` (curl, cold) | 126 ms | 146 ms (same order) |
| `GET /` (curl, warm cache) | 126 ms | **2 ms** |
| Chrome Content Download stall | **55 s** | **0 s** |
| Lighthouse LCP element | `img#sum-poster` (16.21 s) | guide grid (~1–3 s estimated) |

The 55-second Content Download stall in Chrome was the real user-visible bug. Everything else was optimization.

---

## Change 1 — `isComplete: true` on `conn.send()`

**The actual bug.** NWConnection's `conn.send()` does not close the TCP connection unless `isComplete: true` is passed. Without it, Chrome received all the bytes but kept the connection open waiting for more, stalling for 55 seconds before timing out.

`curl` was not affected because it reads until the server closes, but also closes on its own when Content-Length is satisfied. Chrome kept waiting.

**Fix:** One parameter added to one `conn.send()` call.

**Worth it:** Yes — this is the fix. Everything else is polish.

---

## Change 2 — Remove `refreshTunerOccupancy()` from the request path

**What it was:** Before serving the guide page, the server fetched `status.json` from every HDHomeRun device over the LAN (concurrent HTTP requests, 2s timeout each). This added 0–2s of blocking per page load, and the data was already being maintained by the 10-second idle loop.

**Fix:** Deleted ~35 lines. The idle loop already populates `AppState.deviceTunerOccupancy`; the request handler now reads that cache directly.

**Worth it:** Yes — removes complexity and latency. The worst case (stale tuner count by up to 10s) was already acceptable, and SSE pushes live updates anyway.

---

## Change 3 — `requestAnimationFrame` for auto-select and `scrollToNow`

**What it was:** On page load, an IIFE ran synchronously to find the currently-airing program and called `showInfo()`, which set `img#sum-poster.src` to an external CDN URL (`img.hdhomerun.com`). Chrome recorded that CDN image as the LCP element because it was the largest thing that loaded — at ~47 ms over the network, but combined with Lighthouse's network throttling it became 16 s.

**Fix:** Wrapped the auto-select IIFE and `scrollToNow()` in a `requestAnimationFrame` callback. The guide grid paints in frame 1 (LCP). The poster fetches in frame 2+.

Also moved the function definitions before the rAF block so they're in scope inside the callback — the original code had the auto-select IIFE before `scrollToNow()` was even defined, which worked by accident (the IIFE didn't call scrollToNow).

**Worth it:** Yes. Two lines of wrapping. LCP goes from an external CDN image to the guide grid, which is already in the initial HTML.

---

## Change 4 — Progressive poster loading in `showInfo()`

**What it was:** Clicking a program block loaded the CDN poster URL directly into `img#sum-poster`. The panel showed nothing until the CDN responded (~47 ms, but variable).

**Fix:** When both a logo and poster URL are available, set the channel logo immediately (already cached locally), then fetch the CDN poster in a hidden `Image()` object. On load, swap it in. A generation counter prevents a slow fetch from a previous selection from overwriting a later one.

**Worth it:** Yes. ~10 extra lines of JS. The panel now responds instantly to clicks. The generation guard is necessary — without it, selecting two programs quickly causes a race where the first program's poster arrives late and replaces the second program's logo.

---

## Change 5 — TCP_NODELAY on the NWListener

**What it was:** `NWListener(using: .tcp)` uses NWParameters defaults, which leaves Nagle's algorithm enabled (`noDelay = false`). Nagle batches small writes to reduce packet count, which can add up to 200ms of latency on interactive responses.

**Fix:** Created an explicit `NWProtocolTCP.Options()` with `noDelay = true`, passed as `NWParameters(tls: nil, tcp: tcpOpts)`.

**Measured impact:** None. curl already disables Nagle on its own, so our timing method couldn't detect a difference. The change is theoretically correct — a large response like the guide page is not affected by Nagle anyway, since Nagle only delays small writes that haven't been ACKed yet.

**Worth it:** Marginal. The change is 4 lines and correct in principle, but it didn't measurably help this workload. For request-response patterns with a large single payload, Nagle has no effect. Would matter more for streaming or interactive protocols. Low cost to keep, zero proven benefit.

---

## Change 6 — 30-second HTML cache

**What it was:** Every `GET /` called `buildHTML()` (84 ms on MainActor) then `gzip()` (42 ms) = 126 ms per request, including requests from the in-app WKWebView window and any browser tabs simultaneously.

**Fix:** Cache the built + gzipped `Data` for 30 seconds, keyed by desktop/mobile UA. Cache hits skip both steps.

| Request | Before | After |
|---|---|---|
| Cold (first load or >30s since last) | 126 ms | 146 ms (slightly slower: gzip now runs on MainActor instead of cooperatively) |
| Warm (within 30s) | 126 ms | **2 ms** |

**Worth it:** Partially. The real benefit is not the 144ms TTFB improvement — 146ms is already imperceptible on a LAN. The real benefit is **MainActor contention**: `buildHTML()` holds the main actor for 84ms. If the WKWebView and a browser tab both load simultaneously, they queue up. The cache eliminates that. The downside is 25 lines of added code across three places (`WebResponse` enum, `routeOnMain`, `send`), plus the HTML being up to 30s stale (recording-status class names). SSE pushes corrections within seconds, so staleness is acceptable.

**If you wanted to revert it:** The cache is the most complex change and the one with the most subtle failure mode (stale recording indicators). If the code feels like too much, it's the first candidate to drop. The page would still load in 146ms.

---

## Summary

| Change | Lines | Real benefit | Keep? |
|---|---|---|---|
| `isComplete: true` | +1 word | Fixed 55s stall | **Yes** |
| Remove `refreshTunerOccupancy` | −35 lines | Simpler, correct | **Yes** |
| rAF deferral | +5 lines | LCP from CDN → guide grid | **Yes** |
| Progressive poster | +10 lines JS | Instant panel response | **Yes** |
| TCP_NODELAY | +4 lines | None measured | Harmless |
| HTML cache | +25 lines | 2ms warm loads, less MainActor contention | Optional |

The first four changes are unconditionally correct and low-cost. The last two are defensible but not essential for this single-LAN-server use case.
