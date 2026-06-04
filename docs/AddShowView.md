# AddShowView.swift — Add Show Wizard

## Visual Appearance

### Overall window
Fixed **560×540** for steps 1 and 3; expands to resizable **min 1100×720** for the guide step. The window animates between sizes with a 0.2s ease-in-out. Escape closes the window from any step.

**Top of window (all steps)**: 2 small 8pt circles in a row, left-padded under the top edge — progress indicator. Filled accent-color circle = current step; hollow gray circle = other step. `guide` and `details` steps only — `ForEach([Step.guide, .details])` always produces exactly 2 dots. Below the circles: a `Divider`.

### Step 1 — Device selection (usually auto-skipped)
White background. Title `"Select Tuner"` in `.title2` left-padded, with a `"Refresh"` labeled button (↺ icon) at the right.

If no devices: centered `EmptyStateView` — `wifi.slash` SF Symbol, `"No tuners found"` title, description text.

If devices present: macOS `List` with rows, each row:
- `antenna.radiowaves.left.and.right` SF Symbol icon (decorative, hidden from VoiceOver)
- **DeviceID** in bold on the left
- `"Recording N"` in red bold caption on the right (if recording)
- Below: `"192.168.1.x · 4 tuners · 106 channels · fw 20240101"` in caption secondary color
- Selected row highlighted in system accent color

Nav bar (bottom): **Next** button (`.borderedProminent`) enabled when a device is selected.

### Step 2 — Guide (cable grid)
**Compact toolbar** (single row, ~42pt tall, `windowBackgroundColor` background):
- Left: `Menu` showing current tuner name with disclosure indicator (hidden when only 1 tuner)
- `"Genre:"` secondary label + `Picker` (up to 160pt wide) for genre filtering (hidden when no genres in guide data)
- Right side: spinning `ProgressView` (0.7× scale) while loading; `"Now"` button with `clock.arrow.circlepath` icon; `"Refresh"` button with `arrow.clockwise` icon; pop-out button (`arrow.up.left.and.arrow.down.right` icon) — calls `openWindow(id: "cable-guide")` to open `FloatingGuideView` as a standalone browse window; `"[106 ch]"` in caption orange
A `Divider` separates toolbar from content.

**Content area** (fills remaining height via `GeometryReader`):
- **Top 1/3** — Summary panel (see below)
- Thin `Divider`
- **Bottom 2/3** — `CableGuideView` grid

**Summary panel** (when a show is selected):
Background: the guide block's genre color at 90% opacity (e.g. blue for drama, amber for comedy, green for sports). All text is white with black drop shadow (`radius: 1.5, x: 0, y: 1`).

Layout (HStack, 14pt horizontal padding, 10pt vertical padding):
- **Left**: poster image, 180pt wide, fills panel height, `.aspectRatio(.fill)`, `.clipShape(RoundedRectangle(cornerRadius: 7))`. White semi-transparent placeholder if no URL. Yellow 20pt triangle overlay at top-right corner if show is already scheduled. If on-air: `"Recording Now"` red badge with `record.circle.fill` icon.
- **Right** (VStack, 4pt spacing):
  - Title: `.title3` bold white, 1 line
  - Genre badge (if non-"series"): small all-caps text on `Color.white.opacity(0.20)` rounded rectangle, 3pt cornerRadius
  - Episode info: `.subheadline` white
  - Original airdate: `"Orig. Jan 15, 2024"` in `.caption` at 80% opacity
  - Synopsis: `.callout` white, up to 3 lines
  - Upcoming airings: `"Channel 5.1 Thu 8:00 PM · Channel 5.1 Fri 10:00 PM"` in `.caption2` at 85% opacity
  - Bottom row: 52×52 channel icon + `"Channel 5.1 · 8:00 PM – 9:00 PM"` caption + optional **Watch in VLC** / **Watch Now!** buttons + **Record** / **Edit Show** button
  - **Record** button: `WhiteOutlineButtonStyle(borderColor: .red)` custom style; **Edit Show** in `WhiteOutlineButtonStyle(borderColor: .blue)` when show is already managed
  - Bonus Time: orange `StarburstBadge` overlaid top-right of the ZStack when a sports show is selected
  - Overlap warning: small white caption at bottom, invisible (opacity 0) when no overlap

