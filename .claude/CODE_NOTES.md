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
  marked "historical, superseded" doc, and `Tests/hdhr_VCRTests/Views/WindowNavigationTests.swift`'s
  file-header note about *not* covering the removed window remain, all appropriately historical/
  prose). No orphaned snapshot reference PNG (`Tests/hdhr_VCRTests/Views/__Snapshots__/` has no
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
- `Tests/hdhr_VCRTests/Views/WindowNavigationTests.swift` — well-scoped opt-in suite (env-var gate +
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
  the actual struct name in `Tests/hdhr_VCRTests/Views/SnapshotTests.swift:15`, so the regex match is
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
  entry and `Tests/hdhr_VCRTests/Views/SnapshotTests.swift`'s comment), and removed. `Tests/hdhr_VCRTests/Models/GuideRingStateTests.swift`
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
  worth deleting next time `guide.css`'s tuner-badge section is touched. (This whole rule pair was
  since removed in the v2.0.3..main range's dev-bar redesign — `.t-info-full` was folded into
  `.t-info-inline.t-info-full`, so this specific inert-CSS note is now stale/resolved.)

## 2026-08-15 — v2.0.3..main pre-release review (32 commits: VLC deadlock fix, ManagedGuideMatcher channel-scoping, Watch Now ring-state unification)

- `Sources/hdhr_VCR/VLCBridge.swift:322-450` (`play()`/`stop()`/`releasePlayer()`/`stopAndClearState()`
  moving blocking `libvlc_media_player_stop`/`_release` onto the new serial `libvlcQueue`) — traced
  the full interleaving by hand for the "two play() calls land close together" case: `currentURL`/
  `currentMedia`-claim happen synchronously on MainActor before the queue hop (so the staleness
  check in the deferred `Task { @MainActor }` commit is decided purely by MainActor-side ordering,
  independent of how the background queue happens to interleave), and the serial (not concurrent)
  queue preserves the old code's effective FIFO teardown-then-setup ordering per player object.
  Reasoned through the "superseded call's `libvlc_media_release` runs directly on MainActor,
  possibly before the next call's `libvlc_media_player_stop` has even fired" sub-case too — safe
  because `libvlc_media_player_set_media` internally retains its own reference, so releasing our
  local extra ref never drops the count to zero while the media is still attached to the player.
  Verified sound. No test coverage exists for this (nor could easily exist — real libvlc dylib,
  real threading), so this reasoning is the only check it's had; worth a skeptical re-read again if
  this code is ever touched, not just trusted because `swift build`/existing tests pass.
- `Sources/hdhr_VCR/Views/VLCPlayerView.swift:220-244` — **real bug, not yet in ISSUES.md**: the CC
  auto-enable-on-mute `.onChange(of: volume)` handler guards on `selectedSpuTrackId < 0` to mean
  "user hasn't made an explicit choice yet," but the Picker's own "Off" option is tagged
  `Int32(-1)` (`VLCPlayerView.swift:610`) — the exact same value as the untouched default. The
  handler's own comment claims "Skipped if the user already made an explicit choice (…even 'Off'
  was picked on purpose)" but the guard direction does the opposite: an explicit "Off" pick leaves
  `selectedSpuTrackId == -1`, which satisfies `< 0`, so muting after deliberately turning captions
  off will still silently re-enable them. **Fixed 2026-08-15**, same pre-release pass — added
  `spuChoiceIsExplicit: Bool`, set only by the Picker's own binding (a wrapped `Binding(get:set:)`,
  not `$selectedSpuTrackId` directly) so programmatic resets (channel load/switch) don't trip it;
  see `issues_resolved.md` for the full writeup and `docs/VLCPlayerView.md` for the updated
  mechanism description. No longer an open finding.
- `Sources/hdhr_VCR/Models.swift`'s `ManagedGuideMatcher` merge-back-to-4-dicts (sharing
  `seriesKeys`/`seriesTitles` between `"device:SeriesID"` (seriesAll) and
  `"device:channel:SeriesID"` (seriesChannel) shapes in the same dictionary) — checked the
  no-collision claim: `deviceId`/`channelNum`/`show_seriesid`/`show_title` are never
  colon-containing in this codebase (HDHomeRun device IDs are 8 hex chars, channel numbers are
  `major.minor` decimal, SeriesIDs are opaque EPG tokens), so a 2-segment and 3-segment
  colon-joined key can never collide as dictionary keys. `owner(for:)`'s two-step lookup (try
  channel-scoped shape first, then device-only shape) is correctly ordered and has direct test
  coverage for the "same SeriesID/title, different channel, same device" case
  (`ManagedGuideMatcherTests.swift`'s `seriesChannel_bySeriesID_doesNotMatchDifferentChannelSameDevice`/
  `_byTitle_...`). Verified sound.
