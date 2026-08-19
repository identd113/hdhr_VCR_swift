# hdhrVCRplus Changelog

Every entry is tagged **Added** (something new), **Updated** (existing behavior changed, improved, or fixed), **Removed** (something taken away), or **Info** (a note — nothing to do, nothing visibly different).

## Unreleased

**Added**
- **A show now automatically pauses itself when its assigned tuner isn't detected**, instead of silently sitting there scheduled against a tuner that isn't there (which previously logged a warning on every 10-second tick, forever). The moment that same tuner is seen again — whether it was a real device that dropped offline or one that was never actually reachable — the show automatically un-pauses. This never touches a show you paused yourself, or one paused for repeated recording failures; only a show this mechanism paused gets automatically resumed by it.
- **Settings → Advanced gained "Export Config…" / "Import Config…" buttons.** Export copies your live config JSON to wherever you choose; Import validates a chosen file before replacing your config (backing up the old one first) — handy for copying your setup to another machine. Import takes effect after restarting the app.
- **The About tab's changelog now highlights the current version's own entry** in an accent-tinted box at the top, and caps the list to the current version plus the last 5 older ones instead of showing every release ever made.
- **Release builds are now universal** (Apple Silicon + Intel), not arm64-only — Intel Macs can run hdhrVCRplus starting with the next release.

**Removed**
- **Settings → Maintenance no longer offers "Install VLC"/"Install HDHomeRun CLI" via Homebrew.** VLC detection for the "Watch in VLC" toggle is unaffected — only the install-it-for-me buttons are gone. If you don't have VLC yet, install it yourself (e.g. `brew install --cask vlc`) the same way you would any other app.

**Updated**
- **Fixed a series show getting stuck re-skipping the same already-recorded rerun every ~10 seconds for its entire time slot** (up to an hour of repeated "Recording Skipped — already recorded" notifications and Discord cards for one episode). The scheduler was re-selecting that exact same on-air duplicate as the "next" airing every time it rescheduled after a skip; it now correctly moves on to the actual next distinct episode instead.
- **A show resuming from pause (manually, or automatically once its tuner is detected again) now properly re-arms its "Up Next"/"Recording Soon" heads-up notifications.** Previously, if a show stayed paused through both notification windows, it could resume having silently missed its pre-recording alert for that airing — the recording itself was never affected, just the notification.

## v2.0.4 — 2026-08-15

**Added**
- **Record directly from Watch Now and the streaming player, without opening the Add Show wizard.** Clicking Record now shows a pulldown of the four recording types (a single airing, weekly at this time, this series on this channel, or this series on any channel), each with a one-line description — pick one and it's scheduled immediately. The streaming ("Watch") player also gained a Record button for the first time, next to its channel picker.
- **Currently-recording shows now sort above Favorites**, in both Watch Now and the web guide, in their own "Recording" section — a show already capturing to disk is a stronger claim on your attention than a merely-favorited channel.
- The streaming player now turns on closed captions automatically when you mute it, if the channel has them — there's no audio to convey what's being said otherwise. Turning the volume back up leaves them on; you can still turn them off yourself at any time.
- Watch Now can start playback from the very beginning of an in-progress recording, not just ~30 seconds behind live — anything currently recording shows both **Watch Now!** and **Watch from Beginning** buttons, matching the menu bar's recording list.
- Discord notifications now show a **🆕 NEW** tag next to the show title for a first-run episode airing today.