**Empty summary** (nothing selected): `"Select a show from the grid"` centered in `.tertiary` color.

Dark gradient scrim (`black 28% → black 4%`, leading to trailing) behind the text column as `.multiply` blend mode — improves contrast on light genre backgrounds without tinting.

### Step 3 — Details
Fixed 560×540 window. White/system background. `ScrollView` containing a `VStack` with 16pt spacing.

- Form fields using `ShowFormSection` (shared with `EditShowView`)
- `LabeledContent` for channel (TextField, 80pt wide) and length (60pt wide number field)
- Bottom-right: orange `StarburstBadge` (115pt size) floats via `.overlay(alignment: .bottomTrailing)`, springs in on appear if sports show + Bonus Time enabled

**Nav bar** (bottom): **Back** on left, **Save** (`.borderedProminent`) on right. A `Divider` above.

## Intent

`AddShowView` is a 3-step wizard window for adding a new recording schedule. It guides the user from tuner selection → cable guide browsing → recording details. It is the primary way new shows get added when the app is in Wizard mode (vs. the inline cascading menu mode).

Window size: **560×540** for steps 1 and 3; **resizable** (min 1100×720, ideal 1280×820) for step 2 (guide grid). The guide step window can be expanded to full screen — the grid fills available width via dynamic `pxPerMin` scaling.

---

## Steps

```
enum Step { case device, guide, details }
```

A progress indicator (2 dots, filled vs hollow) tracks position across the `guide` and `details` steps. Step content fills the main area. A nav bar (Back / Next or Save) is shown for steps 1 and 3. The guide step hides the nav bar entirely; Record appears in the summary panel. **Escape key** dismisses the window from any step (`.onExitCommand { dismiss() }` on the root VStack).

### Step 1 — Device

Shows a `List` of `state.devices` with expanded device info:
- **DeviceID** + active recording count (red when > 0)
- **IP · N tuners · M channels · fw YYYYMMDD** (firmware shown if non-nil)

Tapping a row sets `selectedDevice`. **Double-tapping** sets `selectedDevice` and immediately advances to step 2 (`.simultaneousGesture(TapGesture(count: 2).onEnded { ... })`). The "Next" button also advances when `selectedDevice != nil`.

**Single-device skip**: `.onAppear` auto-selects the only device and jumps to step 2 immediately, so single-tuner setups never see the device list.

A **Refresh** button runs `state.discoverDevices()` in a `Task` in case the initial startup discovery missed devices.

### Step 2 — Guide

Full cable-guide layout powered by `CableGuideView`. Guide step hides the bottom nav bar to reclaim ~48px for the grid. Record appears in the summary panel. **Escape** (`.onExitCommand`) dismisses the wizard from any step — there is no Cancel button in the toolbar.

**Window resizes** when `step == .guide` — a `.frame()` modifier on the outer `VStack` switches between fixed 560×540 (steps 1 and 3) and resizable with min 1100×720 (step 2):
```swift
.frame(
    minWidth: step == .guide ? 1100 : 560,
    idealWidth: step == .guide ? 1280 : 560,
    maxWidth: step == .guide ? .infinity : 560,
    minHeight: step == .guide ? 720 : 540,
    idealHeight: step == .guide ? 820 : 540,
    maxHeight: step == .guide ? .infinity : 540
)
```
The window animates between sizes with `.animation(.easeInOut(duration: 0.2), value: step)`.

**Guide loading**: `.task(id: taskId)` fires `loadAllGuide()` when `selectedDevice` or `refreshToken` changes. `taskId = "\(deviceId):\(refreshToken)"`.