- `Sources/hdhr_VCR/Views/WatchNowView.swift`'s new `recordedTagsCache`/`recordedTagsRefreshLoop()`
  (unconditional 10s-interval poll calling `state.recordedEpisodeTags`, a synchronous `FileManager`
  scan) is a direct fix for the exact main-actor-blocking-on-every-render issue flagged in this
  file's own 2026-08-11 entry above (`ringStateInputs(for:)` used to call `recordedEpisodeTags`
  straight from `body`). It's a real improvement — bounded to once per 10s instead of once per
  arbitrary `AppState` publish — but is still blind-interval polling for state that has real
  triggers elsewhere (a recording starting/stopping, series added/removed/deleted), where the web
  guide's equivalent scan (`WebServer.swift`'s `buildGuideGridHTML`) only re-runs on those actual
  events. Also unclear whether `refreshRecordedTags()` actually executes on `@MainActor`: unlike
  `body`, plain private methods in a `View`-conforming struct aren't automatically MainActor-isolated
  by protocol inference in current Swift, and `.task {}`'s closure isn't inherently MainActor either
  — this file's pre-existing `boundaryRefreshLoop()` uses the identical `.task {}` + mutate-`@State`
  pattern already, so this is consistent with established precedent here, not a new deviation, but
  worth a definitive check (Instruments thread check, or just add an explicit `@MainActor` to be
  sure) next time this loop is touched, since `@State` mutation off the main thread is technically
  unsupported even when it happens to work in practice.
- Verified `managedShowBySeriesID`/`managedShowByTitle` removal (`AppState.swift`) left no orphaned
  references anywhere (`grep -rn` across the whole tree: zero hits in `Sources/`/`docs/`), and
  `ManagedFlagView`'s removal (`GuideViewHelpers.swift`, replaced by `GuideRingState`/
  `guideRingBadge`) likewise — the one remaining hit (`docs/WatchNowView.md:57`) is deliberate
  past-tense prose describing what the new ring badge replaced, not a stale live reference.
- Overall diff scope discipline is unusually clean for a 32-commit range: every hunk traces to its
  commit's stated purpose, doc updates (`docs/WatchNowView.md`, `docs/WebServer.md`,
  `docs/VLCBridge.md`) kept pace with each behavioral change in the same commit rather than lagging,
  and `issues_resolved.md`/`ISSUES.md` were updated alongside the fixes they describe. No drive-by
  refactors or opportunistic formatting churn found outside what each commit's own message
  describes.

## 2026-08-16 — Pre-release craftsmanship pass (AppState.swift, WebServer.swift, VLCBridge.swift, RecordingManager.swift)

- Full-file read of all four (no diff — standalone quality pass). Overall verdict: unusually
  disciplined for this size (3552/2090/794/319 lines) — every non-obvious line is commented with
  *why*, not just *what*; re-resolve-by-show_id-after-await is applied consistently everywhere
  `shows` can mutate across a suspension point; every `show_id`-keyed side table has a matching
  `deleteShow` purge (spot-checked all of them against the "New show_id-keyed tracking table"
  invariant — none leak). No dead code found: grepped every maintenance-panel/settings action
  (`organizeSeriesRecordings`, `refreshAll`, `resetAllFailCounts`, `reactivatePausedShows`,
  `rediscoverDevices`, `watchInVLC`, `watchRecordingInVLC`, `checkWebhookURL`, `quickRecord`,
  `seekRecordingToLiveEdge`) and every RecordingManager/VLCBridge private func — all have live
  call sites.
- `AppState.swift:3346` — `let statusURL = URL(string: device.statusURL)!` (inside
  `startSignalScan`'s per-batch polling loop) force-unwraps a URL built from the device's
  self-reported `LocalIP`. The near-identical construction 160 lines earlier
  (`fetchDeviceStatusUncached`, `AppState.swift:3184`) safely guards the same
  `URL(string: device.statusURL)` with `guard let`. `LocalIP` comes from mDNS/UDP discovery, not a
  hardcoded literal, so in principle a malformed value could crash the signal-scan Task (not the
  main app — `Task { }`, but still a bad user experience mid-scan). Not fixed (out of scope for
  this review agent) — trivial to align with the safe pattern next time this function is touched.
- `WebServer.swift:9` — `final class WebServer: @unchecked Sendable`. The two collections genuinely
  read/written across queues (`sseConns`, `liveConns`) are correctly `NSLock`-protected. But several
  other stored properties (`listener`, `stateCallback`, `activePort`, `cachedHTML`/`cachedHTMLGzip`/
  `cachedVerticalHTML*`, `verticalRouteEverRequested`, `lastTXTDict`) have no lock and rely entirely
  on an unenforced convention: the cache/state vars are only ever mutated from `@MainActor`-marked
  methods (`prebuildPageHTML`, `routeOnMain`, `updateTXTRecord`), while `listener`/`stateCallback`/
  `activePort` are set once in `start()`/`stop()` (called from AppState on the MainActor) and read
  from the `queue` GCD callbacks (`handleConnection`, `accumulate`, etc.) with no synchronization
  barrier beyond GCD's own happens-before on enqueue. This has clearly worked in practice (the
  `@unchecked Sendable` box for the concurrent-gzip pointer trick even documents its own safety
  reasoning inline), but it's a wider unchecked surface than just the two locked arrays — worth a
  second look if a future change starts mutating `cachedHTML`/`listener`/etc. from a non-MainActor,
  non-`start()/stop()` call site, since the compiler will not catch a new race there.
