# Release Notes

What's new in each version. For the fuller list of changes within a version, see
[CHANGELOG.md](Sources/hdhr_VCR/CHANGELOG.md); for the full download, see the
[GitHub Releases page](https://github.com/identd113/hdhr_VCR_swift/releases).

---

## v2.1.0 (2026-08-25)

### Added
- **Terminal Guide** — a full-screen terminal client for browsing the guide and scheduling
  recordings without a browser, bundled with the app. Enable and open it from Settings → Sharing.
- **Pull-to-refresh on the web guide** — drag down at the top of the grid to refresh in place
  instead of reloading the page.
- **"New Only" recording option** — skip reruns the guide doesn't flag as a new episode, for
  DateTime and SeriesID shows.
- **Signal quality now shown in the web guide's Edit modal**, matching what the Record modal
  already had.

### Updated
- **SeriesID(Channel)/SeriesID(All) are now one "SeriesID" option with a Channel/All scope
  toggle**, instead of two separate, easy-to-conflate top-level choices.
- **The web guide now asks you to confirm before deleting a show**, showing its poster and title.
- Settings' "Web Server" section is now called "Sharing" — same setting, new label.
- **Fixed: a SeriesID(Channel) show without SeriesID guide data could get stuck re-skipping the
  same already-recorded episode every ~10 seconds** for its whole broadcast window.
- **Fixed: editing a SeriesID(All) show could get permanently stuck at Save** if its channel had
  been cleared before switching to All.
- A few smaller fixes: "Update Guides Now"/"Check for Updates" show a spinner while running; the
  Local Network permission retry backs off over time instead of polling forever; the
  delete-confirmation dialog could show a blank poster or briefly disagree about recording status;
  a tuner that goes fully undetected while a show is still scheduled on it now shows up (as
  offline) in Terminal Guide instead of disappearing.

Full change list: [CHANGELOG.md](Sources/hdhr_VCR/CHANGELOG.md)

---

## v2.0.5 (2026-08-22)

### Added
- **Metadata sidecar (.nfo) files for recordings** — Settings → Recording → Post-Processing gains
  "Write metadata sidecar," writing a Kodi-style `.nfo` with episode title, season/episode, air
  date, synopsis, genre, and runtime next to each recording. Off by default.
- **Shows auto-pause when their tuner isn't detected, and auto-resume once it reappears** — instead
  of silently sitting scheduled against a tuner that isn't there. Never touches a show you paused
  yourself.
- **Release builds are now universal** (Apple Silicon + Intel) — Intel Macs can run hdhrVCRplus
  starting with this release.
- **In-app player: true fullscreen (Esc to exit), arrow-key seeking (15s back / 30s forward), and
  labeled toolbar buttons.**
- Settings → Advanced gained Export/Import Config buttons for copying your setup to another
  machine.

### Removed
- Settings → Maintenance no longer offers "Install VLC"/"Install HDHomeRun CLI" via Homebrew —
  VLC detection is unaffected, just the install-it-for-me buttons.

### Updated
- **Watch Now and the VLC player no longer offer Record for paid programming** (infomercials, home
  shopping), matching the web guide's existing behavior.
- **Fixed a series show getting stuck re-skipping the same already-recorded rerun every ~10
  seconds** for its entire time slot, spamming duplicate notifications.
- **Fixed: a recording interrupted partway through (crash, forced restart, reboot) could be
  permanently mistaken for a complete recording** with "Skip already-recorded episodes" on — the
  completeness check now compares against that series' own real recorded file sizes instead of a
  flat guess, so a truncated file is correctly retried next time it airs.
- **Fixed: watching an in-progress recording never showed its poster image or synopsis** in the
  player overlay.
- **Fixed: an already-recorded duplicate being skipped showed a false "Recording now" ring** on the
  web guide and Watch Now for its entire time slot.
- Hardened the LAN web server so a slow/stalled recording drive can no longer freeze guide loads or
  live updates for other devices on the network.
- The web guide's Summary panel now often has poster/synopsis ready the instant you click a tile,
  thanks to a hover-triggered prefetch.
- A "record all airings" series show without SeriesID data (e.g. some local news) no longer
  silently flips between simulcast channels on different guide reloads.
- Assorted smaller fixes: the menu bar's series "Upcoming" preview no longer shows an airing on a
  tuner the show would never actually record from; a resumed-from-pause show properly re-arms its
  heads-up notifications; a completed recording now drops out of the guide's "Recording" section
  immediately instead of waiting for the next unrelated refresh; a single-tuner setup's tuner popover
  now opens on the first click.

Full change list: [CHANGELOG.md](Sources/hdhr_VCR/CHANGELOG.md)

---

## v2.0.4 (2026-08-15)

### Added
- **Record directly from Watch Now and the streaming player** — no need to open the Add Show
  wizard. Click Record for a pulldown of the four recording types (single airing, weekly, series
  on this channel, series on any channel); the streaming player gained its own Record button.
- **Currently-recording shows now sort above Favorites**, in their own "Recording" section, in
  both Watch Now and the web guide.
- Watch Now can now start playback from the very beginning of an in-progress recording, not just
  ~30 seconds behind live.
- The streaming player turns on closed captions automatically when muted, if available, and
  leaves them on when unmuted.
- Discord notifications now show a 🆕 NEW tag for a first-run episode airing today.

### Updated
- Double-clicking a show in the web guide now opens Edit (if scheduled/recording) or Record (if
  not) — previously it always tried Record, even for already-scheduled shows.
- Watch Now's tiles, buttons, and tuner switcher got a round of layout polish (genre coloring
  under posters, one-button-per-row actions with tooltips, faster load with many channels, poster
  borders).
