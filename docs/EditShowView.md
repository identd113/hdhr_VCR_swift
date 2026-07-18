# EditShowView.swift — Edit Existing Show

## Visual Appearance

### Overall window
Fixed **480×520**. Standard macOS window chrome. Title: `"Edit Show"`. While loading (`show == nil`): centered `ProgressView("Loading…")` fills the window.

### Form area (ScrollView, fills window above nav bar)
White/system background. `VStack` with 16pt spacing, 16pt padding on all sides:

- **`"Edit Show"`** title in `.title2`
- **`ShowFormSection`** — shared form fields (title field, signal row, type picker, days toggles, transcode picker, folder row) — see `ShowFormSection.md`. The signal row shows bars + a weak-signal warning for the show's channel when `Signal_quality_enabled`.
- **`LabeledContent("Channel")`** — `TextField` with placeholder `"e.g. 5.4"`, 80pt wide. Tooltip: guide channel number format and redirect use.
- **`LabeledContent("Length (min)")`** — numeric `TextField`, 60pt wide, placeholder `"60"`. Tooltip: set from guide end time; Bonus Time adds extra minutes past guide end.
- **Failures row** (only when `show_fail_count > 0`): `LabeledContent("Failures")` — orange text `"3 — Output file missing"` + blue `"Reset"` button
- **SeriesID row**: `LabeledContent("SeriesID")` — secondary-color text, `"none"` if empty. Tooltip: HDHomeRun series identifier used for smart cross-channel matching.
- **Stream URL row**: `LabeledContent("Stream URL")` — secondary-color caption, 1-line truncated; `"not set"` if empty. Tooltip: tuner stream URL, set automatically from the guide.

**Bonus Time badge**: when `show_bonus_time == true` AND `Sports_padding_enabled`, an orange 150pt `StarburstBadge` floats at the **top-right** corner of the form via `.overlay(alignment: .topTrailing)`, 16pt from the edges. It animates in on appear and out with a shrink-to-zero + fade on dismiss.

### Nav bar (bottom, ~52pt tall)
`HStack` with 16pt padding. `Divider` above.
- **Left**: `"Delete"` button in destructive red — triggers `confirmAndDeleteShow` (async poster fetch + NSAlert)
- **Right**: `"Save"` button in `.borderedProminent` (accent color / blue)

Both buttons are always visible and enabled (Delete enabled any time a show is loaded; Save enabled always). Escape triggers a dirty-check alert with Save / Discard / Cancel options.

## Intent

`EditShowView` is a simple form window for modifying an existing scheduled show. It opens from the menu (via "Edit…" in any show submenu) and allows changing the title, channel, show type, air days, duration, transcode profile, and recording folder. It is the only place where an existing show's metadata can be changed after it was added.

The show to edit is identified by `state.editingShowId` (set by `MenuContent` before calling `open("edit-show")`).

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
navBar: [Delete] ... [Save]
Escape key: `.onExitCommand` on root Group — shows dirty-check `NSAlert` (Save / Discard / Cancel) when unsaved changes exist; dismisses immediately if clean
```

---

## Key Behaviors

### `loadShow()`

Called from `.onAppear` and, conditionally, from `.onChange(of: state.editingShowId)`. The Edit window is a single-instance `Window` (not `WindowGroup`), so the view persists between opens — when it's re-focused for a different show, `onAppear` does not fire again, and the `onChange` handler is what would reload it. That handler no longer calls `loadShow()` unconditionally: if the currently-loaded show has unsaved edits (`isDirty`, comparing `show` against the `originalShow` snapshot), it shows the same Save/Discard/Cancel `NSAlert` `onExitCommand` uses before proceeding — Save calls `saveWithoutDismiss()` then `loadShow()`, Discard calls `loadShow()` directly, and Cancel reverts `state.editingShowId` back to the show currently loaded (via the `onChange` closure's captured `oldValue`) without ever calling `loadShow()`, so the in-progress edits are never silently discarded. `loadShow()` reads `state.editingShowId`, finds the matching show in `state.shows`, and seeds the view's `@State` vars:
- `show` — the full `Show` copy (edits happen on this local copy, not on `state` directly)
- `seriesType` — derived from `show.state`
- `airDays` — `Set(show.show_air_date)`
- `recordFolder` — `URL(fileURLWithPath: show.posixRecordDir)`, falling back to `state.defaultSaveDir`

`posixRecordDir` uses `show_dir` as the primary path. If `show_dir`'s parent directory doesn't exist (i.e. the volume is unmounted), it falls back to `show_temp_dir` (or `~/Movies/hdhr_videos` if that's also empty). This means recordings automatically redirect to a local fallback when a NAS or external drive goes offline.

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

Applies `airDays` and series type flags to the local `show`, applies `recordFolder` to both `show_dir` and `show_temp_dir`, then calls `state.updateShow(s)`. `updateShow` replaces the matching show by ID, saves config, and for any active, non-paused, non-recording, non-single show fires `scheduleNextAir` immediately in an async Task — so type or channel changes take effect without waiting for the next idle loop tick. The window dismisses after save.

### Delete

Calls `state.confirmAndDeleteShow(s) { dismiss() }` — same flow as menu-based deletion: fetches the show's poster image async, shows an `NSAlert` with the image and "Delete / Cancel" buttons, then stops any in-progress recording and removes the show on confirm. The window dismisses after deletion via the completion closure.

### Folder Picker — `chooseFolder()`

`NSOpenPanel` with `canChooseFiles = false`, `canChooseDirectories = true`. On confirmation, sets `recordFolder` local state only (not saved until the user taps Save). Does NOT write to `UserDefaults` — that's only done by the Settings folder picker and the AddShowView wizard.

---

## Relationship to AppState

`EditShowView` edits a local copy of `Show` and calls `state.updateShow(_:)` only on Save. This means:
- Cancel always discards all edits (local copy is thrown away)
- `WindowCloseInterceptor` intercepts window close when `isDirty` and shows a Save / Discard / Cancel alert — same pattern as `SettingsView`
- No undo — once Save is pressed, the old values are gone

---

## What Still Needs Doing

- **No guide integration** — if a user wants to fix a broken show URL, reschedule to a different channel, or see what the guide says about the next episode, they have to do it manually (edit channel, edit stream URL). A "Pick from guide" button on the Channel row would be a significant quality-of-life improvement.

- **Stream URL is read-only** — the stream URL is shown but can't be edited. If a device's IP changes and the URL is stale, the only fix is to delete and re-add the show. The URL field should be editable.

- **Next air time is not editable** — `show_next` is only displayed indirectly (via the menu's "starts in…" label). For DateTime shows where the schedule calculation got out of sync, there's no way to manually correct `show_next` without editing the JSON directly.

- **`show_genre` is not exposed** — the genre field (used for Bonus Time detection) is set automatically when a show is added from the guide, but there's no way to correct it in Edit if it was wrong or missing. A read-only "Genre: Sports" row with a "(change)" link would help, and let users manually apply Bonus Time to shows added before that feature existed.

- **SeriesID is read-only** — the SeriesID is shown but can't be changed. If the SiliconDust guide changes a series' ID (which happens occasionally), the only fix is delete + re-add.

- **No "Schedule Now" button** — for debugging, it would be useful to immediately trigger a scheduling pass for a show (force it to find its next episode in the guide) without waiting for the idle loop.

- **No undo** (see "Relationship to AppState" above) — a Revert button (or Cancel-to-original) is the standard macOS pattern and would make this view safer to use.