**Updated**
- **Double-clicking a show in the web guide now opens the right screen for its state**: Edit for anything already scheduled or currently recording, Record for anything not yet scheduled. Previously it always tried to open Record, so double-clicking an already-scheduled — or even actively-recording — show tried to re-add it.
- **Watch Now's tiles are now colored by genre even when a poster image is showing** — that color used to sit behind the poster art, fully hidden by it in the common case. Favorite status moved to its own stripe on the poster's edge instead.
- Watch Now's window opens noticeably faster with a lot of channels on screen at once.
- Watch Now's action buttons (Watch, VLC, Edit, Record) now stack one per row instead of crowding onto one line and truncating long labels, and every button now shows a tooltip on hover.
- Watch Now's tuner switcher (when you have more than one tuner) now sits next to the "Watch Now" title instead of the toolbar's far right.
- The streaming player's closed-caption picker is now hidden while watching an in-progress recording from disk — switching caption tracks there didn't actually change anything, so the control no longer pretends it does.
- Guide tiles in the web guide no longer let you click-and-drag to highlight their title text — that was an unintended side effect of the tile being clickable, not a real feature. The Summary panel's text (title, tags, channel/time) still copies normally.
- The Live View player's channel picker now lists your favorited channels first, under a "★ Favorites" heading, matching how Watch Now and the web guide already sort favorites to the top.
- Watch Now now catches up to the live edge much faster when watching a show that's currently recording — playback was pacing itself as if it were a real live TV signal, even though it's actually reading bytes already sitting on disk.
- Watching a show that's already recording no longer opens a second connection to your tuner — it now plays back the copy already being written to disk, the way it should have all along.
- Watch Now's list now uses the same colored status indicators as the web guide (recording, scheduled, already-recorded/will skip, tuner conflict, in use by another tuner) instead of a plain yellow triangle and separate "Recording" label.
- Watch Now's poster tiles now have a subtle border, so each show reads as its own card instead of blending into its neighbors and the background.
- The web guide's tuner popup now shows the real channel and show name when a tuner is being used by something outside this app (another device on your network, or someone watching via the HDHomeRun's own app) instead of a generic "Live stream" placeholder.
- The "X/Y tuners — FULL" info is now shown directly on each tuner's name in the web guide instead of tucked inside a dropdown that was easy to miss on mobile — click a tuner's name to switch to it, click again to see tuner details.
- Fixed: a rerun of a series airing on a different channel than the one actually recording could also show up marked "recording" in Watch Now and the web guide.
- Fixed: the new "in use by another tuner" indicator could incorrectly flag your own live Watch Now session as if it belonged to someone else.
- Fixed: a recording's pulsing status indicator could fail to start if a show began recording while its row was already on screen.
- Fixed: Watch Now could show a plain single "Watch" button instead of the "Watch Now!"/"Watch from Beginning" pair for a show that was actually recording, even though its ring correctly showed red/pulsing — a mismatch between which show the ring and the buttons were each looking up.
- Fixed: a "Recording Complete" Discord notification could be missing its episode number and summary, even when an earlier notification for the same recording (e.g. a tuner conflict warning) showed them correctly — the app was looking up "what's airing now" instead of remembering what actually recorded.
- Fixed: a show that failed to start and was waiting to retry could show up as "recording" in Watch Now and the web guide — including sorting into the Recording section and hiding a real tuner-conflict warning — even though nothing was actually being captured.
- Fixed: in rare cases, switching channels, seeking, or closing the player while watching an in-progress recording could freeze the entire app until it was force-quit. Player teardown no longer runs in a way that can block the rest of the app while it finishes.
- Fixed: a "record this series on this channel" show could show a blue "scheduled" indicator on a rerun airing on a *different* channel (e.g. a syndicated rebroadcast on another station) — it would never actually record from that channel, so the indicator was misleading. Series shows locked to one channel now only show the indicator on that channel.
- Fixed: the About panel's "hide changelog entries newer than this build" filter stopped working when this changelog was rewritten in end-user-facing format — it was looking for the old technical header style and silently matched nothing, so nothing ever got filtered. Updated it to read the new format instead.
- A tuner that goes offline no longer clutters the web guide with a permanently dimmed, empty box once nothing is scheduled on it — it's only shown while at least one show still depends on it, matching what the offline warning is actually for. A tuner with a show still assigned continues to show as before.

**Info**
- Reduced background work from this update's new tuner-status tracking and Watch Now's already-recorded lookup, so neither runs more than needed.
- If Add Show's Record button ever silently does nothing when clicked (no confirmation, no error), the app log now records why — previously this left no trace to diagnose after the fact.
- Added automated test coverage for the tuner-discovery and recording-launch code (`HDHRManager`/`RecordingManager`) and the new quick-record path (`AppState.quickRecord`) — no user-visible change.
- Fixed a gap in the visual-regression test harness where Watch Now's scrolling list rendered as a blank image regardless of content, silently proving nothing — no user-visible change; the harness now captures that view via a real off-screen window instead of the renderer that couldn't handle scrolling content.

