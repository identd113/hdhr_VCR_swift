# FloatingGuideView.swift — Standalone Guide Browser

## Intent

`FloatingGuideView` is a browse-only cable guide window that can be opened independently of the Add Show wizard. It uses the same `CableGuideView` grid and summary panel as `AddShowView` step 2, but has no Record button, no wizard navigation, and no step-advance behavior. The user can browse what's on across all tuners, see Bonus Time overlaps, and optionally Watch in VLC for on-air shows.

It is opened from the Add Show wizard via a pop-out button (or from any other trigger in the future). Window minimum: **1100×720**, no maximum.

---

## Layout Architecture

Uses the same `GeometryReader` structure as `AddShowView`'s guide step — this constraint is non-negotiable:

```
VStack(spacing: 0) {
    toolbar
    Divider()
    GeometryReader { proxy in        ← MUST wrap both summaryPanel and CableGuideView
        VStack(spacing: 0) {
            summaryPanel
                .frame(height: proxy.size.height / 3)
            Divider()
            CableGuideView(...)       ← NO .frame() here
                // or EmptyStateView when no guide data
        }
    }
}
.frame(minWidth: 1100, minHeight: 720)
.background(FloatingWindowLevelSetter())
.onExitCommand { dismiss() }
```

See `CableGuideView_pitfalls.md` for why `GeometryReader` must wrap both summary and grid.

---

## `FloatingWindowLevelSetter`

An `NSViewRepresentable` that raises the host `NSWindow` to `.floating` level on first appear. This keeps the floating guide above normal app windows (Finder, other apps) while the user browses, without making it modal.

```swift
private struct FloatingWindowLevelSetter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            v.window?.level = .floating
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
```

`DispatchQueue.main.async` is required because `v.window` is nil during `makeNSView` — the view must be inserted into the window's hierarchy first.

---

## Guide Loading — `loadGuide()`

Identical 3-path strategy to `AddShowView.loadAllGuide()`:
1. **Cache hit** — `guideStore.isFresh(deviceId:)` → read immediately
2. **Already loading** — poll with 200ms sleep until done, then read
3. **Fresh load** — `guideStore.load(for:hours:)` then read

Calls `state.ensureLineupLoaded(for:)` before any of the three paths, for the same reason as in `AddShowView`: startup `fetchAllLineups` can fail silently, and a missing lineup means `CableGuideView` has no `LineupEntry` objects, so taps don't resolve a `selectedChannel` and Watch in VLC stays disabled.

Triggered by `.task(id: taskId)` where `taskId = "\(selectedDevice?.DeviceID ?? ""):\(refreshToken)"`. Changing device or clicking Refresh bumps `refreshToken`.

---

## Toolbar

Single row: `[Tuner picker (multi-tuner only)] [Genre picker (when available)] ─ Spacer ─ [ProgressView] [Now] [Refresh] [N ch]`

- Tuner picker hidden when `state.devices.count == 1`
- Genre picker shows only when `availableGenres` is non-empty
- `[N ch]` is an orange `.caption2` label with the channel count — a quick sanity check for guide load issues
- Changing tuner: calls `state.guideStore.invalidate(deviceId:)` and bumps `refreshToken` — **does not clear `state.lineups`** (unlike `AddShowView`). Lineups are loaded during device discovery and are stable; clearing them in a browse-only view would disable Watch in VLC.
- Refresh: invalidates guide cache for selected device + bumps `refreshToken`

---

## `CableGuideView` Parameters

`FloatingGuideView` passes several extra sets beyond the basics:

| Parameter | Source |
|---|---|
| `recordingSeriesIDs` | `Set` of `show_seriesid` from `state.recordingShows` |
| `recordingTitles` | `Set` of `show_title` from `state.recordingShows` |
| `nextUpSeriesIDs` | `Set` of `show_seriesid` from `state.activeShows` where `show_next` is within 30 min |
| `nextUpTitles` | `Set` of `show_title` from the same next-up filter |
| `bonusSeriesIDs` | `Set` of `show_seriesid` from shows where `show_bonus_time == true` |
| `bonusTitles` | `Set` of `show_title` from bonus shows |
| `onConfirm` | `{}` — no-op; double-tap does nothing (browse-only) |

These are computed inline in the `body` before the `CableGuideView` call, using `let` bindings to avoid repeated set construction.

---

## Summary Panel

Displays the same information as `AddShowView`'s summary panel with a few differences:

**Extra fields not in AddShowView:**
- **Original airdate** — shown when `entry.OriginalAirdate` is non-nil: `"Orig. Jan 15, 2025"` in `.caption` / `secondaryLabelColor`.
- **Genre badge** — when `entry.firstGenre` is non-nil and not `"series"`, displays the genre uppercased in a small pill: `"SPORTS"`, `"NEWS"`, etc. White on a 0.20-opacity white background, rounded corners. Skips `"series"` because it's too generic to be useful.

**Differences from AddShowView:**
- No Record button (browse-only)
- No "Watch in App" button (Player_unlocked not relevant here)
- Shows a Bonus Time overlap warning via `bonusOverlapWarning(for:channel:device:)` — see below

**Common with AddShowView:**
- Background color from `guideEntryColor(for:onAir:)`
- Poster `AsyncImage`, title, episode info, synopsis, upcoming airings list
- `ChannelIcon`, time range, Watch in VLC button (conditional)
- "🔴 Recording Now" badge
- `StarburstBadge` overlay when `entry.firstGenre` contains "sports" and Bonus Time is enabled

---

## `bonusOverlapWarning(for:channel:device:)`

Detects when the selected show's start time falls inside an earlier show's bonus-time extension on the same channel:

```swift
for other in channelEntries {
    guard other.EndTime <= entry.StartTime else { continue }   // earlier show
    let isBonusShow = other.SeriesID.map { bonusSeriesIDs.contains($0) }
                   ?? bonusTitles.contains(other.Title)
    guard isBonusShow else { continue }
    let bonusEndEpoch = other.EndTime + bonusMin * 60
    guard bonusEndEpoch > entry.StartTime else { continue }    // actually overlaps
    let overlapMin = (bonusEndEpoch - entry.StartTime) / 60
    return "⚠️ First \(overlapMin) min overlap with extended recording of \"\(other.Title)\""
}
```

The warning is shown as `.caption` white text below the time range. It is the user's signal that if this show is scheduled, its first N minutes will be lost to the bonus time extension of the preceding show. This appears in `FloatingGuideView` because it is a browse-only view where the user is deciding what to add — in `AddShowView` the same information is implicit from the Bonus Time dotted box.

---

## Auto-Selection on Guide Load

`onChange(of: allChannels.count)` fires when guide data arrives. If nothing is selected yet (`selectedEntry == nil`), it auto-selects the currently-airing show on the first channel — identical to `AddShowView`. This populates the summary panel immediately without requiring a tap.

---

## Date Formatters

Three `static let` formatters (created once):
- `origAirdateFormatter` — `.medium` date, no time (e.g. `"Jan 15, 2025"`)
- `upcomingFormatter` — `"Ejmm"` template: short weekday + locale-preferred hour (e.g. `"Thu 8:00 PM"`)
- `timeRangeFormatter` — `"jmm"` template: locale-preferred hour only (e.g. `"8:00 PM"`)

All three use `DateFormatter.dateFormat(fromTemplate:options:locale:)` so they respect the user's 12h/24h preference.
