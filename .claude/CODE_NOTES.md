# Code Observations — append-only; bugs go to ISSUES.md, deferred work to TODO.md, completed fixes to CHANGELOG.md

## 2026-07-06 — Full-codebase craftsmanship review (verified-safe, no action needed)

- `WebServer.swift:9` `final class WebServer: @unchecked Sendable` — verified intentional and safe.
  `cachedHTML`/`cachedHTMLGzip` are only ever written (`prebuildPageHTML`/`invalidateHTMLCache`) and
  read (`routeOnMain` line ~561) from `@MainActor` contexts; `sseConns`/`liveConns` (the only
  members touched from the non-MainActor `queue`) are protected by `sseLock`/`connLock`. No data
  race found. Worth re-checking if a future edit adds a new stored property that's touched from
  both `queue` and `@MainActor` without one of these two protections.
- `AppState.swift:2273-2280` `refreshTunerOccupancy()`'s flat `Task.sleep(1.5s)` before polling
  `status.json` is a genuine wait-and-hope, but it's waiting on external HDHomeRun hardware to
  register a tuner-state change — there's no local event to observe, so this is about as good as it
  gets without a device-side push API. Documented inline; not flagging as a fixable hack, just
  noting the justification for the next reviewer.
- Signal-bucket / channel-icon caches (`ChannelIconCache.mem`, `ChannelSignalStore`) both have
  explicit bounds (`mem.count > 600` reset; 50-sample-per-channel cap) — checked, not unbounded.

## 2026-07-06 — tunersFull()/activeTunerCount bootstrap staleness (not fixed, just noting)

Both now depend on `deviceTunerOccupancy` being warm — a machine that just launched and hasn't
completed its first `fetchDeviceStatus` poll yet has `hw == 0` and briefly falls back to
local-only (`recordingShows`+VLC) counting, same as pre-fix behavior. The app already primes
`deviceTunerOccupancy` immediately after device discovery at launch (`AppState.swift` ~226-228),
so this window is small, but it isn't literally zero. Relevant if multi-machine tuner-count
accuracy regresses right after app launch specifically.

## 2026-07-17 — Range 9ec4aa9..HEAD craftsmanship review (Watch-Now relay/scrub, VLC native-res, keep-alive, Sparkle removal)

- `VLCBridge.swift:2054-2055` `nonisolated(unsafe) let inst/mp = newFn(0,nil)` — verified safe:
  freshly-created libvlc handles with no other owner, handed to `MainActor.run` in the same
  detached task. OpaquePointer isn't Sendable; this is the correct minimal escape hatch. Justified
  inline. Don't re-flag.
- `WebServer.swift` recording relay (`pumpGrowingFile`, ~355) polls the growing MPEG-TS file every
  0.5s once caught up to the live write pointer. Looks like time-based polling but there is no
  filesystem-append push event that's cheaper/simpler here (DispatchSource vnode watches on a file
  curl keeps `write()`-ing are flaky), and it mirrors how the real tuner stream drips. Accepted;
  the loop is cancellation-aware (checks `conn.state` each recursion) and closes the FileHandle on
  every exit path. Not a leak.
- `AppState.swift:2506` / `VLCBridge.beginRecordingSeek` — the `DispatchQueue.main.async` deferral
  of `beginRecordingSeek` is a genuine SwiftUI render-timing workaround (setting `recordingShowId`
  synchronously inside the same window-open transaction never re-renders the toolbar). Guarded
  against staleness by re-checking `currentURL` still encodes this show id. Verified intentional and
  defended in comments on both sides; not a hack-with-a-timer.
- `Views/SettingsView.swift:519` hard-codes `/System/Applications/Utilities/Console.app` and launches
  via `NSWorkspace.openApplication` (LaunchServices, not `Process()` — the direct-exec path SIGKILLs
  Console on a launch-constraint violation, fixed in 7c23a65). System path, not a home-dir path;
  hardened-runtime/Gatekeeper safe. Sandbox-later note: launching another app is an LSOpen the App
  Store sandbox will block, but this is a diagnostics-only button — degrade gracefully when it fails.
  The Console predicate uses `Bundle.main.bundleIdentifier` while `glog`'s `Logger` subsystem is the
  string literal `"com.hdhr.vcrplus"` (`Models.swift:10`); they currently match (Info.plist), but a
  bundle-id change would silently empty the Console filter. Minor coupling, noted not flagged.
- `VLCBridge.swift:516-517` `videoPixelSize` republished only on change (`if newPixelSize != …`),
  computed once per 3s stats tick — not per render. Good; no churn.

## 2026-07-28 — cb327a1 review (native/web add-flow parity + Show.seriesTitle/localFallbackDir helpers)