- Watch Now and the web guide now share the same colored status indicators (recording, scheduled,
  will-skip, conflict, in-use-elsewhere).
- Fixed several status-indicator mismatches: a rerun on a different channel showing as
  "recording," a stalled retry showing as "recording," a false "in use by another tuner" flag on
  your own session, and a scheduled-indicator appearing on a channel a series show would never
  actually record from.
- Fixed: switching channels, seeking, or closing the player mid-recording-playback could
  occasionally freeze the whole app.
- Fixed: a completed recording's Discord notification could be missing its episode number/summary
  even when an earlier notification for the same show had it.
- A tuner that goes offline with nothing scheduled on it no longer leaves a permanently dimmed,
  empty box in the web guide.

Full change list: [CHANGELOG.md](Sources/hdhr_VCR/CHANGELOG.md)

---

## v2.0.3 (2026-08-11)

### Fixed
- **A crafted web-guide request could crash the whole app, ending any in-progress recording** —
  an extreme time-window value sent to the guide's lazy-load endpoint could overflow an internal
  calculation and trap the process. Requests like that now fall back to the normal guide window
  instead of crashing.
- **A `SeriesID(All)` show could match and record on more than one HDHomeRun device at once**,
  wasting tuner capacity and producing duplicate files, and could silently migrate to a different
  device on reschedule. It's now scoped to the one device it was originally set up on, same as a
  channel-locked `SeriesID` show.
- **Reopening the Settings window while it was already open could show a false "Unsaved Settings"
  warning on close**, even with nothing actually edited. It now resyncs whenever the window
  regains focus, as long as nothing's actually been edited yet.
- **XMLTV guide data used different genre spellings than the app expected**, silently breaking
  Bonus Time auto-detection for Sport-tagged shows and leaving most XMLTV genres shown in plain
  gray instead of their proper color. Both are now recognized, and XMLTV-tagged shopping/
  infomercial entries are now detected and flagged automatically.
- **The passive signal-quality scan assumed every tuner streams on port 5004** — it now reads the
  actual stream URL from the device's own reported channel lineup, so it works correctly on a
  device using a non-default port.
- **A loopback-check bug could, in principle, let a non-loopback IPv6 address bypass the web
  server's LAN-only access check.** Low real-world risk, but the check now requires an exact
  match instead of merely starting with the loopback address.

### Updated
- On a multi-tuner device, if a `SeriesID(All)` show has two different episodes airing at the
  same moment on two channels, the app now prefers whichever one isn't already recorded, instead
  of always breaking the tie toward a favorited channel even when that channel's episode is a
  duplicate you already have.
- Guide/performance polish: faster icon-cache disk cleanup, the vertical (portrait) page variant
  is no longer built for installs that never use it, verbose curl logging now has its own
  correctly size-capped log file, and the web guide gained a per-show "record even if already on
  disk" override for duplicate episodes.

Full change list: [CHANGELOG.md](Sources/hdhr_VCR/CHANGELOG.md)

---

## v2.0.2 (2026-08-09)