## v2.0.3 — 2026-08-11

**Added**
- The web guide can now schedule a "record even if already on disk" override per show (previously only available in the native app).

**Updated**
- Fixed: a specially-crafted request to the web guide could crash the app, ending any in-progress recording.
- Fixed: a "record any channel" series show could occasionally schedule and record on two tuners at once, wasting a tuner and creating duplicate files.
- Improved: when a "record any channel" series show has two matching episodes airing at the same time on different channels, the app now prefers the one you don't already have instead of always favoring your favorited channel.
- Fixed: reopening the Settings window while it was already open could show a false "Unsaved Settings" warning even with nothing changed.
- Fixed: some guide-provided genres (e.g. "Sport") weren't recognized — this could silently disable Bonus Time for sports and show the wrong color in the guide. Shopping/infomercial programs are now also auto-detected instead of needing a manual add to the blocklist.
- Fixed: the background signal-quality check assumed every tuner streams on the same network port, which broke on tuners using a different one.
- Fixed: a low-risk bug in the web server's access check that, in principle, could let a non-local IPv6 address bypass the LAN-only restriction.

**Info**
- Several behind-the-scenes performance improvements to guide loading, icon caching, and log file handling — no visible change.

## v2.0.2 — 2026-08-09

**Updated**
- Fixed: on some machines, a stuck macOS "Local Network" permission prompt could require quitting and reopening the app to ever load your tuner. The app now shows a Dock icon on launch until it confirms it can reach your tuner (which helps the permission prompt appear), then hides the icon automatically once confirmed. A new **Settings → Advanced → Dock icon** option (Auto/Always/Never) lets you override this. The app also now retries every ~10 seconds instead of waiting up to an hour, so granting permission takes effect right away.
- Fixed: the menu bar's "tuners in use" count could go stale while the dropdown was open — it now updates live.

## v2.0.1 — 2026-08-09

**Updated**
- Fixed: some machines never fully loaded channel data because macOS's Local Network permission silently blocked the app — channels, favorites, and some Watch Now/recording links could appear empty with no visible error (recording itself was never affected). This kind of failure is now logged clearly. If you ever see missing channels at launch, check **System Settings → Privacy & Security → Local Network** and make sure hdhrVCRplus is allowed.

**Info**
- The Transcode picker now notes that not every tuner model supports transcoding — picking an unsupported profile will fail the recording; switch back to "None" if that happens.
- Project housekeeping (app icon, automated-test fixes, documentation corrections) with no effect on the app itself.

## v2.0.0 — 2026-08-08

First notarized public release — Apple has verified the app; Gatekeeper should no longer show extra warnings when you open it.

**Added**
- A small, dismissible support window appears on launch and when scheduling a show, with an optional link to leave a voluntary tip. This is not a paywall — every feature works identically whether you see, dismiss, or ignore it. Sending a tip unlocks a registered status shown in Settings → About.
- The About panel's changelog now renders proper formatting (headings, bullet lists) instead of one wall of plain text.

**Removed**
- Removed the standalone "Cable Guide" pop-out window — the full guide is now embedded directly in the Add Show wizard, so the separate window was no longer needed.

**Updated**
- The app is now consistently called "hdhrVCRplus" everywhere (it previously showed up to three different names depending on the screen).
- Fixed: some Settings number fields (e.g. the web server port) could show their value doubled up on recent macOS.
- Fixed: narrow phones could overflow channel names into the favorite star or timeline in the web guide.
- Fixed: selecting a program in the web guide could throw a JavaScript error left over from the removed Cable Guide window.
- Fixed: the About panel's changelog didn't number ordered lists correctly, and its text was hard to read in dark mode.
- Fixed: the in-app changelog viewer (Settings → About) could render completely empty in a deployed build.

## v1.4.5 — 2026-08-01