**Bonus Time data**: computed from `state.shows` filtered to shows with `show_bonus_time == true`:
```swift
let bonusShows    = state.shows.filter { $0.show_bonus_time }
let bonusSeriesIDs = Set(bonusShows.compactMap { $0.show_seriesid.isEmpty ? nil : $0.show_seriesid })
let bonusTitles    = Set(bonusShows.map { $0.show_title })
```
These are passed to `CableGuideView` along with `bonusMinutes: state.config.Sports_padding_minutes` so the dotted Bonus Time overlay box renders on matching guide entries.

**Auto-selection**: `onChange(of: allChannels.count)` auto-selects the currently-airing show on the first channel as soon as guide data loads, so the summary panel is populated immediately without requiring a tap.

**Genre filter resets**: when the tuner picker changes, `availableGenres` repopulates and `genreFilter` becomes invalid (stale genre string). It resets to `nil`.

**Tuner switch cache invalidation**: `onChange(of: selectedDevice)` calls `state.guideStore.invalidate(deviceId:)` and bumps `refreshToken`. Lineups are **not** cleared — clearing them would leave `CableGuideView` without lineup data and disable the Record button. `genreFilter` is also reset to `nil` so a stale filter from the previous tuner doesn't leave the guide non-interactive.

**`guideRevision` observation**: `onChange(of: state.guideRevision)` catches guide updates triggered by the idle loop while the wizard is open, pulling fresh channels into `allChannels` if they were empty.

### Step 3 — Details

`ScrollView` containing the form fields, with a `StarburstBadge` floating at the bottom-right via `.overlay(alignment: .bottomTrailing)` on the outer `Group { switch step }` — outside and above the `ScrollView`.

Form fields:
- **Title** — `TextField` pre-populated by `applyGuideEntry()`
- **Type** — segmented `Picker` for `ShowState.allCases`
- **Days** — weekday toggle buttons (shown for `.single` and `.dateTime`). Single enforces single-day selection; dateTime allows any combination
- **Transcode** — `Picker`: None / Heavy / Mobile / Internet 720
- **Folder** — display + Choose… button; writes to `UserDefaults["defaultSaveDirectory"]`

**Bonus Time starburst**: when `show.show_genre.lowercased().contains("sports") && state.config.Sports_padding_enabled`, a `StarburstBadge` (from `StarburstBadge.swift`) overlays the top-right corner showing "🏈 +N min". It animates in with a `keyframeAnimator` pop-in sequence on appear and has a 5-tap easter egg that triggers a celebration spin. The same component is used in the guide step summary panel and `FloatingGuideView`.

`canAdvance` for details step: `!show.show_title.isEmpty && recordFolder != nil`.

---

## Layout Architecture — Guide Step (CRITICAL)

> **Do not change the outer structure without reading `docs/CableGuideView_pitfalls.md`.**

```
VStack(spacing: 0) {
  compactToolbar                   ← Cancel, Tuner picker, Genre picker, Now, Refresh, [N ch]
  Divider
  GeometryReader { proxy in        ← MUST wrap both summaryPanel and CableGuideView
    VStack(spacing: 0) {
      summaryPanel
        .frame(height: proxy.size.height / 3)
        .clipped()                 ← prevents HStack padding from overflowing the panel frame
      Divider
      CableGuideView(...)          ← NO .frame() here — GeometryReader distributes height
    }
  }
}
```

### Constraints That Must Be Preserved

1. **`GeometryReader` MUST wrap both the summary panel AND `CableGuideView`** — pulling the summary panel outside the `GeometryReader` always causes the guide to fill the window and the summary to disappear.
2. **`CableGuideView` must NOT have a `.frame()` modifier** — the `GeometryReader` + `VStack` distributes height naturally.
3. **Summary height = `proxy.size.height / 3`** (not a fixed pixel value).
4. **Window minimum = 1100×720** for the guide step (resizable up to full screen). The guide grid fills available width dynamically via `pxPerMin` scaling; see `CableGuideView.md`.

---

## Summary Panel

