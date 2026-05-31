# FloatingGuideView.swift — Standalone Guide Browser

## Visual Appearance

### Overall window
Minimum **1100×720**, no maximum. Resizable. Floating above other windows (via `FloatingWindowLevelSetter`). No title bar decorations beyond the standard macOS close/minimize/zoom buttons. Window title: `"Cable Guide"`.

### Toolbar (top bar, ~42pt tall)
Single horizontal row, `windowBackgroundColor` background, 10pt horizontal padding:
- **Tuner picker** (left, up to 170pt wide): `"Tuner:"` secondary label + popup picker showing DeviceID. Hidden when only 1 tuner.
- **Genre filter** (left of center, up to 160pt wide): `"Genre:"` secondary label + popup picker with `"All"` + genre list. Hidden when no genres present.
- **Right side**: spinning `ProgressView` while loading; `"Now"` button (`clock.arrow.circlepath`); `"Refresh"` button (`arrow.clockwise`, disabled while loading)

A `Divider` below the toolbar.

### Content area
`GeometryReader` splits height into two vertical regions:

**Summary panel (top 1/3 of content height)**:
Same appearance as `AddShowView` step 2 summary panel:
- Genre-color background at 90% opacity; all text white with drop shadow
- Left: poster image (140×100, cornerRadius 7) with optional yellow 20pt managed flag triangle at top-right corner; placeholder `Color.white.opacity(0.2)` rounded rectangle when no image
- Right: title (`.title3` bold), `"🔴 Recording Now"` badge if applicable, genre badge (white bg), episode info, original airdate, synopsis (3 lines), upcoming airings, channel icon + time range, **Watch in VLC** / **Watch Now!** buttons
- No Record button — this view is browse-only
- Orange `StarburstBadge` (100pt) overlaid top-right when a sports show is selected with Bonus Time enabled
- `"Select a show from the grid"` tertiary placeholder when nothing is selected

**Guide grid (bottom 2/3 of content height)**:
Identical to `CableGuideView` appearance described in `CableGuideView.md`. When no guide data and not loading: `EmptyStateView` — `tv.slash` SF Symbol, `"No guide data"` title, description.

## Intent

`FloatingGuideView` is a browse-only cable guide window that can be opened independently of the Add Show wizard. It uses the same `CableGuideView` grid and summary panel as `AddShowView` step 2, but has no Record button, no wizard navigation, and no step-advance behavior. The user can browse what's on across all tuners, see Bonus Time overlaps, and optionally Watch in VLC for on-air shows.

It is opened from the Add Show wizard via a pop-out button (`openWindow(id: "cable-guide")`), or from any other trigger in the future. Window ID: `"cable-guide"`. Window minimum: **1100×720**, no maximum.

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
| `deviceId` | `selectedDevice?.DeviceID ?? ""` — keys DateTime/Single slot matching |
| `managedSeriesIDs` | `Set` of `show_seriesid` from SeriesID(Channel/All) shows — yellow flag on any episode |
| `managedTitles` | `Set` of `show_title` from the same SeriesID shows — title fallback when entry has no SeriesID |
| `managedDTSingleSlotKeys` | `Set` of `"deviceId:channel:epoch"` from DateTime/Single shows — yellow flag only on the exact slot |
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
- **Watch Now!** button (`play.tv.fill`, blue) shown when `onAir && VLCBridge.shared.isAvailable` — calls `state.watchInApp(url:title:deviceId:)`; no `Player_unlocked` gate
- Shows a Bonus Time overlap warning via `state.bonusOverlapWarning(for:channel:deviceId:)` (AppState method) — see below

**Common with AddShowView:**
- Background color from `guideEntryColor(for:onAir:)`
- Poster `AsyncImage`, title, episode info, synopsis, upcoming airings list
- `ChannelIcon`, time range, Watch in VLC button (conditional)
- "🔴 Recording Now" badge
- `StarburstBadge` overlay when `entry.firstGenre` contains "sports" and Bonus Time is enabled

---

## `bonusOverlapWarning(for:channel:deviceId:)` — AppState method

Detects when the selected show's start time falls inside an earlier show's bonus-time extension on the same channel. Lives on `AppState` (moved from per-view private helper):

```swift
func bonusOverlapWarning(for entry: GuideEntry, channel: LineupEntry, deviceId: String) -> String?
```

```swift
for other in channelEntries {
    guard other.EndTime <= entry.StartTime else { continue }   // earlier show
    let isBonusShow = other.SeriesID.map { bonusSeriesIDs.contains($0) }
                   ?? bonusTitles.contains(other.Title)
    guard isBonusShow else { continue }
    let bonusEndEpoch = other.EndTime + bonusMin * 60
    guard bonusEndEpoch > entry.StartTime else { continue }    // actually overlaps
    let overlapMin = max(1, (bonusEndEpoch - entry.StartTime) / 60)
    return "⚠️ First \(overlapMin) min overlap with extended recording of \"\(other.Title)\""
}
```

The warning is shown as `.caption` white text below the time range. It is the user's signal that if this show is scheduled, its first N minutes will be lost to the bonus time extension of the preceding show. Call site passes `deviceId: device.DeviceID`.

---

## Auto-Selection on Guide Load

`onChange(of: allChannels.count)` fires when guide data arrives. If nothing is selected yet (`selectedEntry == nil`), it auto-selects the currently-airing show on the first channel — identical to `AddShowView`. This populates the summary panel immediately without requiring a tap.

---

## Date Formatters

Three module-level `let` formatters defined once in `GuideViewHelpers.swift` and shared across `AddShowView`, `FloatingGuideView`, and `CableGuideView`:
- `origAirdateFormatter` — `.medium` date, no time (e.g. `"Jan 15, 2025"`)
- `upcomingFormatter` — `"Ejmm"` template: short weekday + locale-preferred hour (e.g. `"Thu 8:00 PM"`)
- `timeRangeFormatter` — `"jmm"` template: locale-preferred hour only (e.g. `"8:00 PM"`)

All three use `DateFormatter.dateFormat(fromTemplate:options:locale:)` so they respect the user's 12h/24h preference. `guideTimeRange(_:)` is also a free function in `GuideViewHelpers.swift` wrapping `timeRangeFormatter`.
