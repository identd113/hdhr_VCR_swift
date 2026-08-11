# hdhrVCRplus Changelog

## 2026-08-11 (SeriesID(All) tuner scoping, guide-detail crash fix, XMLTV genre colors) — v2.0.3

- **Fix — a crafted web-guide request could crash the whole app, ending any in-progress
  recording.** A LAN request to the guide's lazy-load endpoint with an extreme, absurd time
  window could overflow an internal calculation and trap the process. Requests like that now
  fall back to the normal guide window instead of crashing. (Low-risk on a home network, but a
  real bug regardless of how it could be reached.)
- **Fix — a `SeriesID(All)` show (one set to follow a series across every channel on a tuner)
  could match and record on more than one HDHomeRun device at once**, wasting tuner capacity and
  producing duplicate files, and could silently migrate to a different device on reschedule.
  It's now scoped to the one device it was originally set up on, same as a channel-locked
  `SeriesID` show — the two now differ only in which channels they'll follow on that device, not
  which device.
- **Fix — reopening the Settings window while it was already open could show a false "Unsaved
  Settings" warning on close**, even with nothing actually edited. A background save (from the
  idle loop, tuner probing, etc.) between the first open and a later reopen could leave the
  window's draft copy stale; it now resyncs whenever the window regains focus, as long as
  nothing's actually been edited yet.
- **Fix — XMLTV guide data used different genre spellings than the app expected**, silently
  breaking Bonus Time auto-detection for Sport-tagged shows (XMLTV says "Sport", the app checked
  for "Sports") and leaving most XMLTV genres shown in plain gray instead of their proper color.
  Both are now recognized, and an XMLTV-tagged shopping/infomercial entry is now detected and
  flagged automatically instead of needing a manual add to the blocklist.
- **Fix — the passive signal-quality scan assumed every tuner streams on port 5004.** It now
  reads the actual stream URL from the device's own reported channel lineup, same as every other
  stream request in the app, so it works correctly on a device using a non-default port.
- **Fix — a loopback-check bug could (in principle) let a non-loopback IPv6 address bypass the
  web server's LAN-only access check.** Low real-world risk (those addresses aren't reachable
  from the public internet), but the check now requires an exact match instead of merely
  starting with the loopback address.
- Guide/performance polish: the web guide's icon-cache disk cleanup no longer runs a full
  directory scan after every single icon download (only once per batch); the vertical (portrait)
  page variant is no longer built and compressed on every guide update for installs that never
  use it; verbose curl logging (Settings → Advanced) now writes to its own correctly size-capped
  file instead of silently sharing the main log's cap; and the web guide gained a per-show
  "record even if already on disk" override for duplicate episodes, matching the native app.

## 2026-08-09 (Dock icon until network access confirmed, live tuner count while menu is open) — v2.0.2

- **Fix — a stuck Local Network permission prompt could require quitting and reopening the app.**
  On a machine where macOS's Local Network permission dialog gets stuck or delayed (a known,
  currently-unresolved macOS bug, not unique to this app — see v2.0.1's note), the app now shows a
  Dock icon on launch until it actually confirms it can reach your tuner, giving the system's
  permission prompt a normal foreground app to attach to. Once confirmed, the Dock icon hides
  itself automatically. A new **Settings → Advanced → "Dock icon"** option (Auto/Always/Never) lets
  you override this. The app also now retries reaching your tuner every ~10 seconds instead of
  waiting up to an hour, so granting permission — whenever that happens — takes effect
  automatically without needing to quit and relaunch.
- **Fix — the menu bar's tuner count could show stale info while the dropdown was open.** The
  "X/Y tuners in use" count reflects real usage from any device — this app's own recordings, or
  anything else on your network using the same tuner (another machine running this app, a TV,
  etc.). Previously, if that count changed while you had the menu open, it wouldn't update until
  you closed and reopened it. It now updates live, verified against a real device correctly
  showing "1/2 · app expects 0" while a TV was using a tuner this app didn't initiate — with a
  30-second cooldown so a rapidly changing count (e.g. someone channel-surfing) can't repeatedly
  interrupt the menu.

## 2026-08-09 (Local Network permission show-stopper, transcode note, repo polish) — v2.0.1

- **Fix — some machines never fully loaded channel data.** macOS's Local Network privacy
  permission could silently block the app's requests to the tuner (a system-level permission
  gate, not something the app controls) — when that happened, the channel list, favorites, and
  some Watch Now/recording links could end up empty or stale with no visible error anywhere.
  Recording itself was never affected. Failures like this now write a clear line to the app log
  instead of failing silently, so a repeat of this — or anything with the same shape — is
  immediately diagnosable instead of looking like unrelated guide/channel problems. If you ever
  see channels missing at launch, check System Settings → Privacy & Security → Local Network and
  make sure hdhrVCRplus is allowed.
- **Note — not every tuner model can transcode.** The Transcode picker (Add/Edit Show, and
  Settings → Recording's default) now mentions that picking a profile a specific tuner doesn't
  support will just fail the recording — switch back to None if that happens. No functional
  change; existing recordings and settings are unaffected either way.
- **CI** — the automated test run on every push/PR was failing since before v2.0.0 for a reason
  unrelated to any real bug (its UI-screenshot comparison suite has no baseline images to compare
  against outside a developer's own machine, by design) — that suite is now correctly skipped in
  CI so a green check actually means something again.
- Repo housekeeping: real app icon in place of a placeholder emoji on the project page, a CI
  status badge, a GitHub Sponsor link matching the existing in-app donation option, and doc
  corrections (a stale claim about what the web server does, a corrected note about how the
  favorites-sync failure path already worked).

## 2026-08-08 (donation support, About-tab registration status, naming consistency) — v2.0.0

First notarized public release — Developer ID signed, notarized, and stapled
(`spctl` confirms "accepted, source=Notarized Developer ID"); previous releases were ad-hoc signed.

- **Feature — added a way to support ongoing development.** A small, dismissible window (in the
  app's own colors, not a generic system alert) appears on launch and whenever a show is
  scheduled, with a link to leave a voluntary tip. This is not a paywall — every feature works
  identically whether you ever see, dismiss, or ignore it. Sending a tip and entering the code
  you're given in return permanently stops the reminder on that install; Settings → About then
  shows your registered status and the code back to you for reference.
- **Fix — the app referred to itself by three different names** ("hdhrVCRplus", "hdhrVCR+",
  "hdhr_VCR", plus "hdhr VCR" in accessibility labels and Discord messages) depending on which
  screen you were looking at. Standardized every user-visible occurrence — About tab, the new
  donation window, VoiceOver labels, Discord embed footers, the web guide's page title/header/
  network-discovery name — to "hdhrVCRplus".
- **Fix — some Settings number fields showed their text doubled up** (e.g. the web server port
  reading "1980  1980") — a placeholder that's redundant once a field always holds a real value
  could render simultaneously with that value on recent macOS. Removed the redundant placeholders
  from the affected fields (web server port, recording length in Edit Show).
- **Tests — window-navigation tests now poll for readiness instead of waiting a fixed guess**
  before checking a window opened/closed or a tab finished switching, converging immediately on a
  healthy machine instead of always waiting out the slowest-case delay, and waiting longer
  automatically on a loaded one instead of risking a false failure.
- **Tests — window-navigation tests now dismiss the donation nag before asserting on other windows.**
  The nag opens automatically on every fresh app launch (unless already unlocked); being a
  `.floating`-level window, it sat on top as "window 1" and broke every other test's assumption
  that the window it just opened was frontmost. Also added a dedicated test that opens, verifies,
  and closes the nag window itself via the Accessibility API when a fresh launch's one-per-run nag
  is actually present.
- **Tests — `rootReturnsHTML` still asserted the served guide page contained the retired
  "hdhrVCR+" name**, missed by the app-name-standardization pass above since the page now serves
  "hdhrVCRplus" like everywhere else — updated the assertion to match.

## 2026-08-08 (FloatingGuideView removal, web guide channel-column fix, window-navigation tests)

- **Removed — the "Cable Guide" pop-out window (`FloatingGuideView`)** — a standalone browse-only guide window, launched from a pop-out button in the Add Show wizard's guide step. It had no remaining trigger anywhere in the app once `AddShowView`'s guide step grew to embed the full-size web guide directly, making the separate window redundant. Deleted `Views/FloatingGuideView.swift`, `docs/FloatingGuideView.md`, the `Window("Cable Guide", id: "cable-guide")` declaration in `hdhr_VCRApp.swift`, its snapshot test, and all doc/comment cross-references (`AppState.swift`, `GuideViewHelpers.swift`, `GuideStore.swift`, `docs/README.md`, `docs/AppState.md`, `docs/WebServer.md`, `docs/WKWebView_guide_analysis.md`, `.claude/agents/docs-auditor.md`).
- **Fix — narrow phones could overflow channel number/name text into the favorite star or timeline** — the `max-width:600px` phone breakpoint's `--ch-w` (sticky channel-column width) was 86px, too tight once `.g-cn`/`.g-cname` text got long. Bumped to 100px, shrunk the two font sizes slightly, and added an `overflow:hidden;text-overflow:ellipsis` backstop so anything still too long clips with an ellipsis instead of overflowing. Vertical time-axis mode (which shows several channel columns side by side, not horizontal mode's one sticky column) needed its own separate bump to 108px under `guide-vertical.css`'s `max-width:600px` rule, since it's tighter than horizontal mode at the same breakpoint.
- **Tests — added an opt-in window-navigation smoke test** (`Tests/hdhr_VCRTests/WindowNavigationTests.swift`) that drives the app's real windows via the macOS Accessibility API (AppleScript/System Events, shelled out via `osascript`) to confirm every reachable window still opens, navigates, and closes cleanly. Has real on-screen side effects (pops actual windows open/closed), so unlike the rest of the suite it does nothing under a bare `swift test` — run with `RUN_WINDOW_NAV_TESTS=1 swift test --filter WindowNavigationTests`. Requires Accessibility permission for whatever's running `swift test` (System Settings → Privacy & Security → Accessibility); guards `appRunning()`/`accessibilityTrusted()` skip cleanly otherwise. Backed by new `accessibilityIdentifier`s on `SettingsView`'s tab list rows (`settings-tab-*`), Discard button (`settings-discard`), Save (`settings-save`), and Save & Close (`settings-save-close`) — none of which existed before, since nothing needed a stable non-visual handle for these controls until this suite did.

## 2026-08-08 (code audit cleanup)

- **Fix — the web guide's summary panel threw a JS error on every program selection** — a leftover reset line still referenced `#sum-watch-app`/`#sum-watch-vlc`, two buttons removed along with `FloatingGuideView` (the only thing that ever wired up their native message handler) but not fully swept from `guide.js`/`guide-shell.html`. All dead "watch" bridge code (the buttons, their handler functions, and the always-false visibility check) is now fully removed.
- **Fix — the About panel's changelog would silently drop numbering on a markdown ordered list**, rendering `1. `/`2. ` items as unlabeled bullets. `MarkdownView` now reads whether a list item's immediately-enclosing list is ordered and renders a real `N.` marker instead of `•` when it is.
- **Docs** — corrected several places left stale by the same session's own changes: the now-button `CHANGELOG` entry described the pre-flip (`-5px`) direction instead of the shipped (`+5px`) one; `docs/WebServer.md` still said the phone-breakpoint `--ch-w` was 86px (now 100px) and that `.okPrecompressed` only serves `GET /` (it's served `GET /vertical` too since vertical mode's own page cache was added).
- **Cleanup** — removed a dead `@Environment(\.openWindow)` in `AddShowView.swift` left over from the `FloatingGuideView` pop-out button that was already gone before tonight's session started.

- **Fix — the web guide's "snap to now" button waited until the red now-line had fully scrolled out of view before appearing** — its visibility check originally had zero tolerance (`nowPx < scrollLeft`), then an initial fix overcorrected to a `-5px` margin that delayed it even further past the boundary. It now triggers `5px` *before* the now-line fully leaves the visible area (`nowPx < scrollLeft + 5`, mirrored for vertical mode's `scrollTop`), so the button shows up while the line is still just barely on-screen instead of only after it's gone.

## 2026-08-07 (About panel changelog rendering)

- **Fix — the About panel's changelog text was nearly unreadable in dark mode** — `MarkdownView`'s `NSTextView` displayed the parsed markdown as-is, and AppKit draws any run with no explicit `.foregroundColor` as literal black regardless of appearance, rather than falling back to the text view's own `.textColor`. Now backfilled with `NSColor.labelColor` (AppKit's adaptive system text color) wherever a run doesn't already carry its own color, so plain body text tracks light/dark mode automatically; markdown-link colors are left untouched.
- **Feature — the About panel's changelog now renders real markdown structure** — headers, bulleted lists, and paragraph breaks were previously flattened into one run of continuous text with no separators or list markers (`NSAttributedString(AttributedString)` bridges inline styling like bold/italic/code automatically, but drops block-level structure on the floor). `MarkdownView` now walks each run's `PresentationIntent` to reproduce it: `## ` headers render bold and on their own line, `- ` list items get a hanging-indent bullet (nested lists indent further), consecutive list items get tight spacing while other block transitions get a blank line.

## 2026-08-07 (deploy script fixes)

- **Fix — the in-app changelog view rendered empty in every deployed build** — `CHANGELOG.md` was declared as an SPM `resources:` bundle asset, but `SettingsView` reads it via `Bundle.main.url(...)`, which looks in `Contents/Resources/`; neither `deploy.sh` nor `deploy_release.sh` ever copied it there. Both scripts now copy `CHANGELOG.md` into `Contents/Resources/` alongside the app's other bundled assets.
- **Fix — `deploy_release.sh` had no favicon generation step** — release builds silently reused whatever `Resources/favicon.ico` happened to already be checked into git from a prior `deploy.sh` run instead of regenerating it. `deploy_release.sh` now generates and copies `favicon.ico` the same way `deploy.sh` does, reusing the iconset it already builds for `AppIcon.icns`.

## 2026-08-01 (pre-release cleanup — 7 deferred findings resolved) — v1.4.5

Pre-release pass ahead of v1.4.5: three parallel reviews (docs accuracy, project-invariant compliance, code-quality/notarization fitness) against everything unreleased since v1.4.0, plus re-verifying and fixing every item from `ISSUES.md`'s one remaining open batch (see `ISSUES.md` for full detail on each).

