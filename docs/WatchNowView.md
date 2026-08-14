# WatchNowView.swift — Watch Now Window

Window ID: `"watch-now"`. Opened from the **Watch Now** button in `MenuContent` via `open("watch-now")`.

## Visual Appearance

### Overall window
Default size **480×620** (widened from 420 once a recording row's action row grew a second button — "Watch from Beginning" was clipping at 420), resizable (`.windowResizability(.contentMinSize)`). Standard macOS window chrome. Title: `"Watch Now"`.

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

Favorites section header: 2pt amber top bar, `"★  Favorites"` caption.bold in `favAmber` (an appearance-adaptive `NSColor` defined once in `GuideViewHelpers.swift`, shared with `MenuContent`/`VLCPlayerView` — `#e8a000` dark / `#a05800` light, matching the web Guide's `--fav` value) with 16% opacity amber tint background (matches the web Guide's `color-mix(in srgb, var(--fav) 16%, var(--s1))` row wash). There is no separate bottom border on the section header or bottom-of-section bar — the highlight is carried instead by every favorited row's own background (see below).

Every `WatchNowRow` for a favorited channel gets `favAmber.opacity(0.16)` as its own row background — not just rows inside the Favorites section — matching the web Guide's `.g-row[data-fav="1"]` wash applying throughout the grid, not only under the section divider.

**Empty state**: `tv.slash` SF Symbol (40pt, `.tertiary`) + `"Nothing on right now"` secondary text. If the guide is still loading, a small `ProgressView` appears below the text.

---

## `WatchNowRow` — Per-channel card

Each card is an `HStack(alignment: .top, spacing: 10)` with 14pt horizontal and 10pt vertical padding.

### Poster thumbnail (left, proportional)
Width = 34% of scroll-container width, capped at 220pt (`.containerRelativeFrame(.horizontal) { w, _ in min(w * 0.34, 220) }`); height derived by `.aspectRatio(96.0/68.0, contentMode: .fit)`. At default 480pt window ≈ 163×115pt. Scales with window resize.

`ZStack` (`.accessibilityHidden(true)` — entirely decorative):
- Background: genre color from `guideEntryColor(for:onAir:true)` at 55% opacity
- Poster image (`.scaledToFill`) if available from `ChannelIconCache`, or `tv` SF Symbol at 40% white
- Clip: `RoundedRectangle(cornerRadius: 6)`
- **Card border**: a quiet `RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15), lineWidth: 1)` overlay so each tile reads as a distinct card against its neighbors and the row background, even with no status ring. Applied *before* the status ring overlay below, so when a ring is present its thicker, saturated stroke paints on top and stays the dominant edge — this border only reads on its own when `ringState == .none`.
- **Status ring + badge** (`.guideRingBadge(ringState)`, `GuideViewHelpers.swift`) — the native
  equivalent of the web guide's `.g-st-*` status ring (`docs/WebServer.md`'s "Status ring +
  badge"), sharing its five states, precedence, and colors: `.recording` red `#ff5a5a`
  (`record.circle.fill`, pulsing), `.willSkip` slate `#8a92a3` (`forward.end.fill`), `.conflict`
  orange `#ff9500` (`exclamationmark.triangle.fill`), `.scheduled` blue `#3b93ff` (`clock.fill`),
  `.inUseOtherTuner` purple `#9b59b6` (`play.fill`). A `RoundedRectangle.stroke` ring plus a small
  `Circle()` corner badge (`.topTrailing`) holding the SF Symbol — SwiftUI's equivalent of the
  web's `box-shadow` ring + `::after` glyph. `.none` draws nothing. Replaces the former yellow
  `ManagedFlagView` triangle (scheduled-only) and a separate red "🔴 Recording" text badge in the
  info column below — one consistent visual language for all five states instead of two
  independent, overlapping indicators for a subset of them.

**`managedShow` — now a passed-in parameter, not a locally-computed property.** Used by the action row's Edit/Record button branch and the recording-aware Watch menu (see below). Originally `WatchNowRow` resolved this itself via `state.managedShowBySeriesID`/`state.managedShowByTitle` — a title-based lookup that isn't device-scoped for series shows, so it could resolve to a *different* device's show sharing the same SeriesID/title than the one this exact row's `entry` actually belongs to. In practice this meant a currently-recording row could show the plain "Watch" button (or worse, an Edit button pointed at the wrong show) instead of the "Watch from Beginning"/"Watch Now" menu, because `managedShow.show_recording` read from the wrong `Show` object — even though the ring correctly showed red/pulsing, since the ring already used the accurate lookup below. Fixed by having `WatchNowView.channelRow` pass down `ringInputs.guideMatcher.owner(for: entry)` — the exact same device+channel-scoped `ManagedGuideMatcher` lookup `ringState` is derived from — instead of `WatchNowRow` maintaining a second, less accurate one. The two can no longer disagree.

**`ringState: GuideRingState`** — passed into `WatchNowRow` from `WatchNowView.channelRow(_:device:ringInputs:)`, not computed inside the row itself. `WatchNowView` builds a `RingStateInputs` bundle once per render (`ringStateInputs(for:)` — a `ManagedGuideMatcher` over all active managed shows, the skip-already-recorded config/tag lookup, and the set of hardware-tuner-occupied channels on the selected device this app doesn't own) and resolves each row's state via `guideRingState(for:device:inputs:)`, which mirrors `WebServer.swift`'s `buildGuideGridHTML` per-block computation exactly (same `willSkip`/`isConflict` formulas) but scoped to the one currently-airing entry each row shows — no time-window/`isNow` check needed, since `onAirChannels` already filtered to "airing right now". The shared precedence itself (`resolveGuideRingState`) lives in `Models.swift`, not duplicated here, so the web and native surfaces can't silently drift out of order.

### Info column (right)
`VStack(alignment: .leading, spacing: 3)`:
- Channel logo (16×16, `.accessibilityHidden(true)`) + `"ch 5.1  NBC HD"` caption.bold secondary. (The former inline "🔴 Recording" text badge here was removed — recording status is now shown via the poster's ring+badge above instead.)
- Show title row — `HStack(spacing: 4)`: title (`.subheadline.bold`, 1 line; `.accessibilityLabel` appends `", \(ringState.tooltipSuffix)"` when `ringState != .none` — e.g. ", scheduled to record" or ", in use by another tuner, not managed by this app") + a green **NEW** badge when `isNewEpisode(entry)` returns true (`.accessibilityLabel("New episode")`). The badge uses `system(size: 8, weight: .heavy)` white text on a green (`Color(red: 0.18, green: 0.65, blue: 0.35)`) rounded rect. Detection: `OriginalAirdate` matches today's local date (or tonight for 00:00–05:00 start times).
- Episode subtitle — `entry.episodeInfoLabel` (`.caption` secondary, 1 line); format: `"S01E05 · Episode Title"`, or just the non-nil part if only one is present; omitted when both are absent
- Time range + remaining — `.caption2` tertiary, e.g. `"8:00 PM – 9:00 PM  ·  42m left"`
- **Action row** (`.controlSize(.small)`); each button has an `.accessibilityLabel` that includes the show title so VoiceOver can distinguish rows:
  - **Watch** (`.borderedProminent`, `watchNowBlue`) — shown only when `VLCBridge.shared.isAvailable`. For a show this app is **not** currently recording, a plain button calling `state.watchInApp(url:title:deviceId:)`, label `"Watch [title]"`. For a show it **is** currently recording (`managed?.show_recording == true`), **two separate stylized buttons** instead of one — "Watch Now!" and "Watch from Beginning" — matching the menu bar's own recording submenu (`MenuContent.recordingMenu`), which offers these as two distinct items rather than one nested behind a disclosure control; a pull-down `Menu` was tried first but didn't match that expectation. Opening the plain live-tuner stream here would open a second, redundant tuner connection for a channel already being recorded, so both buttons instead route through the relay: **"Watch from Beginning"** (`state.watchRecordingInApp(show, fromBeginning: true)`, icon `backward.end.fill` — starts at byte/second 0) and **"Watch Now!"** (`state.watchRecordingInApp(show)`, icon `play.tv.fill` — starts ~30s behind live, matching the menu bar's own default). Both route through the `/api/watch-recording` relay (see `docs/WebServer.md`'s "Recording playback relay"), which already handles a still-growing file correctly (polls rather than closing on catch-up) — this only changes the starting offset, not the streaming mechanism.
  - **VLC** (`.borderedProminent`, VLC orange) — `state.watchInVLC(url:deviceId:)`; shown only when `config.Watch_in_VLC` (no `isAvailable` check — this launches the *external* VLC.app via `NSWorkspace`, so it doesn't need the in-app libvlc dylib the `isAvailable` check above guards); button text `"VLC"`; `.accessibilityLabel("Watch [title] in VLC")`
  - **Edit** (`.bordered`) — opens `"edit-show"` window for managed shows; label `"Edit [title]"`
  - **Record** (`.borderedProminent`, red tint) — for unmanaged shows: calls `state.tunersFull(for: device.DeviceID)` first; if all tuners are occupied, shows an "All Tuners Busy" alert and does **not** open the Add Show window (the show is on air now and would immediately fail). If tuners are available, sets `state.pendingAddEntry` and opens `"add-show"`. Label: `"Record [title]"`

---

## Data Flow

`onAirChannels` — iterates `state.lineups[selectedDeviceId]`, calls `state.guideEntries(deviceId:channelNum:)` per channel to find a currently-airing entry (StartTime ≤ now < EndTime), deduplicates by GuideNumber, then sorts favorites first, then by `channelSortKey`. `guideEntries` reads from `GuideStore.channelEntryIndex` (pre-built at guide load time) — no network fetch happens inside this view.

`state.watchNowDeviceId` — set by `MenuContent.watchNowMenu` before calling `open("watch-now")`. `onAppear` seeds `selectedDeviceId` from this value; `onChange` syncs it if the menu sets a new value while the window is already open.

Auto-refresh: `boundaryRefreshLoop()` (a `.task` started on appear, not a `Timer`) sleeps until the next `:00`/`:30` wall-clock boundary — in ≤30s chunks when that's more than a minute away, so `now` stays within 30s of real time in the meantime — pre-fetches posters for the shows about to turn over (`prefetchPostersForDate`), then sleeps the remainder and updates `now` right at the boundary. This drives `onAirChannels` recomputation and `.task(id: entry.ImageURL)` poster re-checks precisely when the on-air list actually changes, rather than on a fixed 30s cadence.

Poster images: fetched via `ChannelIconCache.shared` (disk-backed actor with in-memory `mem` dict). `prefetchPosters()` fires on appear and on device change via `.task(id: selectedDeviceId)`. It runs in two passes: (1) a single actor hop via `allCachedImages(for:)` to populate `posterCache` with everything already in memory — images from prior opens appear instantly; (2) any remaining misses are fetched concurrently via `withTaskGroup` (disk reads and network downloads all in parallel). Per-row `.task(id: entry.ImageURL)` handles any rows that appear after the initial prefetch (e.g. a new channel turning on-air at the next `boundaryRefreshLoop` tick).

---

## Intent

`WatchNowView` is a live "what's on" grid that shows only channels with a currently-airing show. It is browse-and-watch focused: the primary action is **Watch** (in-app VLC player) rather than recording. It complements the full web guide (accessed via a browser, or embedded in the Add Show wizard's guide step) by being compact and quick to open — no scrolling through empty grid slots.
