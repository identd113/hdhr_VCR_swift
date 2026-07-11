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

## Recording

### DeviceAuth via UDP tag 0x2B

`HDHRManager.udpDiscoverSync()` reads only tag `0x02` (DeviceID) from the UDP discovery reply. The EXTEND device also includes DeviceAuth in tag `0x2B`. Parsing it would populate `HDHRDevice.DeviceAuth` from UDP so the guide API works when the device's HTTP server is sleeping or unreachable.

Confirmed DeviceAuth from live UDP packet on device `105404BE`; guide URL with that token returns 106 channels.

**Key file**: `HDHRManager.swift` → `udpDiscoverSync()`.

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

## Web Guide

### Edit modal (`#edit-modal`) doesn't have the Record modal's Details-step parity

The Record modal (`#rec-modal`) was brought to parity with the native `ShowFormSection` (editable title, Day row for both `single`/`dateTime`, config-driven transcode default, gated Bonus Time). The Edit modal wasn't touched: its day row still only shows for `dateTime`, and its Bonus Time row isn't gated on `Sports_padding_enabled`. Same treatment, separate change.

**Key file**: `WebServer.swift` → `openEditShow()`, `updateDaysVisibility()`, `#em-days-row`/`#em-bonus-row`.

---

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

### `WhiteOutlineButtonStyle` is dead code

Defined in `ShowFormSection.swift`, zero call sites (`git log -S "WhiteOutlineButtonStyle"` shows its last usages were removed in `89610a2`). Delete it, or restore a caller if it was meant to still be used somewhere.

**Key file**: `Views/ShowFormSection.swift`.

---

### `AddShowView`'s device-selection step (`.device`) is unreachable

`step` defaults to `.guide` and is never programmatically set to `.device` anywhere in the file — `deviceStep`, its `canAdvance`/`goForward` branches, and the whole Step-1 UI have no live entry point (device is chosen inside the web guide instead). Either delete the dead path or wire up a real entry point if it's still wanted.

**Key file**: `Views/AddShowView.swift`.