- `VLCBridge.swift`'s dlopen of `libvlc.dylib`/`libvlccore.dylib` from VLC.app and its hardened-
  runtime/library-validation implications are already fully documented in
  `docs/MAS_COMPLIANCE.md` ("VLC in-app player (dlopen)") — confirmed current, not re-flagged here
  per this agent's own instructions on accepted debt.
- `RecordingManager.swift` — curl spawning is the one already-accepted MAS blocker
  (`docs/MAS_COMPLIANCE.md`); no new spawned binaries or new sandbox-hostile patterns introduced.
  `spawnDetached`'s posix_spawn usage (POSIX_SPAWN_SETSID, explicit fd redirection, no shell
  interpolation of user data into argv) is clean — arguments are passed as an array, not shell-
  joined, so there's no injection surface from show titles/paths containing shell metacharacters.
- Time-based waits audited for the "should this be event-driven instead" question — all found
  legitimate, not laziness: `AppState.swift:3137`'s 1.5s post-recording-start/stop delay before
  polling `status.json` (hardware needs real time to reflect a tuner state change — no push
  notification exists from the device), and `AppState.swift:3356`'s 500ms×3 signal-scan sampling
  loop (deliberately sampling over time to build a rolling average, not polling for a boolean
  condition). Both are commented with the actual reason. No `asyncAfter`/`Task.sleep` found that's
  papering over a real race (the SIGTERM handler's 2s cap on in-flight Discord sends is a genuine
  bounded-wait-with-timeout pattern, not a guess).

## 2026-08-17 — Full-codebase craftsmanship sweep (remaining files not covered by the 2026-08-15/16 passes: HDHRManager, ConfigManager, GuideStore, Models, ChannelIconCache, ChannelSignalStore, DiscordNotifier, UpdateChecker, XmltvParser, CompatibilityHelpers, all of Views/)

- Confirmed the same unguarded `FileManager.default.urls(for:in:)[0]` force-subscript pattern
  already accepted for `ConfigManager.swift:35` (Documents-fallback path) also exists at
  `ChannelIconCache.swift:20` (`.cachesDirectory`) and `ChannelSignalStore.swift:25`
  (`.applicationSupportDirectory`) — three total instances of the identical hazard class, only one
  of which was previously catalogued in ISSUES.md. Same risk profile as the original entry
  (crashes only if the array is ever empty — not realistic today, unsandboxed; a future App
  Sandbox entitlement gap could trigger it). Not fixed here (out of scope for this review agent);
  worth broadening the existing ISSUES.md entry to cover all three next time any of them is
  touched, using the safer `.first ?? <fallback>` pattern `ConfigManager.init` already uses one
  call site earlier in the same file.
- Read every remaining source file in full (no diff — standalone sweep) against the usual four
  lenses (hacky/scope/dead-code/efficiency) plus the notarization/MAS trajectory lens. Verdict:
  unusually clean, consistent with the two prior 2026-08-15/16 passes over AppState/WebServer/
  VLCBridge/RecordingManager — no new hacks, no dead code (checked candidate "possibly unused"
  private funcs across all six largest Views files by grep-count heuristic; every hit was either a
  protocol-required delegate method or a genuinely cross-file-called symbol, e.g.
  `VLCPlayerWindowManager.closeIfPlaying`/`.focus()` called from `AppState.swift`), no stray
  TODO/FIXME/HACK markers, no commented-out code blocks, no `#if false`.
- `SettingsView.swift`'s `runBrew()` (`Process()` spawning `/opt/homebrew/bin/brew` /
  `/usr/local/bin/brew` to install VLC/hdhomerun_config from Settings → Maintenance) is a second
  spawned-binary class beyond curl — already fully catalogued as MAS blocker #4 in
  `docs/MAS_COMPLIANCE.md` and cross-referenced in `TODO.md`; not re-flagged as new.
