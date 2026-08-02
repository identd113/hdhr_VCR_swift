# TODO

Deferred features and improvements. Add items here when a task is punted. Remove when complete and note the resolving commit in `ISSUES.md` if the work was non-trivial.

---

## Player / Watch Now

### Elapsed/remaining timer in recording menu doesn't tick

Times shown in `recordingMenu` / `scheduledMenu` are computed when the menu opens and stay static for the duration it's open. NSMenu doesn't auto-refresh its view hierarchy. A real-time display would require redesigning recording detail as a window-based popover.

---

### No "Record Now" shortcut

No direct path to immediately record an in-progress show without going through Watch Now or the Add Show wizard. A quick-action from `MenuContent` or `WatchNowView` would skip the wizard for shows currently on air.

---

## Add Show / Edit Show

### No time offset picker for DateTime shows

Air time is locked to the guide entry's start time. Users who want to record a few minutes early have no control in the wizard.

---

### `show_genre` not exposed in Edit Show

The genre field (used for Bonus Time detection) is set from the guide on add but can't be corrected in Edit. Shows added before Bonus Time can't get a genre retroactively without delete + re-add.

---

### SeriesID is read-only in Edit Show

Can't update `show_seriesid` if SiliconDust changes a series' ID (which happens occasionally). Only fix today is delete + re-add.

---

## Recording

### Skip-already-recorded: extend to episode-title matching

The season/episode-number half of "skip already-recorded episodes" is **done** (`Skip_recorded_episodes`, filesystem `SxxExx` scan — see `CHANGELOG.md`). Still deferred: dedup for shows the guide numbers by episode **title** only (no `SxxExx`). The blocker is that the filename doesn't carry the episode title today. Plan: first extend the recording filename to embed a sanitized episode title (update `Show.outputPath` and the `Organize`/`recordedEpisodeTags` parse regex together), then have `recordedEpisodeTags` also collect title keys so the same scan-based, self-healing approach covers title-only shows — no persisted ledger, no stale-delete caveat.

---

## Web Guide

### Duplicate-episode override is a web-guide dead end

`willSkip` (`WebServer.swift`) already renders the green `.g-flag-skip` corner flag + "Already recorded · will skip" tooltip for a managed block the guide grid knows will be skipped as a duplicate — but the web UI has no way to act on it. `show_ignore_duplicate_once` (the per-show one-shot override, see `docs/ShowFormSection.md`) is only exposed in the native Add/Edit dialogs; `handleRecord`/`handleEdit` never read or set it, so any show scheduled or edited from the browser is stuck with it `false` and no in-browser escape hatch. A user watching the web guide sees "this won't record" with zero recourse short of switching to the native app. At minimum, clicking a `.g-flag-skip` block could open a lightweight confirm-to-override call. Also note `docs/ShowFormSection.md`'s claim that the web Record modal "mirrors these fields minus Folder" was already stale before this gap (Duplicate Episodes is a second omission beyond Folder) — worth a doc pass if the modal is revisited.

---

## Settings

### No per-show fail threshold or bonus duration

`Fail_count_setting` and `Sports_padding_minutes` are global-only. Per-show overrides would be useful for shows that regularly run long or need different failure tolerance.

---

### No export / import config

Power users managing multiple machines must copy the JSON manually. Export / Import buttons in the Advanced settings section would simplify this.

---

## Code Quality

### Homebrew installer spawning (`runBrew`) needs a sandbox story

`SettingsView.swift` → `runBrew()` spawns `/opt/homebrew/bin/brew` / `/usr/local/bin/brew` with `install`/`install --cask` to install VLC / hdhomerun_config from the Settings → Maintenance "Tools" section. This is a second class of `Process`-spawning beyond the curl/caffeinate sandbox debt already tracked elsewhere, and isn't covered by the App Store migration plan. There's no sandboxed way to invoke Homebrew, so the likely fix is dropping this row entirely in a sandboxed build.

**Key file**: `SettingsView.swift` → `runBrew()`.

---

### `recordedEpisodeTags` directory scan can block the whole app, not just the dialog

The Add/Edit dialog's duplicate-episode check debounces with a 350ms delay before scanning, but the scan itself still runs synchronous `FileManager` calls (`contentsOfDirectory` + `attributesOfItem` per file, two directory levels) on `@MainActor` — the debounce reduces frequency, not risk. A slow-to-wake external/NAS-backed recording drive stalls the whole app (not just the dialog) for that one scan. Fix: hop the scan off `@MainActor` (`Task.detached` + `nonisolated` FileManager work), publish the result back. Low real-world severity today (local disks return near-instantly), flagged in the 2026-08-01 pre-release review (`.claude/CODE_NOTES.md`).

**Key file**: `AppState.swift` → `recordedEpisodeTags`; caller `Views/ShowFormSection.swift` (`duplicateCheckKey` `.task(id:)`).

---

### Watch for UI hitches from `broadcastGuideChangeEvent`'s wider call-site fan-out

As of the 2026-08-01 pre-release review, `broadcastGuideChangeEvent` is called from 9+ show-lifecycle sites (add/update/pause/resume/delete/favorite-toggle/duplicate-override-clear), each triggering a full page rebuild (`buildGuideGridHTML` + `buildDevBarHTML` + gzip'd `prebuildPageHTML`) on the main actor — previously only the hourly refresh and recording start/stop paid this cost. With `Series_subfolder_enabled && Skip_recorded_episodes` both on, each rebuild also re-scans every managed series' recording folder. Deliberate tradeoff for guide freshness on new tab loads, and show mutations are human-paced so likely fine — but if a large recording library with many managed series shows UI hitches on Add/Edit/Delete/favorite-toggle, this rebuild fan-out is the first place to look.

**Key file**: `WebServer.swift` → `broadcastGuideChangeEvent`.

---