**Added**
- The web guide now flags a show whose assigned tuner is no longer detected (amber banner in the edit window) instead of silently letting you try to manage a phantom tuner.
- Add/Edit Show gained a **"Record even if already on disk"** override to force one specific recording through even when "skip already-recorded episodes" would normally skip it — it clears itself automatically after that one recording.
- New app icon — redrawn as a VHS cassette; the menu bar icon now also doubles as a live status light (dim when idle, red while recording, amber when a show starts within 30 minutes).

**Updated**
- The web guide's recording-status markers switched from a corner triangle to a colored ring + icon badge (scheduled / recording / will-skip-duplicate / conflict), with clearer colors than the old stoplight scheme.
- Fixed: the native menu's tuner-conflict warning could flag every show in an over-booked time slot instead of just the one(s) that would actually lose a tuner; a loss to a favorited show now says so specifically.
- Fixed: a recurring show could occasionally record the wrong program entirely if the network schedule changed at the last minute and the guide hadn't caught up yet — the app now double-checks the guide immediately before recording starts.
- Fixed: a scheduled show's displayed time range could show as hours (even months) longer than its real length for some weekly shows.
- Fixed: a recurring show on a channel that airs many different series back-to-back (e.g. a rerun channel) could get a completely different program's episode number and summary attached to it — occasionally even filing the recording into the wrong folder.
- Fixed: a series show added through the native Add Show wizard could get permanently stuck displaying old guest names/episode info forever, even though new episodes kept recording correctly. (Existing affected shows aren't renamed automatically — edit one and clear the title if you're seeing this.)
- Fixed: adding or editing a show through the native app could silently lose its backup recording location if the primary drive went offline.
- Fixed: adding a show through the native app skipped the tuner-conflict warning and "Show Added" confirmation that adding one from the web guide already gave.
- Fixed: a channel logo could show the wrong channel's logo after a restart.
- Fixed: Edit Show's Save button had no validation — an emptied title or an invalid channel could be saved as a show that would never record correctly.
- Fixed: a recurring show with every day deselected could save and silently never fire.
- Fixed: a Discord "Recording Started" card could occasionally show a bare title with no episode info even though the correct guide data existed.
- Fixed: a fresh web guide page load could show a currently-recording show as merely "on air" instead of "recording" for up to an hour.
- Fixed: the web guide's "Other Upcoming Airings" list, and a couple of other schedule-lookup paths, could hide or mishandle a second tuner's copy of the same airing on multi-tuner setups.
- Several minor reliability and UI-consistency fixes: stale audio/caption track selection after an automatic channel switch, the in-app player occasionally sticking on "Connecting…", and spurious "Unsaved Changes" prompts in Edit Show.

**Info**
- Faster guide updates in the background — several always-on checks now only do real work when something has actually changed, instead of on every cycle.

## v1.4.0 — 2026-07-18

**Added**
- New **Settings → Post-Processing → Skip already-recorded episodes** toggle — a series won't record the same episode twice on a rerun or simulcast (requires Series subfolders). The web guide shows a green "already recorded" flag on episodes it will skip, with an optional Discord notification when a skip happens.
- Signal quality (bars + a "weak signal" warning) now shown when scheduling a recording, in both the native Add/Edit Show dialogs and the web guide's Record form.
- The Add Show wizard's guide window now remembers its size across restarts.

**Updated**
- Recordings now save with a `.ts` file extension (matching what the tuner actually sends) instead of `.m2ts`/`.mkv`. Existing recordings with the old extensions are unaffected and still work everywhere in the app.
- Fixed: a single corrupted show entry in your saved schedule could previously wipe out your *entire* schedule on the next launch — a bad entry is now skipped individually instead.
- Fixed several recording-reliability issues: a failed recording could enter a rapid retry loop (and spam Discord with duplicate messages) instead of waiting for the next scheduled airing; the background idle loop could crash under network stress; recording failure messages now explain what actually went wrong instead of a generic error.
- Fixed: shows added or edited from the native app windows could fail to appear in the web guide.
- Fixed: a tuner going online or offline wasn't reflected live in the web guide.
- Fixed: deleting or stopping a show by channel and title (rather than by its internal ID) could occasionally affect the wrong tuner on a multi-tuner setup.
- Fixed: a malformed or truncated guide response could be treated as a successful load instead of being rejected and retried.
- Fixed: the Guide Hours setting allowed values the guide service doesn't actually support past ~28 hours — capped to match.
- Several in-app player fixes: switching channels could keep the previous channel's audio/caption tracks, double-clicking Watch Now could re-mute an already-playing stream, and a channel with no stream URL could leave the player stuck on "Connecting…" instead of showing a clear error.
- Fixed: Edit Show could silently discard unsaved changes when redirected to a different show from the menu — it now asks first.
- Fixed: the Add Show wizard could get permanently stuck on "Stream URL not found" if opened before device discovery finished.
- Security: the web guide (which has no login, relying only on being on your own network) now validates and restricts several inputs it previously trusted at face value — recording save locations, Discord webhook URLs, and malformed network replies.

