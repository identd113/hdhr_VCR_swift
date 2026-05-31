# WatchNowView.swift — Watch Now Window

Window ID: `"watch-now"`. Opened from the **Watch Now** button in `MenuContent` via `open("watch-now")`.

## Visual Appearance

### Overall window
Default size **420×620**, resizable (`.windowResizability(.contentMinSize)`). Standard macOS window chrome. Title: `"Watch Now"`.

### Toolbar (top bar)
`HStack` with 14pt horizontal and 10pt vertical padding:
- `play.tv.fill` SF Symbol in `watchNowBlue` (`Color(red: 0.2, green: 0.6, blue: 1.0)`), `.title3`
- `"Watch Now"` in `.headline`
- **Spacer**
- **Segmented tuner picker** — only shown when `state.devices.count > 1`; selecting a segment changes `selectedDeviceId`
- **Refresh button** — `arrow.clockwise` plain button; sets `now = Date()` to force an immediate re-evaluation of on-air channels

A `Divider` separates toolbar from content.

### Content area
`ScrollView` with a `VStack(spacing: 0)` of channel cards. Channels with currently-airing shows for the selected device, ordered:
1. **Favorites** (amber `★ Favorites` section header + amber accent bars above and below)
2. **All others** (no separator label)

Favorites section header: 2pt amber top bar, `"★  Favorites"` caption.bold in `favAmber` (`Color(hue: 0.13, sat: 0.85, bri: 0.80)`) with 8% opacity amber tint background, 1pt amber bottom bar, then 2pt amber bottom-of-section bar.

**Empty state**: `tv.slash` SF Symbol (40pt, `.tertiary`) + `"Nothing on right now"` secondary text. If the guide is still loading, a small `ProgressView` appears below the text.

---

## `WatchNowRow` — Per-channel card

Each card is an `HStack(alignment: .top, spacing: 10)` with 14pt horizontal and 10pt vertical padding.

### Poster thumbnail (left, proportional)
Width = 34% of scroll-container width, capped at 220pt (`.containerRelativeFrame(.horizontal) { w, _ in min(w * 0.34, 220) }`); height derived by `.aspectRatio(96.0/68.0, contentMode: .fit)`. At default 420pt window ≈ 143×101pt (~50% larger than the former hardcoded 96×68pt). Scales with window resize.

`ZStack`:
- Background: genre color from `guideEntryColor(for:onAir:true)` at 55% opacity
- Poster image (`.scaledToFill`) if available from `ChannelIconCache`, or `tv` SF Symbol at 40% white
- Clip: `RoundedRectangle(cornerRadius: 6)`
- **Yellow managed flag**: `ManagedFlagView(size: 18)` at `.topTrailing`. SeriesID(Channel/All) shows: shown on any matching episode. DateTime/Single shows: shown only when `device.DeviceID`, `channel.GuideNumber`, and `entry.StartTime` all match the scheduled slot.

### Info column (right)
`VStack(alignment: .leading, spacing: 3)`:
- Channel logo (16×16) + `"ch 5.1  NBC HD"` caption.bold secondary + `"🔴 Recording"` red badge when `managedShow?.show_recording == true`
- Show title — `.subheadline.bold`, 1 line
- Episode subtitle — `entry.episodeInfoLabel` (`.caption` secondary, 1 line); format: `"S01E05 · Episode Title"`, or just the non-nil part if only one is present; omitted when both are absent
- Time range + remaining — `.caption2` tertiary, e.g. `"8:00 PM – 9:00 PM  ·  42m left"`
- **Action row** (`.controlSize(.small)`):
  - **Watch** (`.borderedProminent`, `watchNowBlue`) — `state.watchInApp(url:title:deviceId:)`; shown only when `VLCBridge.shared.isAvailable`
  - **VLC** (`.borderedProminent`, VLC orange) — `state.watchInVLC(url:deviceId:)`; shown only when `config.Watch_in_VLC`
  - **Edit** (`.bordered`) — opens `"edit-show"` window for managed shows
  - **Record** (`.borderedProminent`, red tint) — sets `state.pendingAddEntry` and opens `"add-show"` window for unmanaged shows

---

## Data Flow

`onAirChannels` — iterates `state.lineups[selectedDeviceId]`, calls `state.guideEntries(deviceId:channelNum:)` per channel to find a currently-airing entry (StartTime ≤ now < EndTime), deduplicates by GuideNumber, then sorts favorites first, then by `channelSortKey`. `guideEntries` reads from `GuideStore.channelEntryIndex` (pre-built at guide load time) — no network fetch happens inside this view.

`state.watchNowDeviceId` — set by `MenuContent.watchNowMenu` before calling `open("watch-now")`. `onAppear` seeds `selectedDeviceId` from this value; `onChange` syncs it if the menu sets a new value while the window is already open.

Auto-refresh: `Timer.publish(every: 30, on: .main, in: .common)` fires every 30 seconds to update `now`, which drives `onAirChannels` recomputation and `.task(id: entry.ImageURL)` poster re-checks.

Poster images: fetched via `ChannelIconCache.shared.image(for:)` (disk-backed actor cache). `prefetchPosters()` fires on appear and on device change via `.task(id: selectedDeviceId)` to warm the cache before the user scrolls.

---

## Intent

`WatchNowView` is a live "what's on" grid that shows only channels with a currently-airing show. It is browse-and-watch focused: the primary action is **Watch** (in-app VLC player) rather than recording. It complements the full cable guide (`FloatingGuideView`) by being compact and quick to open — no scrolling through empty grid slots.