- `GuideStore.swift`, `ChannelIconCache.swift`, `HDHRManager.swift`, `ConfigManager.swift`,
  `DiscordNotifier.swift`, `XmltvParser.swift` — all read start-to-finish, all clean: every
  force-unwrap present is on a genuinely-static literal (hardcoded URLs, well-known enum switches
  with exhaustive non-nil branches), every `Task.sleep`/`asyncAfter` found across `Views/` is
  either a real debounce with a stated reason (`ShowFormSection.swift:154`'s 350ms duplicate-check
  debounce, `SettingsView.swift`'s `SignalRing` pulse-animation timing) or pure UI-animation
  timing, not a disguised synchronization wait. `WatchNowView.swift`'s `boundaryRefreshLoop`/
  `recordedTagsRefreshLoop` polling (already the subject of a 2026-08-15 CODE_NOTES entry above)
  is the one still-open "polling where events could exist" item in this whole area — no new
  instances of that pattern found elsewhere.

## 2026-08-22 — v2.0.5 pre-release full-diff review (v2.0.4..main, 62 commits)

- Reviewed `git diff v2.0.4..main` (AppState/WebServer/GuideStore/VLCPlayerView/VLCBridge/
  SettingsView/UpdateChecker/RecordingManager/HDHRManager/ChannelIconCache/DiscordNotifier/
  ConfigManager/Models/guide.js) end to end plus a `swift build` of every touched file (clean, zero
  warnings). Verdict: no hacks, no scope creep, no dead code, no new efficiency regressions — one
  of the cleanest multi-commit ranges reviewed so far. Every non-trivial change carries a
  load-bearing WHY comment; several are genuine bug fixes with real repro evidence cited inline
  (VLCBridge.swift's `releasePlayer` use-after-free window on `retainedDrawable`/`drawableView`,
  HDHRManager.swift's UDP-reply DeviceID-TLV-collapsing-duplicate-devices fix, AppState.swift's
  truncated-recording-passing-as-"already recorded" floor found via a real 25-min-into-60
  tuner-reboot case on 2026-08-22).
- `Sources/hdhr_VCR/VLCBridge.swift` `releasePlayer()`: fixed a genuine use-after-free — previously
  nilled `retainedDrawable`/`drawableView` synchronously before the async `libvlcQueue.async`
  release ran, while libvlc can still dispatch drawable callbacks off-main after
  `libvlc_media_player_release` returns. Now deferred into a `Task { @MainActor }` inside the
  release completion, guarded by `self.mediaPlayer == nil` so a quick `ensurePlayer()` reopen that
  legitimately reused the view in the meantime isn't torn down out from under it. Worth remembering
  as the canonical example of "why teardown order matters here" if this file is touched again.
- `Sources/hdhr_VCR/RecordingManager.swift:58-70` (spawn failure) and `Sources/hdhr_VCR/Models.swift`
  (`RotatingLogFile` `FD_CLOEXEC`) / `RecordingManager.swift`'s `POSIX_SPAWN_CLOEXEC_DEFAULT`: this
  release's fd-hygiene pass (commit a3b9174) is thorough — every spawned-child fd-inheritance path
  (curl, log handles, the web server's listener socket) is now closed-on-exec by default, with only
  the three explicitly-wired fds (stdin/stdout/stderr via `posix_spawn_file_actions`) surviving
  exec. No gaps found on re-check.
- Commit 23f4e28 ("remove: Homebrew install UI and PATH-prepend, per user request") deleted
  `SettingsView.swift`'s `runBrew()`/`brewInstallRow` (spawned `/opt/homebrew/bin/brew` or
  `/usr/local/bin/brew` to install VLC/hdhomerun_config) — this was previously catalogued in this
  same notes file (2026-08-16 entry) as MAS blocker #4 / a second spawned-binary class beyond curl.
  It is now gone; `docs/MAS_COMPLIANCE.md`/`TODO.md` should be checked next time either is read to
  confirm that blocker entry was also removed there (not verified in this pass — out of scope for
  a code-quality review, flagged for the docs-auditor angle instead).
- `Sources/hdhr_VCR/ChannelIconCache.swift:25` / `Sources/hdhr_VCR/ChannelSignalStore.swift:25` —
  the `.urls(for:in:)[0]` array-indexing hazard already catalogued in this file's earlier
  (pre-2026-08-22) entry is still present unchanged; this range's own test-seam additions
  (`init(cacheDir:)`/`init(appSupportDir:)`) touched the same lines but only added an `?? real-path`
  test override, not a fix for the `[0]` vs `ConfigManager.swift:13`'s safer `.first ?? fallback`
  pattern. Still accepted debt, still worth folding into the existing ISSUES.md entry next time
  either file is touched for an unrelated reason.
- `Sources/hdhr_VCR/Views/VLCPlayerView.swift`'s new fullscreen key monitor
  (`VLCPlayerWindowManager.installKeyMonitor`) hardcodes NSEvent keyCodes 123/124 (arrow
  left/right) and 53 (escape) with only inline comments identifying them, rather than named
  constants — minor style nit, not flagged as a real issue since the comments are clear and this
  is the only place in the codebase doing raw keyCode matching (no established constant to reuse).
- `Sources/hdhr_VCR/Views/VLCPlayerView.swift`'s `fullScreenTopInset: CGFloat = 32` (native
  title-bar reveal strip height estimate) is explicitly flagged by its own comment as an untuned
  guess ("macOS doesn't expose the real strip height") — worth a follow-up glance after real visual
  testing on the actual notarized build, not urgent.

## 2026-08-25 — v2.0.5..HEAD release review (hdhr_guide TUI, SeriesID Type/Scope consolidation, New Only, pull-to-refresh)

- `Sources/hdhr_guide/API.swift:87-111` `syncData(_:)` uses a `DispatchSemaphore` to bridge
  URLSession's async completion to a blocking call, polled in 100ms slices against `interrupted`.
  This is an async→sync escape hatch by the letter of the rule, but it's justified and narrow:
  `hdhr_guide` is a single-threaded terminal client with no other concurrent I/O to interleave with
  (documented inline), and the slicing exists specifically so Ctrl-C stays responsive mid-request.
  Not flagged as a hack needing fixing — correctly scoped, well-reasoned, self-documenting.
