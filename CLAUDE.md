# hdhr_VCR Swift

macOS menu bar app (menu-bar-first; the Dock icon is hidden in steady state) recording TV from HDHomeRun tuners via guide-based scheduling. Swift/SwiftUI rewrite of the original AppleScript app.

> Conventions, commits, deploy rules: [`.claude/CONVENTIONS.md`](.claude/CONVENTIONS.md)

---

## Build & Deploy

```bash
./deploy.sh          # stop → swift build → copy binary → ad-hoc sign → launch → WebServerPerfTests (live-app tests opt-in: RUN_LIVE_PERF_TESTS=1, which deploy.sh sets)
swift build          # build only
swift test           # Tests/hdhr_VCRTests/ — full Xcode required; snapshot refs: RECORD_SNAPSHOTS=1 swift test
RUN_WINDOW_NAV_TESTS=1 swift test --filter WindowNavigationTests   # opt-in live UI test (Accessibility API); one live suite per invocation (or --no-parallel) — docs/LiveUITests.md
RUN_WINDOW_NAV_TESTS=1 swift test --filter PiPTunerChurnTests      # opt-in soak; needs both tuners idle (FEED test also needs `ssh laptop`) — docs/LiveUITests.md
```

`.app` bundle at `hdhrVCRplus.app/` — binary replaced on each deploy; its `Info.plist` is live (not SPM-generated). `deploy_release.sh` = release build + Developer ID sign + notarize (`--skip-notarize` to sign only); direct distribution only, see `docs/Distribution.md` (Mac App Store needs App Sandbox: `docs/MAS_COMPLIANCE.md`).

- **Trust `swift build`, not SourceKit** — on macOS 26 Beta SourceKit reports bogus cross-file errors ("Cannot find type X in scope"). If `swift build` passes, the diagnostics are noise.
- **macOS 15.0 minimum** — use the string literal `"15.0"` in `Package.swift`; `LazyVStack(pinnedViews:)` in a bidirectional ScrollView needs macOS 15+.
- **Info.plist**: `LSUIElement = false`; the Dock icon is set at runtime by `NSApp.setActivationPolicy` in `hdhr_VCRApp.init()` (visible until a real lineup fetch confirms Local Network access, or per `Dock_icon_mode`; see `TODO.md` "Show Stoppers"). `NSAllowsLocalNetworking = true` (WKWebView loads `localhost:1980`).
- **Logs** — `~/Library/Logs/hdhrVCRplus.log` (`glog()`), plus `-discord.log` and `-curl.log`; each keeps one `.log.1`. **Always read with `tail -n N` / bounded grep, never open-ended.** Secrets are masked. → [full text](docs/Logging.md)

---

## Architecture

`Sources/hdhr_VCR/` (one doc per area in `docs/`, named after the source file):

```
hdhr_VCRApp.swift     Entry: MenuBarExtra (.menu style) + single-instance Windows
AppState.swift        @MainActor ObservableObject: all app logic, idle loop, state
HDHRManager / GuideStore / RecordingManager (curl + sleep assertions) / ConfigManager (hdhr_VCR-{hostname}.json)
WebServer.swift       NWListener LAN server (port 1980): guide HTML, JSON API, SSE push
Models.swift          All data types + glog()
DiscordNotifier, ChannelIconCache, ChannelSignalStore, CachePruner, LocalRelay, LANFetch, AppRelocator, AppIcon, UpdateChecker, XmltvParser, TunerSharing, ReleaseNotes (RELEASES.md → About tab)
VirtualTunerService   UDP discovery + HTTP for the recording-relay "virtual tuner" (docs/VirtualTunerService.md)
VLCBridge.swift       libvlc wrapper (docs/VLCBridge.md); ThroughputTracker feeds the player status bar
WebStreaming/         Web player pipeline: AVFoundation → HLS (HLSFollower/Converter, StreamSessions, TSRebaser) — docs/WebStreaming.md
OTAGuide/             Over-the-air scan + guide (PSIPDecoder, OTAScanner, OTAStore) — docs/OTAGuide.md; OTA-only channels merge into lineups/guide
Version.swift         `appVersion` build stamp, rewritten by deploy.sh (see CONVENTIONS for committing it)
Views/                One SwiftUI view per window/section (docs/<ViewName>.md); shared: Dialogs (the only way to show a dialog), NativeContextMenu,
                      PlayerStatusBar, GuideViewHelpers, InfoButton, WindowAction, VLCPlayerView (player/PiP), WatchNowView
Resources/            guide.css, guide.js, guide-shell.html, guide-vertical.css (the web guide), hls.min.js, icons
Sources/hdhr_guide(_core)/   Bundled terminal client (docs/TUIGuide.md)
```

