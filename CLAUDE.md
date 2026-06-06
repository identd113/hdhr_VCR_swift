# hdhr_VCR Swift

macOS menu bar app (`LSUIElement`, no Dock icon) recording TV from HDHomeRun tuners via guide-based scheduling. Swift/SwiftUI rewrite of the original AppleScript app.

> Conventions, commits, deploy rules: [`.claude/CONVENTIONS.md`](.claude/CONVENTIONS.md)

---

## Build & Deploy

```bash
./deploy.sh          # stop → swift build → copy binary → ad-hoc sign → launch
swift build          # build only
swift test           # Tests/hdhr_VCRTests/ (uses unsafeFlags for Swift Testing)
```

`.app` bundle at `hdhrVCRplus.app/` — binary replaced on each deploy; `Info.plist` there is live (not SPM-generated).

**macOS 15.0 minimum** — use string literal `"15.0"` in `Package.swift` (enum form triggers false SourceKit diagnostic on macOS 26 Beta). `LazyVStack(pinnedViews:)` in a bidirectional ScrollView requires macOS 15+; do not lower target without reverting to plain VStack.

**Info.plist**: `LSUIElement = true` (no Dock icon) · `NSAllowsArbitraryLoads = true` (HTTP image URLs from guide API).

---

## Architecture

```
hdhr_VCRApp.swift          Entry point — MenuBarExtra + WindowGroups
AppState.swift             @MainActor ObservableObject — all app logic, idle loop, state
HDHRManager.swift          Device discovery (concurrent known-hosts + mDNS + UDP) and lineup fetch
GuideStore.swift           Guide cache: fetch, index, query
RecordingManager.swift     Launches/stops caffeinate+curl processes, sleep prevention
ConfigManager.swift        Reads/writes ~/Library/Application Support/hdhrVCRplus/hdhr_VCR-{hostname}.json
WebServer.swift            NWListener LAN web server — guide HTML, JSON API, SSE push events
Models.swift               All data types + glog() logging function
DiscordNotifier.swift      sendDiscordEmbed() — posts embeds to a Discord webhook URL
AddShowMode.swift          Enum: .menu vs .wizard
ChannelIconCache.swift     Actor: async disk-backed cache for channel logos
ChannelSignalStore.swift   Actor: per-channel SNQ history, bucketing, adaptive re-sample logic
Views/
  MenuContent.swift        Menu bar dropdown (entire UI)
  AddShowView.swift        3-step Add Show wizard
  CableGuideView.swift     Cable TV-style guide grid (AddShowView step 2)
  FloatingGuideView.swift  Browse-only guide window
  EditShowView.swift       Edit existing show
  SettingsView.swift       NavigationSplitView settings window
  StarburstBadge.swift     Animated starburst badge for Bonus Time
  GuideViewHelpers.swift   Shared guide-view utilities: ManagedFlagView, sortedGuideChannels, guideTimeRange, shared DateFormatters
```

---

## Documentation

**`docs/*.md` are the source of truth for visual layout and style.** Read before editing any view. If doc contradicts code, stop and flag it — do not silently reconcile. Any visual removal requires explicit approval.

**Views:**
- [MenuContent](docs/MenuContent.md) — dropdown structure, recording/scheduled/paused menus, dark mode color rules
- [AddShowView](docs/AddShowView.md) — 3-step wizard, guide layout, summary panel, CRITICAL GeometryReader constraints
- [CableGuideView](docs/CableGuideView.md) — cable grid layout, scroll sync, color system, performance
- [CableGuideView Pitfalls](docs/CableGuideView_pitfalls.md) — 10 failed layouts; **read before touching guide/AddShowView outer structure**
- [FloatingGuideView](docs/FloatingGuideView.md) — browse-only guide window, FloatingWindowLevelSetter
- [EditShowView](docs/EditShowView.md) — edit show window
- [SettingsView](docs/SettingsView.md) — draft/save pattern, WindowCloseInterceptor, Maintenance
- [StarburstBadge](docs/StarburstBadge.md) — keyframeAnimator sequences, 5-tap easter egg
- [WatchNowView](docs/WatchNowView.md) — live "what's on" grid, Watch/Record/Edit actions
- [VLCPlayerView](docs/VLCPlayerView.md) — VLC in-app player, poster overlay, channel picker, audio selectors
- [VLCBridge](docs/VLCBridge.md) — dlopen libvlc.dylib, buffered playback, rate controller
- [ShowFormSection](docs/ShowFormSection.md) — shared form fields (AddShowView + EditShowView)
- [PlayerView](docs/PlayerView.md) — superseded AVKit player (historical reference only)

**Systems:**
- [AppState](docs/AppState.md) — startup sequence, idle loop, device discovery, @Published safety rule
- [GuideStore](docs/GuideStore.md) — URL building, internal indexes, key methods, freshness
- [RecordingManager](docs/RecordingManager.md) — caffeinate+curl model, stop, HDHR response headers
- [Models](docs/Models.md) — 4-state show model, ManagedGuideMatcher, GuideEntry, HDHRDevice, glog
- [Config](docs/Config.md) — file location/migration, all AppConfig fields with defaults
- [WebServer](docs/WebServer.md) — routes, device switcher, JSON API, SSE push events, security
- [ChannelSignalStore](docs/ChannelSignalStore.md) — SNQ history actor, bucketing, passive/active collection, SignalBarsView

---

## Development Notes

**New show field**: (1) add to `Show` in `Models.swift` (2) add `CodingKeys` entry (3) `init(from:)` line with fallback default (4) update `Show.blank()`.

**Tuner occupancy** — watching and recording both occupy a tuner. Always use `AppState.tunersFull(for: deviceId)`, which counts both `recordingShows` and the in-app VLC stream (`VLCPlayerWindowManager.shared.currentDeviceID`). Never count recordings alone. Used in `startRecording`, `WatchNowView` Record button, conflict detection.

**Testing recordings** — set `show_next = now+30s`, `show_end = now+2min`. Check `show_fail_reason` on failure; enable verbose curl (Settings → Advanced) for raw exchange.

**Bonus Time** — `show_bonus_time` extends any show past guide end. Sports entries default to `true` via `applyGuideEntry()`; all other genres default `false`. Duration = `AppConfig.Sports_padding_minutes`.

**Web UI push** — call `webServer.broadcastEvent(["type": "...", ...])` after any state change the web UI should reflect (recording start/stop, show add/edit/delete). Triggers `refreshGuide()` DOM swap on all connected SSE clients; browser refreshes on any event.

**Issue tracking** — bugs found during work → `ISSUES.md` (note commit hash on resolve). Deferred features → `TODO.md`.

---

## Custom Scripts

| Script | Purpose |
|---|---|
| `deploy.sh` | Stop → build (debug) → copy binary → ad-hoc sign with Hardened Runtime → launch |
| `deploy_release.sh` | Stop → build (release) → Developer ID sign → notarize → staple → launch. `--skip-notarize` to sign only |
| `tools/setup_signing.sh` | One-time: CSR, Developer ID cert, notarization credentials, patches `deploy_release.sh`. Run before first `deploy_release.sh` |
| `tools/generate_sparkle_keys.sh` | One-time: EdDSA Sparkle keys; patches public key into `Info.plist`; private key → `~/.sparkle_private_key` |
| `tools/mock_hdhr.py` | Fake HDHomeRun device for testing discovery, guide, and fault injection |
