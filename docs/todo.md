# hdhrVCRplus — Known Improvements / TODO

All original feature requests have been implemented. Items below are quality-of-life enhancements surfaced during development. They are not bugs or missing features.

---

## Menu Bar (MenuContent.swift)

- **Elapsed/remaining timer doesn't tick** — times are computed when the menu opens and stay static. NSMenu doesn't auto-refresh; a real-time display would require a window-based popover for recording detail.

- **"Stop Recording" has no confirmation** — clicking it immediately deactivates the show with no undo. An NSAlert ("Stop recording and deactivate [Title]?") with Keep/Stop options would prevent accidental permanent deactivation.

- **No Bonus Time callout in recording menu** — when a sports show is recording past the guide end in Bonus Time, the remaining-time counter reflects the padded end time but nothing labels this as "🏈 Bonus Time". The user has no visible explanation for why the recording extends past the guide.

- **Paused show submenu shows only fail reason** — no show type, channel, or last-recorded date. Adding this context would help the user decide whether to reactivate or delete.

- **Delete has no confirmation in scheduled and paused menus** — `.destructive` role adds a red tint but no NSAlert. Accidental deletion is permanent.

- **No "Record Now" shortcut** — there is no direct path to immediately record a show that's currently on air without going through the full Add Show cascade.

---

## Add Show Wizard (AddShowView.swift)

- **No "Back" from Details to Guide** — if the user wants to pick a different guide entry after reaching step 3, they must Cancel and restart from step 1. A "Back" button should return to the guide with the previous selection intact.

- **Genre filter resets silently on tuner change** — when the tuner picker changes, `genreFilter` resets to `nil` because `availableGenres` repopulates. The user gets no indication this happened.

- **No time offset picker for DateTime shows** — air time is locked to the guide entry's start time. Users who want to record 5 minutes early have no control for that in the wizard.

---

## Edit Show (EditShowView.swift)

- **Delete has no confirmation** — immediate and irreversible. An NSAlert "Delete [Title]? This cannot be undone." would prevent accidental data loss.

- **Stream URL is read-only** — displayed but not editable. If a device's IP changes, the only fix is delete + re-add the show.

- **`show_next` (next air time) is not editable** — can't correct a drifted schedule without editing the config JSON directly.

- **`show_genre` not exposed** — the genre field (used for Bonus Time detection) is set when a show is added from the guide, but can't be corrected in Edit. Shows added before the Bonus Time feature can't get it retroactively without a re-add.

- **SeriesID is read-only** — can't update if SiliconDust changes a series' ID (which happens occasionally). Only fix today is delete + re-add.

- **No unsaved-changes warning on close** — unlike SettingsView, EditShowView has no `WindowCloseInterceptor`. Closing the window discards edits silently.

---

## Settings (SettingsView.swift)

- **No per-show overrides** — transcode profile, Bonus Time, and fail threshold all apply globally. A useful future feature: per-show overrides so one show always transcodes to Mobile, or one sports show gets 60 min of Bonus Time.

- **No export / import config** — power users managing multiple machines must copy the JSON manually. "Export config…" / "Import config…" buttons in Advanced would be user-friendly.

- **Notification timing not validated** — "Recording alert" can be set higher than "Up Next" with no warning. The notification sequence breaks silently.

- **No "Clear guide cache" button** — if guide data becomes stale or corrupt, the only fix is restarting the app or waiting for the idle loop's auto-invalidation.

---

## Cable Guide (CableGuideView.swift)

- **No "jump to channel" shortcut** — the only way to find a specific channel is to scroll. A channel number search field or picker in the compact toolbar would help on large lineups (100+ channels).

---

## Recording Engine

- **No retry backoff** — failed shows go straight to Paused after N consecutive failures with no grace period or exponential backoff. A short wait (e.g. 5 min) before retrying the next eligible airing would handle transient network blips without deactivating the show.
