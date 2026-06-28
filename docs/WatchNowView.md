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

`ZStack` (`.accessibilityHidden(true)` — entirely decorative):
- Background: genre color from `guideEntryColor(for:onAir:true)` at 55% opacity
- Poster image (`.scaledToFill`) if available from `ChannelIconCache`, or `tv` SF Symbol at 40% white
- Clip: `RoundedRectangle(cornerRadius: 6)`
- **Yellow managed flag**: `ManagedFlagView(size: 18)` at `.topTrailing`, driven by the `isScheduled` computed property (see below).

**`managedShow` computed property** — looks up the scheduled show for this guide entry. Checks `state.managedShowBySeriesID` first (when `entry.SeriesID` is non-empty), then falls back to `state.managedShowByTitle[entry.Title]` — a `[String: [Show]]` dict (multiple shows can share a title, e.g. "News" on different channels). From the array, picks the first entry that is either a series show (title match is sufficient regardless of channel) or matches the specific `device.DeviceID` + `channel.GuideNumber`. This prevents a show scheduled on ch 5.1 from shadowing an unscheduled "News" on ch 9.1.

**`isScheduled` computed property** — returns `true` when: the show is series-based (`seriesChannel` / `seriesAll`), OR when it's a DateTime/Single show where `hdhr_record`, `show_channel`, and `show_next` all match the current entry's device/channel/StartTime. `show_next` is nil-guarded explicitly — a `?? -1` sentinel would spuriously match any guide entry with `StartTime == -1`. Used by both the managed-flag overlay and the title's accessibility label.

### Info column (right)
`VStack(alignment: .leading, spacing: 3)`:
- Channel logo (16×16, `.accessibilityHidden(true)`) + `"ch 5.1  NBC HD"` caption.bold secondary + `"🔴 Recording"` red badge (icon `.accessibilityHidden(true)`) when `managedShow?.show_recording == true`
- Show title row — `HStack(spacing: 4)`: title (`.subheadline.bold`, 1 line; `.accessibilityLabel` appends `", scheduled"` when `isScheduled`) + a red **LIVE** badge when `isLiveAiring(entry)` returns true (`.accessibilityLabel("Live")`). The badge uses `system(size: 8, weight: .heavy)` white text on a dark-red rounded rect.
- Episode subtitle — `entry.episodeInfoLabel` (`.caption` secondary, 1 line); format: `"S01E05 · Episode Title"`, or just the non-nil part if only one is present; omitted when both are absent
- Time range + remaining — `.caption2` tertiary, e.g. `"8:00 PM – 9:00 PM  ·  42m left"`
- **Action row** (`.controlSize(.small)`); each button has an `.accessibilityLabel` that includes the show title so VoiceOver can distinguish rows:
  - **Watch** (`.borderedProminent`, `watchNowBlue`) — `state.watchInApp(url:title:deviceId:)`; shown only when `VLCBridge.shared.isAvailable`; label `"Watch [title]"`
  - **VLC** (`.borderedProminent`, VLC orange) — `state.watchInVLC(url:deviceId:)`; shown only when `config.Watch_in_VLC && VLCBridge.shared.isAvailable`; button text `"VLC"`; `.accessibilityLabel("Watch [title] in VLC")`
  - **Edit** (`.bordered`) — opens `"edit-show"` window for managed shows; label `"Edit [title]"`
  - **Record** (`.borderedProminent`, red tint) — for unmanaged shows: calls `state.tunersFull(for: device.DeviceID)` first; if all tuners are occupied, shows an "All Tuners Busy" alert and does **not** open the Add Show window (the show is on air now and would immediately fail). If tuners are available, sets `state.pendingAddEntry` and opens `"add-show"`. Label: `"Record [title]"`

---

## Data Flow

`onAirChannels` — iterates `state.lineups[selectedDeviceId]`, calls `state.guideEntries(deviceId:channelNum:)` per channel to find a currently-airing entry (StartTime ≤ now < EndTime), deduplicates by GuideNumber, then sorts favorites first, then by `channelSortKey`. `guideEntries` reads from `GuideStore.channelEntryIndex` (pre-built at guide load time) — no network fetch happens inside this view.

`state.watchNowDeviceId` — set by `MenuContent.watchNowMenu` before calling `open("watch-now")`. `onAppear` seeds `selectedDeviceId` from this value; `onChange` syncs it if the menu sets a new value while the window is already open.

Auto-refresh: `Timer.publish(every: 30, on: .main, in: .common)` fires every 30 seconds to update `now`, which drives `onAirChannels` recomputation and `.task(id: entry.ImageURL)` poster re-checks.

Poster images: fetched via `ChannelIconCache.shared` (disk-backed actor with in-memory `mem` dict). `prefetchPosters()` fires on appear and on device change via `.task(id: selectedDeviceId)`. It runs in two passes: (1) a single actor hop via `allCachedImages(for:)` to populate `posterCache` with everything already in memory — images from prior opens appear instantly; (2) any remaining misses are fetched concurrently via `withTaskGroup` (disk reads and network downloads all in parallel). Per-row `.task(id: entry.ImageURL)` handles any rows that appear after the initial prefetch (e.g. after a 30-second timer tick).

---

## Intent

`WatchNowView` is a live "what's on" grid that shows only channels with a currently-airing show. It is browse-and-watch focused: the primary action is **Watch** (in-app VLC player) rather than recording. It complements the full cable guide (`FloatingGuideView`) by being compact and quick to open — no scrolling through empty grid slots.
