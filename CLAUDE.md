# hdhr_VCR Swift — Project Guide

macOS menu bar app (no Dock icon) that records TV shows from HDHomeRun tuners using guide-based scheduling. Swift/SwiftUI rewrite of the original AppleScript app.

> **Working conventions** (commits, reviews, visual changes, deploy rules, issue tracking): see [`.claude/CONVENTIONS.md`](.claude/CONVENTIONS.md).

---

## Build & Deploy

```bash
./deploy.sh          # stops app, swift build, copies binary into .app, launches
swift build          # build only
swift test           # tests in Tests/hdhr_VCRTests/ (uses unsafeFlags for Swift Testing)
```

The `.app` bundle is committed at `hdhrVCRplus.app/`. The binary is replaced on each deploy; `Info.plist` there is live (not SPM-generated).

**Minimum OS**: macOS 15.0 — set as string literal `"15.0"` in `Package.swift` (enum form triggers a SourceKit false diagnostic on macOS 26 Beta). `LazyVStack(pinnedViews:)` in a bidirectional ScrollView requires macOS 15+; do not lower the target without reverting to plain VStack.

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
Models.swift               All data types + glog() logging function
DiscordNotifier.swift      sendDiscordEmbed() — posts embeds to a Discord webhook URL
AddShowMode.swift          Enum: .menu vs .wizard
ChannelIconCache.swift     Actor: async disk-backed cache for channel logos
Views/
  MenuContent.swift        Menu bar dropdown (entire UI)
  AddShowView.swift        3-step Add Show wizard
  CableGuideView.swift     Cable TV-style guide grid (AddShowView step 2)
  FloatingGuideView.swift  Browse-only guide window
  EditShowView.swift       Edit existing show
  SettingsView.swift       NavigationSplitView settings window
  StarburstBadge.swift     Animated starburst badge for Bonus Time
```

---

## Documentation

**Docs are the source of truth for visual layout and style.** Read the relevant doc before editing a view. If a doc contradicts the code, stop and flag it — do not silently reconcile. Any visual removal requires explicit user approval.

**Views:**
- [MenuContent](docs/MenuContent.md) — dropdown structure, recording/scheduled/paused menus, add-show cascade, dark mode color rules
- [AddShowView](docs/AddShowView.md) — 3-step wizard, guide step layout, summary panel
- [CableGuideView](docs/CableGuideView.md) — cable grid layout, scroll sync, color system, performance
- [CableGuideView Pitfalls](docs/CableGuideView_pitfalls.md) — 10 failed layout attempts; read before touching guide/AddShowView outer structure
- [FloatingGuideView](docs/FloatingGuideView.md) — browse-only guide window, FloatingWindowLevelSetter
- [EditShowView](docs/EditShowView.md) — edit show window
- [SettingsView](docs/SettingsView.md) — draft/save pattern, WindowCloseInterceptor, Maintenance section
- [StarburstBadge](docs/StarburstBadge.md) — keyframeAnimator sequences, 5-tap easter egg
- [WatchNowView](docs/WatchNowView.md) — live "what's on" poster-card grid, per-channel row, Watch/Record/Edit actions
- [VLCPlayerView](docs/VLCPlayerView.md) — VLC in-app player, poster overlay, channel picker, audio selectors
- [VLCBridge](docs/VLCBridge.md) — dlopen runtime loader for libvlc.dylib, @convention(c) typedefs
- [ShowFormSection](docs/ShowFormSection.md) — shared form fields (AddShowView + EditShowView)
- [PlayerView](docs/PlayerView.md) — superseded AVKit player (reference only)

**Systems:**
- [AppState](docs/AppState.md) — startup sequence, idle loop, device discovery, computed properties, guide helpers, @Published safety rule
- [GuideStore](docs/GuideStore.md) — URL building, internal indexes, key methods, freshness
- [RecordingManager](docs/RecordingManager.md) — caffeinate+curl process model, stop, file verification, verbose logging
- [Models](docs/Models.md) — 4-state show model, state flags, scheduleNextAir, EpochDate, GuideEntry, HDHRDevice, DeviceTunerInfo, glog
- [Config](docs/Config.md) — file location/migration, all AppConfig fields with defaults, save dir resolution

---

## Development Notes

### Adding a new show field
1. Add to `Show` struct in `Models.swift`
2. Add `CodingKeys` entry
3. Add `init(from:)` decode line with fallback default
4. Update `Show.blank()` initializer

### Testing recordings without live TV
Set `show_next` to `now + 30s` and `show_end` to `now + 2min`. The idle loop picks it up and attempts curl. Check `show_fail_reason` if it fails; enable verbose curl to see the raw HTTP exchange.

### Issue tracking
Unrelated bugs found during work go in `ISSUES.md` — do not fix inline. Note the commit hash when resolved.

---

## Custom Scripts

| Script | Purpose |
|---|---|
| `deploy.sh` | Stop → build → copy binary → launch. `./deploy.sh --help` for options. |
| `tools/mock_hdhr.py` | Fake HDHomeRun device for testing discovery, guide, and fault injection. |