- `Sources/hdhr_guide/DebugLog.swift` writes a timestamped line to `~/Library/Logs/hdhrVCRplus-guide-debug.log`
  unconditionally on every keypress/render-path event (21 call sites in `main.swift`/`Terminal.swift`)
  — not gated behind an env var or flag, unlike `RUN_WINDOW_NAV_TESTS`/`RUN_DISK_IO_TESTS` elsewhere
  in this codebase. Bounded (2MB truncation at launch) so not an efficiency problem, and
  `docs/TUIGuide.md` documents it as an intentional standing diagnostic (a `tail -f` companion
  file), not leftover debug spam from one investigation — verified this is deliberate, not dead
  code to flag.
- `Sources/hdhr_VCR/Models.swift:239-243` `genreImpliesBonusTime`'s doc comment already
  self-discloses a 4th independent copy of the "sport" genre-matching string logic in
  `Sources/hdhr_guide_core/GuideLogic.swift` (can't import `hdhr_VCR`, an executable target, from
  there) — this is the accepted-debt pattern CLAUDE.md already calls out for `VLCBridge`'s 2-copy
  case, now genuinely a 3rd/4th copy (`guide.js`'s `_isSports`, `AddShowView.swift`,
  `GuideLogic.swift`). Not re-flagging per the reviewer brief's guidance on a documented 3rd copy,
  but worth folding into a shared TODO note if a 5th ever appears.
- `Sources/hdhr_VCR/CHANGELOG.md`'s Unreleased section documents the new "Enable Terminal Guide"
  sub-switch (line ~8) but never announces the headline feature it's a sub-switch *of* — the bundled
  `hdhr_guide` terminal client itself (new Settings → Sharing row, path display, "Open in Terminal"
  button) has no top-level CHANGELOG entry of its own before the release checklist runs. A reader
  encountering "Enable Terminal Guide" cold has no CHANGELOG context for what that terminal client
  even is. Flagged to the parent agent as a pre-release gap, not something this reviewer can fix
  (CHANGELOG.md is off-limits to write from this role).

## 2026-08-27 — FirstRunWizardView.swift (new feature review)

- The transcode-profile tag list `["none","heavy","mobile","internet720"]` is now hardcoded in a
  4th independent place (`Sources/hdhr_VCR/Views/FirstRunWizardView.swift:132-136`), joining
  `WebServer.swift:1892`, `SettingsView.swift:314-318`, and `ShowFormSection.swift:122-124`. Not
  flagged as a blocking finding for this diff (matches the existing accepted-copy pattern precedent
  set for `VLCBridge`'s route string), but 3→4 copies is exactly the threshold CLAUDE.md's own
  "flag any THIRD copy" guidance is written to catch — worth factoring into a shared
  `CaseIterable` enum (e.g. in `Models.swift` next to `Show.show_transcode`'s own comment listing
  the same 4 values) before a 5th copy appears.
- **Correction to an earlier pass's claim in this same review**: this reviewer initially asserted
  `AppState.loadConfig()` runs synchronously inside `AppState.init()` with "no load race." That's
  wrong — `AppState.init()` (`AppState.swift:355`) calls `Task { await startup() }`, an *unawaited*
  Task; `startup()` (`AppState.swift:360-393`) is what actually calls `loadConfig()`, as its first
  step, but only once that Task gets scheduled — after `init()` has already returned. A follow-up
  `/code-review` pass caught this and had it independently verified: `appState.config` genuinely
  can still read `AppConfig()`'s bare defaults at the moment the launch `.onAppear` in
  `hdhr_VCRApp.swift` first fires, exactly the same race the Dock-icon-visibility logic in that
  same `init()` already works around via its own synchronous `ConfigManager().load()` peek. Fixed
  by giving the wizard/nag launch-guard checks their own `@State private var needsFirstRunWizard`,
  seeded from that same synchronous peek rather than from live `appState.config` — see
  `hdhr_VCRApp.swift`'s `needsFirstRunWizard` and `docs/FirstRunWizardView.md`'s "Auto-open-on-
  launch" section. Left here as a reminder that "read the code" isn't the same as "traced the
  actual async call chain" — this file's own async Task dispatch was one hop away from the line
  actually being checked.
- `FirstRunWizardView`'s `hasFinished`/`hasLoadedInitialValues` `@State` guards, combined with the
  `.onChange(of: state.config.First_run_wizard_shown)` reset at
  `FirstRunWizardView.swift:87-94`, correctly defend against the same SwiftUI single-instance
  `Window` state-retention-across-close quirk that `DonationNagView.swift`'s own `.onAppear` reset
  was added for (see `docs/DonationNagView.md:17-18`) — the wizard's reset is keyed off the config
  flag transition itself rather than `.onAppear`, which is more robust here since the flag flip
  (Settings → Maintenance → "Reset First-Run Setup") is the only way the wizard ever reopens after
  a first dismissal, and it fires regardless of whether the window view instance was still alive
  or fully recreated.

## 2026-08-28 — pre-release pass over b901958..HEAD (wizard chrome, transcode gating, guide search, TUI search)

- Verified the 919a045 fix commit's 10 findings (XSS quote-escape in `hej()`, em-modal transcode
  warning, `ModelNumber` refresh in device re-probe, wizard/nag guard bidirectionality, SSE `nt`
  flag, off-actor `/api/guide-search`, concurrent lineup fetch in the wizard's network check,
  `RecordingDefaultsFields` extraction, `activateAndOpen` extraction, `selectedDeviceSupportsTranscode`
  default) are all still intact as of `HEAD` — none were partially reverted or re-broken by the
  three commits that landed after it (`a78ac58`, `fff10a8`+`9d3c04d`+`8e98623`, `09b0ea8`). No
  re-flag needed on any of the 10.