Displayed in the top 1/3 of the guide step content area. Background color matches the selected guide cell color via `guideEntryColor(for:onAir:)` (module-level function in `CableGuideView.swift`, non-private so `AddShowView` can call it).

When a show is selected:
- **Poster image** — `AsyncImage`, `.frame(width: 180).frame(maxHeight: .infinity)` (fills HStack height dynamically), clipped and rounded via `.clipShape(RoundedRectangle(cornerRadius: 7))`. Carries `.accessibilityLabel("\(entry.Title) poster")`. Has a yellow 20pt right-angle triangle overlay in the top-right corner via `ManagedFlagView()` — shown when the entry matches an already-scheduled show (SeriesID or title match against `state.shows`). **Important**: `.clipShape` is used instead of `.cornerRadius + .clipped()` because the latter clips to a rectangle, allowing image content to bleed past the rounded corners.
- **`ManagedFlagView`** — shared struct in `GuideViewHelpers.swift` that draws a `Path`-based yellow right-angle triangle when rendered, with `.accessibilityLabel("Already scheduled")`. Default size 20pt; CableGuideView uses `ManagedFlagView(size: 22)`.
- **"🔴 Recording Now" badge** — shown if the selected channel is actively recording (`recordingShows` match by channel + time)
- **Title** — `.title3`, bold, white with drop shadow
- **Episode info** — `entry.episodeInfoLabel` → `"S02E05 · The Episode Title"`, `.subheadline`
- **Synopsis** — up to 3 lines, `.callout`
- **Upcoming airings** (SeriesID shows) — calls `state.upcomingGuideEpisodes(seriesID:)` → `"ch 5.1 Thu 8:00 PM · ch 5.1 Fri 10:00 PM"`, `.caption2`
- **Channel icon** — `ChannelIcon(urlString:size:52)` from `ChannelIconCache`; sourced from `GuideChannel.ImageURL` (not `LineupEntry`, which has no icon); sets `img = nil` on nil `urlString` to prevent stale logo bleed when switching to a channel without an icon
- **Time range** — `"ch 5.1 · 8:00 PM – 9:00 PM"`, `.caption`
- **Watch in VLC** button — conditional on `config.Watch_in_VLC && VLC installed && onAir`
- **Watch Now!** button — conditional on `onAir && VLCBridge.shared.isAvailable`
- **Record** button — `.borderedProminent`; calls `applyGuideEntry()` then advances to step 3

Placeholder `"Select a show from the grid"` shown when nothing is selected.

---

## Guide Loading — `loadAllGuide()`

Before any of the three cache paths, `loadAllGuide()` calls `await state.ensureLineupLoaded(for: device)`. This recovers from silent `try?` failures in `fetchAllLineups` at startup — if `lineups[deviceID]` is nil or empty, it re-fetches on demand so that `CableGuideView` has valid lineup data, `selectedChannel` resolves correctly, and the Record/VLC buttons are enabled.

Three paths follow:
1. **Cache hit**: `guideStore.isFresh(deviceId:)` → read from `guideStore.channels(deviceId:)` immediately (sub-millisecond)
2. **Startup already loading**: `guideStore.isLoading(deviceId:)` → poll with 200ms sleep until loading finishes, then read channels
3. **Fresh load**: call `guideStore.load(for:hours:)`, then read channels

After any path, `state.guideByDevice` is updated to reflect the latest cache state.

---

## `applyGuideEntry()`

Copies selected `GuideEntry` and `LineupEntry` fields onto the `show` state variable:

```swift
show.show_title    = entry.Title
show.show_channel  = channel.GuideNumber
show.show_length   = entry.durationMinutes
show.show_next     = entry.startDate
show.show_end      = entry.endDate
show.show_seriesid   = entry.SeriesID ?? ""
show.show_logo_url   = entry.ImageURL ?? ""
show.show_genre      = entry.firstGenre ?? ""
show.show_bonus_time = entry.firstGenre?.lowercased().contains("sports") == true  // auto-enables Bonus Time for sports
show.hdhr_record     = device.DeviceID
show.show_url        = channel.URL ?? ""
```

