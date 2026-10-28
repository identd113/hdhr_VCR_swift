# hdhr_VCR Swift

macOS menu bar app (menu-bar-first; the Dock icon is hidden in steady state — see the Info.plist note below) recording TV from HDHomeRun tuners via guide-based scheduling. Swift/SwiftUI rewrite of the original AppleScript app.

> Conventions, commits, deploy rules: [`.claude/CONVENTIONS.md`](.claude/CONVENTIONS.md)

---

## Build & Deploy

```bash
./deploy.sh          # stop → swift build → copy binary → ad-hoc sign → launch → WebServerPerfTests (live-app tests are opt-in: RUN_LIVE_PERF_TESTS=1, which deploy.sh sets)
swift build          # build only
swift test           # Tests/hdhr_VCRTests/ — full Xcode required (xctest); snapshot refs: RECORD_SNAPSHOTS=1 swift test
RUN_WINDOW_NAV_TESTS=1 swift test --filter WindowNavigationTests   # (one live suite per invocation, or add --no-parallel when combining filters: Swift Testing runs different suites at the same time and they all drive the one running app) opt-in: drives real app windows via Accessibility API (osascript); needs the app running + Accessibility permission granted to whatever runs swift test
RUN_WINDOW_NAV_TESTS=1 swift test --filter PiPTunerChurnTests      # opt-in soak: PiP/FEED/window churn, checks hardware + app tuner counts after every step; needs both tuners idle (FEED test also needs `ssh laptop`) — see docs/LiveUITests.md
swift test --enable-code-coverage && xcrun llvm-cov report .build/*/debug/hdhr_VCRPackageTests.xctest/Contents/MacOS/hdhr_VCRPackageTests -instr-profile .build/*/debug/codecov/default.profdata -ignore-filename-regex='\.build|Tests/'
```

`.app` bundle at `hdhrVCRplus.app/` — binary replaced on each deploy; `Info.plist` there is live (not SPM-generated). `deploy_release.sh` = release build + Developer ID sign + notarize (`--skip-notarize` to sign only). This covers direct distribution only (see `docs/Distribution.md`) — Mac App Store distribution is a separate, larger track requiring App Sandbox; see `docs/MAS_COMPLIANCE.md` for the full blocker list.

**Trust `swift build`, not SourceKit** — on macOS 26 Beta, SourceKit reports bogus cross-file errors ("Cannot find type X in scope", spurious "No such module" errors) for same-module types. If `swift build` passes, the diagnostics are noise.

**macOS 15.0 minimum** — use string literal `"15.0"` in `Package.swift` (enum form triggers false SourceKit diagnostic). `LazyVStack(pinnedViews:)` in a bidirectional ScrollView requires macOS 15+; do not lower target.

