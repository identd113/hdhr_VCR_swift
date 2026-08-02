# ShowFormSection.swift — Shared Show Form Fields

## Intent

`ShowFormSection` is a reusable `Group` of `Form` rows shared between `AddShowView` step 3 (Details) and `EditShowView`. It contains the fields that are common to both: title, type, air days, transcode, Bonus Time, and folder. Extracting this into a shared component ensures both views stay in sync when new fields are added.

The web guide's Record modal (`#rec-modal` in `WebServer.swift`, see `docs/WebServer.md`'s "Record type modal" section) mirrors these fields minus Folder (the server keeps the config default directory) — keep them in sync when either changes.

---

## Fields

```
Title        — TextField bound to show.show_title
Signal       — SignalBarsView for the selected channel + a "weak signal" warning banner when the
               channel's bucket is .poor. Only when state.config.Signal_quality_enabled and the
               channel has signal history (bucket != .noData). Reuses signalBucket(guideName:) via
               state.lineups[show.hdhr_record] → GuideName. Appears in both Add and Edit.
Type         — Segmented Picker (ShowState.allCases): Single | DateTime | SeriesID(Channel) | SeriesID(All)
               Tooltip: explains each mode
Transcode    — Picker: None | Heavy | Mobile | Internet 720
               Tooltip: None keeps raw MPEG; others transcode for size/device
Bonus Time   — Toggle (only when state.config.Sports_padding_enabled); bound to show.show_bonus_time
Day/Days     — Weekday toggle buttons (only for .single and .dateTime)
               Tooltip: single-day vs. multi-day selection intent
Duplicate    — Only when state.config.Series_subfolder_enabled && state.config.Skip_recorded_episodes
Episodes       && seriesType.isSeries. A "Record even if already on disk" toggle bound to
               show.show_ignore_duplicate_once (per-show override of the global skip-already-recorded
               setting), plus an orange warning banner — shown only while the override is off and
               state.duplicateEpisodeTag(for: show) resolves a tag — reading "Episode SxxExx is
               already on disk — this recording will be skipped."
Folder       — Last path component of recordFolder + a button (label from folderButtonLabel param)
```

---

## Day Toggle Behavior

- For `.single`: selecting a day deselects all others (`airDays = on ? [day] : []`). Enforces exactly 0 or 1 day.
- For `.dateTime`: any combination is allowed (`airDays.insert` / `airDays.remove`).
- Day buttons are hidden for `.seriesChannel` and `.seriesAll` — SeriesID shows record on any day.

---

## Bonus Time Toggle

Only shown when `state.config.Sports_padding_enabled`. The label reads `"+N min past guide end"` where N is `state.config.Sports_padding_minutes`. The toggle sets `show.show_bonus_time`. The `withAnimation(.spring(...))` wrapper on the setter makes the `StarburstBadge` in the parent's ZStack animate in/out when the toggle changes.

---

## Duplicate Episodes Toggle

`AppState.duplicateEpisodeTag(for:isSeries:baseDir:)` looks up the show's next-airing episode tag from the guide and checks it against on-disk files via the same `recordedEpisodeTags`/regex logic `AppState.duplicateEpisodeTag(title:episodeTag:baseDir:)` uses at record time (`startRecording` in `AppState.swift`) and the web guide's slate `.g-st-skip` ring+badge uses (`WebServer.swift`) — all three read the exact same on-disk state so the dialog, the record-time skip, and the guide marker never disagree. It takes `isSeries`/`baseDir` as explicit parameters (`seriesType.isSeries` / `recordFolder?.path`) rather than reading `show.isSeries`/`show.posixRecordDir`, because in the Add wizard those `Show` fields aren't written until Save — the picker/folder state the user is actively editing is the only accurate source before then. It also excludes a show that's currently recording (its own in-progress file would otherwise flag itself as a duplicate). The result is cached in `@State private var duplicateTag` and only recomputed via `.task(id:)` when title/type/folder/channel/device/next/`Series_subfolder_enabled`/`Skip_recorded_episodes` actually change — not on every body re-render — since the underlying check does a real directory scan that runs synchronously on the main actor (no offloading), which can take real wall-clock time on a slow-to-wake external drive. Because `.task(id:)` cancels the previous task on every id change and `title` is part of the key, the task also debounces with a 350ms `Task.sleep` before scanning, bailing out via `Task.isCancelled` if superseded — so a burst of keystrokes triggers one scan after typing pauses, not one per character. Enabling `show_ignore_duplicate_once` bypasses the skip at record time and also suppresses the web guide's `.g-st-skip` marker for that show (shows the normal managed `.g-st-sched` marker instead), since the recording will actually happen. One-shot, not sticky, and only consumed if actually needed: `AppState.startRecording` checks for a duplicate regardless of the override, and only when it finds one *and* the override is on does it mark `duplicateOverrideUsedThisAttempt` for that show; `stopRecording(index:natural:)` clears `show_ignore_duplicate_once` back to `false` only when that marker is present and the recording lands with a non-empty file. So enabling the toggle ahead of an airing that turns out not to be a duplicate leaves it armed for the actual rerun, rather than silently spending itself on an unrelated success.

## Callbacks

`ShowFormSection` does not call `state` directly. Mutations that need side effects go through callbacks:
- `onSeriesTypeChange()` — called from `onChange(of: seriesType)` — the parent applies flag changes (e.g., `EditShowView.applySeriesType()`)
- `onChooseFolder()` — called when the folder button is tapped — the parent runs `NSOpenPanel`

This keeps the component free of direct `AppState` mutations and makes it testable.

---

## Adding New Fields

When adding a new field to `Show` that should appear in both Add and Edit flows, add it here. The field will automatically appear in both views. If the field is only relevant to one flow (e.g., a field that only makes sense on first-add), put it directly in the parent view instead.