- **Fix — a channel logo could show the wrong channel after a restart** — the on-disk icon cache keyed files by `URL.lastPathComponent` alone, so two logo URLs sharing a basename (or both falling back to a generic `"icon.png"` name) collided. Now keys by a SHA256 hash of the full URL.
- **Fix — Edit Show's Save button had no validation** — a cleared title or a channel number typed into the free-text field that doesn't exist on the assigned device could be saved as a show that will never record correctly. Save is now gated the same way Add Show already was (non-empty title + channel-in-lineup), with a graceful fallback to a bare non-empty check when the device's lineup isn't currently known — so editing a show on a temporarily offline tuner (see the tuner-not-detected work above) still works.
- **Fix — a recurring DateTime show with every day deselected saved and silently never fired** — Add Show now requires at least one day selected before Record is enabled for that type.
- **Fix — a rare device-discovery race could double-register a newly-connected tuner** — the background device probe had no reentrancy guard; a probe slower than its own ~60s/300s trigger interval could overlap with the next one, both appending the same first-seen device.
- **Fix — a display-only per-show tracking leak** — deleting a show mid-flight during a tuner-status network call could leave a stale entry behind that nothing would ever clear again.
- **Fix — the in-app player's audio/caption track picker could show a stale selection** after an externally-triggered (not user-initiated) channel switch.
- **Fix — the in-app player's buffering/connecting state could stick** — its stats timer ran in a run-loop mode that pauses during modal UI tracking (an open menu, a live window resize), so "Connecting…" could hang until the tracking ended.
- **Hardening** — one inline-script value in the web guide now goes through the same JS-escaping helper every other dynamic value there already uses (consistency fix; not exploitable — the value is always hardware-generated hex).

## 2026-08-01 (web guide tuner-not-detected handling + mobile fixes)

- **Feature — the web guide's edit modal now flags a show whose tuner is no longer detected** — clicking a show inside an offline/undetected tuner's ▾ dropdown shows an amber banner ("Tuner HDHR-XXXX is no longer detected — delete this show, or leave it as is in case the tuner returns") and hides the Pause button, since pausing a show tied to a phantom tuner does nothing useful. Cancel/Delete remain the only meaningful actions.
- **Fix — an offline tuner's ▾ dropdown could render underneath the summary panel instead of over it** — `.tuner-off`'s dimming opacity was applied to the whole `.tuner-box` (which also contains the `.tdrop` dropdown), and `opacity < 1` creates a new CSS stacking context that trapped the dropdown's `z-index` inside it; scoped the opacity to just `.tuner-row` instead.
- **Fix — the web guide couldn't be scrolled on a landscape phone** — `body{height:100vh}` doesn't account for mobile Safari's address-bar chrome, so the page could size taller than the actual visible viewport with no way to scroll to the rest. Added a `100dvh` override, plus a `@media(max-height:480px)` rule that compacts the summary panel (drops poster/genre/date/synopsis) so the guide grid keeps its scrollable room on short screens.
- **Testability — added a ConfigManager test seam** — `AppState`'s mutating paths (`deleteShow`, `addShow`, ...) call `saveConfig()`, which had no way to avoid writing through to the real on-disk config; `ConfigManager.init(appSupportDir:)` now accepts an injectable directory (production unaffected), and `makeTestAppState()` points every test at a fresh temp directory.
- **Tests — added 26 tests covering previously zero-coverage logic**: `ManagedGuideMatcher`'s tiered guide-flag matching (`seriesAll`/`seriesChannel`/`dateTime`/`single`, including tuner- and weekday-scoping), `ChannelSignalStore.key`'s trim+lowercase normalization, `XmltvParser`'s date/name parsing and full XML parse, and `deleteShow`'s show_id-keyed side-table cleanup — and removed 4 redundant/tautological tests found in a full-suite audit.

## 2026-08-01 (stale recording marker on fresh guide page loads)

- **Fix — a fresh web guide page load (a new tab, a hard refresh, or reopening the native Guide window, which loads a fresh `GET /` every time it's created) could show a currently-recording show as merely on-air, not recording, for up to an hour.** The full-page HTML cache (`cachedHTML`, served on every `GET /`) was only rebuilt on the hourly guide refresh — a recording start/stop, or any add/delete/pause/resume/edit/favorite-toggle, only pushed a live SSE patch to tabs that were already open, without updating the cached page itself. `broadcastRecordingEvent` and `broadcastGuideChangeEvent` now also re-run `prebuildPageHTML` after every push, so the cache stays in sync with the same state change connected tabs already see live. Verified live with `tools/mock_scenario.py record-test`-style scheduling: before the fix, a `GET /` issued immediately after a recording started still showed `g-prog-now` with no recording marker; after the fix, it shows `g-prog-rec g-st-rec` with the "— Recording now" tooltip immediately.

## 2026-07-31 (guide status markers redesign, conflict-detection over-flagging)

- **Feature — the web guide's recording-status markers switched from an 18px corner triangle (gold/red/green) to a colored ring + VCR-transport-glyph badge (⏱ scheduled, ⏺ recording, ⏭ will-skip-duplicate, ⚠ conflict)** — genre background stays untouched, and the palette moved off stoplight gold/red/green (which implied stop/caution/go, backwards for "will skip") to blue/red/slate/orange.
- **Fix — the native menu's tuner-conflict warning (⚠️) flagged every show in an over-capacity time slot, not just the one(s) that would actually lose a tuner** — a 2-tuner device with 3+ overlapping shows marked all of them, even ones guaranteed to record. Conflict detection now simulates per-device tuner-slot assignment (ordered by air time, favorite-channel-first on exact ties, matching the real recording-start priority) and only flags the actual loser(s). A loss specifically to a favorited competitor now says so in the tooltip, on both the native menu and the new web guide conflict badge.
- **Fix — the new web guide conflict badge (⚠) could appear on every rerun/simulcast of a show, not just its actually-contested airing** — a syndicated show airing many times a day, or a "any channel" series favorite, could show the conflict badge on every occurrence once its *next* airing lost a tuner, even ones with no real tuner contention. The badge now also requires the specific guide block to match the conflicting show's own device and air time.
- **Fix — adding, editing, pausing, resuming, or deleting a show could leave the web guide's conflict badges stale immediately after the change** — the pushed grid update reused whatever conflict data was last computed on the previous guide reload or idle-loop tick, so a newly-created or just-resolved conflict wouldn't show correctly until one of those unrelated events happened to catch up. Conflict data now refreshes immediately before each of these pushes.
- **Fix — a recurring SeriesID show could record the wrong program entirely if the network preempted it and the guide hadn't caught up yet** — a show's next-air time is locked in from an earlier successful guide match, and if the guide's periodic rescans subsequently stop confirming that slot (e.g. after a live schedule change), nothing previously stopped the app from recording blind at that stale time anyway, capturing whatever was actually airing under the original show's name. The app now does one final live guide check immediately before recording a SeriesID show starts — if the guide no longer confirms it, the recording is skipped and the show re-resolves against the next real matching episode instead.

## 2026-07-30 (diagnostic logging for the above two fixes)

- **Logging — confirms the `show_end` re-sync fix is actually correcting drift, and surfaces a real guide-provider mistagging incident if one recurs.** The `show_end` re-sync now logs (with before/after values) whenever it corrects more than a minute of drift, instead of silently updating every tick. Separately, the show-scheduling matches (`resolveSeriesAir`, `scheduleNextAir`) and the episode-tag lookup (`guideEntryForShow`) all still trust a matching SeriesID as authoritative, but now log a loud warning whenever the matched entry's title doesn't look like it belongs to the show anyway — the exact shape of the guide-provider crosswalk error behind the original Star Trek/MacGyver mix-up, where the guide had mistagged an unrelated rerun with this show's own SeriesID.

## 2026-07-29 (stale show_end causing nonsensical Discord/menu time ranges)

- **Fix — a scheduled show's displayed time range could span hours or even months longer than its actual length** — for a weekly show (Saturday Night Live, `20/20`) in particular, once the next real episode drops outside the guide's ~29-hour lookahead window (true most of the time between airings), the hourly rescan correctly leaves the show's next-air time alone but was never refreshing its paired end time to match — so the end time kept whatever a much earlier successful match had last set it to, drifting weeks or months stale while the (correct) next-air time moved forward. Any Discord card or menu view built from that mismatched pair before the next real match landed would show a nonsensical range — e.g. a 12-hour span for a 1-hour show. The end time is now re-derived from the show's own length whenever a fresh match isn't available, so the pair stays internally consistent instead of silently drifting apart.

## 2026-07-28 (wrong-show episode info on rerun/multiplex channels)

- **Fix — a recurring show on a channel that airs many different series back-to-back (e.g. H&I, which runs several different Star Trek series plus MacGyver, Walker, CSI, and others hour by hour) could get a completely different program's episode number and synopsis attached to it** — visible as the correct show name paired with a wrong `SxxExx` tag and a plot summary for something else entirely, and, more importantly, capable of misfiling the actual recording into the wrong season subfolder with a wrong episode-tagged filename, or missing a real duplicate-episode warning. The lookup this fed (shared by the season/episode-tag logic, the Discord recording card, and the Add/Edit dialog's duplicate warning) matched purely by channel + approximate time, with no check that the entry it found actually belonged to the show being described — so any staleness between when a show's next air time was set and when this ran (a guide correction, a refresh landing in between) could silently latch onto whatever program happened to occupy that exact slot instead. It now confirms the match's identity (by SeriesID, or by title for shows without one) before using it, and treats a failed match the same as finding nothing — a plain filename/no episode info instead of a wrong one.

## 2026-07-28 (multi-tuner audit)

- **Fix — the web guide's "Other Upcoming Airings" list had the same shared-antenna multi-tuner bug just fixed on the native side below**: it excluded the just-selected airing by channel + start time only, so a second tuner's identical copy of that airing (same channel number, same time, different device) was wrongly hidden from the list too, even though double-clicking it is how you'd switch the recording to that tuner instead.
- **Fix — a SeriesID(All) show (records any episode across all channels/devices) could fail to reschedule at all for an airing the guide happened to list without a SeriesID**, where the equivalent SeriesID(Channel) show would have recovered fine — the title-match fallback that handles this case only ever ran when both a specific channel and a specific device were known, which is never true for SeriesID(All) by design (it deliberately searches everywhere). The fallback now searches every device/channel when neither is specified, instead of being silently skipped.

## 2026-07-28 (series show title freezing on old guests)