**Info.plist**: `LSUIElement = false` — no longer unconditionally true; the Dock icon is now controlled at runtime via `NSApp.setActivationPolicy(_:)` in `hdhr_VCRApp.init()` (`.regular`/Dock-icon-visible until `AppState.confirmLocalNetworkAccessIfNeeded()` confirms a real lineup fetch succeeded, or per `Settings → Advanced`'s `Dock_icon_mode` override — `"always"`/`"never"`/`"auto"`, see `TODO.md`'s "Show Stoppers" entry for why: a background-only process may never receive the system's Local Network permission prompt). `NSAllowsLocalNetworking = true` (required for WKWebView loading `localhost:1980`).

- **Logs** — Main log `~/Library/Logs/hdhrVCRplus.log` (via `glog()`), plus `-discord.log` and `-curl.log`; each self-rotates keeping one `.log.1` — check it for older history. **Always read with `tail -n N` / bounded grep, never open-ended.** Secrets (`DeviceAuth`, Discord webhook tokens) are masked in logs. → [full text](docs/Logging.md)

---

## Architecture

```
hdhr_VCRApp.swift          Entry point — MenuBarExtra (.menu style — native NSMenu) + Windows (single-instance)
AppState.swift             @MainActor ObservableObject — all app logic, idle loop, state
HDHRManager.swift          Device discovery (concurrent known-hosts + mDNS + UDP) and lineup fetch
GuideStore.swift           Guide cache: fetch, index, query
RecordingManager.swift     Launches/stops curl processes, IOKit sleep-prevention assertions
ConfigManager.swift        Reads/writes ~/Library/Application Support/hdhrVCRplus/hdhr_VCR-{hostname}.json (adopts the newest other hdhr_VCR-*.json if the hostname changed)
WebServer.swift            NWListener LAN web server (port 1980) — guide HTML, JSON API, SSE push
Models.swift               All data types + glog() logging function
DiscordNotifier.swift      sendDiscordEmbed() — posts embeds to a Discord webhook URL
ChannelIconCache.swift     Actor: async disk-backed cache for channel logos
CachePruner.swift          Pure, injectable stale-file pruner (guide cache, --dump-header temp files) — see docs/GuideStore.md, docs/RecordingManager.md
ChannelSignalStore.swift   Actor-like @MainActor store: per-channel SNQ history + stats
VirtualTunerService.swift  UDP discovery responder for the recording-relay virtual tuner (see docs/VirtualTunerService.md)
ThroughputTracker.swift   Rolling 2-minute bitrate window → steady / trending / stalled (VLC raw × 8 = Mbps); pure, unit-tested (docs/VLCPlayerView.md "Status bar")
LocalRelay.swift           URL shapes for the in-process /api/watch-recording and FEED-cache relays the player reads from
LANFetch.swift             Bounded-timeout LAN HTTP fetch helper (tuner requests are cut off after 10 s and logged as [LAN])
AppRelocator.swift         Release-build "Move to Applications?" prompt — atomic copy-then-swap, never offered inside a git checkout
AppIcon.swift              Pre-baked menu-bar/About bitmaps (idle, recording, up-next, FEED) and the station-logo placeholder
CompatibilityHelpers.swift CRC-32 shared by HDHRManager's UDP discovery trailer and WebServer's gzip trailer
UpdateChecker.swift        GitHub-release update check (Sparkle is a parked dead end — SPM resolve hangs)
XmltvParser.swift          XMLTV → [GuideChannel], same output shape as the guide.php JSON decoder (`Guide_use_xml`)
OTAGuide/                  Over-the-air guide (beta; scan window = Views/OTAScanView.swift, docs/OTAScanView.md): PSIPDecoder (ATSC tables → channels/events), OTAGuideConverter (→ [GuideChannel]), OTAScanner (actor: sweeps RF channels on idle tuners), OTAStore, AppState+OTA — docs/OTAGuide.md, research in overtime/
TunerSharing.swift         Menu-header note for tuners in use by something other than this instance (hw vs app count)
ReleaseNotes.swift       RELEASES.md → the About tab's version chips and big-feature headline (the app bundles RELEASES.md, not the changelog; deploy*.sh copy it)
Version.swift              `appVersion` build stamp — rewritten by deploy.sh, never commit it
Views/
  MenuContent.swift        Menu bar dropdown (entire UI)
  AddShowView.swift        2-step Add Show wizard (Web Guide → Details)
  EditShowView.swift       Edit existing show
  SettingsView.swift       NavigationSplitView settings window
  StarburstBadge.swift     Animated starburst badge for Bonus Time
  DonationNagView.swift    Honor-system donation nag window
  GuideViewHelpers.swift   Shared guide-view utilities + SignalBarsView
  NativeContextMenu.swift  NSMenu-at-click-time right-click host (immune to SwiftUI re-renders)
  PiPPickerView.swift      "Add Picture-in-Picture…" picker (Recording Now / FEED / Live TV sections)
  LaunchSplashView.swift   Launch splash: logo, version, tuner/lineup/guide checklist, flying posters; flies to the menu-bar icon — or, on a first run, glides into the setup wizard (docs/LaunchSplash.md) — an AppKit window made by `LaunchSplashController`, destroyed when it ends (not a `Window` scene)
  StatusLightLegend.swift  About tab: live menu-bar light on the logo; click steps through every light/blink pattern
  KeyboardShortcutsOverlay.swift  Generic translucent "?" shortcuts card (player; docs/VLCPlayerView.md)
  RecordingDefaultsFields.swift  Shared default-recording fields (transcode, Time Machine, Bonus Time…) for Settings and the first-run wizard
  FirstRunWizardView.swift  First-run setup wizard (docs/FirstRunWizardView.md); ShowFormSection.swift = shared Add/Edit form (docs/ShowFormSection.md)
  WatchNowView.swift       Watch Now window (docs/WatchNowView.md); VLCPlayerView.swift = player/PiP (docs/VLCPlayerView.md); VLCBridge.swift = libvlc wrapper (docs/VLCBridge.md)
  PlayerStatusBar.swift    Optional 52 pt status bar under the player's video + ThroughputGraph (docs/VLCPlayerView.md "Status bar")
  TunerDiscoveryCard.swift Wizard's tuner checking/found/not-found card; NetworkFlowDiagram / WebLANDiagram / TerminalTypingDiagram = wizard "how it works" maps; DiagramAnimationSupport = shared cyclic-progress math
  Dialogs.swift            Non-blocking alerts/sheets/file pickers (`Dialogs.show`/`present`/`choose`) — the only way to show a dialog; see the "No blocking dialogs" invariant
  CaveatBanner.swift, InfoButton.swift, WindowAction.swift  Small shared pieces: muted caveat banner, (i) help popover, SwiftUI→NSWindow bridge (floating level, re-centering)
```

---

## Documentation

**`docs/*.md` are the source of truth for visual layout and style.** Read the matching doc before editing any view; cross-check after. If doc contradicts code, stop and flag — never silently reconcile. Any visual removal requires explicit approval.

Views: [MenuContent](docs/MenuContent.md) · [AddShowView](docs/AddShowView.md) · [FirstRunWizardView](docs/FirstRunWizardView.md) · [EditShowView](docs/EditShowView.md) · [SettingsView](docs/SettingsView.md) · [StarburstBadge](docs/StarburstBadge.md) · [DonationNagView](docs/DonationNagView.md) · [WatchNowView](docs/WatchNowView.md) · [VLCPlayerView](docs/VLCPlayerView.md) · [VLCBridge](docs/VLCBridge.md) · [LaunchSplash](docs/LaunchSplash.md) · [ShowFormSection](docs/ShowFormSection.md) · [PlayerView](docs/PlayerView.md) (historical) · [TUIGuide](docs/TUIGuide.md) (bundled terminal client, not a SwiftUI view)

Reference: [Invariants](docs/Invariants.md) (full text of every invariant) · [Tools](docs/Tools.md) (full tool descriptions) · [Logging](docs/Logging.md) (log files, rotation, redaction)

Systems: [ApplicationFlow](docs/ApplicationFlow.md) (mermaid map: discovery → scheduling → recording → push) · [WebServerPerfFindings](docs/WebServerPerfFindings.md) (guide-load measurements) · [AppState](docs/AppState.md) · [GuideStore](docs/GuideStore.md) · [RecordingManager](docs/RecordingManager.md) · [Models](docs/Models.md) · [Config](docs/Config.md) · [WebServer](docs/WebServer.md) · [ChannelSignalStore](docs/ChannelSignalStore.md) · [VirtualTunerService](docs/VirtualTunerService.md) · [OTAGuide](docs/OTAGuide.md) · [HDHRFindings](docs/HDHRFindings.md) (live-tested device/API behavior) · [LiveUITests](docs/LiveUITests.md) (opt-in Accessibility-driven tests) · [WKWebView_guide_analysis](docs/WKWebView_guide_analysis.md) (historical)

---

## Invariants & Gotchas

Each bullet is the binding rule; the **→ full text** link has the complete original paragraph (history, measurements, edge cases) in [`docs/Invariants.md`](docs/Invariants.md). Paragraphs shown in full here (Tuner occupancy, Virtual tuner relay guardrails, and the short ones) are not duplicated there. Read the full text before changing the code an invariant covers.

- **Tuner occupancy** — watching and recording both occupy a tuner, *except* watching a currently-recording show via Watch Now! (`AppState.watchRecordingInApp`), which plays it back from disk through the local relay (`docs/WebServer.md`'s `/api/watch-recording`) and consumes none. Always use `AppState.tunersFull(for:)`, which delegates to `activeTunerCount(for:)` = `max(status.json hardware-polled count, recordingShows + in-app VLC stream)` (VLC via the `vlcOccupiesTuner(for:)` helper that excludes a relay session — checks `VLCBridge.shared.recordingShowId == nil`). The hardware-polled half matters when multiple machines run this app against the same physical HDHomeRun device — local `recordingShows` alone only sees this instance's own recordings. Never count recordings alone, and never count the VLC stream unconditionally — check whether it's the relay first.

- **Virtual tuner relay guardrails** — while ≥1 show is actively recording, `VirtualTunerService` advertises a temporary HDHomeRun-like tuner (UDP discovery + `/discover.json`/`/lineup.json`/`/status.json`, see `docs/VirtualTunerService.md`) whose channel(s) relay the in-progress recording(s) from disk, so another hdhrVCRplus instance can watch without opening a second real tuner. Two backstops must never regress: (1) **self-exclusion** — `AppState.excludingOwnVirtualTuner(_:)` filters a newly-discovered device out of `state.devices` whenever its `DeviceID` matches `activeVirtualTunerDeviceID`; both `discoverDevices`/`probeForNewDevices` call sites must keep routing through it, or this instance would show its own relay as a normal, recordable tuner. (2) **watch-only** — `HDHRDevice.isVirtualRelay` (decoded from `/discover.json`'s non-standard `HdhrVCRplusVirtualRelay` field) is checked as a hard backstop in both `AppState.addShow`/`updateShow` (the two universal show-creation/edit funnels) and `WebServer.handleRecord`. (3) **never treated as a real tuner anywhere else** — any device-enumeration/picker AND any background polling loop (guide fetch, signal scan) must build from `AppState.recordableDevices` (`devices.filter { !$0.isVirtualRelay }`) instead of raw `devices`; a picker doesn't inherit backstop (2) for free just because `addShow` will eventually reject the result, and an unfiltered guide-fetch/signal-scan loop doesn't just fail harmlessly — it can fire a real "Guide Load Failed" notification for a device the user never configured, or (signal scan) overwrite a *real* channel's signal history with a bogus reading, since `ChannelSignalStore` keys purely by channel name, not device. Two full audits after initial shipment each found call sites that still missed this — see `docs/VirtualTunerService.md`'s Guardrails section for the current (long) list of everywhere it applies; default new device-facing code to `recordableDevices` rather than assuming raw `devices` is safe.

- **Web guide rows are never hidden** — guide filtering (genre, infomercial) dims individual `.g-prog` blocks via `.g-prog-dim`; `.g-row` elements stay visible at all times. Never add `display:none` to a row as a filter mechanism.

- **Web guide genre filter and show search share one dim function and are mutually exclusive** — `applyFilterDim()` (guide.js) is the only place `.g-prog-dim` is toggled; genre filter and show search are mutually exclusive (picking one clears the other). Never add a parallel dim pass. → [full text](docs/Invariants.md#web-guide-genre-filter-and-show-search-share-one-dim-function-and-are-mutually-exclusive)
- **Web guide managed markers are tuner-scoped, and channel-scoped for seriesChannel** — Blue ⏱ ring/badge comes from `ManagedGuideMatcher.owner(for:)`, scoped like the scheduling: `seriesAll` = device-only keys, `seriesChannel` = device+channel keys, `dateTime` keys include weekday. "Tuner" = HDHomeRun *device*, never a physical tuner port. Skip-already-recorded shows the slate ⏭ ring instead. → [full text](docs/Invariants.md#web-guide-managed-markers-are-tuner-scoped-and-channel-scoped-for-serieschannel)
- **Web guide offline devices** — Devices referenced by `show.hdhr_record` but absent from `state.devices` get a dashed "not detected" button — never silently omit them; their edit modal shows amber `#em-dev-warn` and hides Pause. → [full text](docs/Invariants.md#web-guide-offline-devices)
- **Web guide is per-tuner** — No global schedule popover: each tuner has its own box + ▾ dropdown (`buildTunerShowsHTML`); >1 tuner means no "All" view (bootstraps to `defaultDev`); inactive tuners render dimmed; an unavailable device is shown only while a show still references it. → [full text](docs/Invariants.md#web-guide-is-per-tuner)
- **Web guide now-line origin** — `applyGuidePayload` must re-read `data-winstart`/`data-winsec` from the new `.g-hdr` and call `updateNowLine()`; every grid payload goes through the `nextEvtSeq()` ordering guard. → [full text](docs/Invariants.md#web-guide-now-line-origin)

- **No blocking dialogs** — never call `NSAlert.runModal()` / `NSSavePanel.runModal()` (or `NSOpenPanel.runModal()`): the main thread sits in the modal's event loop, so the web server, SSE, FEED viewers, idle loop and recording start/stop all stop until someone answers (2026-10-14: a stray "No Tuner Available" froze `:1980`). Use `Dialogs.show(alert)` (fire-and-forget), `await Dialogs.present(alert)` (needs the answer; same `.alertFirstButtonReturn…` values) or `Dialogs.choose(panel) { url in … }`; they use a sheet on the frontmost window or a floating window when none is open. Only `AppRelocator`'s launch-time prompt is exempt (`NoBlockingDialogsTests` enforces it). A `windowShouldClose` that needs a prompt returns `false`, asks, then `close()`s (see `WindowCloseInterceptor`).

- **Show pictures** — anywhere a show's picture is drawn: the show's own image, then its network logo, then the app logo (`stationLogoPlaceholder` / web `/api/icon`); never a bare symbol, grey box or hidden image. Web uses `imgChain()` in `guide.js`. → [full text](docs/Invariants.md#show-pictures-show-image-then-network-logo-then-app-logo)

- **OTA-only channels are ordinary channels** — merged into `lineups` (frequency-tuned, `LineupEntry.isAirTuned`) and the guide (`GuideStore.setSupplement`, genre "Over the Air"); never add a separate OTA-only code path, row or tile type. → [full text](docs/Invariants.md#ota-only-channels-are-ordinary-channels)

- **New show field** — (1) add to `Show` in `Models.swift` (2) `CodingKeys` entry (3) `init(from:)` with fallback default (4) update `Show.blank()`.

- **Per-show runtime tracking** — Per-show runtime state lives in `AppState.showRuntime[show_id]` (`ShowRuntimeState`); `deleteShow` clears it with one `removeValue`. `tunerStatus` stays a separate `@Published` dict on purpose (menu rebuild churn). → [full text](docs/Invariants.md#per-show-runtime-tracking)

- **Bonus Time** — `show_bonus_time` extends past guide end; sports genres default `true` via `applyGuideEntry()` (genre comes from guide `Filter` tags). Duration = `Sports_padding_minutes`.

- **Transcode capability gate** — `effectiveTranscode = device.supportsTranscode ? show.show_transcode : "none"` is applied once, in `startRecording`; never mutate `show.show_transcode`. A new recording call site must reapply the gate itself. → [full text](docs/Invariants.md#transcode-capability-gate)
- **Web UI push** — After any state change the web UI should show, call `webServer.broadcastEvent(...)`; tuner-count changes via `broadcastTunerOccupancyChange` (the badge push is never throttled); recording start/stop via `broadcastRecordingEvent`; any show removal re-runs `updateVirtualTunerPresence()`. → [full text](docs/Invariants.md#web-ui-push)

- **Discord card sends** — always go through `fireDiscordCard(...)`, never call `discordRecordingCard` directly. `fireDiscordCard` chains per-show sends behind each other via `showRuntime[showId].discordCardTask` (mirrors `ensureLineupLoaded`'s `loadingLineupTasks` idiom) so two lifecycle events for the same show (e.g. a "Recording Started" confirmation racing a "Paused" card) can't race and orphan/duplicate a Discord message.

- **Guide page CSS/JS/HTML live in Resources/guide.css/guide.js/guide-shell.html/guide-vertical.css** — Guide CSS/JS/HTML are real files in `Resources/` (`guide.css`, `guide.js`, `guide-shell.html`, `guide-vertical.css`) stitched by `fillTemplate`; validate JS against the *served* page; deploy scripts must copy all four. No auth beyond LAN-subnet matching — validate inputs; POSTs must send `Content-Type: application/json` (`requestRejectionReason`). → [full text](docs/Invariants.md#guide-page-cssjshtml-live-in-resourcesguidecssguidejsguide-shellhtmlguide-verticalcss)
- **New cached page variant in prebuildPageHTML/buildHTML** — A new cached page variant multiplies `prebuildPageHTML`'s MainActor cost: share `buildGuideGridHTML`, keep `buildHTML` calls sequential, run only actor-free work (gzip) via `DispatchQueue.concurrentPerform`. → [full text](docs/Invariants.md#new-cached-page-variant-in-prebuildpagehtmlbuildhtml)

- **Signal keys** — every signal-history read/write derives its key via `ChannelSignalStore.key(for:)` (trim+lowercase). A reader that only lowercases silently misses data.

- **Appearance sync (native ↔ embedded guide) is one-directional per call, never a single shared function** — `applyNativeTheme(m)` (native → web, never posts back) and `setTheme(m)` (a real user click, posts back) are deliberately two functions — never merge them. → [full text](docs/Invariants.md#appearance-sync-native--embedded-guide-is-one-directional-per-call-never-a-single-shared-function)

- **Web server listener is IPv4-only** — `WebServer.start(port:)` sets `NWProtocolIP.Options.version = .v4`. The default dual-stack `NWListener` sent ~500× slower to IPv4 LAN clients under Network.framework's user-space TCP stack (~0.2 MB/s, ~40% retransmits — starved every FEED viewer); IPv4-only measured ~100 MB/s. Don't remove it without re-measuring a LAN client's throughput (`issues_resolved.md`'s "FEED starvation: dual-stack NWListener").

- **Guide API** — cloud `guide.php` caps a single call at ~29h regardless of `Duration`; `GuideHours` is a constant 28 (no longer a setting) to stay within it (`GuideStore.load()` makes one call, no pagination); `DeviceAuth` rotates (re-fetch from `/discover.json`). Details + untapped endpoints: `docs/HDHRFindings.md`.

- **Idle-loop show-array safety** — `idleLoop()` guards against overlapping runs (`idleLoopRunning`). Its passes, plus `scheduleNextAir`/`stopRecording(showId:)`, re-resolve `shows` by `show_id` after any `await` — never reuse a captured `Int` index, since `shows` can mutate (a web-UI delete, another show's own reschedule) while suspended.

- **Auto-pause-on-missing-tuner marker** — The idle loop auto-pauses/resumes on the exact `show_fail_reason == "Tuner not detected"` (`autoPauseTunerMissingReason`); any pass over `pausedShows` that flips `show_paused` must exclude that marker. → [full text](docs/Invariants.md#auto-pause-on-missing-tuner-marker)
- **Menu rebuild churn** — Batch/coalesce `@Published` writes while a menu is open (`AppState.menuIsOpen`); keep the begin/end tracking root-menu-only; player context menus are native `NSMenu`s via `NativeContextMenuHost`, never SwiftUI `.contextMenu`. → [full text](docs/Invariants.md#menu-rebuild-churn)

- **Testing recordings** — set `show_next = now+30s`, `show_end = now+2min`; check `show_fail_reason`; enable verbose curl (Settings → Advanced).

- **Guide service outages** — `GuideStore` records *why* a fetch failed; `needsRecovery` (empty or last-fetch-failed) drives retries; falls back to the newest on-disk guide (≤36 h); a certificate failure alerts once per outage. → [full text](docs/Invariants.md#guide-service-outages)
- **SwiftUI Menu is not a styleable button on macOS** — Never rebuild a styled control as a SwiftUI `Menu` (macOS ignores `.borderedProminent`/`.tint`); Watch Now's Record is a `Button` that pops a native `NSMenu`. → [full text](docs/Invariants.md#swiftui-menu-is-not-a-styleable-button-on-macos)

- **Issue tracking** — bugs found during work → `ISSUES.md` (note commit hash on resolve, then move the entry to `issues_resolved.md` — `ISSUES.md` holds only what's still open or accepted-as-is). Deferred features → `TODO.md`. Repeated failed technique attempts (independent of any one bug) → `FAILED_APPROACHES.md`.

---

## Tools

| Tool | What it does |
|---|---|
| `tools/setup_signing.sh` | One-time Developer ID cert + notarization credential setup (run before first `deploy_release.sh`) |
| `tools/mock_hdhr.py` | Proxy fake HDHomeRun for discovery/guide/fault injection; `--guide-file` serves a hand-authored guide |
| `tools/mock_tuner.py` | Standalone high-fidelity HDHomeRun emulator (UDP discovery, HTTP API, streams); doubles as a third-party-client probe |
| `tools/mock_scenario.py` | Plant/clean mock app states via the live API: `duplicate`, `conflict`, `record-test`, `start`, `ensure`, `status`, `plant`, `list`, `clean` (all `[MOCK]`-marked) |
| `tools/test_favorite.sh [device-ip] [channel]` | Manual favorite-toggle diagnostic against a real device (restores state) |
| `tools/run_test_scenarios.sh [--port N]` | End-to-end scheduling-engine scenarios; **restarts the real app, needs sudo** |
| `tools/ui_events.swift` | Synthetic right-click/key events for UI tests (compiled on demand) |
| `tools/ax_query.swift` | Fast Accessibility queries for UI tests (`windows`/`find`/`count`/`text`; compiled on demand) |
| `tools/build_dmg.sh <version> <path-to-app>` | Assemble the release installer DMG via `create-dmg` |
| `tools/build_readme_manual.swift` | Build the DMG's `Read Me.rtfd` from `docs/screenshots/` |
| `tools/apply_finder_icon.swift` | Set a custom Finder icon via `NSWorkspace` |
| `tools/generate_favicon.py` | Build `Resources/favicon.ico` from two PNGs |
| `tools/feed_diagnostics/` | FEED stall root-cause toolkit (capture tagger, window extractor, TS PCR analyzer) |
| `hdhrVCRplus.app/Contents/Helpers/hdhr_guide` | Bundled terminal client for the guide (`docs/TUIGuide.md`) |
| `tools/apple_bug_repro/make_samples.sh` + `read_samples.swift` | Reproduces the AVFoundation MPEG-TS bug (timestamps crossing 2^32) with generated test streams; see `docs/AppleBugReport_TS_2e32.md` |
| `tools/perf_baseline.py <prime\|run\|compare>` | Release-to-release performance baseline (launch, idle CPU, memory, web timings) in an isolated temp home; results in `docs/perf/`, history in `docs/PerformanceHistory.md` |
| `tools/release_checklist.py <preflight\|stamp\|notes\|publish> <version>` | Release paperwork around `deploy_release.sh`: readiness report, CHANGELOG stamp, GitHub Release notes + (draft) Release, README "Latest" update; dry-run by default, never pushes or builds |

Full descriptions, flags and safety notes for every tool: [`docs/Tools.md`](docs/Tools.md).

## Agents (`.claude/agents/`)

| | |
|---|---|
| `log-detective` | Answers "what happened?" from `hdhrVCRplus.log` — knows prefixes, benign noise, healthy-session signatures, bounded-read rule |
| `docs-auditor` | Cross-checks `docs/*.md` claims against code; reports drift, never reconciles (flag-and-stop rule) |
| `invariants-reviewer` | Reviews a diff against the Invariants & Gotchas above — use as an extra finder angle in `/code-review` or standalone pre-commit |
| `swift-quality-reviewer` | Swift/SwiftUI/network craftsmanship review — hacks, diff scope, dead code, efficiency, notarization/App Store fitness; appends observations to `.claude/CODE_NOTES.md` |