---

## Documentation

**`docs/*.md` are the source of truth for visual layout and style.** Read the matching doc before editing any view; cross-check after. If doc contradicts code, stop and flag — never silently reconcile. Any visual removal requires explicit approval.

Start from: [Invariants](docs/Invariants.md) (full text of every invariant) · [Tools](docs/Tools.md) · [Logging](docs/Logging.md) · [ApplicationFlow](docs/ApplicationFlow.md) (discovery → scheduling → recording → push) · [WebServer](docs/WebServer.md) · [WebStreaming](docs/WebStreaming.md) · [OTAGuide](docs/OTAGuide.md) · [HDHRFindings](docs/HDHRFindings.md) (live-tested device/API behavior) · [LiveUITests](docs/LiveUITests.md). Every view and system file has a doc of its own name in `docs/` (`MenuContent.md`, `AppState.md`, `GuideStore.md`, `VLCPlayerView.md`, …).

---

## Invariants & Gotchas

Each bullet is the binding rule; the **→ full text** link has the complete paragraph (history, measurements, edge cases) in [`docs/Invariants.md`](docs/Invariants.md). Read the full text before changing the code an invariant covers.

- **Tuner occupancy** — watching and recording both occupy a tuner, except watching a recording via Watch Now! (plays from disk through the local relay). Always use `AppState.tunersFull(for:)` (`activeTunerCount(for:)` = max(hardware-polled `status.json` count, recordings + in-app VLC stream)); never count recordings alone, and never count the VLC stream unconditionally (`vlcOccupiesTuner(for:)` excludes a relay session). → [full text](docs/Invariants.md#tuner-occupancy)
- **Virtual tuner relay guardrails** — a recording instance advertises a temporary relay tuner. Never regress: (1) discovery routes through `AppState.excludingOwnVirtualTuner(_:)`; (2) `HDHRDevice.isVirtualRelay` is checked in `addShow`/`updateShow` and `WebServer.handleRecord`; (3) every device picker and background polling loop (guide fetch, signal scan) builds from `AppState.recordableDevices`, never raw `devices`. → [full text](docs/Invariants.md#virtual-tuner-relay-guardrails)
- **No blocking dialogs** — never `NSAlert`/`NSSavePanel`/`NSOpenPanel` `.runModal()` (it freezes the web server, SSE, idle loop and recording start/stop). Use `Dialogs.show` / `await Dialogs.present` / `Dialogs.choose`; only `AppRelocator`'s launch prompt is exempt (`NoBlockingDialogsTests`). → [full text](docs/Invariants.md#no-blocking-dialogs)
- **Show pictures** — wherever a show's picture is drawn: the show's own image, then its network logo, then the app logo (`stationLogoPlaceholder` / web `/api/icon`); never a bare symbol, grey box or hidden image. Web: `imgChain()` in `guide.js`. → [full text](docs/Invariants.md#show-pictures-show-image-then-network-logo-then-app-logo)
- **OTA-only channels are ordinary channels** — merged into `lineups` (frequency-tuned, `LineupEntry.isAirTuned`) and the guide (`GuideStore.setSupplement`, genre "Over the Air"); never add a separate OTA-only code path, row or tile type. → [full text](docs/Invariants.md#ota-only-channels-are-ordinary-channels)
- **Web guide rows are never hidden** — filtering dims `.g-prog` blocks (`.g-prog-dim`); never `display:none` a `.g-row`.
- **Web guide genre filter and show search share one dim function and are mutually exclusive** — `applyFilterDim()` (guide.js) is the only place `.g-prog-dim` is toggled; never add a parallel dim pass. → [full text](docs/Invariants.md#web-guide-genre-filter-and-show-search-share-one-dim-function-and-are-mutually-exclusive)
- **Web guide managed markers are tuner-scoped, and channel-scoped for seriesChannel** — `ManagedGuideMatcher.owner(for:)`: `seriesAll` = device-only keys, `seriesChannel` = device+channel, `dateTime` includes weekday; "tuner" = HDHomeRun *device*. → [full text](docs/Invariants.md#web-guide-managed-markers-are-tuner-scoped-and-channel-scoped-for-serieschannel)
- **Web guide offline devices** — a device referenced by `show.hdhr_record` but absent from `state.devices` gets a dashed "not detected" button; never silently omit it. → [full text](docs/Invariants.md#web-guide-offline-devices)
- **Web guide is per-tuner** — no global schedule popover; each tuner has its own box + ▾ dropdown (`buildTunerShowsHTML`); >1 tuner means no "All" view. → [full text](docs/Invariants.md#web-guide-is-per-tuner)
- **Web guide now-line origin** — `applyGuidePayload` re-reads `data-winstart`/`data-winsec` and calls `updateNowLine()`; every grid payload goes through `nextEvtSeq()`. → [full text](docs/Invariants.md#web-guide-now-line-origin)
- **Guide page files** — CSS/JS/HTML are real files in `Resources/` (`guide.css`, `guide.js`, `guide-shell.html`, `guide-vertical.css`) stitched by `fillTemplate`; validate JS against the *served* page; deploy scripts copy all four. No auth beyond LAN-subnet matching: validate inputs; POSTs need `Content-Type: application/json`. → [full text](docs/Invariants.md#guide-page-cssjshtml-live-in-resourcesguidecssguidejsguide-shellhtmlguide-verticalcss)
- **New cached page variant** — share `buildGuideGridHTML`, keep `buildHTML` calls sequential, only actor-free work (gzip) in `concurrentPerform`. → [full text](docs/Invariants.md#new-cached-page-variant-in-prebuildpagehtmlbuildhtml)
- **Appearance sync is one-directional per call** — `applyNativeTheme(m)` (native → web, never posts back) and `setTheme(m)` (user click, posts back) stay two functions. → [full text](docs/Invariants.md#appearance-sync-native--embedded-guide-is-one-directional-per-call-never-a-single-shared-function)
- **New show field** — (1) add to `Show` in `Models.swift` (2) `CodingKeys` (3) `init(from:)` with fallback default (4) `Show.blank()`.
- **Per-show runtime tracking** — runtime state lives in `AppState.showRuntime[show_id]`; `deleteShow` clears it with one `removeValue`; `tunerStatus` stays a separate `@Published` dict on purpose. → [full text](docs/Invariants.md#per-show-runtime-tracking)
- **Bonus Time** — `show_bonus_time` extends past guide end; sports genres default `true` via `applyGuideEntry()`; duration = `Sports_padding_minutes`.
- **Transcode capability gate** — `effectiveTranscode = device.supportsTranscode ? show.show_transcode : "none"` is applied once, in `startRecording`; never mutate `show.show_transcode`; a new recording call site must reapply it. → [full text](docs/Invariants.md#transcode-capability-gate)
- **Web UI push** — after any state change the web UI should show, call `webServer.broadcastEvent(...)`; tuner counts via `broadcastTunerOccupancyChange`; recording start/stop via `broadcastRecordingEvent`; any show removal re-runs `updateVirtualTunerPresence()`. → [full text](docs/Invariants.md#web-ui-push)
- **Discord card sends** — always `fireDiscordCard(...)` (chains per-show sends via `showRuntime[showId].discordCardTask`), never `discordRecordingCard` directly. → [full text](docs/Invariants.md#discord-card-sends)
- **Signal keys** — every signal-history read/write derives its key via `ChannelSignalStore.key(for:)` (trim+lowercase).
- **Web server listener is IPv4-only** — `WebServer.start` sets `NWProtocolIP.Options.version = .v4` (dual-stack was ~500× slower to LAN clients, starving FEED viewers); don't remove without re-measuring. → [full text](docs/Invariants.md#web-server-listener-is-ipv4-only)
- **Guide API** — `guide.php` caps one call at ~29 h; `GuideHours` is a constant 28 (one call, no pagination); `DeviceAuth` rotates (re-fetch from `/discover.json`). Details: `docs/HDHRFindings.md`.
- **Idle-loop show-array safety** — `idleLoop()` guards overlapping runs; it, `scheduleNextAir` and `stopRecording(showId:)` re-resolve `shows` by `show_id` after any `await`, never a captured `Int` index. → [full text](docs/Invariants.md#idle-loop-show-array-safety)
- **Auto-pause-on-missing-tuner marker** — the idle loop auto-pauses/resumes on the exact `show_fail_reason == "Tuner not detected"` (`autoPauseTunerMissingReason`); any pass that flips `show_paused` must exclude it. → [full text](docs/Invariants.md#auto-pause-on-missing-tuner-marker)
- **Menu rebuild churn** — batch `@Published` writes while a menu is open (`AppState.menuIsOpen`); player context menus are native `NSMenu`s via `NativeContextMenuHost`, never SwiftUI `.contextMenu`. → [full text](docs/Invariants.md#menu-rebuild-churn)
- **Guide service outages** — `GuideStore` records *why* a fetch failed; `needsRecovery` drives retries; falls back to the newest on-disk guide (≤36 h). → [full text](docs/Invariants.md#guide-service-outages)
- **SwiftUI Menu is not a styleable button on macOS** — never rebuild a styled control as a `Menu`; Watch Now's Record is a `Button` that pops a native `NSMenu`. → [full text](docs/Invariants.md#swiftui-menu-is-not-a-styleable-button-on-macos)
- **Testing recordings** — set `show_next = now+30s`, `show_end = now+2min`; check `show_fail_reason`; enable verbose curl (Settings → Advanced).
- **Issue tracking** — bugs found during work → `ISSUES.md` (note commit hash on resolve, then move to `issues_resolved.md`). Deferred features → `TODO.md`. Repeated failed techniques → `FAILED_APPROACHES.md`.

---

## Tools

Scripts in `tools/` (setup_signing.sh, mock_hdhr.py, mock_tuner.py, mock_scenario.py, test_favorite.sh, run_test_scenarios.sh, ui_events.swift, ax_query.swift, build_dmg.sh, build_readme_manual.swift, apply_finder_icon.swift, generate_favicon.py, feed_diagnostics/, perf_baseline.py, release_checklist.py, apple_bug_repro/) and the bundled `hdhrVCRplus.app/Contents/Helpers/hdhr_guide` terminal client. Descriptions, flags and safety notes (e.g. `run_test_scenarios.sh` restarts the real app and needs sudo): [`docs/Tools.md`](docs/Tools.md).

## Agents (`.claude/agents/`)

`log-detective` (answers "what happened?" from the log) · `docs-auditor` (docs vs code drift; reports, never reconciles) · `invariants-reviewer` (a diff against the invariants above) · `swift-quality-reviewer` (craftsmanship, scope, dead code; appends to `.claude/CODE_NOTES.md`).