### Fixed
- **A stuck Local Network permission prompt could require quitting and reopening the app** — the
  app now shows a Dock icon on launch until it confirms it can actually reach your tuner (giving
  macOS's permission prompt a normal app to attach to), then hides it automatically. New
  **Settings → Advanced → "Dock icon"** option (Auto/Always/Never) to override. The app also now
  retries reaching your tuner every ~10 seconds instead of up to an hour, so granting permission
  takes effect on its own — no relaunch needed.
- **The menu bar's tuner-in-use count could go stale while the dropdown was open** — it now
  updates live, so if something else on your network (another machine running this app, a TV,
  etc.) starts or stops using a tuner, you'll see it right away instead of only after closing and
  reopening the menu.

Full change list: [CHANGELOG.md](Sources/hdhr_VCR/CHANGELOG.md)

---

## v2.0.1 (2026-08-09)

### Fixed
- **Some machines never fully loaded channel data** — macOS's Local Network privacy permission
  could silently block the app's requests to the tuner. When that happened, the channel list,
  favorites, and some Watch Now/recording links could end up empty or stale with no visible
  error. Recording itself was never affected. This is now clearly logged instead of silent, so
  it's diagnosable if it happens again. If you ever see channels missing at launch, check
  System Settings → Privacy & Security → Local Network and make sure hdhrVCRplus is allowed.
- The Transcode picker now notes that not every tuner model supports transcoding — pick None if
  a recording fails immediately after choosing a different profile.

Full change list: [CHANGELOG.md](Sources/hdhr_VCR/CHANGELOG.md)

---

## v2.0.0 — First Notarized Release (2026-08-08)

**This is the first hdhrVCRplus release signed with a Developer ID certificate and notarized by
Apple** — no more "unidentified developer" warning, no right-click-Open or `xattr` bypass step.
macOS accepts it as a normal app on first launch, verified offline via a stapled ticket.

### Added
- **Donation support** — an optional, dismissible in-app reminder (shown on launch and when
  scheduling a show) with a link to leave a voluntary tip. Not a paywall — every feature works
  identically whether you ever see it, dismiss it, or ignore it entirely. Settings → About shows
  your registered status if you've tipped.
- **Vertical time-axis mode for the mobile web guide** — on a portrait phone, the guide grid
  transposes so channels become side-by-side columns and time reads top-to-bottom, like a
  calendar view, instead of the usual side-scrolling horizontal grid.

### Removed
- **The "Cable Guide" pop-out window** — redundant since the Add Show wizard's guide step already
  embeds the full-size web guide directly; had no remaining way to open it.

### Fixed
- The app referred to itself by three different names ("hdhrVCRplus", "hdhrVCR+", "hdhr_VCR")
  depending on which screen you were looking at — standardized to "hdhrVCRplus" everywhere.
- Some Settings number fields could show their value doubled up (e.g. the web server port reading
  "1980  1980") on recent macOS — a redundant placeholder rendering alongside the real value.
- Narrow phones could overflow channel number/name text in the web guide's channel column.
- The web guide's "snap to now" button appeared later than it should have, and the summary panel
  had a leftover error from an earlier feature's removal.
- The About panel's changelog now renders markdown headers and numbered/bulleted lists properly
  instead of one flattened paragraph, and reads correctly in dark mode.
- Log files (`hdhrVCRplus.log`, the Discord activity log) now self-rotate instead of growing
  without bound over a long-running session.
- A recording resumed after an app restart could leave behind a stray temp file and silently lose
  error-code reporting for the rest of that recording — fixed by properly reattaching its curl
  header-file tracking. The channel-logo disk cache also now has a 150 MB ceiling (oldest logos
  evicted first) instead of growing without bound.

Full change list: [CHANGELOG.md](Sources/hdhr_VCR/CHANGELOG.md)

### Installing

1. Download `hdhrVCRplus-v2.0.0.zip` from the
   [Releases page](https://github.com/identd113/hdhr_VCR_swift/releases) and unzip it.
2. Move `hdhrVCRplus.app` to `/Applications`.
3. Open it — no warning, no bypass step needed.
4. Requires macOS 15.0 (Sequoia) or later, and an HDHomeRun tuner on your local network. VLC is
   optional, for Watch Now playback.

---

*Releases before v2.0.0 were ad-hoc signed, not notarized — see that release's own notes on the
[Releases page](https://github.com/identd113/hdhr_VCR_swift/releases) for its Gatekeeper bypass
instructions.*