- Transcode-tag list `["none","heavy","mobile","internet720"]` is still duplicated in 3 native Swift
  spots after 919a045's `RecordingDefaultsFields` extraction reduced it from 4: `ShowFormSection.swift`
  (its own picker, intentionally separate since it has per-show copy `RecordingDefaultsFields` doesn't),
  `RecordingDefaultsFields.swift` (shared by Settings + wizard), and `WebServer.swift:1976`'s
  `validTranscode` array — plus two literal `<option>` copies in `guide-shell.html` (`#rm-transcode`/
  `#em-transcode`). Not blocking for this pass (each copy currently serves a genuinely different
  layer: native picker, native defaults form, server-side validation, client HTML), but worth a
  `CaseIterable` enum in `Models.swift` before a 6th copy appears.
- `FirstRunIntroSplash.swift`'s `FirstRunSplashContent.collect(state:count:)` polls
  `state.guideByDevice` every 100ms (bounded to ~900ms total) waiting for `ensureGuideLoaded` — a
  fire-and-forget `Task` with no completion signal — to populate poster URLs, rather than observing
  `guideByDevice`'s own `@Published` publisher. Judged acceptable here specifically because it's a
  one-time, hard-bounded (900ms), purely cosmetic splash with a placeholder fallback either way —
  not a correctness-affecting race — but it's the one spot in this diff that matches the "polling
  where an event exists" pattern CLAUDE.md's own review guidance calls out. If this pattern is
  copied elsewhere for something less decorative, prefer awaiting `state.$guideByDevice` directly.
- `deploy_release.sh` now invokes `swift build -c release --arch arm64 --arch x86_64` once for the
  real build and a second time (`--show-bin-path`, same flags) purely to resolve the output
  directory — the flag list is duplicated across the two lines rather than stored once in a
  variable. `--show-bin-path` doesn't trigger a rebuild so there's no perf cost, but the two flag
  lists can drift if one is edited without the other. Minor, build-tooling only, not blocking.

## 2026-08-28 — DMG release tooling (09b0ea8..HEAD: build_dmg.sh, build_readme_manual.swift, apply_finder_icon.swift)

- `tools/apply_finder_icon.swift` is deliberately invoked twice per `build_dmg.sh` run — once on
  `$GEN/Read Me.rtfd` and again on `$STAGE/Read Me.rtfd` after `ditto` — per the script's own
  comment, because an earlier `cp -R` was empirically observed to silently drop the custom-icon
  xattr, so neither copy is trusted to carry it without re-applying at the final staged path. Since
  the switch to `ditto` (which normally does preserve xattrs), the first application may now be
  redundant work, but it's cheap (one more `swift` script-mode invocation, one-off release tooling)
  and the defensive intent is explicit in the comment — not flagging as a bug, just noting why two
  calls exist if a future edit is tempted to remove one.

(Three other findings from this same pass — `qlmanage` rendering into the tracked `tools/dmg_assets/`
dir instead of the gitignored `generated/` subfolder, no upfront Pillow dependency check, and no
`trap` cleanup on the `mktemp` staging dir — were fixed directly in `tools/build_dmg.sh` rather than
left here; re-ran the script end-to-end afterward to confirm all three fixes actually work.)

## 2026-08-30 — CRLF header-trim fix (a5cfb81) scope verification

- Verified `RecordingManager.swift`'s two `X-HDHomeRun-Resource`/`X-HDHomeRun-Error` parsers
  (`readHDHRResource`, `readAndClearHDHRError`, ~line 108-146) were the *only* two places reading
  the curl `--dump-header` (CRLF) file — grepped `dump-header`/`headerFiles`/`X-HDHomeRun` across
  `Sources/hdhr_VCR/*.swift`, no third copy exists. `AppState.swift:594`'s
  `.trimmingCharacters(in: .whitespaces)` (in `reattachRecordings()`) parses `ps -Axo` output, not
  a CRLF header dump — `ps` lines aren't CRLF-terminated, so `.whitespaces` there is correct as-is,
  not the same bug class. `WebServer.swift:720/724` splits on `"\r\n"` first (not `"\n"`), so no
  trailing `\r` ever reaches its own `.whitespaces` trim — also not the same bug. No other
  dump-header-style parser needs the `.whitespacesAndNewlines` fix.
- `glog("[Rec] ... tuner resource: \(resource)")` (`AppState.swift:3585`) logs the value right
  after `readHDHRResource()` captures it — now clean post-fix, and the fix's own inline comments
  correctly describe the bug in past tense. No stale/misleading log messages found adjacent to
  this diff.

## 2026-08-30 — 5f4355d ShowRuntimeState consolidation (efficiency-focused review)

- Verified the trickiest migration by hand: `rebuildMenuEntries`'s `affectedIds` full-replace loop
  (`AppState.swift:1136-1143`) correctly reproduces the old `conflictingShowIDs = newConflicts`
  plain-Set-reassignment semantics for every id that had *any* footprint in `showRuntime` (not just
  current candidateShows) — a show that drops out of `candidateShows` (e.g. gets paused) while still
  flagged `isConflicting`/`conflictBeatenByFavorite` from a prior pass is correctly swept into
  `affectedIds` via the `showRuntime.filter{...}.keys` term and reset to false, matching what the old
  full Set reassignment did implicitly. No correctness gap found.
- Verified `fireDiscordCard`'s chaining (`AppState.swift:3272-3273`, using
  `showRuntime[showId]?.discordCardTask` / `showRuntime[showId, default:].discordCardTask =`)
  preserves the exact prior `discordCardTasks[showId]` behavior — `previous` is captured before the
  new Task overwrites the dict entry, so the chain (`await previous?.value` inside the new Task) is
  unchanged. Correct.