- **Fix — a recurring series show added via the native Add Show wizard could get permanently stuck displaying whichever guests/episode info happened to be on screen at the moment you added it** — new episodes kept recording correctly every night, but the menu bar, Discord cards, and the recording folder name all kept showing the same old guest names indefinitely, because the show's display title was set once from that night's specific guide listing and never updated afterward. (Adding a show from the web guide already avoided this — only the native app's wizard had the gap.) Series shows now get named after the series itself, not a single airing, the same way the web guide already did. Existing affected shows aren't renamed automatically; edit one and clear the guest names from the title if you're seeing this.
- **Fix — editing (or adding) a show through the native app could silently disable its ability to fall back to local storage if its recording folder's drive went offline** — the Add/Edit Show dialogs were setting both the primary and fallback folder to the same value on every save, which quietly discarded the real fallback location. Repairs itself automatically for any already-affected show the next time the app loads — no need to re-save anything.
- **Fix — adding a show through the native app skipped the tuner-conflict warning and the "Show Added" confirmation** that adding one from the web guide (or the menu's quick-add) already gave — including missing the Discord "Show Added" card entirely for anyone with that notification enabled. Both now happen the same way regardless of which Add Show flow you use.
- **Fix — a recurring series show could silently stop rescheduling itself for future airings that the guide happened to list without a SeriesID**, once its title had been switched over to the series-name-only form above — the fallback lookup used for that case compared the show's (now series-only) title against the raw guide listing's title byte-for-byte, which no longer matched once one side had guest names stripped and the other didn't. Both sides are now compared in the same series-name-only form.
- **Fix — editing a show and closing the Edit window without changing anything, then opening a different show for editing, could pop a spurious "Unsaved Changes" prompt** — saving never actually cleared the window's own "has this been edited" tracking, so it stayed stuck on even right after a successful save.
- **Fix — double-clicking an alternate airing in the Add Show wizard's "Other Upcoming Airings" panel could leave the day-of-week selection pointing at the originally-selected airing's day** instead of the one you just switched to, if you'd also changed the recording Type after switching airings. Now updates together.
- **Cleanup** — a third copy of the series-title-stripping logic (in the folder-organizing step) now shares the same helper as the other two, instead of its own separate regex that could drift out of sync.
- **Fix — the Add Show wizard's "Other Upcoming Airings" panel could hide a second tuner's copy of the airing you'd just selected**, on multi-tuner setups where two devices share one antenna and report the same channel number — it excluded the just-selected airing by channel + start time alone, so an identical airing on your *other* tuner was wrongly excluded too, when double-clicking it is exactly how you'd switch the recording to that tuner instead.
- **Fix — promoting a show from Single to a SeriesID recording type in Edit Show didn't strip an already-set episode-specific title** the way adding a new SeriesID show already does — a show originally added as Single could get stuck on that one episode's guest names/subtitle after being promoted, the same freezing behavior fixed above for new adds.
- **Fix — the Add Show wizard's "Other Upcoming Airings" list could go stale if left open across the once-an-hour background guide refresh** — it now also recomputes whenever a guide reload happens, not just when you change the show's own type/channel/time.

## 2026-07-27 (guide-refresh race + follow-up fixes)

- **Fix — a Discord "Recording Started" card could show a bare title with no episode/matchup info, even though the guide data was correct and had been cached all day** — the once-an-hour background guide refresh cleared all cached guide data before fetching its replacement; if a show's start time landed near that same hour boundary, the deferred Discord card could be built in the brief window where the guide store had just been emptied but not yet refilled. The upfront clear wasn't actually needed for correctness (each device's stale data is already atomically replaced the moment its own fetch succeeds), so it's simply gone from the automatic background path — user-triggered guide refreshes (Settings → Update Guides Now, and guide-affecting setting changes) are unaffected and still clear immediately as expected.
- **Fix — a stalled device status check could silently skip a live tuner-availability check** — Watch Now and Watch-in-VLC deliberately wait for a fresh tuner-status poll before deciding whether all tuners are busy; a recent internal change meant that wait could return instantly with stale data if the idle loop's own background poll for that device happened to already be running. Now shares the same in-flight check instead of skipping it, so the wait always reflects real, current data.
- **Fix — the web guide's Edit button could fail to pre-fill for a managed series show** whose specific airing lacked a SeriesID in that day's guide data, even though the green/gold corner flag correctly recognized it as managed. The flag and the edit-button data now come from one shared lookup instead of two separately-built ones, so they can no longer disagree.
- **Cleanup** — consolidated repeated JSON-POST boilerplate in the web guide's client-side script behind one small helper (no behavior change).

## 2026-07-26 (performance + dead-code cleanup)

- **Fix — several always-on idle-loop costs gated to a sane cadence** — a diagnostic guide scan and the Bonjour TXT-record republish were both running on every idle-loop tick (every 5-10s, forever) regardless of whether anything had actually changed; the menu-cache rebuild was also re-scanning the whole channel lineup for logo URLs every tick even though that only changes on guide reload. All three now only do real work when something relevant has actually changed or enough time has passed, with no user-visible behavior change. A permanently-unreachable-but-still-discoverable device could also pin the fast 60s device-recheck cadence forever instead of settling back to the normal 5-minute one — now bounded to the first 5 minutes of that state.
- **Fix — every Record/Edit/Delete/Pause/Favorite action on the web guide rebuilt the page twice** — the browser tab performing the action re-fetched and rebuilt the whole guide grid itself right after already being pushed the identical rebuilt grid over its live update connection. Removed the redundant fetch; the live-update push already covers it. The once-an-hour background guide refresh had the same double-rebuild and is fixed the same way.
- **Fix — two SwiftUI screens re-ran non-trivial work on every keystroke** — the menu bar's "Now Watching" poster bypassed the shared image cache (re-downloading over the network every time the menu opened) and the Add Show wizard's "Other Upcoming Airings" list recomputed on every unrelated edit; both are now cached and only recompute when something they actually depend on changes.
- **Cleanup — removed unused code** — several functions, one field, and one SwiftUI view with zero remaining callers were confirmed dead and removed; a one-time diagnostic script whose question was already answered and documented was likewise removed. No behavior change.

## 2026-07-25 (duplicate-episode override)

- **New — override "skip already-recorded episodes" for one recording** — the Add/Edit dialog's new **Duplicate Episodes** row warns when the upcoming airing is already on disk and would otherwise be skipped, with a **"Record even if already on disk"** toggle to force it through anyway (e.g. you deleted the existing file, or just want another copy). One-shot: it only ever suppresses a skip that would actually have happened, and clears itself automatically once that recording succeeds — later reruns go back to being skipped normally, no need to remember to turn it back off. The web guide's green "already recorded" corner flag reflects the override too (falls back to the normal gold "will record" flag while it's active).

## 2026-07-23 (new app icon)

- **New app icon** — redrawn as a single VHS cassette (two reels, red/white label) with a fold-out antenna, replacing the old three-panel banner. The label's bottom half now doubles as a live status light in the menu bar: dim when idle, red while recording, amber when a show is coming up within 30 minutes — reusing the app's existing `isRecording`/`nextShowMinutes` state instead of swapping to a generic `record.circle.fill`/`clock.badge.fill` SF Symbol. Also fixes a longstanding bug where the Dock/Finder icon showed black letterbox bars: `AppIcon.icns` was previously padded from the rectangular menu-bar image with a solid fill color; it's now built from a dedicated square, alpha-transparent master (`Resources/AppIcon-source.png`), so the icon is a clean transparent-cornered squircle. `deploy.sh`/`deploy_release.sh` updated to match.

## 2026-07-18 — v1.4.0

- **Add Show — the cable-guide step remembers its size** — resize the Add Show guide window (wider, taller) and it now reopens, and survives an app restart, at that size instead of resetting to a fixed default. Persisted per-machine; the compact details step is unaffected.
- **Recordings now use the `.ts` extension** — for every transcode profile. Captured directly from the tuner and confirmed that HDHomeRun sends an **MPEG-2 transport stream** on the wire for *all* profiles (188-byte TS packets); transcoding only re-encodes the video *inside* the TS (MPEG-2 → H.264), it never changes the container. The recorder writes the stream verbatim (no remux), so the accurate extension is `.ts` — the same convention Plex/Emby/Jellyfin/MythTV use, and it matches the `video/mp2t` type the built-in player relay already serves. Previously recordings were named `.m2ts` (no transcode) or `.mkv` (transcoded); `.mkv` in particular described a container the device never produces. **Existing `.m2ts`/`.mkv` recordings are unaffected** — they're still recognized everywhere (Watch Now, Organize, skip-already-recorded), just no longer created. A new regression test locks the wire-format finding against real captured stream fixtures.

## 2026-07-17 (skip already-recorded episodes)

- **New — skip an episode you've already recorded** — a new Settings → Post-Processing toggle, **Skip already-recorded episodes** (only available when **Series subfolders** is on), stops a series from grabbing the same episode twice on a rerun or simulcast. Before recording, the app checks whether a file with the same season/episode (e.g. `S02E04`) already exists in that show's folder; if so it quietly advances to the next airing without recording or counting a failure. Matching is by season+episode number read straight from existing filenames — no new bookkeeping, and deleting a recording lets it record again. Episodes the guide gives no season/episode number for are unaffected (recorded as before).
- **New — web guide "already recorded" corner flag** — a scheduled airing the app will skip because you already have that episode shows a **green corner flag** (in place of the usual gold "will record" flag) on the guide, so you can see at a glance that it's recognized and being skipped on purpose. Legend: gold = will record, red = recording now, green = already recorded / will skip. Hovering a program block now also spells out its state in the tooltip (e.g. "— Already recorded · will skip").
- **New — optional Discord card for duplicate skips** — a dedicated "Skipped — already recorded" Discord toggle (separate from the disk-full skip card) posts when an airing is skipped as a duplicate.

## 2026-07-17 (tuner-count re-probe follow-up)

- **Fix — a permanently-unreachable tuner no longer keeps the app probing every 60 s** — the tuner-count restore added on 2026-07-16 re-probed the network every ~60 s while *any* device had an unknown tuner count. A device that never returns a tuner count (e.g. a device whose web server stays unreachable) kept that fast cadence running for the whole session instead of settling back to the normal 5-minute cycle. The quick re-probe now only fires for devices that are actually reachable.

## 2026-07-16 (tuner-count regression + Add-Show signal quality)

- **Fix — tuner display could read "no active tuner" after a UDP-only startup** — if the app discovered a tuner over UDP while that device's built-in web server was briefly unreachable (increasingly common now that UDP-only discovery works), the device was cached with an unknown tuner count and the tuner badge vanished entirely — even while it was actively recording. Device probes now restore the tuner count (and firmware) as soon as the device's web server is reachable again, and re-probe every ~60 s until it is, so the badge comes back on its own instead of staying blank for the session.
- **New — signal quality shown when scheduling a recording** — the Add Show (and Edit Show) dialog and the web guide's Record form now show the channel's signal bars, plus a "weak signal" warning when the channel's signal is poor, so you can see before scheduling whether a channel is reliable. Uses the signal history the app already collects (gated on the existing signal-quality setting); channels never recorded or scanned simply show nothing.

## 2026-07-16 (fix pass 3 — security + TODO cleanup)

- **Security — the web UI can no longer choose where recordings are saved** — the web Edit form's endpoint used to accept a save-directory path, which on a LAN-only-no-auth app meant any device on your network could redirect where a recording is written. That field is now ignored entirely; the save location is only changeable from the local app (matching what the UI already implied). The local filesystem path is also no longer embedded in the web page.
- **DeviceAuth now read straight from UDP discovery** — the tuner's cloud-guide token (tag `0x2B`) is parsed from the UDP discovery reply, so the guide keeps working even when the device's built-in web server is asleep or unreachable. Previously only the DeviceID was read from that reply.
- **Web Edit form now matches the Record form** — the day-of-week row shows for one-time and weekly shows (not just weekly), and the Bonus Time row is hidden when Sports padding is disabled — same behavior as the Add/Record form.
- **Cleanup** — removed two pieces of dead code (an unused button style and the unreachable device-selection step in the native Add Show wizard, since the tuner is chosen in the web guide).

## 2026-07-16 (fix pass 2 — review of the last 6 commits)

A fresh 3-angle review of the recent recording/Discord/WebServer fix passes found six real defects (the supporting device/guide/player files reviewed clean):

- **Fix — tuner count could read low right after a device reconnects** — when a tuner device flapped offline then online, the web guide re-rendered its tuner badge from hardware-reported occupancy alone, briefly undercounting an in-app stream or a just-started recording that the hardware status hadn't caught up to yet. The badge now uses the same combined count everywhere.
- **Fix — recording save-directory field hardened** — the web Edit form's "save to" path is validated on an app that has no auth beyond being on your LAN: it now rejects `..` path tricks, resolves symlinks, requires the target (or its existing parent) to be a writable directory, and will only create a single new folder under an existing one instead of building arbitrary deep paths.
- **Fix — two per-show tracking entries could leak** — deleting a show that had been skipped after a signal dropout left behind internal signal/tuner tracking state for the rest of the session; `deleteShow` and the skip path now clear it.
- **Fix — a dying recording could post a stray "In Progress" Discord update** — on the exact tick a recording's process died as a 5-minute progress update came due, the app could post a bogus "Recording In Progress" edit; the progress update now checks the recording is actually still running first.
- **Hardening — start-recording loop no longer trusts a stale list position across an await** — matches the pattern applied everywhere else in the recent passes, so a future change that adds a suspension point can't make it act on the wrong show.
- **Fix — web Edit form now validates channel and length** — the channel must exist in the device's lineup (matching the Record form) and the length is capped at 24 hours, instead of being stored unchecked.

Four lower-severity / pre-existing nuances were logged to `ISSUES.md` rather than changed in this pass.

## 2026-07-16

Follow-up review of the 2026-07-15 fix pass (fresh 8-angle review of that commit) caught several gaps in its own fixes:

- **Fix — a recording could still crash or corrupt the wrong show's notification** — `stopRecording`'s natural-completion path awaited a guide reload, then read the show back out by its original position instead of re-checking it was still there; a show deleted during that reload could point it at a different show (or crash outright). The same gap existed in "Rescan Series" (Settings → Maintenance) if a show was deleted mid-scan.
- **Fix — Discord card serialization was a busy-poll that could race a deploy's stop-the-app step** — replaced the polling mutex with a chained-Task design (same idea already used elsewhere in the app for lineup loading), and closed a narrow window where killing the app mid-send (as every deploy does) could leave a stale Discord message reference that caused a bogus "Recording Complete" notice on the next launch.
- **Fix — a device coming online or offline could close a dropdown you had open in the web guide** — the live update now remembers and restores whichever tuner's schedule you had expanded.
- **Fix — editing a show's schedule could show outdated info in the web guide for a few seconds** — the live update now fires again once the change actually finishes processing, not just when it starts.
- **Cleanup** — a tuner-occupancy calculation that existed in two copies (and had already drifted between them) is now one shared calculation.
- **Docs** — corrected three settings/behavior descriptions that fell out of sync with yesterday's fixes (Guide Hours range, Add Show's retry behavior, Edit Show's unsaved-changes prompt).

## 2026-07-15

- **Fix — recording retry storm after a mid-episode failure** — once a show hit the fail-count threshold and paused, it could immediately auto-resume (the "next airing imminent" check was trivially true right after a mid-recording pause, since `show_next` still pointed at the airing that just failed) and re-fail in a ~20–30s loop for the rest of that airing's window instead of staying paused until the window actually ended. The Carol Burnett Show was hitting this nightly.
- **Fix — Discord posted dozens of duplicate messages during a retry storm** — a side effect of the above, compounded by every recording-lifecycle Discord send now being serialized through a new per-show mutex (`discordCardInFlight`) so two events for the same show (e.g. a "Recording Started" confirmation racing a "Paused" card) can no longer both create their own message and orphan/stomp each other's card.
- **Fix — recording failure messages didn't say why** — failures now report the actual HDHomeRun device error or a decoded curl exit code (e.g. `"No Video Data (807)"`, `"curl timeout (28)"`) instead of a generic `"curl exited unexpectedly"` or bare `"file missing or empty"`.
- **Fix — idle loop could crash under network stress** — `idleLoop()` now guards against two overlapping runs (the timer fires a new one every tick regardless of whether the last one finished), and stopped trusting array indices captured before an `await` — a show deleted while a guide fetch was in flight could previously leave a stale index pointing out of bounds or at the wrong show.
- **Fix — deleting an actively-recording show left stale state behind** — `deleteShow` now fully tears down the recording (tuner-occupancy clear, stopped-event broadcast) instead of just killing the curl process, and clears all of its internal per-show tracking instead of leaking most of it for the rest of the session.
- **Fix — shows added/edited via the native Add Show / Edit Show windows never appeared in the web guide** — those two windows call the same `addShow`/`updateShow` used everywhere else, which now push the update themselves instead of leaving it to each caller to remember.
- **Fix — a tuner going online/offline mid-session never updated in the web guide** — previously silently stale until the next 2-hour reload; now pushes a live update to the tuner's box.
- **Fix — the web guide's edit modal accepted any save-folder path with no validation** — since that endpoint has no auth beyond LAN-subnet matching, any device on the network could redirect a show's recording output anywhere on disk; it now requires a real (or creatable) absolute directory.
- **Fix — deleting/stopping a show by channel + title could hit the wrong tuner** — the web guide's fallback match (used when no show ID is given) now also requires the device to match, so a multi-tuner setup with an identically-titled show on the same channel number on two tuners can't cross-hit.
- **Fix — a malformed UDP discovery reply could crash the app** — any device on the LAN replying to the discovery broadcast with a crafted payload-length field could walk the parser past its buffer; it's now bounded against the actual bytes received.
- **Fix — a single corrupted show in the saved config could wipe every scheduled show** — a missing/invalid ID on one show previously threw during decode, discarding the entire list; that field now always has a fallback.
- **Fix — Discord webhook validation accepted lookalike hosts** — e.g. `notdiscord.com` passed the old suffix check; it now requires an exact match or a proper subdomain.
- **Fix — a truncated or malformed XMLTV guide response was treated as a complete, successful load** — parse errors are now detected and the load is rejected instead of silently indexing a partial guide.
- **Fix — Guide Hours allowed up to 48h but the cloud guide API silently truncates past ~29h** — capped the setting at 28 to match what a single request actually returns.
- **Fix — switching channels in the in-app player kept the previous channel's audio/CC track list** — tracks now reset and re-detect on every switch.
- **Fix — switching from a recording relay to a live channel in a narrow timing window could resurrect the old recording's scrub-bar state over live video** — closed with a staleness guard on the deferred seek-state update.
- **Fix — a double-click on Watch Now could re-mute an already-playing stream** — added a second "already playing" check after the async device-status fetch that the race was slipping through.
- **Fix — a channel with no stream URL in the lineup left the in-app player stuck on a permanently-disabled "Connecting…"** — now caught upfront with a clear alert instead of a silent dead end.
- **Fix — Edit Show silently discarded unsaved edits when re-targeted to a different show from the menu** — now prompts to save/discard/cancel, same as closing the window with unsaved changes.
- **Fix — the Add Show wizard could get permanently stuck showing "Stream URL not found"** — if opened before device discovery finished, the lineup-load task never retried; it now re-runs once devices populate.
- **Fix — Settings' Discord webhook "Test" button could mark a since-edited, never-tested URL as "Verified"** — if you changed the field again before the test finished, its result now only applies if the URL it tested is still the one showing.

## 2026-07-14

- **Discord activity log** — Discord sends/edits now also write to a dedicated `~/Library/Logs/hdhrVCRplus-discord.log` (embed title, HTTP result, and the message ID used for edits), so legitimate progress-update edits can be told apart from real duplicate sends without wading through the main log.

## 2026-07-11

- **Escalating retry backoff for failed recordings** — a failing recording now waits 2 idle-loop ticks (then 3, capped) before retrying, instead of hammering the same show every idle interval and burning through the whole fail-count in well under a minute. Also fixed the disk-full "Recording Skipped" path — the one failure branch still posting a brand-new Discord message on every retry instead of updating the existing card.
- **Weekday toggles are Sunday-first** — the Day/Days pickers in the native Add Show / Edit Show forms now read Su Mo Tu We Th Fr Sa, matching the web guide's Record modal (they had drifted apart).

## 2026-07-10

- **Other Upcoming Airings — redesigned, and double-click to switch** — when adding or editing a SeriesID show, the list of other upcoming airings of that series now shows channel logos and a genre-color accent bar (matching the guide / Watch Now look) instead of a plain text line, and renders correctly with more than one result. **Double-click any row to re-anchor the whole Record dialog / Details step to that airing** (title, channel, time, device) while keeping your Type / Transcode / Bonus settings — a swap, not an append.
- **Web guide Record modal now matches the in-app Details step** — editable title, a day-of-week row for one-time and weekly shows, config-driven transcode default, Bonus Time gated on the Sports-padding setting, and the same Other Upcoming Airings panel (via `GET /api/airings/{seriesId}`).

## 2026-07-09

- **See other upcoming airings while adding a series** — the Add Show wizard's Details step now surfaces other future airings of the same series (time, channel, episode info) for SeriesID(Channel) / SeriesID(All) shows, so you can see at a glance when else it's on without leaving the wizard.

## 2026-07-06

- **Fix — tuner-full check now honors another machine's recordings** — `tunersFull(for:)` (the gate checked before starting a new recording) previously only counted this instance's own `recordingShows`, missing tuners already locked by another machine running this app against the same physical HDHomeRun device. It now uses the same hardware-polled `status.json` count the display badge already relied on, giving an accurate global tuner count across machines.
- **Fix — tuner badge could briefly over-report occupancy right after a recording stops** — the SSE-pushed tuner count takes the max of the hardware-polled and software-tracked occupancy; on a stop, a stale hardware count could outrank the already-decremented software count for up to ~1.5s. The just-released tuner's hardware entry is now cleared immediately instead of waiting for the next poll.
- **Fix — dead theme-sync call in Add Show wizard** — the embedded web guide's `didFinish` handler called a nonexistent `applyTheme()` function (a silent no-op); it now calls `setTheme(...)` like `FloatingGuideView` already did, so dark/light mode applies immediately instead of on the guide's next load.
- **Fix — wrong default save folder in Add Show wizard** — a first-time user who went straight to the guide step without opening Settings could get shows saved to `~/Documents/hdhr_videos` instead of the real default, `~/Movies/hdhr_videos`.
- **Fix — lineup-load waiters polled instead of awaiting** — `ensureLineupLoaded` polled a `loadingLineupDevices` set every 100ms (up to 5s) while waiting for a concurrent in-flight fetch; it now stores and awaits the in-flight `Task` directly, so coalesced callers resume the instant the fetch finishes.
- **Cleanup** — removed an orphaned label-formatting chain in `MenuContent.swift` (`relativeLabel`/`elapsedLabel`/`remainingLabel`/`timeRange`/`weekdayName` + a static `weekdayFormatter`) that nothing called.

## 2026-07-03 (260703-2203) — v1.3.0

- **Watch Now! on a recording no longer costs a tuner** — clicking "Watch Now!" on a show that's currently recording used to re-request the same channel from the HDHomeRun device, silently consuming a second tuner for content already being captured. It now plays the in-progress recording straight from disk instead, through a new local relay (served over the built-in web server, even with the LAN web UI disabled in Settings) that streams the growing file as it's written — so recording and watching the same show now shares the one tuner already in use. Starts ~30 seconds behind the live edge, matching how live TV normally feels, rather than at the beginning of the file.
- **Scrub bar for in-progress recordings** — hover over the video while watching a recording to reveal a scrub bar (fades in/out) showing the recording's start time and current live time as clock times, with a slider to jump anywhere already written to disk. Seeking is approximate (the raw recording has no index) but close enough for casual scrubbing.
- **Switch between simultaneous recordings from the channel picker** — the in-app player's channel picker now lists a "Live" row for every show currently recording on that tuner, letting you switch straight between them (or back to a live channel) without leaving the player window.
- **Fix — recording playback buffer** — the live-stream buffer fill-ramp (and its toolbar indicator) no longer applies to recording playback, which is a local disk read with no network jitter to buffer against; recordings now start at full speed immediately.
- **Fix — tuner count while watching your own recording** — watching a recording via Watch Now! was incorrectly counted as occupying an extra tuner, which could block scheduling a second, actually-free recording and inflate the tuner count shown in the web guide. The app now correctly recognizes that a recording-relay session (unlike watching a live channel) doesn't use a tuner at all.
- **Fix — re-clicking Watch Now! on an already-open recording** — used to reconnect and rebuffer instead of just bringing the window forward, discarding any scrub position.
- **Fix — "catch up to live" during recording playback** — now actually jumps to the live edge of the recording instead of reconnecting at the same stale position.
- **Fix — media-key next/prev** — no longer goes dead when a "Live" recording row is selected in the channel picker.
- **Add Show — Record button** — the wizard's final "Save" button is now labeled **Record**, tinted the same red as the web guide's Record button, to make it clearer that finishing the wizard starts a recording.

## 2026-06-27 (260627-1933)

- **Web guide — instant page load** — The guide HTML is now pre-built and cached after every guide fetch (`prebuildPageHTML`). `GET /` serves the cached copy immediately instead of blocking the `@MainActor` thread for 2–4 seconds to build ~1.1 MB of HTML on every request. Desktop and mobile variants are cached separately; the cache is invalidated and rebuilt on each hourly guide refresh.
- **Web guide — loading splash** — A fixed overlay shows the app icon, name, and build version while the page is loading. A 300 ms CSS animation delay makes it invisible on fast local loads; on slow remote loads it fades in and disappears once the first frame paints. The app icon is served from the new `GET /api/icon` endpoint (72×72 PNG, cached after first render).
- **Web guide — NEW pill** — Program blocks for first-run shows airing today display an inline green **NEW** badge next to the title. Detection: `OriginalAirdate` (stored as midnight UTC for the local broadcast calendar date) is decoded in UTC and compared against the server's local calendar date. Late-night shows with a 00:00–05:00 local start time whose UTC date rolls to "tomorrow" also count. The pill sits immediately after the title text rather than pushed to the edge.
- **Web guide — New genre filter** — "New" option added to the genre filter dropdown. Selecting it dims all non-new-episode program blocks (same pattern as Infomercials). Only appears when new-episode shows are in the current guide window.
- **Watch Now — NEW pill** — The `isNewEpisode()` helper (shared in `GuideViewHelpers.swift`) adds a green NEW badge next to the show title in each Watch Now row.
- **Fix — original air date timezone** — `origAirdateFormatter` now forces UTC so US timezones no longer roll the displayed date back to the previous day's evening.
- **Settings — InfoButton descriptions** — Every setting's description is now behind a small `ⓘ` button (tapping shows a popover) instead of an always-visible caption line. Applies to all sections including Maintenance and Homebrew install rows.
- **Web guide — logo placeholder removed** — The summary panel poster now loads directly from the CDN URL; the channel logo is only used as an `onerror` fallback (no longer shown as a fill-in while the poster loads).

## 2026-06-24 (260624-0000)

- **Series subfolders** — New toggle in Settings → Recording. When enabled, SeriesID recordings (`seriesChannel`/`seriesAll`) are saved into `Title/Season XX/` subfolders inside the recording folder. The episode tag (e.g. `S02E04`) is also embedded in the filename before the channel number. Falls back to `Title/` when no season is parseable from the guide's `EpisodeNumber`. dateTime shows are always saved flat. The episode number regex (`^S(\d+)(?:E\d+)?$`) handles bare season-only strings (`S03`) and is case-insensitive. The **Organize** maintenance action (Settings → Maintenance) scans existing flat-root files and moves them into the correct subfolders.
- **Post-recording script hook** — New field in Settings → Recording. Set a shell script path; after each successful recording (non-zero file size confirmed), the script is launched via `/bin/sh` with the recording path as `$1`. Env vars passed: `HDHR_PATH`, `HDHR_TITLE`, `HDHR_CHANNEL`, `HDHR_TRANSCODE`, `HDHR_EPISODE`, `HDHR_DEVICE`, `HDHR_SERIES`, `HDHR_FILESIZE`. Homebrew paths prepended to `PATH` so tools like `comskip` work by name. The script runs detached and does not block the app; exits are logged.
- **Settings — Maintenance section reorder** — Most-used actions moved to the top of each group (Shows: Reactivate Paused → Rescan Series → Reset Fail Counts → Organize; Guide & Devices: Rediscover → Refresh → Clear Cache). All descriptions rewritten to explain why you'd run each action.
- **Fix — series subfolder directory creation now logs errors** — `createDirectory` for a new `Title/Season XX/` subfolder previously used `try?`, silently swallowing filesystem errors (read-only volume, bad permissions). It now logs the error at `.error` level so the root cause of a failed recording is diagnosable.
- **Fix — season-only episode tags in post-recording script** — `HDHR_EPISODE` was empty when the recording file contained a bare season tag like `_S03_` (no episode number). The extraction regex is now `_(S\d+(?:E\d+)?)_`, matching both `_S02E04_` and `_S03_`.
- **Fix — season regex unified and case-insensitive** — `seasonNumber()` previously selected the regex branch with a case-sensitive `contains("E")` check, silently returning nil for any lowercase `EpisodeNumber`. Replaced with a single case-insensitive pattern `^S(\d+)(?:E\d+)?$` that handles both full and bare-season forms.
- **Web guide — full-viewport layout** — The guide grid now fills the entire window height with `flex:1;min-height:0` instead of `max-height:60vh`, so the guide extends to the bottom edge of the window regardless of window size.
- **FloatingGuideView — theme injection** — System appearance is now applied via `setTheme('dark'|'light')` instead of setting `localStorage` directly + calling the removed `applyTheme()`.

## 2026-06-18 (260618-0008)

- **Web guide — tuner count + device link moved into ▾ dropdown** — Each tuner box in the toolbar is now just the tuner name and a ▾ button. The `active/total` badge and ↗ device web UI link moved into the top of the per-tuner dropdown, reducing toolbar clutter. The badge still updates live and still opens the tuner popover.
- **Web guide — one dropdown at a time** — Opening one tuner's ▾ now closes any other open dropdown. Clicking anywhere in a different tuner box (name, ▾, or inside it) also closes the current dropdown; previously the outside-click guard exempted the entire toolbar from closing dropdowns.
- **Web guide — jump-to-guide from dropdown rows** — Each show row in a ▾ dropdown now has a → button that closes the dropdown, switches the guide to that tuner's device, scrolls to the show's guide block, and selects it. Clicking the row itself still opens the edit modal.
- **Web guide — original air date on mobile** — The original air date in the summary panel was hidden on screens ≤600 px wide (mobile). Removed that rule; it now shows whenever the guide entry has one.
- **Infomercial detection — title fallback** — `"Paid Programming"` title is now treated as an infomercial marker alongside the existing SeriesID blocklist (`C459763EN3L6D`, `C11809220ENAPZK`). Catches generic paid-programming slots that appear with an unknown SeriesID without requiring a blocklist update.

## 2026-06-17 (260617-1144)

- **Web guide — unified top toolbar** — The title, tuner list, genre filter, and theme switcher now sit together in a single top toolbar row.
- **Web guide — per-tuner schedule dropdowns** — The global schedule popover is gone. Each tuner now has its own box with a ▾ that drops down that tuner's Recording / Up Next / Scheduled / Paused shows. Clicking a tuner's name filters the guide to its lineup; with more than one tuner the guide opens on the first tuner that has guide data (no combined view). Tuners that are referenced by a show but not currently detected are still listed, dimmed and marked "offline", with their assigned shows still viewable via the ▾.
- **Web guide — now-line no longer drifts** — The red "now" line could creep ahead of the real time after the guide sat open through an hourly background refresh, because its live position was still measured against the original page-load window. `refreshGuide()` now resyncs the window origin (`winStart`/`winSec`) from the refreshed grid, so the line stays accurate no matter how long the page is left open.
- **Windows — never open duplicates** — Add Show, Edit Show, Settings, Watch Now, and the floating guide are now single-instance windows; choosing one from the menu brings the existing window to the front instead of opening a second copy. Edit Show also reloads correctly when opened for a different show while already open.
- **Web guide — accurate live tuner counts** — The tuner badge updates pushed on recording start/stop (and on reconnect) now include the in-app VLC stream and tuners in use by other apps, instead of counting only this app's recordings — so the `active/total` count and "FULL" label no longer under-report.
- **Web guide — correct poster on quick selection** — Rapidly clicking between shows could leave a previous show's poster showing; each selection now invalidates any in-flight poster swap.
- **Discord — one card per recording** — A recording that fails and then succeeds on retry now updates a single Discord card (❌ Failed → 🔴 Started → ✅ Complete) instead of posting a separate failure card followed by a start/complete card. The card id is kept across retries and cleared only when the recording completes or the show is paused.

## 2026-06-11 (260611-1048)

- **Signal stats — tap to inspect** — The signal bars in Watch Now are now clickable: a popover shows bucket + average, last reading, min–max range, **last checked** (relative time — the freshness of the recordability assessment), and sample counts. Backed by a new `ChannelSignalStore.stats(guideName:)` computed over the same last-20 window that drives the bars, so the numbers always match the displayed bucket. Menu-bar bars are unchanged (NSMenu can't host a popover).
- **Web guide — tuner popover signal line** — Each active tuner row in the tuner popup now shows an inline signal line: colored dot + Poor/Fair/Good + `{avg}% avg · {last}% last · checked {Xm/Xh/Xd ago}`, fetched per row from the new `/api/signal-stats/{guideName}` endpoint. Colors match the guide-row SVG bars and SSE palette.
- **Web guide — tuner popover generation token** — `tPopGen` is bumped on every popover open/close; all async enrichment fetches (signal-stats and now-airing) capture their generation and discard stale responses. Fixes a pre-existing race where a quick close/reopen let an in-flight now-airing fetch append stale poster/episode/end-time nodes into the rebuilt popover.
- **Signal store — canonical key helper** — All signal-history key derivations now go through `ChannelSignalStore.key(for:)` (trim + lowercase). Previously `signalBucket()`, the web guide's `data-gname` attribute, and the SSE broadcast keys only lowercased, so a whitespace-padded `GuideName` recorded data the readers could never find.
- **Channel icons — incremental publishing** — On a cold cache, downloaded channel icons now appear in the UI in batches of 16 as downloads complete, instead of all at once after the last download. All downloads still run concurrently (total time ≈ slowest single download); the warm-cache path keeps its single bulk assignment.

## 2026-06-10 (260610-1952)

- **Web guide — lazy row rendering for faster load** — Added `content-visibility:auto; contain-intrinsic-size:auto 55px` to every `.g-row`. A full guide is ~100 rows × ~1300 absolutely-positioned program blocks with per-row gradient backgrounds; the browser was spending ~23 s (in WKWebView/Safari) on style/layout/paint of the entire grid, including the ~90 rows scrolled off-screen. The engine now skips off-screen rows and renders them on scroll, so the initial paint costs only the ~12 visible rows. Pure CSS — no JS, no new endpoint, survives `refreshGuide()` DOM swaps, and leaves the `winStart`/gap-fill math untouched. The sticky channel column was verified intact (the implied `contain` can otherwise interfere with `position:sticky`). Older browsers without `content-visibility` degrade to rendering all rows up front.
- **Web guide — gzip compression** — `.ok` HTTP responses ≥ 1400 bytes are now gzip-compressed when the client sends `Accept-Encoding: gzip`, shrinking the ~1.1 MB guide page to ~160 KB (6.8×) — the dominant initial-load cost for LAN Wi-Fi clients. Implemented with libcompression raw DEFLATE wrapped in a gzip container (10-byte header + CRC-32/ISIZE trailer); falls back to uncompressed if compression fails or wouldn't shrink the payload. Already-compressed icon image responses are never gzipped.
- **Web guide — bounded tuner occupancy fetch** — The pre-render `/status.json` fetch now skips devices already marked unavailable by the probe loop and uses a 2 s timeout (down from 5 s). Previously a single offline tuner stalled every page load for up to 5 s.
- **Guide — hourly boundary refresh** — Replaced the every-6-hours interval guide refresh with an hourly-boundary refresh synced to the web UI's 30-minute window recalculation (`winStart` floors to :00/:30). The guide reloads at the top of each hour so new entries appear at the right edge just as the window slides to reveal them; the hour boundary also prevents retry storms when the guide API fails. `lastRefreshHour` is stamped in `fetchAllGuides()` on a successful load so the first idle-loop tick after startup no longer triggers a redundant full reload of data just fetched seconds earlier (a failed startup load leaves it `nil`, preserving immediate retry).
- **Web guide — controls moved to corner cell** — The ⊙ Now and ↺ Refresh buttons moved from the page header into the sticky guide-grid corner cell (top + left sticky, so they stay visible while scrolling in any direction); the header's right side now shows only the theme switcher. Refresh now calls `refreshGuide()` (scroll- and selection-preserving DOM swap) instead of `location.reload()`.
- **Web guide — genre filter dims instead of hides** — Selecting a genre now dims non-matching program blocks (35 % opacity, `pointer-events:none` so they're unselectable) rather than hiding their rows — rows stay visible, only individual programs are dimmed. Dimming is applied in a single page-level `applyGenreDim()` pass independent of device filtering, so the two filters compose cleanly and an unfiltered page load is a no-op instead of iterating every program per row.
- **Recording — suppress transient-failure notifications** — A single transient recording error (e.g. error 807 "No Video Data" that self-recovers on the next idle tick) no longer fires a user notification. Notifications are sent only on persistent failure (`fail_count > 1`, i.e. 2+ attempts) or when the show is paused at the configured `Fail_count_setting` threshold.

## 2026-06-09 (260609-1544)

- **Web guide — lazy-load images + icon cache headers** — Channel logos and poster images carry `loading="lazy"` so the page renders immediately without waiting for image downloads, showing neutral dark/light-aware gray placeholders while images load. `/icon/*` responses gained `Cache-Control: max-age=2592000` (30 days) since logos don't change — fixes Windows repeat-load caching and improves LAN performance.

## 2026-06-08 (260608-2017)

- **Web guide — tuner popup click-to-guide** — All non-idle tuner rows in the tuner popover now have a clickable title (dotted underline, pointer cursor) that calls `goToShow(ch)` — closes the popup and scrolls the guide to the currently-airing block for that channel. Previously only async-enriched external-stream rows were clickable; our own recording rows were not.
- **Light theme overhaul** — Replaced washed-out light-mode CSS variables with values that meet WCAG AA contrast on light surfaces: `--t4`/`--t5`/`--t6` darkened from `#888–999` to `#666–7d8`; borders darkened to the `#78–c4` range so structure is visible; surfaces given distinct layering (`--bg #e4e6ea`, `--s1 #eceef2`, `--s3 #fff`); program-block base colors darkened; genre-block lightness dropped from 80–92 % to 68–80 % with visible colored borders added.

## 2026-06-08 (260608-1707)

- **Web guide — SSE fragment push for recording events** — `recording_started` and `recording_stopped` SSE events now carry pre-rendered `sumPh` and `schedPop` HTML fields. The JS handler applies them directly to `#sum-ph` and `#sched-pop-body` without a second `fetch('/')` round-trip. The currently-airing guide entry's `.g-prog-rec` class and red-dot flag are toggled inline via `data-num`/`data-device` selectors. A new `buildSumPhHTML(state:)` helper in `WebServer.swift` was extracted from `buildHTML` to make the fragment available at broadcast time.
- **Web guide — `guide_refreshed` SSE event** — `refreshGuides()` now emits `{"type":"guide_refreshed"}` after a successful guide fetch. Connected clients call `refreshGuide()` automatically, replacing the previous manual-reload requirement after the guide data changes.
- **Web guide — now-line timer tightened** — The `updateNowLine` interval changed from 5 minutes to 1 minute, keeping the progress indicator and time cursor accurate across all guide views.
- **Web guide — absolute time strings** — Schedule popover and summary banner (`#sum-ph`) replaced relative time strings with `state.shortTime()` absolute times (e.g. "at 9:00 PM") so times stay correct without a page reload.
- **MAS compliance prep** — Launch at Login converted from a LaunchAgent plist to `SMAppService`; `PrivacyInfo.xcprivacy` added and wired into `Package.swift` resources; `Info.plist` switched from `NSAllowsArbitraryLoads` to `NSAllowsLocalNetworking`.
- **Favicon** — `GET /favicon.ico` route added to `WebServer.swift`; `deploy.sh` generates a minimal 16×16 ICO from the app icon PNG using Python `struct` packing on each deploy.

## 2026-06-07 (260607-2020)

- **Web guide — channel logos in guide grid** — Channel logo images are now shown in the left-hand channel column of the web guide. Icons are fetched from the HDHomeRun guide API on lineup load, cached to `~/Library/Caches/hdhr_VCR/channel_icons/`, and served locally via `GET /icon/{filename}`. The channel column width is 125 px; ellipsis truncation is suppressed. `rebuildMenuEntries()` is now called unconditionally in `fetchAllGuides()` so `channelImageURLs` is always populated even when the menu is open at startup.
- **Web guide — tuner popup enrichment** — The tuner info popover now shows richer per-tuner rows: idle tuners display "Idle" instead of "? / Active stream"; our own recordings show a red ● dot, the show title, and "Ends H:MM AM/PM" from `show_end`; external live streams show the client IP, and after an async `GET /api/now-airing/{devId}/{ch}` fetch, display the guide title (clickable — scrolls guide to that show and opens its info panel), episode name, poster thumbnail, and end time. The popup is wider (max 400 px) with more padding.
- **Web guide — recording match improvement** — `recsByDevJS` now falls back to channel-number matching when `show_tuner_resource` is empty (first ~1.5 s of a new recording before the `X-HDHomeRun-Resource` header is captured). The resource comparison is also case-insensitive.
- **Web guide — `GET /api/now-airing/{devId}/{ch}`** — New endpoint; returns `{title, epTitle, poster, endTime}` for the currently-airing guide entry on the given device/channel. Used by the tuner popup for external stream enrichment.

## 2026-06-07 (260607-0011)

- **Recording — caffeinate replaced with direct curl + IOKit** — Recordings now spawn `/usr/bin/curl` directly via `posix_spawn` with `POSIX_SPAWN_SETSID` (no caffeinate wrapper). Sleep prevention uses `IOPMAssertionCreateWithDescription` (`kIOPMAssertPreventUserIdleSystemSleep`) keyed per show ID with a timeout of recording duration + 5 min; the OS auto-releases the assertion if the app crashes. `releaseAssertion(id:)` and `releaseAllAssertions()` provide explicit teardown. Watch Now (VLC) also acquires a `"vlc"`-keyed assertion sized to the guide entry end + 5 min, released explicitly on player close.
- **Recording stop — SIGKILL instead of SIGTERM** — `RecordingManager.stop()` now sends `SIGKILL` to the curl process. SIGTERM was silently ignored because the app sets `signal(SIGTERM, SIG_IGN)` for its DispatchSource handler, and `posix_spawn` inherits that disposition — making every previous stop call a no-op. SIGKILL cannot be caught or ignored. Confirmed: tuner is freed by the HDHR within ~1 second of delete/stop.
- **Recording stop — zombie reap** — After sending SIGKILL, `stop()` immediately calls `waitpid(pid, WNOHANG)` to reap the curl zombie if it has already exited, preventing zombie accumulation on long-running sessions.
- **Startup — orphaned curl processes killed on reattach** — `reattachRecordings()` now sends `SIGKILL` to any curl process whose `show_id` header doesn't match a current show in config (deleted while recording, config reset) or whose show end time is already past, rather than silently skipping it. Previously, such orphans held a tuner for their full original duration with no app-side tracking.
- **IOKit sleep assertion safety** — `preventSleep()` now checks the `kIOReturnSuccess` return value from `IOPMAssertionCreateWithDescription` and logs a warning on failure instead of storing an invalid assertion ID. `releaseAssertionsIfIdle()` safety net releases all tracked assertions when the device reports zero active streams, no recordings are active, and no VLC session is open — clearing any assertion that outlived its recording due to a crash or unexpected exit.
- **Idle loop — unexpected curl exit cleanup** — When the idle loop detects a show marked `show_recording = true` whose curl process has exited, it now calls `teardownRecordingState(index:)` (which includes `recordingManager.stop()`, IOKit assertion release, `tunerStatus` and `signalDropoutTicks` cleanup, and SSE broadcast) before reading the HDHR error header. Previously, the IOKit assertion, tuner status, and signal dropout state were leaked on unexpected exits.
- **Menu open guard** — `fetchDeviceStatus()` skips writing `deviceTunerOccupancy` and `tunerStatus` (and the vstatus fetch) while the SwiftUI menu is open (`menuIsOpen == true`). Writing `@Published` properties triggers a SwiftUI view rebuild that forces the menu to collapse. Signal alerting runs unconditionally regardless of menu state.
- **Series Up Next filter** — Series shows with no upcoming guide match (`menuScheduledEntry[show_id] == nil`) are now excluded from the **Up Next** menu section and remain only in **Scheduled**. Previously, unmatched series appeared in Up Next with a blank episode label.
- **Web guide — pending recording cells** — Guide blocks for shows that have passed `show_next` but whose idle-loop tick hasn't fired yet now appear red (recording-in-progress color) immediately after the web Record button is tapped, via `pendingRecChannelsByDevice`. The filter requires `!hdhr_record.isEmpty` to avoid false positives for shows without an assigned device.
- **Web guide — genre schedule colors** — Scheduled managed-show blocks now receive genre-based CSS classes (`.g-prog-sched.gg-news`, `.gg-sports`, `.gg-movie`, etc.) so they can be styled differently from the default teal.
- **Web guide — `refreshGuide(selOverride?)` patch** — `refreshGuide` accepts an optional attribute-patch dict; after the DOM swap it applies the overrides to the re-selected block's dataset before calling `showInfo()`. Used by the Record flow to patch `data-recording="1"` and update the info panel without a full reload.
- **Web guide — Record button becomes Stop & Delete** — After a successful Record API call, the modal's action button switches to "Stop & Delete" (danger styling) so the user can immediately cancel the recording without leaving the modal.
- **Web guide — `Permissions-Policy` header** — All HTTP responses now include `Permissions-Policy: geolocation=(), camera=(), microphone=(), interest-cohort=()` to suppress Safari's "Reduce Permissions" Advanced Tracking and Fingerprinting Protection banner, which was triggered by `Date.now()` calls in the guide JavaScript.

## 2026-06-03 (260603-2215)

- **LaunchAgent login item** — Settings → General now has a **Launch at Login** toggle backed by a `LaunchAgent` plist in `~/Library/LaunchAgents`; toggling immediately registers or unregisters the agent without requiring a restart.
- **`/api/ping` health endpoint** — New `GET /api/ping` returns `{"status":"ok","version":"..."}` for health checks and uptime monitoring. The redundant "All Tuners" device-switcher button removed.
- **Web guide — triangle flags and live tuner update** — Red triangle corner flags appear on guide blocks for managed shows that are currently recording. The tuner-count badge in the header updates immediately when a recording is started from the web UI, without requiring a page reload.
- **Cable guide — red recording triangle** — `ManagedFlagView(recording: true)` now draws a red filled triangle on shows that are actively recording, replacing the previous red dot decoration.
- **Summary panel — theme persistence fix** — The add-show wizard's summary panel now re-applies CSS variable colors when dark/light mode is toggled; previously it retained the initial theme's colors for the rest of the session.
- **ManagedGuideMatcher / ShowMatcher extraction** — Managed-show matching refactored from six parallel `Set` fields into two named structs: `ManagedGuideMatcher` (4-tier: seriesID, title, `dateTime` slot `device:channel:HH:MM`, `single` epoch `device:channel:epoch`) and `ShowMatcher` (seriesID + title, used for recording / nextUp / bonus). `GuideEntry` and `LineupEntry` now carry a stamped `deviceId`; `GuideEntry` carries `channelNum` — eliminating per-block lookups throughout the guide grid.
- **dateTime slot matching fix** — Weekly managed shows were not being flagged on the correct device+channel combination. `dateTime`-type matching now uses `device:channel:HH:MM` composite keys instead of bare time-of-day strings.
- **Web guide — day-of-week selector for weekly repeat** — Scheduling a weekly-repeat show from the record modal now shows a days-of-week row (same UI as the edit modal). The edit modal's days row no longer appears for `single` show type — it is shown only for `dateTime` (weekly). Deselecting to zero days is blocked in both modals.
- **Web guide — record modal redesign** — Record modal restyled to match edit modal: 400 px dialog, `em-row` / `em-lbl` / `em-input` CSS classes, CSS variable theming, "Record Show" header, border separators, in-place tuner-full feedback message (no separate alert dialog).
- **Web guide — transcode selector in record modal** — Record modal now includes a Transcode dropdown (None / Heavy / Mobile / Internet 720), matching the edit modal. The selection is passed in the POST body and applied when the show is created; `addShowFromGuide` accepts an optional `transcode:` parameter (nil → config default), leaving all existing call sites unchanged.
- **Web guide — schedule popup end time** — Recording entries in the hamburger schedule popup now show "· Ends HH:MM AM/PM" in the channel cell alongside the channel number and name.
- **Web guide — hamburger button position** — The status/hamburger button moved to the upper-left, adjacent to the page title.
- **Web guide — page title cleanup** — Removed the stray `·` separator from the `<title>` tag (was "hdhrVCR+ · Guide", now "hdhrVCR+ Guide").
- **Web guide — device header layout** — For a single device, the tuner badge and device link now appear on a second line below the `h1` title. For multiple devices, each device is its own horizontal row (name · link · tuner badge side-by-side) with rows stacked vertically; previously all devices shared one horizontal line.

## 2026-06-03 (260603-1501)

- **VLC stream counts as an occupied tuner** — the tuner-full gate in `startRecording` now adds `VLCPlayerWindowManager.shared.currentDeviceID == deviceId ? 1 : 0` to the recording count before comparing against `TunerCount`. Previously, watching live TV via the in-app player consumed a tuner the scheduler couldn't see, causing a second recording to start, receive an 805 "All Tuners In Use" error from the device, and spin in a fail→retry loop. New helper `AppState.tunersFull(for: deviceId)` encapsulates the combined check and is reused by the WatchNow guard below.
- **WatchNow Record button — tuner-full block** — clicking **Record** on a currently-airing show now calls `tunersFull(for:)` first; if all tuners are busy it shows an alert ("All Tuners Busy — free a tuner first") and does **not** open the Add Show window. Shows not currently on air are unaffected — their window opens normally since tuners may be free by airtime.
- **Stop-recording PGID fix** — `RecordingManager.stop()` was sending `kill(-caffenatePID, SIGTERM)` intending a process-group kill, but on macOS `caffeinate` joins the curl child's process group after forking, so the actual PGID equals the curl PID, not the caffeinate PID. Changed to direct `kill(caffenatePID, SIGTERM)` and `kill(curlPID, SIGTERM)` — both processes are killed individually and reliably. Deleting a currently-recording show (via UI or web endpoint) now always tears down the recording.
- **Reattach captures curl PID directly** — `reattachRecordings()` already iterates `ps -Axo pid,args` at startup; it now matches both caffeinate and curl lines in the same pass and calls `recordingManager.reattachCurlPid(showId:pid:)` for the curl process. This replaces the async `pgrep -P caffeinate_pid` approach that was unreliable when the PGID mismatch was present. Log now shows both PIDs: `[Startup] Reattached 'Title' caffeinate=N` and `[Startup] Reattached 'Title' curl=N`.

## 2026-06-03 (260603-1011)

- **Web edit modal — type-change reschedule** — changing a show's type to seriesChannel or seriesAll from the web UI now immediately triggers `rescheduleAllSeries()` so the guide is searched right away; previously `show_next` was left at the old single-episode timestamp until the next guide refresh.
- **Web edit modal — save-directory sync** — editing the save directory now always updates `show_temp_dir` to match; the old guard (`if show_temp_dir.isEmpty`) meant a second edit left `show_temp_dir` stale, writing in-progress recordings to the original path.
- **Web edit modal — day picker deselect-all fix** — in single-episode mode, clicking the already-selected day button no longer deselects it (leaving zero days selected and wiping `show_air_date` on Save); the clicked button always remains selected.
- **Web delete — channel-required fallback** — the title-match fallback in `handleDelete` no longer accepts a series show as a match by title alone regardless of channel (`|| $0.isSeries` removed); both series and non-series shows now require a channel match, preventing wrong-show deletion when two shows share a title.
- **Series bump interval** — when no guide episode is found for a series show, `show_next` is now bumped by `Series_scan_retry_hours` (not `GuideHours`); the shorter interval means the idle loop retries sooner and the bump window is consistent with the manual rescan setting.
- **Rescan Series count fix** — the "Rescan Series" maintenance row now excludes currently-recording shows from its reported count, matching the `!show_recording` guard in `rescheduleAllSeries()` that was already skipping them.

## 2026-06-02 (260602-sparkle)

- **Sparkle auto-updater** — `SPUStandardUpdaterController` integrated; Settings → About now has a **Check for Updates** button that opens Sparkle's standard update panel. The in-changelog version comparison and manual "Update available" banner have been removed in favour of Sparkle handling all update discovery and installation. `SUFeedURL` in Info.plist points to the repo's `appcast.xml`; `SUPublicEDKey` is set to the EdDSA public key matching `~/.sparkle_private_key` (generated once by `tools/generate_sparkle_keys.sh`). `deploy.sh` and `deploy_release.sh` updated to bundle and sign `Sparkle.framework` (including its nested XPC services and `Updater.app`) inside-out before signing the main bundle.
- **Sparkle — `SUPublicEDKey` placeholder crash fix** — Sparkle aborts the process if `SUPublicEDKey` is missing or not a valid EdDSA key. Replaced `SPARKLE_PUBLIC_KEY_PLACEHOLDER` with the real public key from the pre-existing `~/.sparkle_private_key`. `generate_sparkle_keys.sh` parser updated to handle Sparkle's "pre-existing key" output format.
- **Web server settings** — New **Settings → Web Server** panel: enable/disable toggle, port field (validated 1025–65534), live status and access URL (shown only when running). Saving changed web server config calls `setupWebServer()` immediately to start/restart/stop the listener. Port validation blocks Save and `WindowCloseInterceptor` with a consistent error message alongside the existing Discord webhook check.
- **`com.apple.security.network.server` entitlement** — Added to `hdhrVCRplus.entitlements` so `NWListener` can bind under Hardened Runtime. Without it the listener silently failed to start when the app was launched via `open`.
- **`NSLocalNetworkUsageDescription`** — Added to `Info.plist` for the NWListener mDNS service advertisement (required for macOS local network privacy prompt to appear).
- **deploy.sh — iCloud `com.apple.FinderInfo` race fix** — `codesign --options runtime` rejects `com.apple.FinderInfo` as "detritus"; iCloud Drive re-attaches this xattr to Sparkle's nested executables faster than a retry loop can strip it. The signing step now works in a `/tmp` copy of the bundle (outside iCloud Drive), then replaces the in-repo bundle with the freshly signed copy.
- **Web server — early startup** — `setupWebServer()` moved to run right after `loadConfig()` in `startup()`, before device discovery and guide fetch. The server binds the port within ~1s of launch instead of waiting 10–20s for the full startup sequence.
- **AppState.onAirNow(for:at:)** — Extracted the on-air channel lookup from `WatchNowView` into a shared method; also used by `WebServer.buildNowJSON` to avoid duplicating the lineup × guide walk.
- **Shared helpers** — `timeRemaining(until:)` and `he()` (HTML entity escaping) moved from `WatchNowView` / `WebServer` into `GuideViewHelpers.swift` as free functions.

## 2026-06-02 (260602-webserver)

- **Web server — multi-device Recording badge fix** — `recChannels` was a flat set of channel numbers across all devices, so a recording on device A incorrectly showed the red ● Recording badge on device B's same channel number in the guide grid. Replaced with `recChannelsByDevice: [String: Set<String>]` keyed by device ID; `isRecCh` now checks only the current device's recording channels.
- **Web server — paused-show badge alignment** — `buildNowJSON`'s `isScheduled` field was querying `managedShowBySeriesID`/`managedShowByTitle` (which include paused shows) while the guide HTML's ★ badge logic excluded paused shows via `activeMgd`. Added `!show_paused` guards to both checks in `buildNowJSON` so the JSON API and the guide grid agree on managed-show status.
- **Web server — `</script>` injection prevention** — `JSONSerialization` does not escape `<`, `>`, or `&` by default; a show title containing `</script>` would terminate the script block in the served page. Added `jsEscapeForScript()` (replaces `<`/`>`/`&` with `\uXXXX` escapes) applied to both `var tuners` and `var recsByDev` before embedding in the `<script>` block. `tunerJS` also moved from raw string interpolation to `JSONSerialization` so DeviceID and LocalIP values are never interpolated directly into JS string literals.
- **Web server — tuner popover innerHTML XSS fix** — `showTunerInfo()` was concatenating `r.title`, `r.ch`, `r.chname`, and `r.tuner` directly into `innerHTML`. Added client-side `hej(s)` helper (escapes `&`, `<`, `>`) and applied it to all four values.
- **Web server — onclick JS injection fix** — device filter buttons and tuner badge buttons now use `onclick="setDev(this.dataset.dev)"` / `onclick="showTunerInfo(this.dataset.dev,this)"`, reading DeviceID from the already-`he()`-escaped `data-dev` attribute rather than interpolating it into a JS string argument.
- **Web server — IPv4-mapped loopback** — `isLocalAddress()` now strips the `::ffff:` prefix before the loopback check so `::ffff:127.0.0.1` (IPv4-in-IPv6 localhost connection) is correctly allowed without falling into the AF_INET6 subnet walk.
- **Web server — 128 KB request cap** — `accumulate()` now rejects any connection whose total buffered bytes exceed 128 KB (or whose `Content-Length` header declares more) with `413 Content Too Large`, preventing memory exhaustion from slow or malicious LAN clients.
- **Web server — O(n²) buffer copies fixed** — `let data = buffer + chunk` allocated a full copy of the accumulated buffer on every receive callback. Changed to `var data = buffer; data.append(chunk)` so Swift reuses existing storage capacity; a 128 KB request arriving in small chunks now copies each byte once instead of ~4 MB total.
- **Web server — `\r\n\r\n` separator static constant** — the HTTP header separator `Data` was re-created from a string literal on every `conn.receive` callback. Promoted to `private static let httpSep`.
- **Web server — `recordingShows` captured once per render** — `state.recordingShows` (a computed `shows.filter` property) was accessed six times inside `buildHTML`. Captured as `let recording = state.recordingShows` at the top of the function.
- **Web server — single-pass isSeries filter** — `activeMgd.filter { $0.isSeries }` was called twice to build `mgdSID` and `mgdTitSeries`. Merged into a single `for s in activeMgd where s.isSeries` loop.
- **Web server — Watch Now avoids redundant guide walk** — `state.onAirNow(for:)` was performing a full lineup × `guideStore.entries` walk that the guide grid loop had just completed for every channel. Now `nowByDevice` is populated in-place during the grid pass (`if isNow { nowByDevice[device.DeviceID, default: []].append((ch, e)) }`); the Watch Now section iterates this dict directly.
- **Web server — `pct()` uses integer arithmetic** — the percentage-position formatter called `String(format: "%.4f", ...)` for every guide block's left and width positions (~1500 calls per full-guide render). Replaced with integer multiply/divide and manual digit extraction; no `String(format:)` at all in the hot loop.
- **Web server — removed dead `.redirect` case** — `WebResponse.redirect` was defined and handled in `send()` but never returned by any route handler. Removed.

## 2026-05-31 (260531-1950)

- **Exact tuner identity from `X-HDHomeRun-Resource` header** — reuses the existing `--dump-header` file from the X-HDHomeRun-Error feature; `RecordingManager.readHDHRResource()` peeks at the file 1.5s after recording starts (without deleting it) and stores the result as `show_tuner_resource` on `Show`; `fetchDeviceStatus` now targets `/tunerN/vstatus` directly via this value instead of searching by channel number, eliminating the ambiguous-match problem when two shows share the same channel

## 2026-05-31 (260531-1930)

- **About logo signal pulse** — tapping the app icon in Settings → About fires three concentric rings that expand outward and fade, staggered 150 ms apart, like a broadcast signal radiating from the icon; replaces the old 5-tap easter egg (Watch Now is no longer gated)

## 2026-05-31 (260531-1720)

- **Discord embed recovery on restart** — at startup, `reattachRecordings()` now checks every show that has a `discord_start_msg_id` but wasn't reattached as actively recording; if the output file exists with size > 0 it sends a "✅ Recording Complete (before restart)" PATCH, otherwise a "⚠️ Recording Interrupted" PATCH; the ID is cleared before the network call so a crash during send can't re-trigger on the next launch

## 2026-05-31 (260531-1710)

- **Watch Now poster images appear instantly** — `prefetchPosters()` now calls `ChannelIconCache.allCachedImages(for:)` first (single actor hop) to populate the local cache from everything already in memory, then fetches any disk/network misses concurrently via `withTaskGroup` instead of awaiting each image serially; previously 20 channels = 20 sequential waits even when all icons were cached

## 2026-05-31 (260531-1700)

- **`X-HDHomeRun-Error` header parsing** — `RecordingManager` now passes `--dump-header /tmp/hdhrVCRplus-<showId>.headers` to every curl recording. When curl exits unexpectedly mid-recording, `AppState` reads the header file via `readAndClearHDHRError(showId:)` and maps the error code to a human-readable string (e.g. "Tuner In Use (804)", "No Video Data (807)", "DVR Full (810)"). The precise reason replaces "curl exited unexpectedly" everywhere it appears: `show_fail_reason`, the system notification subtitle, and the Discord embed `Reason` field. Falls back to "curl exited unexpectedly" if no `X-HDHomeRun-Error` header was written (connection-level failures). Header file is cleaned up on both stop and read.
- **Native Markdown changelog** — Settings → About replaces the hand-parsed `renderChangelog()` `@ViewBuilder` with a `MarkdownView: NSViewRepresentable` backed by `NSTextView` + `AttributedString(markdown:options: .init(interpretedSyntax: .full))`. Delivers proper heading sizes, real bullet lists, inline code, and bold text. Height is self-measured via `layoutManager.usedRect(for:)` after each layout pass and injected as `.frame(height:)` so the view grows with content.

## 2026-05-31 (260531-1625)

- **VLC error overlay** — when VLC hits a fatal stream error (connection refused, no route to host, etc.), an orange triangle + "Stream Unavailable" overlay appears within ~3 seconds instead of a silent black screen; a Retry button restarts the stream. Powered by `libvlc_media_player_get_state` (state 7 = `libvlc_Error`) polled each rate-controller tick.
- **Start button gating** — the poster overlay's Start button now shows a spinner + "Connecting…" (disabled) until VLC confirms `libvlc_Playing` (state 3); prevents unmuting a stream that hasn't connected yet. `VLCBridge` publishes `isPlaying: Bool` updated each tick.
- **MPEG-2 audio init fix** — added `--no-audio-time-stretch` media option to prevent the `too low audio sample frequency (0)` crash that occurs on live MPEG-2 streams before the first audio frame arrives.
- **Real-time tuner occupancy refresh** — `AppState.refreshTunerOccupancy()` polls `/status.json` 1.5 s after any tuner-affecting event (recording start/stop, VLC open/close, channel switch) so the menu header count updates promptly instead of waiting for the next idle-loop tick (~10 s).
- **Tuner count includes VLC player** — the "app expects N" figure in the menu header now counts the VLC player as +1 tuner on its device; recording one show while watching = "app expects 2".
- **Now Watching section** — moved below the Settings divider, directly above Recording Now; wrapped in a `Section("Watching · <deviceID>")` header matching the style of Recording Now / Scheduled.

## 2026-05-31 (260531-1324)

- **Tuner audit log** — `fetchDeviceStatus` now logs `[TunerAudit] DEVID: N/M active  rec=N vlc=N` every idle tick (~10s), making unexpected tuner usage immediately visible in the log without manual status endpoint polling
- **VLC stop on quit** — `quit()` now calls `VLCBridge.shared.stop()` in all three exit branches (fast-quit, Keep Recording & Quit, Stop Recordings & Quit) so the in-app player releases its tuner immediately on app exit rather than relying on OS-level cleanup

## 2026-05-31 (260531-1212)

- **Immediate channel buffering** — `playChannel` now calls `VLCBridge.play()` immediately when the channel picker changes so the new stream starts buffering the moment the poster overlay appears; tuner status check moved to a fire-and-forget background Task that logs results without blocking stream start
- **Now Watching tracks channel switches** — `state.vlcCurrentURL` is now updated by `playChannel` (picker-driven switches), not only by `watchInApp`, so the Now Watching indicator stays accurate after switching channels inside the player
- **Start button logs buffer depth** — clicking Start to dismiss the poster overlay logs `[VLC] Start clicked — buffer ~X.Xs built before unmute` showing how much headroom accumulated while the poster was visible
- **Post-switch tuner log** — after each channel switch, `playChannel` fetches `status.json` and logs `[VLC] post-switch tuner status ch X.X: N/M active (ours=N other=N)`; warns if other streams appear to have taken all slots
- **VLC diagnostic logging** — comprehensive `[VLC]` log lines throughout `VLCBridge` and `VLCPlayerView` to diagnose the black-screen issue: `play()` logs URL and warns when deferred to pending (drawable not ready); `stop()` logs drawable state at call time; `setDrawable()` logs view identity and pending-URL handoff; `catchUpToLive()` logs the reconnect URL; `syncChannel()` logs match result; `playChannel()` logs channel + URL; `WindowManager.open` logs reuse vs new window; remote Stop command (media key / Now Playing) logged as the likely black-screen cause — clears `drawableView`, leaving window black until closed

## 2026-05-31 (260531-0239)

- **Close VLC player on show delete/skip** — deleting or skipping a show now closes the in-app VLC player window if it is currently streaming that show's URL, freeing the tuner immediately alongside the recording PID kill; uses `VLCPlayerWindowManager.closeIfPlayingURL(_:)` — exact URL match, no-op when the player is on a different channel
- **URL match fix** — `nowWatchingInfo` channel lookup now uses exact URL equality instead of a bidirectional prefix check, preventing false matches when one channel URL is a prefix of another (e.g. `v5.1` matching when watching `v5.10`)
- **Now Watching indicator** — when the VLC player is open, a `play.tv.fill` button appears in the menu between the status row and Watch Now showing the current channel number, name, and on-air show title (e.g. "Ch 5.1  NBC · Jeopardy!"); clicking it focuses the player window without switching the stream. Disappears automatically when the player window is closed.
- **VLCPlayerWindowManager.focus()** — new method that brings the player window to the front without affecting the stream; used by the Now Watching button and available for future callers
- **Player window clear on close** — `vlcCurrentURL` is now cleared to `""` when the VLC player window is dismissed, ensuring the Now Watching button never lingers after the player is gone

## 2026-05-31 (260531-0223)

- **Native resolution button** — `aspectratio` icon in VLC player toolbar; calls `libvlc_video_get_size`, divides by screen backing scale, and resizes the window to display video at 1:1 physical pixels; no-op until the first frame is decoded
- **Buffer monitor icon** — `waveform` SF Symbol added to the left of the fill bar; color tracks fill state (accent while filling, green when full)
- **Speed up to live** — catch-up button updated to `forward.end.circle` icon with tooltip "Speed up to live — discard buffer and jump to live edge"
- **Native resolution** — `videoNativeSize()` added to `VLCBridge` via `libvlc_video_get_size`; `VLCPlayerWindowManager.sizeToNativeVideo()` handles window resize

## 2026-05-31 (260531-0157)

- **Buffer monitor** — `waveform` icon + fill-bar capsule in VLC player toolbar (visible only when buffering enabled); fill = lag / 8s, blue while filling, green when full (≥ 7s); hover popover shows lag, rate, bitrate, and corruption count. `VLCBridge` made `ObservableObject`; `VLCBufferInfo` published every 3s; rate/lag published unconditionally before stats guard so bar works on VLC 4+
- **Watch Now focus-or-open** — clicking Watch Now in the menu now brings the existing window forward if already open, matching Add Show / Edit Show / Settings behaviour

## 2026-05-31 (260531-0137)

- **Proportional poster images** — Watch Now thumbnails are now ~50% larger (34% of window width, capped at 220pt, aspect-ratio locked at 96:68) and scale with window resize instead of being fixed at 96×68pt; VLC player poster overlay scales to 30% of the player window width instead of a hardcoded 300pt

## 2026-05-31 (260531-0001)

- **Buffered live TV playback** — the in-app VLC player now builds and maintains an ~8-second live buffer to absorb brief signal drops invisibly. Uses an adaptive rate controller: starts at the user-configured floor rate (default 93%), ramping toward 100% as the buffer fills over ~3 minutes, then holds at 1.0× to maintain the lag. `--drop-late-frames` and `--avcodec-hurry-up` tell VLC to drop corrupt/late frames rather than showing artifacts.
- **Auto catch-up on bad signal** — polls `libvlc_media_player_get_stats` every 3 seconds; if `i_demux_corrupted` rises by >15 or `i_lost_pictures` rises by >20 in a single tick, the stream restarts at the live edge automatically (30s debounce). The rate controller resets and the fill phase begins again.
- **Catch Up button** — `⟳` button in the VLC player toolbar; discards buffered content and reconnects at the live edge on demand without showing the poster overlay or requiring a Start click.
- **Min buffer rate setting** — Settings → Recording → Min buffer rate picker (90%–100%, default 93%). Sets the floor speed during the fill phase; 100% disables buffering entirely while keeping the Catch Up button functional.
- **Buffering diagnostics** — VLC version logged at startup; WARNING if VLC 4+ detected (stats struct changed); rate acceptance verified after `set_rate` and logged as WARNING if ignored; stats call failures logged; rate ramp ticks logged to `hdhrVCRplus.log`.
- **Discord progress updates** — new "Progress updates (every 5 min)" toggle in Settings → Discord. When enabled, the Recording Started embed is edited in-place every 5 minutes with elapsed and remaining time (e.g. "32m elapsed · 28m remaining"). Completion and failure events also edit the same message rather than posting a new one, so each recording produces a single Discord message that tracks its full lifecycle. Uses `?wait=true` capture on the start embed and `PATCH /messages/{id}` for edits.

## 2026-05-30

- **Code modularization** — extracted duplicated helpers from AddShowView, FloatingGuideView, MenuContent, and CableGuideView into a shared `GuideViewHelpers.swift`: `ManagedFlagView` (yellow corner triangle), `sortedGuideChannels(_:favorites:)`, `guideTimeRange(_:)`, and shared DateFormatters (`origAirdateFormatter`, `upcomingFormatter`, `timeRangeFormatter`). `GuideEntry.episodeInfoLabel` moved to a Models.swift extension. `bonusOverlapWarning` moved to AppState. Show failure field mutations consolidated into `Show.recordFailure(reason:)` and `Show.clearFailures()`. Guide API backoff+notify logic deduplicated into `handleGuideLoadFailure(deviceId:)`. Net: −139 lines, no behaviour changes.
- **vstatus log removed** — "no locked tuner found in status.json" warning suppressed; it fired spuriously when the tuner released between recording end and the vstatus poll
- **Bonus overlap display fix** — overlap minutes now floor at 1 so sub-60-second overlaps never display as "First 0 min overlap"
- **Bad config repair** — four shows had a stale Mac alias path (`Raid6:DVR Tests:`) as `show_temp_dir`; updated to `/Volumes/Raid6/DVR Tests` to match all other shows

## 2026-05-29 (260529-1620)

- **Recording Started notification end time** — notification now shows the correct end time when Bonus Time is active (was showing the un-padded guide end instead of the extended time)
- **Tuner signal sub-channel fallback** — signal data now falls back to any locked tuner when the channel number format in status.json doesn't match exactly — fixes missing signal strength on some sub-channel configurations
- **Config v2 migration failure logging** — migration failure (e.g. disk full) now logs a warning instead of silently retrying on every launch

## 2026-05-29 (260529-1534)

- **Config format v2** — dates now stored as ISO8601 strings ("2026-05-30T21:00:00Z") instead of string epochs; existing configs auto-migrate on first launch
- `"the_shows"` JSON key renamed to `"shows"`; Mac alias path conversion removed; Int/Double type ambiguity in `show_length`, `show_fail_count`, and `Min_disk_free_gb` eliminated

## 2026-05-29 (260529-1432)

- **VLC player mute-until-Start** — audio is now muted until Start is clicked; stream buffers silently; Start restores saved volume; volume persists across sessions
- **Conflict indicator** — a scheduled show overlapping an already-recording show now correctly gets the conflict triangle (was limited to scheduled-vs-scheduled)
- **Default recording folder** — `~/Movies/hdhr_videos` consistently (was `~/Documents/hdhr_videos` or bare `~/Movies` depending on code path)

## 2026-05-29 (260529-1145)

- **Deactivating a show deletes it immediately** — no more "inactive" limbo state that was lost on restart
- **Fail→pause→resume loop fixed** — fail count is now cleared on auto-resume so a show doesn't re-pause immediately
- **CableGuideView lineup dict** — built once per render instead of once per channel row; smoother scrolling on large lineups
- **CableGuideView time-slot formatter** — promoted to a static instance; eliminates repeated `DateFormatter` allocation during guide scroll
- **WatchNowView guide entry** — resolved once per channel per refresh instead of twice; halves guide lookups on each 30s tick
- **UDP discovery EINTR** — `EINTR` no longer terminates the receive loop early; transient signal interrupts are retried

## 2026-05-29 (260529-0957)

- **VLC player poster overlay** — stream buffers silently on open; poster + title + synopsis fill the video area until Start is clicked, then fades to live video; poster reappears on channel change
- **Tuner conflict notifications** — fire once per show+episode window, not every idle tick; eliminates per-tick spam when a show can't start due to a full tuner
- **Discord send logging** — Discord sends now log success or failure to `hdhrVCRplus.log` for easier webhook debugging
- **Menu header device warnings** — consolidated inline: "DEVID 0/4  ⚠ no lineup, no guide" in orange instead of separate warning rows below each device

## 2026-05-29 (260529-0830)

- **Changelog reads from bundle** — Settings → About now reads the bundled changelog instead of fetching from GitHub
- **Mock HDHomeRun tool** — `DeviceAuth` background refresh thread keeps fallback cache current; proxy logging for lineup/guide/status requests; `--auth-refresh` flag

## 2026-05-29 (260529)

- **Consolidated logging** — all log output (guide, curl, app) written to a single `~/Library/Logs/hdhrVCRplus.log`
- **DeviceAuth refresh** — cloud token refreshed every 5 minutes via device probe; guide no longer goes stale after long uptimes on EXTEND devices
- **Recording stop before start** — recording stops are now guaranteed to complete before new recordings start on the same tick, preventing tuner-count races at show boundaries

## 2026-05-28 (260528-2055)

- **Menu header live tuner occupancy** — polled from `status.json` each idle tick; shows real active/total count; flags count mismatch vs app's expected recording count
- **Device health warnings** — orange warnings (no lineup, no guide) after startup; unhealthy devices excluded from the "N tuner(s) ready" status count
- **Guide summary poster clipping** — now correctly clipped with `clipShape(RoundedRectangle)` — content no longer bleeds past rounded corners

## 2026-05-24 (260524-0119)

- **Discord webhook notifications** — Settings → Notifications → Discord Webhook; paste a webhook URL to send rich embeds to any Discord channel. Per-event toggles (enabled by default): Recording Started, Recording Complete, Recording Failed, Show Paused, Skipped (Disk Full), Tuner Conflict, Guide Load Failed. Off by default: Up Next, Recording Soon, Show Added. Each toggle has a **Test** button that fires a live embed to the draft URL using real show data without saving. Embeds include: station icon (`author.icon_url` from guide channel image), show poster thumbnail, bold title + episode number/title + synopsis, Channel/Type/Time inline fields, filter tags as `` `Drama` `` `` `Series` `` code buttons, and event-color sidebar (green=started, blue=complete, red=failed, orange=paused/skipped, yellow=conflict, teal=added, purple=reminders, grey=errors). Recording Complete embeds additionally show **Format** (file extension, e.g. `TS`) and **File Size** (e.g. `2.34 GB`) inline fields from the actual output file. Blank or non-discord.com URLs are silently skipped.
- **Watch Now! ungated** — the VLC in-app player "Watch Now!" button no longer requires the `Player_unlocked` easter egg; it appears whenever VLC is installed at `/Applications/VLC.app`
- **Tuner availability check** — clicking "Watch Now!" fetches live `/status.json` from the device and shows an alert if all tuners are occupied; channel switching in an already-open player window bypasses the check since that window already holds a tuner slot
- **Channel picker sync** — the channel picker in the VLC player window now syncs to the channel you clicked "Watch Now!" from; switching channels while the window is open also updates the picker; `suppressNextChannelPlay` flag prevents a redundant second play call on sync-driven selection changes
- **Settings: Save & Close as default** — Save & Close is now the rightmost, prominent (`.borderedProminent`) button in the Settings footer, triggered by Return; Save (⌘S) is secondary and only enabled when dirty; Save & Close is always enabled (just closes when nothing is dirty)

## 2026-05-23 (260523-1751)

- **Config moved to Application Support** — config file relocated to `~/Library/Application Support/hdhrVCRplus/hdhr_VCR-{hostname}.json`; ad-hoc re-signing during development no longer resets TCC permissions and clears all shows; one-time migration from `~/Documents` runs on first launch, old file preserved for AppleScript app compatibility
- **Unbuffered log output** — `setbuf(stdout/stderr, nil)` applied after `freopen`; every `print()` line now lands on disk immediately instead of buffering in 8 KB chunks
- **Cable guide vertical scroll sync** — replaced `.onScrollGeometryChange` (fires only on SwiftUI re-evaluation, not AppKit layer scroll) with `VerticalScrollTracker: NSViewRepresentable`; embeds a zero-size `NSView` that hooks `NSView.boundsDidChangeNotification` on the enclosing `NSScrollView`, firing on every scroll frame
- **Guide summary poster fills panel height** — poster image is now `frame(width: 180).frame(maxHeight: .infinity)` (was `frame(width: 140, height: 100)`); channel icon enlarged to 52 pt
- **Stale channel icon cleared** — `ChannelIcon` now sets `img = nil` when `urlString` changes to nil/empty; switching from a channel with a logo to one without no longer shows the previous channel's logo
- **Wizard SeriesID scheduling fixed** — `save()` now calls `resolveSeriesAir()` before `addShow()`, matching the menu-flow; selecting a future airing now correctly schedules from the current (or nearest) episode
- **"Watch in App" gated on onAir** — button only appears when the selected show is currently broadcasting, consistent with "Watch in VLC"; applies in both the guide summary panel and `entryMenu()`

## 2026-05-23 (260523-1212)

- **Prevent duplicate scheduling** — the guide wizard and menu-mode Add Show now detect already-managed shows (matched by SeriesID, falling back to title) and replace the Record button / record menu items with an "Edit Show" action; you can no longer accidentally create a duplicate entry for a show already in your schedule; clicking "Edit Show" opens the existing show directly in EditShowView
- **Record/Edit button layout stability** — the button is now a single SwiftUI `Button` view with a fixed minimum width (90 pt) that switches label and color in place; previously two separate `if/else` views caused the Spacer to relax and the channel-time text to shift when clicking between managed and unmanaged shows
- **Overlap warning layout stability** — the bonus-time overlap warning text in the guide summary panel is always in the layout (opacity 0 when absent) so the button row above it stays at a fixed vertical position when switching between shows that do and don't trigger a warning
- **Per-show bonus time flag** — `show_bonus_time: Bool` added to `Show`; any show type can now opt into the recording extension, not just shows whose genre contains "sports"; existing config files migrate automatically (genre-based detection used as the decode fallback)
- **Bonus-time overrun box redesign** — the dotted overrun box in the cable guide is now filled with the bonus show's genre color (70% opacity) instead of just a colored outline; the overlapped show's title is displayed inside the box; the box is tappable and selects the overlapped show in the summary panel
- **ShowFormSection extracted** — title, type, days/day, transcode, and folder picker rows extracted into a shared `ShowFormSection` component; used by both the Add Show details step and EditShowView, eliminating ~80 lines of duplication
- **Starburst badge in details step and EditShowView** — the animated starburst badge now appears when `show_bonus_time` is true in both the Add Show details step and EditShowView; removal uses a shrink+fade transition

## 2026-05-22 (260522-2057)

- **Multi-selection bug fixed** — selecting a show in the cable guide no longer highlights every block at the same start time across all channels; caused by Swift's `nil == nil` evaluating to `true` when lineup data was absent — `ShowBlocksRow` now requires `lineupEntry != nil` before comparing `GuideNumber`
- **Record and Watch in VLC buttons now reliably enabled** — `AppState.ensureLineupLoaded(for:)` re-fetches lineup on demand if `lineups[deviceID]` is nil or empty (recovering from silent `try?` failures in `fetchAllLineups`); called at the start of guide loading in both `AddShowView` and `FloatingGuideView`, guaranteeing `selectedChannel` resolves correctly before the guide grid populates
- **FloatingGuideView lineup fix** — the floating cable guide was clearing `state.lineups` on device change, leaving `selectedChannel` permanently nil and disabling both buttons; lineup is now stable across device changes (only the guide cache is invalidated)
- **StarburstBadge** — extracted starburst animation into a standalone reusable `StarburstBadge` component (`StarburstBadge.swift`); uses two stacked `keyframeAnimator` modifiers for a pop-in animation on appear and a 5-tap celebration spin; used in AddShowView details step, AddShowView summary panel, and FloatingGuideView summary panel
- **macOS 14 minimum** — deployment target raised from macOS 13 to macOS 14; `EmptyStateView` simplified to call `ContentUnavailableView` directly; `keyframeAnimator` (macOS 14+) now available without availability guards

## 2026-05-22 (260522-1600)

- **Discard resets OS-sim picker** — the Discard button in Settings now correctly reverts the OS simulation picker to its saved value (was missing from the reset list, causing `isDirty` to stay true permanently after touching the picker then discarding)
- **Stale-interface clear propagates to live config** — when Settings opens and detects a disconnected interface (e.g. VPN dropped), it now clears `Network_interface` in both the draft AND the live `AppConfig` and saves immediately; previously only the draft was cleared, so Discard-and-close left the dead interface name active for all subsequent curl recordings, causing every recording to fail silently
- **`refreshGuides()` guards concurrent runs** — added an in-flight flag so the idle loop and an interface-change Save can't both enqueue a `refreshGuides()` simultaneously; the second call returns immediately rather than racing through guide invalidation and rebuild at interleaved await points
- **`refreshGuides()` retry on empty load** — `lastGuideRefresh` is now only stamped when at least one channel was actually loaded, matching `fetchAllGuides()`; previously a refresh that found no devices (e.g. right after a VPN reconnect) would suppress the next periodic retry for up to 12 hours
- **`if_nametoindex` failure logged** — when the UDP socket can't resolve a configured interface name to an index, a `[Discovery]` log line is printed instead of silently falling back to the OS default route

## 2026-05-22 (260522-1530)

- **All new settings require Save** — the OS simulation picker in Maintenance → Developer now follows the draft/save pattern; changing the picker marks Settings as dirty (Save button turns orange) but does not apply until Save is clicked; Discard reverts the draft; the existing `isDirty` banner and ⌘S shortcut work as expected
- **Interface change triggers refresh** — switching the "Discovery & recording interface" in Settings → Advanced and clicking Save automatically invalidates the guide cache, clears loaded device channels, re-runs device discovery (so UDP binds to the new NIC), and reloads the guide; the new interface is fully active immediately without restarting the app

## 2026-05-22 (260522-1500)

- **Network interface binding** — Settings → Advanced → "Discovery & recording interface" picker; binds UDP device discovery and curl recordings to a specific NIC; "Auto" uses OS routing (default); VPN tunnels (utun*, tun*, cscotun*, gpd*, zt*, etc.) are listed alongside physical interfaces, each labelled with its current IP address; tunnel detection uses the kernel's `IFF_POINTOPOINT` flag so all VPN types are caught regardless of vendor naming
- **VPN recording support** — when a VPN tunnel interface is selected, UDP broadcast is automatically skipped (tunnels don't support broadcast); known-hosts discovery (device IPs from saved shows) handles remote device lookup; curl stream is explicitly bound to the tunnel; enables recording from an HDHomeRun on a remote network via any standard VPN
- **OS simulation picker default** — Maintenance → Developer picker now shows "macOS X (current)" as the pre-selected default on first launch; stored as sentinel 0 so the AppStorage default always matches a picker tag (eliminates blank-picker flash on first open)
- **Stale interface auto-clear** — on Settings open, if the saved `Network_interface` names an interface that is no longer available (e.g. VPN disconnected), it is silently reset to Auto so a Save can't persist a value that breaks every recording
- **Changelog version filtering** — Settings → About now shows only the changelog sections up to the running build version; if a newer version exists in the fetched changelog, an "Update X is available" notice with a Releases link is shown above the changelog

## 2026-05-22 (260522-1342)

- **Pop-out cable guide** — toolbar button in the guide step opens the cable guide as a standalone floating window; Escape closes it; duplicate presses re-focus the existing window instead of opening a new one; browse-only (no Record button)
- **Homebrew install buttons** — Settings → Maintenance shows a Tools section when Homebrew is installed; buttons to install VLC (`brew install --cask vlc`) and the HDHomeRun CLI (`brew install libhdhomerun`); buttons replaced by a green "Installed" checkmark when the tool is already present
- **Stop Recording confirmation** — clicking Stop Recording now shows an NSAlert ("Stop & Deactivate / Keep Recording") to prevent accidental permanent deactivation
- **Delete confirmations** — Delete in scheduled menus, paused menus, and Edit Show now shows an NSAlert before permanently removing a show
- **Edit Show close warning** — closing Edit Show with unsaved changes prompts Save / Discard / Cancel, matching the Settings window behaviour; uses the same `WindowCloseInterceptor` pattern
- **Bonus Time callout in recording menu** — when a sports show is recording past its guide end time, a "🏈 Bonus Time (+N min)" info line appears in the recording submenu; remaining time now reflects the padded end, not the guide end
- **Paused show context** — paused show submenus now show show type and channel at the top, not just the last error reason
- **Notification timing validation** — Settings → Notifications shows an orange warning when the Recording alert interval is ≥ the Up Next interval, preventing a silent broken notification sequence
- **Clear Guide Cache** — new button in Settings → Maintenance discards all cached guide data immediately without requiring a restart
- **App icon** — `app.jpg` converted to `AppIcon.icns` (all required sizes, dark-padded square) and declared as `CFBundleIconFile`; the app bundle now shows the logo in Finder; `NSApplication.shared.applicationIconImage` set on launch so Force Quit and Activity Monitor also display it; `deploy.sh` regenerates the icns from `Resources/app.jpg` on every deploy
- **macOS 13+ compatibility** — deployment target lowered from macOS 15 to macOS 13 (Ventura); `onScrollGeometryChange` replaced with a version-adaptive `View.onScrollOffset` extension that uses the native API on macOS 15+ and a `PreferenceKey + GeometryReader` fallback on macOS 13/14; `ContentUnavailableView` wrapped in `EmptyStateView` (native on macOS 14+, custom VStack fallback on macOS 13); all `onChange` two-parameter closures converted to single-parameter form; `Color(Color)` initialiser replaced with direct `.opacity()` call
- **OS simulation picker** — Settings → Maintenance → Developer section lets you select "macOS 14 (Sonoma)" or "macOS 13 (Ventura)" to preview compatibility fallback paths on the current machine; reopen the guide or Add Show wizard to activate; orange warning label shown while simulation is active

## 2026-05-22 (260522-1210)

- **Project renamed to hdhrVCRplus** — bundle name, identifier (`com.hdhr.vcrplus`), Quit button, and process marker updated; source directory and config filename unchanged for AppleScript compatibility
- **App icon in menu bar** — `app.jpg` bundled locally (`Contents/Resources/`); used as the menu bar icon, proportionally scaled to actual menu bar height (`NSStatusBar.system.thickness − 2`); dimmed during startup, full opacity when idle; falls back to SF Symbol `tv` if bundle resource is absent
- **App icon in About** — Settings → About now loads the icon from the local bundle instead of fetching from GitHub; instant display, no network required
- **Tuner signal status in recording menu** — signal strength, lock type, and bitrate (`"Signal: 78% · lock: qam256 · 12.4 Mbps"`) appear in the recording submenu, polled from `http://<device-ip>/tuner{N}/vstatus` each idle loop tick
- **Recording conflict detection** — `⚠️` badge on scheduled show labels when all tuner slots are occupied at that show's start time; conflict detail line inside the submenu
- **Skip This Airing** — new button in active recording submenu; stops the recording and advances to the next scheduled airing without incrementing the fail count
- **Cable guide dynamic width** — guide grid fills available window width; `pxPerMin` scales up as the window is widened (min 4.2 px/min); window resizable from 1100×720 minimum instead of fixed 980×700
- **Next Up submenus** — shows in the "Next Up" section now open full submenus (poster, synopsis, episode info, timing, Edit/Deactivate/Delete) matching the Scheduled section
- **Watch in VLC auto-enable** — on first launch, if `/Applications/VLC.app` is installed the Watch in VLC setting is automatically enabled; subsequent user toggles are never overridden
- **Config recovery from backup** — if the main config file is missing or corrupt on launch, the app automatically restores it from the `.json.bak` backup

## 2026-05-22 (v1.0.0)

- **SeriesID title fallback** — when the guide omits a SeriesID for a currently-airing episode, recording scheduling now falls back to a title match against the channel entry index
- **Maintenance panel** — Settings → Maintenance with five action buttons: Rescan Series, Reset Fail Counts, Reactivate Paused Shows, Refresh Guide, and Rediscover Devices
- **Add Show at top of menu** — moved above Recording Now so it is always the first action
- **Recording process survives force-quit** — recording processes launched via `posix_spawn` with `POSIX_SPAWN_SETSID`, placing them in their own POSIX session; a force-quit of the app leaves recordings running and boot-resume reattaches them on next launch

## 2026-05-22

- Next Up section in main menu — next upcoming recording time slot and all shows starting then
- Episode info in menu labels — scheduled and recording menu items show season/episode number and title without opening the submenu
- Tuner shown in recording submenu
- Show Recording in Finder button
- Tuner slot enforcement — recording start blocked when all tuner slots on a device are occupied
- Auto-detect new tuners — idle loop probes for newly-connected HDHomeRun devices every 5 minutes
- SeriesID earliest-episode resolution — finds the earliest available episode (including currently-airing)
- Universal menu readability fix — Button wrapper defeats AppKit dimming on disabled NSMenuItems
- Upcoming recording slots in scheduled show submenu
- Settings deferred save — Add Show Mode, Default Folder, and Launch at Login require Save (⌘S) to take effect
- SeriesID-only badge matching in cable guide — title fallback only used for shows with no SeriesID
- Live changelog in About tab — fetched from GitHub, inline scroll, offline fallback
- Cable guide status badges — red border/dot for recording, orange border/clock for recording within 30 min
- Record defaults to Single type
- Quit defaults to Keep Recording & Quit
- SeriesID(All) device fix — resolves correct device/URL when episode is on a different tuner
- Menu first-click warmup — pre-renders the menu view 2 s after startup
- Cable guide lazy rows — only visible rows rendered (~4× faster initial load)

## 2026-05-21

- Guide summary panel polish — upcoming airings for SeriesID shows with channel + day/time formatting
- IP auto-update — when a device's IP changes (DHCP lease renewal), stream URLs in saved shows are automatically updated
- Flat record options — Single, DateTime, SeriesID-channel, and SeriesID-all at the same menu level
- Static DateFormatter caching for performance
- Discovery reliability — startup attempts up to 10 retries; idle loop retries every tick while device list is empty
- Menu header shows each tuner's device ID and active/total recording slot count

## 2026-05-20

- **Cable guide grid** (`CableGuideView`) — full cable TV-style guide with rows per channel, proportional show blocks, genre-color coding, sticky channel column, synchronized vertical scroll, "Now" snap button, and genre filter picker
- **VLC integration** — "Watch in VLC" buttons appear in recording submenus and on-air guide entries when `/Applications/VLC.app` is installed and the toggle is enabled in Settings
- **Settings window** — `NavigationSplitView` settings with draft/save pattern, close warning, and six categories: General, Recording, Guide, Notifications, Advanced, About
- **Bonus Time for sports** — recording extends past the guide end time for shows whose genre contains "sports"; duration and toggle configurable in Settings
- **Fail threshold** — show is auto-paused after N consecutive recording failures (configurable); each successful start decrements the counter
- **Launch at Login** — `SMAppService` toggle in Settings → General
- **Verbose curl logging** — curl `-v` output piped to `~/Library/Logs/hdhr_VCR_curl.log`; toggled in Settings → Advanced
- **Notifications** — "Up Next" and "Recording Soon" alerts with configurable lead times
- **Boot resume** — recordings that survive an app restart are reattached on next launch by scanning `ps` for the caffeinate PID
- **Swift/SwiftUI rewrite** — full rewrite of the original 2016 AppleScript app; config file format preserved for compatibility
