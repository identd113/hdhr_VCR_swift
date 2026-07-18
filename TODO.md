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

### Native/web title divergence for series shows

The native Add Show wizard saves series shows under the raw (possibly episode-suffixed) guide title; the web Record modal's `addShowFromGuide` call strips the suffix server-side unless the user supplies an explicit title override. Documented as intentional pre-existing divergence in `docs/WebServer.md`, not changed.

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