- Verified `Show.localFallbackDir`'s self-heal repair condition (`decodedTempDir == show_dir &&
  show_dir != Show.localFallbackDir`) has no legitimate false-positive case: every current write
  path (AddShowView.swift:405, EditShowView.swift:199, AppState.swift:930) sets
  `show_temp_dir = Show.localFallbackDir` unconditionally, never to a copy of `show_dir`, and the
  one case where a user deliberately sets `show_dir` to the fallback path itself is explicitly
  excluded from the repair. Confirmed clean, no misfire risk found.
- `ManagedGuideMatcher` (Models.swift ~562-643) changed from `Set<String>` membership tables to
  `[String: Show]` lookup tables with a new `owner(for:)` method, consumed by the skip-already-
  recorded corner-flag logic (`WebServer.swift:1234`) — confirmed this replaces what would
  otherwise be a second, separately-maintained series→Show lookup, not redundant/dead. `isManaged`
  is now a one-line wrapper (`owner(for:) != nil`) — no remaining direct Set-membership callers.

## 2026-07-31 — 0fc566b review (VCR-glyph guide markers, conflict-simulation rewrite)

- `AppState.swift:894-916` conflict-simulation's `ordered.contains { … }` inner scan (populating
  `conflictBeatenByFavorite`) is O(N) per loser, O(N²) worst case per device — technically
  reintroduces the quadratic shape the rewrite's headline goal was to eliminate. Not worth fixing:
  it only runs for actual conflict losers (rare), bounded by shows-per-device (tens, not
  thousands), and the whole `rebuildMenuEntries()` call itself is already gated to run once per
  idle tick / guide load (not once per menu open, per its own comment) — nowhere near a hot path
  at this app's scale. Tracking slot *occupant* instead of just free-at `Date` (to make this O(1)
  lookup) would add real complexity for a savings that never matters here.

## 2026-08-01 — v1.3.0..HEAD pre-release quality gate (94 commits)

- `Views/ShowFormSection.swift:148-157` (`duplicateCheckKey` `.task(id:)`) debounces the
  already-recorded-episode check with `try? await Task.sleep(for: .milliseconds(350))` before
  calling `AppState.duplicateEpisodeTag(for:isSeries:baseDir:)`, whose comment explicitly
  acknowledges `recordedEpisodeTags` does synchronous `FileManager` calls (`contentsOfDirectory` +
  `attributesOfItem` per file, two directory levels) on the main actor and "can block the whole
  app for real wall-clock time if the recording folder is on a slow-to-wake external drive." The
  debounce reduces *frequency* (once per typing pause instead of per keystroke) but doesn't remove
  the main-actor blocking risk it names — a genuinely slow volume still stalls the Add/Edit dialog
  (and, since this is `@MainActor` `AppState`, the whole app) for that one scan. Real fix would hop
  the scan off `@MainActor` (e.g. `Task.detached` + `nonisolated` FileManager work) and publish the
  result back. Low real-world severity (feature is opt-in via `Skip_recorded_episodes`, and local
  disks return near-instantly) but worth fixing before it's someone's bug report from a NAS-backed
  recording folder.
- `WebServer.broadcastGuideChangeEvent` (added this range) is now called from 9+ `AppState` show
  lifecycle sites (add/update/pause/resume/delete/favorite-toggle/duplicate-override-clear), each
  triggering a full `buildGuideGridHTML` + `buildDevBarHTML` + `prebuildPageHTML` (gzip) rebuild on
  the main actor — previously only the hourly guide refresh and recording start/stop paid this
  cost (`prebuildPageHTML`'s own comment cites ~30-60ms for the gzip pass alone on the ~1.5MB page).
  When `Series_subfolder_enabled && Skip_recorded_episodes` are both on, each of those rebuilds also
  re-scans every managed series' recording folder via `recordedEpisodeTags` (one `FileManager`
  directory walk per series, per CLAUDE.md's own documented "one scan per managed series per
  build" invariant) — so toggling a single favorite now costs one full-page rebuild + N directory
  scans where before it was a bare `{type,device,guideNumber}` SSE push. Deliberate tradeoff for
  guide-freshness on new tab loads (documented in the surrounding comments), and show mutations are
  low-frequency (human-paced, not per-render/per-tick), so likely fine — but if a large recording
  library with many managed series starts showing UI hitches on Add/Edit/Delete/favorite-toggle,
  this rebuild-fan-out is the first place to look.

## 2026-08-06 — vertical time-axis mode (uncommitted working-tree review)

- `Sources/hdhr_VCR/WebServer.swift:681-683` carries a stale comment ("`/vertical` is a plain
  alias for `/` — kept only because it was bookmarked/typed during vertical-mode development…
  the guide is identical either way") that describes an *earlier, since-replaced* design —
  `docs/WebServer.md`'s new "Vertical time-axis mode" section explicitly says that alias
  behavior was replaced specifically so `/` and `/vertical` would differ (`includeVerticalCSS`
  false vs true, `VT_ELIGIBLE` token baked differently). The very next case block (`"/vertical"`,
  line 693-696) and every other comment added in this diff correctly describe the real,
  divergent behavior. Left as a flag for the main agent to fix (delete/replace the stale
  comment) rather than edited directly, per this agent's write restrictions.
- `Resources/guide.js` — `updateNowLine()` (~899-916), `scrollToNow()` (~918-921), and the
  now-button visibility `check()` (~1083-1090) each hand-roll the same
  `ch/cw + (gi.scrollHeight/scrollWidth - ch/cw) * (nowPct()/100)` formula in parallel
  `isVT() ? … : …` branches (3x duplication of the vertical-axis formula, 3x of the horizontal
  one). Explicitly justified in `docs/WebServer.md` ("kept as small paired branches rather than
  a shared abstraction, matching this file's existing terse style") and not currently diverged
  (all three copies agree), so not flagged as a bug — but it's exactly the shape CLAUDE.md calls
  out as WebServer.swift's JS-string repeat-offender pattern. Worth collapsing into one
  `nowScrollTarget()` helper returning `{prop, value}` if a fourth call site ever needs the same
  math, or if any of the three drift out of sync.
- `Resources/guide.css` has two separate `@media(max-width:600px){...}` blocks (~line 88 and
  ~line 151) rather than one merged block — pre-existing summary-panel rules in the first,
  new toolbar/grid/modal compaction rules in the second. Not a functional bug (CSS allows
  repeated media queries; no property collisions between the two), just a missed tidy-up.
- `guide-vertical.css`/`guide.js`'s `isVT()`-branching code is unusually well-commented with
  on-device WebKit failure modes (sticky-left-in-flex-row unreliability, `content-visibility:auto`
  + sticky-descendant paint bug, `contain-intrinsic-size` two-group requirement) — read as
  hard-won findings, not speculative hedging. Treat these as load-bearing constraints, not
  cleanup targets, if touching vertical-mode CSS later.

## 2026-08-08 — v1.4.6..HEAD review (DonationNagView, FloatingGuideView removal, vertical mode, WindowNavigationTests)

- `Sources/hdhr_VCR/Views/DonationNagView.swift` — clean, well-justified new file: honor-system
  unlock (`attemptUnlock`) has no force-unwraps beyond `URL(string: paypalURL)!` on a hardcoded
  literal (fine per this agent's own criteria), `FloatingWindowLevelSetter` is a verbatim
  re-paste of the identical `private struct` that used to live in the now-deleted
  `FloatingGuideView.swift` (confirmed via `git show v1.4.6:...FloatingGuideView.swift`) — not
  copy-paste *divergence* since the old copy no longer exists, but if a third window ever wants
  floating-level behavior, promote it out of file-private scope into a shared helper rather than
  a third paste.
- `docs/DonationNagView.md` explicitly documents "no throttling or snooze" — the nag re-opens on
  every `addShow` call (native or web) until unlocked, including immediately after "Not now" —
  confirmed intentional design (not a bug): `TODO.md`-style deferred fix already named in the doc
  itself ("a cooldown timestamp in `AppConfig`, not a design change here") if it proves too
  aggressive in practice.
- `Sources/hdhr_VCR/hdhr_VCRApp.swift`'s `pendingDonationNagTrigger`/`launchDonationNagShown`
  gating verified correct: `MenuBarExtra`'s `.menu`-style content view stays mounted across
  open/close (that's *why* `onAppear`/`onDisappear` already double as `menuIsOpen` tracking pre
  this change), so the `.onChange(of: pendingDonationNagTrigger)` fires even while the menu is
  closed — required for the web-guide-Record trigger path to work without the user opening the
  menu bar dropdown first.
- Verified full removal of `FloatingGuideView`/"Cable Guide" window: zero remaining live
  references anywhere in `Sources/`, `Resources/`, or non-historical `docs/*.md` (grep swept
  clean — only `CHANGELOG.md` history entries, `docs/WKWebView_guide_analysis.md`'s explicitly-
  marked "historical, superseded" doc, and `Tests/hdhr_VCRTests/WindowNavigationTests.swift`'s
  file-header note about *not* covering the removed window remain, all appropriately historical/
  prose). No orphaned snapshot reference PNG (`Tests/hdhr_VCRTests/__Snapshots__/` has no
  `FloatingGuideView*` file) and its `@Test` was removed from `SnapshotTests.swift` in the same
  commit. Dead client-side "watch" bridge JS (`doWatchInApp`/`doWatchInVLC`, `#sum-watch-app`/
  `#sum-watch-vlc`) was fully swept from `guide.js`/`guide-shell.html` too — confirmed zero hits.
- `ISSUES.md`'s 2026-08-08 "Code audit" entries (double gzip pass in `prebuildPageHTML`,
  `ChannelIconCache.pruneDiskCacheIfNeeded()`'s O(n) full-directory-scan-per-write, verbose-curl/
  `RotatingLogFile` byte-counter race, `RotatingLogFile`'s phantom-growth-on-failed-write edge
  case) match exactly what an independent read of the same diff surfaces — already logged as
  OPEN with accurate root-cause/fix notes, correctly not fixed inline. No new efficiency findings
  beyond what's already tracked there.
- Doc-drift gap (real, not yet flagged anywhere): commit `a808bb4` added a "Registered supporter"
  checkmark badge + unlock-code display to `SettingsView.swift`'s About tab (between the Version
  text and the History text, `aboutView` ~line 887-903) but never touched `docs/SettingsView.md`'s
  About section bullet list to describe it — the doc's About list still jumps straight from
  "Version" to "History text" with no mention of the new registered-supporter block. Reported to
  the main agent as a finding rather than fixed here (out of this agent's write scope).
- Second instance of the same gap: `docs/Config.md`'s own documented "Adding a New Field" 3-step
  checklist (step 1: add to `AppConfig`; the doc's `## AppConfig Fields` code block is meant to be
  an exhaustive table) was not followed for the three new fields added in this range
  (`Donation_unlocked`, `Donation_target_checksum`, `Donation_unlock_code`, all in `Models.swift`)
  — the field table still ends at `Config_version` with no `Donation_*` rows. Also reported as a
  finding.
- `CLAUDE.md`'s own "Views:" doc-link list and the `Views/` architecture tree were correctly
  scrubbed of `FloatingGuideView` on removal, but were never updated to *add*
  `Views/DonationNagView.swift` / `docs/DonationNagView.md` despite `docs/README.md`'s own table
  getting the addition — asymmetric thoroughness worth calling out since CLAUDE.md is the
  project's primary instruction file other agents (including this one) rely on for an accurate
  file inventory.
- `Sources/hdhr_VCR/CHANGELOG.md` has zero entries for either donation-nag commit (`6086787` "feat:
  add donation nag window", `a808bb4` "feat(about): show registered-supporter status…") despite
  every other commit in this same `v1.4.6..HEAD` range adding one — a ~200-line new user-facing
  feature (window, 3 new `AppConfig` fields, About-tab status display, app-name standardization)
  with no changelog trace. Inconsistent with this diff's otherwise meticulous CHANGELOG discipline
  (see the FloatingGuideView-removal and deploy-script-fix entries, which even log same-session
  code-audit cleanups).
- `Tests/hdhr_VCRTests/WindowNavigationTests.swift` — well-scoped opt-in suite (env-var gate +
  `appRunning()`/`accessibilityTrusted()` guards, all correctly composed so a bare `swift test`
  never triggers it). One inconsistency worth a look if this suite gets flaky in CI:
  `editShowOpensAndCloses`'s AppleScript polls with a bounded
  `repeat 20 times { delay 0.25/0.2; check condition }` loop for both window-open and
  window-close confirmation, but `settingsAllTabsReachable`/`openAndCloseTopLevelWindow` instead
  use a single blind `delay 0.5/0.6/0.7/0.3` after each click/selection with no readiness check —
  a slower machine (the file's own `TODO.md` entry about `WebServerPerfTests` flaking under load
  average ~4-5 shows this machine does see that) could plausibly open a window slower than the
  fixed delay, producing a false failure rather than a real regression signal. Same
  bounded-poll pattern already proven correct elsewhere in this same file would remove the
  guesswork.

## 2026-08-08 — v2.0.0 final release-gate review (placeholder fix, Donation_unlock_code, RELEASES.md, CHANGELOG tag)

- Verified the `TextField("", value:, format:)` placeholder fix in `Views/SettingsView.swift:590`
  (`Donation_target_checksum`), `Views/SettingsView.swift:612` (`Web_server_port`), and
  `Views/EditShowView.swift:113` (`show_length`): all three bindings are non-optional `Int`
  with a fixed default (`Donation_target_checksum = -1`, `Web_server_port = 1980`,
  `show_length` via `Binding(get: { show?.show_length ?? 60 }, ...)`) — `TextField(_:value:format:)`
  only shows its placeholder when the formatted text is empty, which never happens for a
  non-optional numeric binding. The old `"not set"`/`"1980"`/`"60"` placeholders were dead
  weight even before the double-render bug; removing them costs no real affordance (the -1
  "disable unlocking" behavior is explained by the adjacent `InfoButton`, not the placeholder).
- `AppConfig.Donation_unlock_code` (`Models.swift:380`) — confirmed this stores the user's own
  locally-entered code (any 6 hex digits whose values sum to the private
  `Donation_target_checksum` target), not the target itself; many distinct codes satisfy one
  target, so displaying it back in Settings → About (`SettingsView.swift:893-897`) cannot be
  reverse-engineered into the private checksum. Grepped the full tree for a literal
  `Donation_target_checksum = <number>` — zero hits outside `Models.swift`'s own `-1` default;
  the real per-install value only ever lives in the gitignored local config file.
- `RELEASES.md`, the `README.md` Installation/Gatekeeper rewrite, and the `docs/MAS_COMPLIANCE.md`
  banner checked for anything beyond already-intentionally-public info (GitHub repo URL, the
  developer's own PayPal.me name already present in `DonationNagView.swift`'s hardcoded link) —
  clean, nothing new disclosed.
- **Real finding, since fixed**: `deploy_release.sh`'s `SIGN_IDENTITY` line (in the "Fill these
  in" block near the top) was `"Developer ID Application: YOUR NAME (XXXXXXXXXX)"` in every prior
  commit back through this script's introduction, but briefly held the developer's real identity
  string in an uncommitted working tree at one point. Never actually landed in a commit (verified
  against full history), but there's no reason for the literal identity string to live in
  committed source when the placeholder pattern existed specifically so it wouldn't — and this
  same session already had a near-miss with actual private key material almost landing in git
  (`b88e711`, `.signing_work/`). Reported to the main agent rather than reverted here (out of this
  agent's write scope).

## 2026-08-09 — v2.0.1 pre-release review (v2.0.0..main)

- `AppState.swift:649-666` (`fetchAllLineups`) and `HDHRManager.swift:58-96`
  (`knownHostsDiscover`, `udpDiscoverAndFetch`) — the Local Network Privacy show-stopper fix
  converts bare `try?` to `do`/`catch` + `glog(..., level: .warning)` while preserving each
  function's pre-existing fallback value (`nil` for the two lineup/known-hosts paths, the raw
  UDP-reply `device` for `udpDiscoverAndFetch`). Verified the fallback values are byte-identical
  to pre-fix behavior — only the silence was removed, not the error-handling semantics. Clean,
  minimal, correctly scoped fix; matches the `[Discovery] attempt \(attempt)/\(attempts) failed`
  idiom already established at `AppState.swift:532`, so no new logging convention introduced.
- `HDHRManager.swift`'s `mDNSDiscover`/`cloudDiscover` call sites (`discoverDevices`, lines ~27-40)
  still use bare `try? await ...` and were deliberately left untouched by this fix — confirmed
  intentional via `TODO.md`'s "macOS Local Network permission block" entry, which explicitly scopes
  the fix to `fetchAllLineups` + `fetchDeviceInfo`'s two callers and says `fetchLineup` itself needs
  "no in-function change since its caller handles the error." Not a gap to re-flag; the remaining
  bare `try?` calls are pre-existing debt, not newly introduced by this diff.
- `AppState.swift:630` — the comment above `ensureLineupLoaded` ("Guards against silent try?
  failures in fetchAllLineups") is now slightly stale wording: the `try?` was replaced with
  `do`/`catch` in this same release, so failures are no longer *silent* (they're logged at
  `.warning`), even though `lineups[deviceID]` can still end up nil on failure, which is what the
  comment is actually guarding against. Not worth a standalone fix commit — cosmetic wording drift,
  flagged here so nobody re-investigates it as a functional bug.
- CI fix (`.github/workflows/ci.yml`, `swift test` → `swift test --skip SnapshotTests`) confirmed
  `--skip <regex>` is a real `swift test` flag (checked `swift test --help`) and `SnapshotTests` is
  the actual struct name in `Tests/hdhr_VCRTests/SnapshotTests.swift:15`, so the regex match is
  correct, not a typo'd skip that silently does nothing.

## 2026-08-09 — v2.0.2 pre-release review (v2.0.1..main)

- `Sources/hdhr_VCR/AppState.swift:2996-2998` (`fetchDeviceStatusUncached`) — the new count-only
  gate (`newActiveCount != oldActiveCount`) correctly leaves the app's own recording-control logic
  unaffected: the alerting/matching loop just below the gate (`for show in recordingShows where
  show.hdhr_record == device.DeviceID`) reads the freshly-fetched local `tuners` array, never the
  stored `deviceTunerOccupancy`, so signal alerting and tuner-resource matching for this app's own
  recordings stay fully fresh every poll regardless of the gate. Verified by reading the full
  function body.
- Same spot — the doc addition at `docs/AppState.md`'s `fetchDeviceStatus(for:)` paragraph claims
  "the only other reader of those [stale] fields (`TargetIP`/`SignalQualityPercent`) is
  `stopRecording`'s optimistic tuner-clear) just copies them through unchanged," but this misses
  `WebServer.swift:1514` (`recsByDevJS`, feeding the web UI's per-tuner dev-bar dropdown), which
  reads full per-tuner identity (`info.Resource`, `info.VctNumber`) out of the same stored
  `deviceTunerOccupancy` array to decide which physical tuner is idle/recording/live-streaming and
  what channel. Per `docs/WebServer.md:831`, this is a documented, real consumer of per-tuner
  detail, not just count. Practical exposure is narrow — it only shows a wrong tuner-to-channel
  label in the web UI's per-tuner dropdown, and only during the exact race the new gate's own
  comment calls out (an external consumer swapping which physical tuner is active while the
  aggregate active-tuner count coincidentally stays flat) — self-heals on the next count-changing
  poll, and does not touch the app's actual recording-control path (see previous bullet). Also
  worth noting for whoever revisits this: pre-fix, this staleness window was bounded to "while the
  menu happens to be open"; post-fix it can now persist across idle ticks indefinitely whenever the
  aggregate count happens not to move, even with the menu closed — a real (if narrow) widening of
  the staleness surface versus the old `menuIsOpen`-only gate, not just a relocation of it. Not
  filed as a bug (display-only, self-healing, narrow trigger) — recorded here so the docs claim
  isn't taken as the complete picture if someone chases a "wrong tuner in the web dropdown" report.
- `Sources/hdhr_VCR/AppState.swift:1197-1207` (`idleLoop`'s fast lineup-retry branch) — correctly
  bounded to *stop* (guarded by `config.Local_network_confirmed`, which only ever flips one-way to
  true), but has no backoff or attempt cap: if a user's Local Network permission is actually denied
  (as opposed to merely pending — the two are indistinguishable from this app's side, per
  `TODO.md`'s "Show Stoppers" research), this calls `fetchAllLineups` (full per-device lineup
  fetch + `reconcileFavorites`) every idle tick (`Idle_timer_interval`, default 10s) forever, not
  just while genuinely waiting on the one-time OS prompt. Low real-world impact (LAN-local HTTP GET
  to a device that's already being polled for status every tick anyway) but worth an exponential
  backoff or attempt cap falling back to the existing hourly cadence if this ever needs revisiting.
- `Sources/hdhr_VCR/hdhr_VCRApp.swift:24` — the throwaway `ConfigManager().load()` in `init()` is
  a reasonable, well-commented tradeoff (not a hack): `@StateObject`'s `AppState()` hasn't loaded
  its own config yet at this point in `init()`, and the alternative (restructuring init order or
  threading a shared `ConfigManager` through `App` init before `@StateObject` is available) is more
  invasive than a second small sync JSON read of a small file, once, at launch. Minor and harmless:
  it re-runs `ConfigManager.init()`'s `FileManager.default.createDirectory` for the already-existing
  Application Support directory — a no-op in practice, not worth removing given the clarity of
  keeping `ConfigManager()` self-contained.
- `AppConfig.Dock_icon_mode: String` (`Models.swift:377`, values `"auto"/"always"/"never"`) is
  stringly-typed matched via `switch` in three places (`hdhr_VCRApp.swift`, `AppState.swift`'s
  `confirmLocalNetworkAccessIfNeeded`, `SettingsView.swift`'s `applyAndSave`) plus `Picker` tags —
  but this exactly mirrors the codebase's pre-existing, established idiom for mode-style config
  strings (`Default_transcode: String = "none"`, matched the same way across `Models.swift`,
  `WebServer.swift`, `AddShowView.swift`, `SettingsView.swift`). Not flagging as new debt — it's
  consistency with the existing convention, not a third divergent copy of a different pattern.

## 2026-08-11 — pre-release review (v2.0.2..HEAD, swift-quality-reviewer)
- `Sources/hdhr_VCR/Views/GuideViewHelpers.swift:161-167` (`_genreAlias`) is a **third** copy of the
  genre-alias table that already exists twice — `Resources/guide.js`'s `_ggAlias` and
  `WebServer.swift:1419-1421`'s `ggAlias` (both pre-existing, both still have `"kids":"children"`).
  The new Swift copy dropped that one entry (confirmed real: `docs/WebServer.md`'s own `/api/airings`
  example payload shows `"genre":"Kids"` as a genre `guide.php` actually emits). Net effect: a
  "Kids"-genre entry rendered through `guideEntryColor(for:onAir:)` (consumers: `WatchNowView.swift:286`,
  `AddShowView.swift:504`) now falls through to the default gray `Color(white:0.22)` instead of the
  "children" hue it got before this diff (previously `_genreColorMap` had `"kids"` as a *direct* key,
  so no aliasing was needed there at all — the alias table is new in this diff, the regression is a
  side effect of introducing it without copying the sibling tables exactly). No test exercises
  `guideEntryColor` (zero hits for that name under `Tests/`), so this shipped silently. Reported to
  the user as a finding, not fixed here (out of scope for this review agent) — worth a real helper
  (one shared `[String:String]` genre-alias constant reachable from both this file and `WebServer.swift`,
  since both are now in-process Swift) so a fourth divergence can't happen next time a genre tag is added.
- `Sources/hdhr_VCR/Views/SettingsView.swift` — the "Use XMLTV guide format" toggle's relocation from
  Guide→Format to General→Guide shipped inside commit `3bfee29` ("fix(settings): resync draft config on
  window refocus…"), whose commit message never mentions it. Confirmed via `git show 3bfee29` (only
  commit in the v2.0.2..HEAD range touching those lines) — the move is real, deliberate, and well
  documented in `docs/SettingsView.md`'s diff (which explicitly dates it "2026-08-10"), just not
  disclosed in the commit that shipped it. A UI-relocation is exactly the kind of drive-by change the
  project's own commit-sequencing convention (features/refactors get their own commit) exists to keep
  visible in `git log`; low-stakes here since docs kept pace, but flagged so a future `git bisect` on a
  "why did the XMLTV toggle move" question doesn't dead-end at an unrelated commit title.
- Commit `2849182` ("fix: scope SeriesID(All)…") bundles ~7 materially distinct changes under one
  commit (per its own body): SeriesID(All) tuner-scoping bug fix, off-actor duplicate-episode scan,
  ChannelIconCache prune-batching perf fix, curl-verbose-log file separation, prebuildPageHTML gzip
  parallelization + lazy vertical-variant build, a **new** web-guide feature (duplicate-episode
  override toggle + `/api/edit` field), and unrelated accessibility additions (`role="button"`,
  `aria-label`, `tabindex`, keyboard handler on `.g-prog`/`.d-btn`/`.g-fav-btn`) that aren't mentioned
  in the commit body at all. The new feature bundled into a "fix:"-titled commit is the sharpest edge
  of this — violates the project's own "features and refactors go in separate commits (features first)"
  rule. Retrospective only (already merged, not worth unwinding for a release review) — recorded so the
  pattern (large multi-purpose "found and fixed in one session" commits) is visible if it recurs.
- `Sources/hdhr_VCR/WebServer.swift:143-183` (`prebuildPageHTML`'s `DispatchQueue.concurrentPerform`
  + raw `UnsafeMutablePointer<Data?>` + `UncheckedSendableBox` for the 2-way gzip parallelization) is
  functionally correct (disjoint-index writes, `defer`-guarded init/deinit/dealloc, only ever invoked
  from `@MainActor`) and matches a pattern CLAUDE.md itself prescribes for this exact spot ("New cached
  page variant…" invariant) — not flagging as a new hack. Noting the manual pointer bookkeeping is more
  verbose than necessary; `Foundation.Data` has been `Sendable` since Swift 5.5, so the same result is
  reachable with less unsafe surface via `results.withUnsafeMutableBufferPointer { ... }` over a plain
  `[Data?]` instead of manual `allocate`/`initialize`/`deinitialize`/`deallocate`. Cosmetic, not a bug.

## 2026-08-11 — GuideRingState / Watch-from-Beginning pass (pre-push review)

- `Sources/hdhr_VCR/Views/GuideViewHelpers.swift:188-201` (`PulseIfRecording`) — `dimmed` only ever
  gets animated inside `.onAppear`, gated by `guard active else { return }`. Since `WatchNowRow`'s
  identity is keyed by `channel.id` (`ForEach(favs, id: \.channel.id)` /
  `WatchNowView.swift`'s `channelRow`), a row that transitions from a non-recording ring state
  (e.g. `.scheduled`) to `.recording` *without remounting* — plausible any time a user leaves
  Watch Now open long enough to watch a scheduled show start — will show the correct red ring
  color (read live from `state.ringColor`) but never start the pulse, because `onAppear` already
  fired once with `active == false` and won't fire again. Not caught by any test (pure-SwiftUI
  animation timing, no snapshot covers a live state transition). Confirmed via read, not exercised
  live. Fix would be `.onChange(of: active)` (re-arm the animation whenever `active` flips true)
  instead of (or in addition to) `.onAppear`.
- `Sources/hdhr_VCR/GuideStore.swift:210` — `buildIndex(deviceId:channels:)` was widened
  `private` → `internal` specifically so a new snapshot test could seed on-air guide data
  directly. That snapshot test was written, found to render blank under `ImageRenderer`
  (`ScrollView` limitation, documented in `TODO.md`'s "`ImageRenderer`-based snapshot tests…"
  entry and `Tests/hdhr_VCRTests/SnapshotTests.swift`'s comment), and removed. `Tests/hdhr_VCRTests/GuideRingStateTests.swift`
  (the test suite that did ship) only calls `resolveGuideRingState` directly and never touches
  `GuideStore` at all. Zero-hit grep for `buildIndex(` outside `GuideStore.swift` itself confirms
  no current caller needs the wider access — the visibility bump is now unjustified scope, worth
  reverting to `private` next time this file is touched (not urgent enough to revert on its own).
- `Sources/hdhr_VCR/AppState.swift:3112-3113` — the new `webServer.broadcastGuideChangeEvent(type:
  "tuner_occupancy_changed", …)` call inside `fetchDeviceStatusUncached` fires on every hardware
  active-tuner-*count* change, gated only by `!menuIsOpen || cooldownElapsed` — i.e. **unthrottled**
  whenever the menu bar menu happens to be closed (the common case). `broadcastGuideChangeEvent`
  unconditionally calls `buildGuideGridHTML` (1300+ program blocks per CLAUDE.md's own estimate)
  plus `prebuildPageHTML`'s gzip rebuild, regardless of whether any SSE client is even connected.
  The idle loop polls every device's status roughly every `Idle_timer_interval` (default/min ~5-10s)
  via `fetchDeviceStatus`. CLAUDE.md's own "Tuner occupancy" invariant explicitly anticipates the
  scenario that would hit this repeatedly: another machine running this app (or the HDHomeRun's own
  app) against the *same physical device*, channel-surfing — each channel change flips the hardware
  active count, re-triggering a full guide-grid rebuild+broadcast on the very next idle tick,
  indefinitely, with the web UI open or not. Reported as a finding, not fixed (out of scope for this
  review agent) — a dedicated cooldown for this specific broadcast (independent of
  `lastMenuOpenTunerWrite`, which only bounds *menu* disruption) would cap the worst case.
- `Sources/hdhr_VCR/Views/WatchNowView.swift`'s `ringStateInputs(for:)` calls
  `state.recordedEpisodeTags(forTitle:baseDir:)` (synchronous `FileManager` directory
  enumeration + per-file `attributesOfItem` stats, `AppState.swift:2459`) directly inside
  `var body`'s call chain whenever `Series_subfolder_enabled && Skip_recorded_episodes` are both
  on — once per managed series show, every time `WatchNowView.body` re-evaluates. Since the view
  holds `@EnvironmentObject var state: AppState` (not scoped to a subset of `@Published`
  properties), body re-evaluates on *any* AppState publish while the window is open, not just
  guide-relevant ones. `WebServer.swift`'s `buildGuideGridHTML` has the identical scan (per
  CLAUDE.md's own "Skip already-recorded episodes" note) but only runs on explicit rebuild
  triggers (add/edit/delete/etc.), a much lower ceiling than SwiftUI's `body` re-evaluation
  frequency. Confirmed the ring-state *bundle itself* is correctly computed once per render (not
  once per row, per the task's specific ask) — the concern is the render frequency, not row-level
  duplication.
- `Resources/guide.css:56-59` (bare `.t-info-full`/`.t-info-full:hover` rules, pre-existing
  selector kept from before this session's `tunerCountSpan` redesign) are now effectively inert:
  every element that can carry `t-info-full` in the current markup also always carries
  `t-info-inline` (`WebServer.swift:1197`'s `tunerCountSpan`, and `guide.js`'s `tb=document.getElementById('tun-'+…)`
  call sites at lines ~365/1045/1095 which only ever target that same span) so the more specific
  `.t-info-inline.t-info-full` combo rule wins for the properties both define, and the bare rule's
  unique property (`border-color`) has no visible effect since `.t-info-inline` sets no `border`.
  Not flagged as a hard finding (still technically reachable by the cascade, just visually inert) —
  worth deleting next time `guide.css`'s tuner-badge section is touched.