Local time extraction (all times are **local, not UTC**):
```swift
let comps = Calendar.current.dateComponents([.hour, .minute, .weekday], from: entry.startDate)
show.show_time = Double(comps.hour ?? 20) + Double(comps.minute ?? 0) / 60.0
```

Air day is pre-populated from the guide's local weekday. Series type always resets to `.single` — the user must manually pick a series type after selecting a guide entry.

---

## `save()`

Applies the selected series type flags and folder to the `show` struct, then calls `state.addShow(show)`:

```swift
show.show_is_series        = seriesType != .single
show.show_use_seriesid     = seriesType == .seriesChannel || seriesType == .seriesAll
show.show_use_seriesid_all = seriesType == .seriesAll
show.show_air_date         = seriesType == .seriesChannel || seriesType == .seriesAll
    ? ["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"]
    : Array(airDays)
```

For SeriesID shows (`show_use_seriesid == true`), `resolveSeriesAir(show:device:isAll:channel:)` is called **before** `state.addShow(show)`: it checks for a currently-airing episode first (so recording starts immediately if the show is on now), then falls back to the next future episode. This matches the menu-flow behavior — without this call, the show would be scheduled for the tapped guide entry's time rather than the nearest airing.

`state.addShow` deduplicates by `show_id` (UUID), then saves the config to disk.

---

## Compact Toolbar (Guide Step)

```
[Tuner: ▾ (multi-tuner only)]  [Genre: ▾ (when genres available)]
─────────────────────────  Spacer  ─────────────────────────
[ProgressView]  [Now ⏱]  [Refresh ↺]  [↗]  [N ch]
```

- **Escape** — `.onExitCommand { dismiss() }` on root VStack dismisses from any step; there is no Cancel button
- **Tuner picker** — hidden when `state.devices.count <= 1`; changing selection invalidates cache for that device and bumps `refreshToken`
- **Genre picker** — shown only when `availableGenres` is non-empty. Dims non-matching show blocks to 0.2 opacity
- **`[N ch]`** — orange `.caption2` text showing `allChannels.count`; useful for debugging guide load issues
- **Now** — sets `snapToNow = true`, which `CableGuideView`'s `ScrollViewReader` uses to scroll to the current time
- **Refresh** — invalidates guide cache for the selected device and bumps `refreshToken` to re-fire `loadAllGuide()`

---

## Key Functions

| Function | Purpose |
|---|---|
| `loadAllGuide()` | Async: cache hit → startup wait → fresh fetch; updates `allChannels` |
| `applyGuideEntry()` | Copies guide entry + channel fields onto `show`; sets `show_genre` |
| `save()` | Applies series type flags + folder; calls `state.addShow(show)` |
| `chooseFolder()` | `NSOpenPanel` folder picker; writes to `UserDefaults["defaultSaveDirectory"]` |
| `entry.episodeInfoLabel` | `GuideEntry` extension (Models.swift); joins `EpisodeNumber` + `EpisodeTitle` with ` · ` |
| `guideTimeRange(_:)` | Free function in `GuideViewHelpers.swift`; returns `"8:00 PM – 9:00 PM"` string |
| `goForward()` / `goBack()` | Step navigation logic |

---

## What Still Needs Doing

- **No way to manually set a stream URL** — if a channel's URL can't be resolved from the lineup, the user can't override it in the wizard. The step 3 form could show the resolved URL and allow edits.

- **Time picker for DateTime shows** — air time is always taken from the guide entry's start time. If the user wants to schedule 5 minutes early, there's no control for that.

- **Single device step skip + slow discovery** — if discovery is still running when the wizard opens, it might auto-select a device that isn't the preferred one. A loading indicator at the device step ("Discovering tuners…") would be cleaner.

- **No edit integration** — there's no way to change a show's scheduled episode by browsing the guide in the Edit view. For SeriesID shows this doesn't matter, but for Single and DateTime shows it would be useful.
