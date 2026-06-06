# ChannelSignalStore — Channel Signal Quality History

`@Observable @MainActor final class ChannelSignalStore` in `ChannelSignalStore.swift`. Singleton (`shared`). Stores per-channel signal quality samples and exposes a bucketed view for display.

---

## Purpose

Persists historical SNQ (Signal Quality Percent) readings so the guide views can show signal strength bars without live tuner access. Data is collected two ways:

- **Passive** — during any active recording, `AppState` reads `SignalQualityPercent` from `status.json` and calls `record(guideName:snq:)`.
- **Active scan** — user triggers `AppState.startSignalScan()` (Settings → Advanced → Signal Strength Scan), which tunes each channel briefly and takes 3 SNQ readings per channel.

---

## Storage

File: `~/Library/Application Support/hdhrVCRplus/channel_signal_history.json`  
Format: `{ "guidename": [{"ts": epoch, "snq": 0-100}, …] }`

Up to **50 samples** are kept per channel (oldest dropped). Writes are debounced — a save is scheduled 60 s after the first unsaved `record()` call; further calls within that window coalesce. `flush()` bypasses the debounce for an immediate write.

---

## Key Methods

| Method | Description |
|---|---|
| `load()` | Reads history from disk at startup. Called from `AppState.startup()`. |
| `record(guideName:snq:)` | Appends a sample, caps at 50, updates `buckets[key]` immediately, schedules a debounced save. |
| `flush()` | Cancels any pending debounced save and writes immediately via `Task.detached`. Called after each scan batch so partial progress survives a quit. |
| `needsSample(guideName:) -> Bool` | Adaptive re-sample gate: poor → 1 day, fair → 3 days, good → 7 days. Returns `true` when no data. |

---

## Bucketing

`bucketFor(_ samples:)` — rolling average of the last 20 SNQ values ÷ 100:

| SNQ average | Bucket |
|---|---|
| < 0.33 | `.poor` |
| 0.33 – 0.66 | `.fair` |
| ≥ 0.66 | `.good` |
| 0 samples | `.noData` |

A single sample is sufficient — the `noData` guard was lowered from ≥3 to ≥1 so bars appear immediately after the first scan.

---

## Observable State

`private(set) var buckets: [String: SignalBucket]` — updated synchronously on every `record()` call. SwiftUI views observe it directly via `@Observable`; no snapshot relay or `@Published` wrapper needed. Any view that reads `ChannelSignalStore.shared.buckets[key]` re-renders automatically when that key changes.

---

## Key Lookup

Both write side (`record`) and read side (`buckets`, `needsSample`) use `guideName.lowercased()` as the dictionary key. `GuideName` is device-agnostic — the same call sign appears on every device tuned to that multiplex — so signal data collected on one device applies to matching channels on all devices.

---

## AppState Integration

```swift
@Published var signalScanProgress: String? = nil

func startSignalScan(force: Bool = false)  // iterates lineups, tunes each channel, records SNQ
func cancelSignalScan()                    // cancels in-flight scan Task, clears progress
```

**Scan behaviour:**
- Processes channels **one at a time** (`batchSize = 1`) — one tuner used per step, no cross-channel interference.
- Takes **3 SNQ readings per channel** at 500 ms intervals (~1.5 s lock time per channel).
- Calls `flush()` after each channel so progress is saved incrementally.
- Skips channels where `needsSample()` returns `false` (already fresh) unless `force: true`.
- At startup, if `Signal_quality_enabled` and the store already has data (a prior scan was started), any channels still needing samples are scanned automatically.

Each scanned channel broadcasts one `signal_update` SSE event so connected web clients update bars in-place without a page reload.

---

## AppConfig Fields

```swift
var Signal_quality_enabled:      Bool = false  // show bars in guide/WatchNow
var Signal_quality_alert_notify: Bool = false  // system notification + Discord on dropout
```

Signal data is **always collected** during recordings regardless of `Signal_quality_enabled`. That toggle only controls display.

---

## SwiftUI — `SignalBarsView`

Defined in `GuideViewHelpers.swift`. A 3-bar chart rendered inline in guide rows.

```swift
struct SignalBarsView: View {
    let bucket: SignalBucket
}
```

- `.noData` → renders nothing (invisible, takes no space)
- `.poor` → 1 bar (red)
- `.fair` → 2 bars (yellow)
- `.good` → 3 bars (green)

Bar widths: 3 pt each, 1 pt spacing, aligned to `.bottom`. Used in `CableGuideView` (including AddShowView's guide step), `FloatingGuideView`, `WatchNowView`, and `MenuContent` when `Signal_quality_enabled`.

Helper: `signalBucket(guideName:)` — `@MainActor` free function that reads `ChannelSignalStore.shared.buckets[key]` directly. Returns `.noData` if no entry.