## v1.3.0 — 2026-07-03

**Added**
- **Web-based TV guide** — a full browser-accessible guide (phone, tablet, or any computer on your network) with per-tuner schedule dropdowns, a live tuner-occupancy popup, genre filtering, dark/light themes, and live updates as shows are scheduled or start/stop recording — no need to open the Mac app to check or manage your schedule.
- **Discord notifications** — post rich recording updates (started, complete, failed, paused, tuner conflict, and more) to a Discord channel via a webhook URL, with a Test button per notification type and optional live progress updates every 5 minutes while recording.
- **Buffered live playback** in the in-app player — live channels now build a short buffer automatically to smooth over brief signal drops, with a "Catch Up" button to jump back to the live edge on demand, and a clear error overlay (with Retry) if a stream fails outright instead of a silent black screen.
- **Network interface selection** (Settings → Advanced) — bind device discovery and recording to a specific network connection, including VPN tunnels, so you can record from a remote HDHomeRun over a VPN.
- **Automatic update checking** via Sparkle (Settings → About → Check for Updates).
- New **Settings → Web Server** panel to enable/disable the web guide and choose its port.

**Updated**
- Watching a show that's currently recording no longer uses a second tuner — Watch Now now plays it back from the copy already being recorded, starting about 30 seconds behind live, with a scrub bar to jump to any already-recorded point and a "catch up to live" control.
- The web guide's tuner popup, schedule dropdowns, and toolbar were substantially reorganized and sped up — near-instant page loads, images that load progressively, genre filtering that dims rather than hides shows, and live tuner counts that correctly account for in-app viewing too.
- Discord now edits a single message through a recording's full lifecycle (started → complete/failed) instead of posting a new message for every event.
- Your saved config now lives in the standard Application Support folder — re-signing the app during development no longer wipes your saved shows.
- Numerous reliability and performance fixes across recording start/stop, device discovery, and the guide/player — recordings are now noticeably more resilient to network hiccups and app restarts.

**Info**
- Several security hardenings to the web guide (input validation, script-injection protection, request size limits), since it has no login and relies on being on your own network.

## v1.0.0 — 2026-05-22

First versioned release — a full Swift/SwiftUI rewrite of the original AppleScript-based app, keeping the same config file format for compatibility.

**Added**
- Cable-style TV guide (in-app) with genre-color coding, a sticky channel column, synchronized scrolling, and a "Now" snap button.
- In-app playback via VLC ("Watch in VLC") when VLC is installed.
- Settings window with General, Recording, Guide, Notifications, Advanced, and About sections, with an unsaved-changes warning before closing.
- **Bonus Time** — automatically extends a recording past the guide's listed end time for sports.
- Fail-count threshold — a show automatically pauses after repeated recording failures instead of retrying forever.
- Launch at Login, verbose curl logging, and configurable "Up Next"/"Recording Soon" notifications.
- Recordings survive a force-quit or restart — the app reattaches to anything still recording on relaunch.
- Automatic tuner discovery, including devices that appear on the network after the app has already started.
- SeriesID-based recurring recording — follows a series across airings without needing an exact date/time.

**Updated**
- Numerous early-release polish fixes from the first few days: menu items showing episode/tuner info at a glance, a live changelog in the About tab, corrected default behaviors for the Record and Quit actions, and various guide/menu display and reliability fixes.
