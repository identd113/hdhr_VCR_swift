# hdhrVCRplus — Known Improvements / TODO

All original feature requests have been implemented. Items below are quality-of-life enhancements surfaced during development. They are not bugs or missing features.

---

## Menu Bar (MenuContent.swift)

- **Elapsed/remaining timer doesn't tick** — times are computed when the menu opens and stay static. NSMenu doesn't auto-refresh; a real-time display would require a window-based popover for recording detail.

- **No "Record Now" shortcut** — there is no direct path to immediately record a show that's currently on air without going through Watch Now or the Add Show wizard.

---

## Add Show Wizard (AddShowView.swift)

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

- **No per-show fail threshold or bonus duration** — transcode profile and Bonus Time on/off are already per-show (stored on `Show`, editable via EditShowView). The fail threshold (`Fail_count_setting`) and Bonus Time duration (`Sports_padding_minutes`) remain global-only. A useful future feature: per-show overrides for these two settings.

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

- **#10 — `guideStore.entries()` rebuilds key string on every call** (`GuideStore`): `"\(deviceId):\(channelNum)"` string interpolation happens at each call site. Fix: pass a pre-built key, or add a direct `entries(key:)` overload that accepts a pre-computed string.
