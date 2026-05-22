# EditShowView.swift — Edit Existing Show

## Intent

`EditShowView` is a simple form window for modifying an existing scheduled show. It opens from the menu (via "Edit…" in any show submenu) and allows changing the title, channel, show type, air days, duration, transcode profile, and recording folder. It is the only place where an existing show's metadata can be changed after it was added.

The show to edit is identified by `state.editingShowId` (set by `MenuContent` before calling `open("edit-show")`).

Window size: **480×520**.

---

## Layout

```
ScrollView {
  VStack {
    Title (editable TextField)
    Channel (editable TextField, width 80)
    Type (segmented Picker: Single / DateTime / SeriesID(Channel) / SeriesID(All))
    Day / Days (toggle buttons — only for Single and DateTime)
    Length in minutes (TextField + .number format)
    Transcode (Picker: None / Heavy / Mobile / Internet 720)
    Folder (display last path component + Change… button)
    Failures (orange text + Reset button — only shown when show_fail_count > 0)
    SeriesID (read-only Text, "none" if empty)
    Stream URL (read-only Text, .caption, lineLimit 1)
  }
}
navBar: [Delete] ... [Cancel] [Save]
```

---

## Key Behaviors

### `loadShow()`

Called from `.onAppear`. Reads `state.editingShowId`, finds the matching show in `state.shows`, and seeds the view's `@State` vars:
- `show` — the full `Show` copy (edits happen on this local copy, not on `state` directly)
- `seriesType` — derived from `show.state`
- `airDays` — `Set(show.show_air_date)`
- `recordFolder` — `URL(fileURLWithPath: show.posixRecordDir)`, falling back to `state.defaultSaveDir`

`posixRecordDir` handles Mac alias paths (`"Vol:Dir:Sub:"` → `"/Volumes/Vol/Dir/Sub"`). If `show_temp_dir` is empty, falls back to `~/Movies`.

### Show Type Changes — `applySeriesType()`

Fires from `onChange(of: seriesType)`. Sets the three boolean flags immediately:

```swift
show?.show_is_series        = seriesType != .single
show?.show_use_seriesid     = seriesType == .seriesChannel || seriesType == .seriesAll
show?.show_use_seriesid_all = seriesType == .seriesAll
```

Switching to `seriesChannel` or `seriesAll` automatically selects all weekdays, since SeriesID records any episode on any day.

### Single Day Enforcement

For `.single` type, the day toggle buttons are mutually exclusive: selecting one deselects all others (`airDays = on ? [day] : []`). For `.dateTime`, any combination is allowed.

### Failure Reset

When `show.show_fail_count > 0`, a "Failures: N — reason" row appears in orange with a Reset button. Reset sets `show_fail_count = 0`, `show_fail_reason = ""`, and `show_active = true` on the local `show` copy (saved only when the user taps Save).

### Save — `save()`

Applies `airDays` and series type flags to the local `show`, applies `recordFolder` to both `show_dir` and `show_temp_dir`, then calls `state.updateShow(s)`:

```swift
func updateShow(_ show: Show) {
    guard let i = shows.firstIndex(where: { $0.show_id == show.show_id }) else { return }
    shows[i] = show; saveConfig()
}
```

Replaces the matching show in `state.shows` by ID, then writes the config to disk. The window dismisses after save.

### Delete

Calls `state.deleteShow(s)` (which also calls `recordingManager.stop(showId:)` to halt any in-progress recording) and dismisses. No confirmation dialog — the delete is immediate and irreversible.

### Folder Picker — `chooseFolder()`

`NSOpenPanel` with `canChooseFiles = false`, `canChooseDirectories = true`. On confirmation, sets `recordFolder` local state only (not saved until the user taps Save). Does NOT write to `UserDefaults` — that's only done by the Settings folder picker and the AddShowView wizard.

---

## Relationship to AppState

`EditShowView` edits a local copy of `Show` and calls `state.updateShow(_:)` only on Save. This means:
- Cancel always discards all edits (local copy is thrown away)
- No draft-save safety net (unlike `SettingsView` which has `WindowCloseInterceptor`)
- No undo — once Save is pressed, the old values are gone

---

## What Still Needs Doing

- **No confirmation on Delete** — a show can be deleted by accident. An `NSAlert` "Delete [Title]? This cannot be undone." would prevent unintentional data loss.

- **No guide integration** — if a user wants to fix a broken show URL, reschedule to a different channel, or see what the guide says about the next episode, they have to do it manually (edit channel, edit stream URL). A "Pick from guide" button on the Channel row would be a significant quality-of-life improvement.

- **Stream URL is read-only** — the stream URL is shown but can't be edited. If a device's IP changes and the URL is stale, the only fix is to delete and re-add the show. The URL field should be editable.

- **Next air time is not editable** — `show_next` is only displayed indirectly (via the menu's "starts in…" label). For DateTime shows where the schedule calculation got out of sync, there's no way to manually correct `show_next` without editing the JSON directly.

- **`show_genre` is not exposed** — the genre field (used for Bonus Time detection) is set automatically when a show is added from the guide, but there's no way to correct it in Edit if it was wrong or missing. A read-only "Genre: Sports" row with a "(change)" link would help, and let users manually apply Bonus Time to shows added before that feature existed.

- **SeriesID is read-only** — the SeriesID is shown but can't be changed. If the SiliconDust guide changes a series' ID (which happens occasionally), the only fix is delete + re-add.

- **No "Schedule Now" button** — for debugging, it would be useful to immediately trigger a scheduling pass for a show (force it to find its next episode in the guide) without waiting for the idle loop.

- **No unsaved-changes warning on close** — unlike `SettingsView`, `EditShowView` has no `WindowCloseInterceptor`. Closing the window (not Cancel) discards edits silently.

- **No undo** — once Save is pressed, the old values are gone. A Revert button (or Cancel-to-original) is the standard macOS pattern and would make this view safer to use.
