# hdhrVCRplus — Known Improvements / TODO

All original feature requests have been implemented. Items below are quality-of-life enhancements surfaced during development. They are not bugs or missing features.

---

## Menu Bar (MenuContent.swift)

- **Elapsed/remaining timer doesn't tick** — times are computed when the menu opens and stay static. NSMenu doesn't auto-refresh; a real-time display would require a window-based popover for recording detail.

- **No "Record Now" shortcut** — there is no direct path to immediately record a show that's currently on air without going through the full Add Show cascade.

---

## Add Show Wizard (AddShowView.swift)

- **No "Back" from Details to Guide** — if the user wants to pick a different guide entry after reaching step 3, they must Cancel and restart from step 1. A "Back" button should return to the guide with the previous selection intact.

- **Genre filter resets silently on tuner change** — when the tuner picker changes, `genreFilter` resets to `nil` because `availableGenres` repopulates. The user gets no indication this happened.

- **No time offset picker for DateTime shows** — air time is locked to the guide entry's start time. Users who want to record 5 minutes early have no control for that in the wizard.

---

## Edit Show (EditShowView.swift)

- **Stream URL is read-only** — displayed but not editable. If a device's IP changes, the only fix is delete + re-add the show.

- **`show_next` (next air time) is not editable** — can't correct a drifted schedule without editing the config JSON directly.

- **`show_genre` not exposed** — the genre field (used for Bonus Time detection) is set when a show is added from the guide, but can't be corrected in Edit. Shows added before the Bonus Time feature can't get it retroactively without a re-add.

- **SeriesID is read-only** — can't update if SiliconDust changes a series' ID (which happens occasionally). Only fix today is delete + re-add.

---

## Settings (SettingsView.swift)

- **No per-show overrides** — transcode profile, Bonus Time, and fail threshold all apply globally. A useful future feature: per-show overrides so one show always transcodes to Mobile, or one sports show gets 60 min of Bonus Time.

- **No export / import config** — power users managing multiple machines must copy the JSON manually. "Export config…" / "Import config…" buttons in Advanced would be user-friendly.

---

## Cable Guide (CableGuideView.swift)

- **No "jump to channel" shortcut** — the only way to find a specific channel is to scroll. A channel number search field or picker in the compact toolbar would help on large lineups (100+ channels).

---

## Recording Engine

- **No retry backoff** — failed shows go straight to Paused after N consecutive failures with no grace period or exponential backoff. A short wait (e.g. 5 min) before retrying the next eligible airing would handle transient network blips without deactivating the show.

---

## Performance Backlog

Items identified during audit but deferred (medium or low impact, no user-visible regression).

- **#1 — Idle vstatus fetches fire unconditionally** (`AppState.idleLoop` ~line 596): `fetchTunerStatus` runs every 10 s for each active recording regardless of whether anyone is watching the recording submenu. Each call fires O(tunerCount) HTTP requests. Fix: track NSMenu open/close state and only poll while the menu is visible, or throttle to 30–60 s.

- **#4 — Guide index sort is eager** (`GuideStore.buildIndex`): After every guide load, all series entries are sorted — O(series × entries log entries) on the main actor. Fix: sort lazily (only when `nextEpisode` is first queried for a given series ID); skip re-sort if the series was already sorted.

- **#5 — menuGuideEntries still splits on-air/upcoming at menu render time** (`MenuContent.channelMenu`): The pre-cached array (≤4 entries) is filtered twice per channel at open time. Fix: store `(onAir: [GuideEntry], upcoming: [GuideEntry])` tuples in the cache so the menu just reads pre-split slices with no filtering.

- **#6 — Device lookup in `updateShowURLsFromLineups` is O(shows × devices)** (`AppState`): `devices.first(where:)` is called once per show. Fix: build a `[DeviceID: HDHRDevice]` dictionary before the loop (O(devices)) and use O(1) lookups inside.

- **#7 — DateTime "next occurrences" loops through 60 calendar days per show** (`MenuContent.nextDateTimeOccurrences`): Fix: compute the next matching weekday with modulo arithmetic (jump directly rather than stepping day-by-day) to reduce 60 Calendar iterations to ≤7.

- **#8 — Startup JIT warm-up renders full MenuContent synchronously** (`AppState.startup` +2 s): The `NSHostingView + fittingSize` pass forces a full layout of the menu tree including all show submenus. Fix: render a minimal placeholder view (just the header + a few static items) instead of the live state-driven MenuContent.

- **#10 — `guideStore.entries()` rebuilds key string on every call** (`GuideStore`): `"\(deviceId):\(channelNum)"` string interpolation happens at each call site. Fix: pass a pre-built key, or add a direct `entries(key:)` overload that accepts a pre-computed string.