- Genuine but very minor efficiency regression, not worth fixing on its own: `rebuildMenuEntries`
  (`AppState.swift:1136`) now does `showRuntime.filter{...}.keys` — an O(showRuntime.count) scan
  plus two `Set.union` allocations — every idle tick when the menu is closed (~every
  `Idle_timer_interval`, default 10s), replacing what was a single O(1)-ish `Set` reassignment
  pre-refactor. Necessary for correctness (see bullet above), and `showRuntime.count` is bounded by
  the user's own show count (tens, not thousands) — not a real hot-path concern at this app's scale,
  same reasoning as the pre-existing 2026-07-31 `conflictBeatenByFavorite` O(N²) note in this file.
- **Fixed same day**: `resetAllFailCounts`/`reactivatePausedShows`'s `for id in showRuntime.keys { showRuntime[id]?.retryAfter = nil }`
  (`AppState.swift:2671`, `2691` at review time) forced one avoidable full copy-on-write copy of
  `showRuntime`'s backing store per call — the live `.keys` view keeps a reference to the same
  storage `showRuntime` itself uses, so the first in-loop mutation finds two owners and copies.
  Switched both to `for id in Array(showRuntime.keys) { ... }` — materializing the keys into a plain
  `Array` first drops the aliasing, so `showRuntime` is uniquely referenced again and every
  subscript mutation happens in place. Both call sites are rare, user-triggered actions (Settings
  buttons), not idle-loop hot paths, so this was a correctness-neutral cleanup, not a felt fix.
- One real, if small, hoist opportunity matching the review's specific ask: `AppState.swift:1642-1648`
  (idle loop's "first confirmation curl is alive" branch) touches `showRuntime[show.show_id]` three
  separate times in one block (a guard-read, a `pendingDiscordStart = false` write, and a
  `discordEpisodeSnapshot = ...` write) where hoisting to `var rt = showRuntime[id] ?? ShowRuntimeState()`,
  mutating both fields locally, then one `showRuntime[id] = rt` write-back would cut it to two
  dictionary touches. Fires once per recording-start confirmation (not per-tick, per-show), so
  real-world cost is negligible — flagged only because it's the one place in the diff with 3+ raw
  dictionary touches in a single block; every other multi-touch site in the diff (e.g.
  `AppState.swift:1611-1612`, `2010-2011`, `2103-2104`, `2148-2149`) is already a minimal
  read-then-write pair that a hoist wouldn't reduce further (Dictionary's `subscript(_:default:)` and
  optional-chained `dict[k]?.field =` both already use Swift's `_modify` accessor, so a single
  compound expression is already one hash lookup, not two — the "redundant lookup" risk the review
  was checking for is largely pre-empted by the stdlib itself, not a pattern this diff introduced).
- **Fixed same day**: stale in-code comments across `AppState.swift` (4 sites: `discordCardTasks`/
  `discordEpisodeSnapshots`/`showRetryAfter`/`signalDropoutTicks` referenced by their pre-refactor
  names) and `Tests/hdhr_VCRTests/Recording/TunerOccupancyTests.swift` (2 sites) all updated to
  point at `showRuntime`/`ShowRuntimeState` instead. Comment-only, no functional effect either way.
- Scope: the commit message's claim of "Also fixes a same-file, same-target duplicate…Models.swift's
  decode-fallback bonus-time check" is *not* actually in this commit's diff (`git show 5f4355d --stat`
  has no `Models.swift` entry) — that fix landed separately as `c384a0e`, immediately adjacent in
  history. Not scope creep in `5f4355d` itself, just a commit-message cross-reference to sibling
  work; worth knowing if `git log --grep`/`git blame` searches for that fix land on the wrong commit.
