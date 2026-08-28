# ShowFormSection.swift — Shared Show Form Fields

## Intent

`ShowFormSection` is a reusable `Group` of `Form` rows shared between `AddShowView` step 3 (Details) and `EditShowView`. It contains the fields that are common to both: title, type, air days, transcode, Bonus Time, and folder. Extracting this into a shared component ensures both views stay in sync when new fields are added.

The web guide's Record modal (`#rec-modal` in `WebServer.swift`, see `docs/WebServer.md`'s "Record type modal" section) mirrors these fields minus Folder (the server keeps the config default directory) — keep them in sync when either changes. It also omits Duplicate Episodes: that toggle only exists in the web guide's *Edit* modal (`#edit-modal`, added since this modal was last revisited), since a brand-new Record can't yet know whether the episode it's about to schedule will land on disk as a duplicate the way an already-scheduled show being edited can.

---

## Fields

```
Title        — TextField bound to show.show_title
Signal       — SignalBarsView for the selected channel + a "weak signal" warning banner when the
               channel's bucket is .poor. Only when state.config.Signal_quality_enabled and the
               channel has signal history (bucket != .noData). Reuses signalBucket(guideName:) via
               state.lineups[show.hdhr_record] → GuideName. Appears in both Add and Edit.
Type         — Segmented Picker over 3 collapsed top-level choices: Single | DateTime | SeriesID
               (private TopType enum, computed from/written back to seriesType via the `topType`
               Binding — see "Type/Scope split" below). Tooltip: explains each mode.
Scope        — Only when seriesType.isSeries. A 2-segment Picker — Channel | All — bound to a
               derived Bool (seriesType == .seriesAll) that writes seriesType as .seriesChannel/
               .seriesAll. See "Type/Scope split" below.
Transcode    — Picker: None | Heavy | Mobile | Internet 720
               Tooltip: None keeps raw MPEG; others transcode for size/device; notes that not all
               tuner models support transcoding and to fall back to None if a recording fails
               immediately. Below the picker, an orange warning banner (added 2026-08-28, same
               style as the Signal and Duplicate Episodes banners) appears whenever
               show.show_transcode != "none" and the selected device's HDHRDevice.supportsTranscode
               is false — "This tuner doesn't support transcoding — the Transcode setting above
               will be ignored and recorded as None." Informational only: the actual enforcement
               happens unconditionally in AppState.startRecording regardless of whether this banner
               was ever seen — see CLAUDE.md's "Transcode capability gate" invariant. The device
               lookup (selectedDeviceSupportsTranscode) defaults to *true* (no warning) when
               show.hdhr_record doesn't resolve to a known device — the opposite of
               startRecording's own conservative default — since a device simply not yet picked in
               the Add wizard shouldn't read as "detected unsupported."
Bonus Time   — Toggle (only when state.config.Sports_padding_enabled); bound to show.show_bonus_time
Day/Days     — Weekday toggle buttons (only for .single and .dateTime)
               Tooltip: single-day vs. multi-day selection intent
New Only     — Only when seriesType != .single. A "Skip reruns" toggle bound to show.show_new_only —
               at record time, skips an airing the guide doesn't mark as new (isNewEpisode, keyed off
               OriginalAirdate) and advances to the next scheduled airing, same as a duplicate skip.
               Independent of the Duplicate Episodes toggle below: this catches any rerun the app has
               never recorded, not just an exact SxxExx already on disk. No live-typing preview banner
               (unlike Duplicate Episodes) — whether the current guide entry counts as new can only be
               checked at record time.
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

## Type/Scope split

As of 2026-08-23, the Type picker shows only 3 segments — `ShowState`'s 4 real cases (`.single`/`.dateTime`/`.seriesChannel`/`.seriesAll`) are still exactly what `seriesType`/`Show` carry (unchanged everywhere else: `ManagedGuideMatcher`, scheduling, Discord labels, docs), but `.seriesChannel`/`.seriesAll` collapse into one visible "SeriesID" segment. A private `TopType` enum (`.single`/`.dateTime`/`.seriesID`) and a computed `topType: Binding<TopType>` sit between the Picker and `seriesType`: the getter maps either series case to `.seriesID`; the setter maps `.single`/`.dateTime` straight through, and maps `.seriesID` to `.seriesChannel` *only* if `seriesType` wasn't already a series type (so re-tapping an already-selected SeriesID segment doesn't reset an existing Channel/All choice back to Channel).

Picking SeriesID reveals a second row, **Scope**, directly below Type — a 2-segment Picker (Channel | All) bound to a derived `Binding<Bool>` (`seriesType == .seriesAll`) that writes `.seriesChannel`/`.seriesAll` back to `seriesType` on toggle.

Because the Scope Picker's own selection is a derived `Bool`, not `seriesType` itself, `.onChange(of: seriesType) { onSeriesTypeChange() }` is attached once at the outer `Group` level (not on the Type Picker) — that's the one place guaranteed to see every real `seriesType` mutation regardless of which of the two Pickers caused it.

`EditShowView`'s own Channel field (`LabeledContent("Channel")`, below `ShowFormSection` — not part of this shared component) is hidden when `seriesType == .seriesAll`: that scope floats across every channel the tuner receives, so a fixed channel number would misleadingly imply a lock that `resolveSeriesAir`/`scheduleNextAir` don't actually honor (they rewrite `show_channel` on their own as the matching episode moves). `AddShowView` has no equivalent field to hide — channel context there comes from the guide entry picked in Step 1, not an editable field. The web guide's Record modal (`docs/WebServer.md`) keeps its read-only `Ch X · Name · time` line visible regardless of scope (it names the specific airing being added from, not a lock); its Edit modal hides its editable Channel field the same way `EditShowView` does.

`AddShowView`'s "Other Upcoming Airings" panel also reacts to the Scope toggle (Edit views have no equivalent panel to react — see `docs/AddShowView.md`): `AppState.upcomingGuideEpisodes(seriesID:channelNum:)` is called with `channelNum: show.show_channel` for `.seriesChannel` (that scope only ever records from the one channel it's locked to, so the preview would otherwise list airings this show could never actually catch) and `nil` for `.seriesAll`. The web Record modal mirrors this client-side — `GET /api/airings/{seriesId}` always returns every channel, and `renderAirings()` filters to the current channel only when scope is `'seriesChannel'` — so toggling Channel/All there re-filters the already-cached list instead of re-fetching (`docs/WebServer.md`'s Scope row entry).

## Duplicate Episodes Toggle

`AppState.duplicateEpisodeTag(for:isSeries:baseDir:)` (`async`) looks up the show's next-airing episode tag from the guide and checks it against on-disk files via the same `recordedEpisodeTags`/regex logic `AppState.duplicateEpisodeTag(title:episodeTag:baseDir:)` uses at record time (`startRecording` in `AppState.swift`) and the web guide's slate `.g-st-skip` ring+badge uses (`WebServer.swift`) — all three read the exact same on-disk state so the dialog, the record-time skip, and the guide marker never disagree. It takes `isSeries`/`baseDir` as explicit parameters (`seriesType.isSeries` / `recordFolder?.path`) rather than reading `show.isSeries`/`show.posixRecordDir`, because in the Add wizard those `Show` fields aren't written until Save — the picker/folder state the user is actively editing is the only accurate source before then. It also excludes a show that's currently recording (its own in-progress file would otherwise flag itself as a duplicate). The result is cached in `@State private var duplicateTag` and only recomputed via `.task(id:)` when title/type/folder/channel/device/next/`Series_subfolder_enabled`/`Skip_recorded_episodes` actually change — not on every body re-render. The guide lookup and config checks inside `duplicateEpisodeTag(for:isSeries:baseDir:)` stay on `@MainActor` (in-memory, no I/O), but the actual directory scan (`recordedEpisodeTags`, `nonisolated`) is dispatched to a detached background task — the real wall-clock cost on a slow-to-wake external/NAS-backed drive lands there instead of blocking the whole app. Because `.task(id:)` cancels the previous task on every id change and `title` is part of the key, the task also debounces with a 350ms `Task.sleep` before scanning, bailing out via `Task.isCancelled` if superseded — so a burst of keystrokes triggers one scan after typing pauses, not one per character. Enabling `show_ignore_duplicate_once` bypasses the skip at record time and also suppresses the web guide's `.g-st-skip` marker for that show (shows the normal managed `.g-st-sched` marker instead), since the recording will actually happen. One-shot, not sticky, and only consumed if actually needed: `AppState.startRecording` checks for a duplicate regardless of the override, and only when it finds one *and* the override is on does it mark `duplicateOverrideUsedThisAttempt` for that show; `stopRecording(index:natural:)` clears `show_ignore_duplicate_once` back to `false` only when that marker is present and the recording lands with a non-empty file. So enabling the toggle ahead of an airing that turns out not to be a duplicate leaves it armed for the actual rerun, rather than silently spending itself on an unrelated success.

## Callbacks

`ShowFormSection` does not call `state` directly. Mutations that need side effects go through callbacks:
- `onSeriesTypeChange()` — called from `onChange(of: seriesType)` — the parent applies flag changes (e.g., `EditShowView.applySeriesType()`)
- `onChooseFolder()` — called when the folder button is tapped — the parent runs `NSOpenPanel`

This keeps the component free of direct `AppState` mutations and makes it testable.

---

## Adding New Fields

When adding a new field to `Show` that should appear in both Add and Edit flows, add it here. The field will automatically appear in both views. If the field is only relevant to one flow (e.g., a field that only makes sense on first-add), put it directly in the parent view instead.
