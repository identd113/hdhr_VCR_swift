# ChannelSignalStore — Channel Signal Quality History

`actor ChannelSignalStore` in `ChannelSignalStore.swift`. Singleton (`shared`). Stores per-channel signal quality samples and exposes a bucketed view for display.

---

## Purpose

Persists historical SNQ (Signal Quality Percent) readings so the guide views can show signal strength bars without live tuner access. Data is collected two ways:

- **Passive** — during any active recording, `AppState` reads `SignalQualityPercent` from `status.json` and calls `record(guideName:snq:)`.
- **Active scan** — user triggers `AppState.startSignalScan()` (Settings → Advanced → Scan Channels), which tunes each channel briefly (2 s) and samples SNQ.

---

## Storage

File: `~/Library/Application Support/hdhrVCRplus/channel_signal_history.json`  
Format: `{ "guidename": [{"ts": epoch, "snq": 0-100}, …] }`

Up to **50 samples** are kept per channel (oldest dropped). Writes are debounced — a save is scheduled 60 s after the first unsaved `record()` call; further calls within that window coalesce.

---

## Key Methods

| Method | Description |
|---|---|
| `load()` | Reads history from disk at startup. Called from `AppState.startup()`. |
| `record(guideName:snq:)` | Appends a sample, caps at 50, schedules a save. |
| `allBuckets() -> [String: SignalBucket]` | Returns a snapshot of every channel's bucket (rolling 20-sample average). Used to populate `AppState.channelSignalBuckets`. |
| `needsSample(guideName:) -> Bool` | Adaptive re-sample gate: poor channels re-check after 1 day, fair after 3 days, good after 7 days. `true` when no data. |

---

## Bucketing

`bucketFor(_ samples:)` — rolling average of the last 20 SNQ values ÷ 100:

| SNQ average | Bucket |
|---|---|
| < 0.33 | `.poor` |
| 0.33 – 0.66 | `.fair` |
| ≥ 0.66 | `.good` |
| < 3 samples | `.noData` |

Requires ≥ 3 samples to avoid noise from brief lock-ons.

---

## Key Lookup

Both write side (`record`) and read side (`allBuckets`, `needsSample`) use `guideName.lowercased()` as the dictionary key. `GuideName` (from `LineupEntry`) is device-agnostic — the same call sign appears on every device tuned to that multiplex — so signal data collected on one device applies to matching channels on all devices.

---

## AppState Integration

```swift
@Published var channelSignalBuckets: [String: SignalBucket] = [:]
@Published var signalScanProgress: String? = nil

func startSignalScan()   // iterates all device lineups, tunes briefly, records snq
func cancelSignalScan()  // cancels in-flight scan Task, clears progress
```

`channelSignalBuckets` is refreshed from `ChannelSignalStore.shared.allBuckets()` at startup (when `Signal_quality_enabled`) and after each scan step. Each step also broadcasts a `signal_update` SSE event so connected web clients update bars in-place.

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
- `.poor` → 1 bar (red, heights: 4pt filled, 7pt unfilled, 10pt unfilled)
- `.fair` → 2 bars (yellow)
- `.good` → 3 bars (green)

Bar widths: 3 pt each, 1 pt spacing, aligned to `.bottom`. Used in `CableGuideView`, `FloatingGuideView`, and `WatchNowView` channel columns when `Signal_quality_enabled`.

Helper: `signalBucket(guideName:in:)` — looks up a pre-computed snapshot dict; falls back to `.noData`. Views capture the snapshot once per render rather than calling the actor directly.