- `ShowRuntimeState` (`AppState.swift:36-81`) has no internal `Array`/`Dictionary` fields that would
  make its dictionary-value-type COW copies expensive — `DiscordEpisodeSnapshot.tags: [String]` is
  the only collection anywhere in the struct's transitive shape, and it's `nil` for the overwhelming
  majority of entries (only set briefly per-recording). Confirmed the value-semantics concern the
  review asked about (#3, "is CoW overhead a real hot-path issue") is not — every
  read-mutate-write cycle in the diff copies at most a handful of scalars/`Optional<Date>`/
  `Optional<Task>`, not a large collection.

## 2026-09-03 — Range v2.2.0..HEAD review (virtual tuner relay, VLCBridge, VLC gating/hot-install, Sharing settings reorg)

8 finder agents (correctness ×3, cleanup ×3, altitude, CLAUDE.md conventions) over the ~4,500-line
diff, 1-vote-verified. Conventions and both removed-behavior/cross-file-tracer angles came back
clean — the `recordableDevices`/`isVirtualRelay` guardrail refactor is well executed everywhere it
was checked. Two of the ten raw candidates were already fixed same-day (`3d12114`, from the prior
`HEAD~5..HEAD` pass); of the rest, three turned out to already be documented, deliberate design
(not gaps) once cross-checked against `docs/VirtualTunerService.md`; six are genuine, still-open —
moved to `ISSUES.md`. Full breakdown:

- **Already fixed same day (`3d12114`)** — the `relaunchForVLC()` port race and `checkVLCHotInstall()`
  timer-polling findings from the prior `HEAD~5..HEAD` review. Not re-listed below.
- **Verified as intentional, not a gap**: `WebServer.handleRecord`/`handleToggleFavorite` looking up a
  device via `state.devices.first(where:)` then separately checking `!device.isVirtualRelay`, rather
  than looking up via `state.recordableDevices`. `docs/VirtualTunerService.md`'s own `recordableDevices`
  section says this explicitly: "Single-device backstop checks on an already-known device (`addShow`/
  `updateShow`/`handleRecord`/`handleToggleFavorite`/`vlcOccupiesTuner`) check that device's own
  `isVirtualRelay` flag directly instead, and stay separate from this accessor." Correctly implemented
  per that documented design — flagged by the review because it doesn't match the more common
  `recordableDevices`-filtering pattern used elsewhere, but that's the deliberate exception, not a miss.
- **Verified as already-documented, tracked elsewhere, not new**:
  - `excludingOwnVirtualTuner` being a filter callers must remember to route through, rather than
    structurally baked into every device-merge path — this is `docs/VirtualTunerService.md`'s own
    "Guardrails" section, verbatim ("new call sites should default to this rather than raw `devices`" /
    "two full audits after initial shipment each found call sites that still missed this"). Same known,
    named architectural risk, not a fresh finding.
  - `beginTranscodeRelay`'s fixed ~0.6s startup grace period instead of an event-driven readiness
    check — already in `docs/VirtualTunerService.md`'s "Real transcode (Phase 2)" section ("still a
    fixed guess, not an event-driven readiness signal") and already named as gap #4 in this session's
    earlier "is the relay ready for release" assessment.
- **New, genuine, moved to `ISSUES.md`** (see that file for full writeups): `applyWebServerState()`
  stamping `boundWebServerPort` from live `config` instead of the port actually bound (a Settings
  port-change-mid-bind race); the virtual-tuner relay's `TunerCount`/lineup/discover JSON builders
  (`AppState.swift:848`, `WebServer.swift:2654/2686/2723`) re-deriving "is this show recording" via a
  bare `shows.filter { $0.show_recording }` instead of the canonical `recordingShows` property (which
  also excludes a show whose `show_end` has already passed) — a real, if narrow-window, inconsistency
  between what the relay advertises and what the rest of the app considers still recording; the PAT/PMT
  on-disk codec-probe fallback (`sourceIsAlreadyModernCodec`) re-reading and re-scanning ~2MB per viewer
  connection with no per-show cache; `lanIPAddress()`/`virtualTunerBaseURL()` re-running a full
  `getifaddrs()` enumeration on every `/discover.json`/`/lineup.json` request instead of caching the
  resolved LAN IP; `MenuContent.remoteRelayEntries` (the "Recording on Another Mac" list) being
  recomputed via `filter`+`flatMap` on every menu body render with no caching — landing directly in the
  "Menu rebuild churn" hot path CLAUDE.md already warns about; `usableDeviceIDs` being derived from raw
  `devices` rather than `recordableDevices`, currently harmless only because every caller happens to
  separately intersect against an already-filtered list first.
- **Noted, low value, not moved anywhere**: `LineupEntry.AudioCodec` is decoded from the wire but read
  by no production code path, only test assertions — dead stored property, not worth its own issue
  entry; fine to just delete next time that file is touched for something else, or leave as-is.
