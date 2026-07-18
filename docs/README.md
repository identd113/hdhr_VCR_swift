# hdhr_VCR Swift — Documentation Index

Doc per view/system: intent, architecture, key behaviors. Source of truth for visual layout — read before editing the matching view, cross-check after (see root `CLAUDE.md`).

## Views

| File | Source | Purpose |
|---|---|---|
| [MenuContent.md](MenuContent.md) | `Views/MenuContent.swift` | Menu bar dropdown — recording, scheduling, add show |
| [AddShowView.md](AddShowView.md) | `Views/AddShowView.swift` | 3-step wizard: Device → Web Guide → Details |
| [FloatingGuideView.md](FloatingGuideView.md) | `Views/FloatingGuideView.swift` | Browse-only guide window (WKWebView), FloatingWindowLevelSetter |
| [EditShowView.md](EditShowView.md) | `Views/EditShowView.swift` | Form for editing an existing scheduled show |
| [SettingsView.md](SettingsView.md) | `Views/SettingsView.swift` | App settings — draft/save pattern, all config knobs |
| [StarburstBadge.md](StarburstBadge.md) | `Views/StarburstBadge.swift` | Animated starburst badge for Bonus Time |
| [WatchNowView.md](WatchNowView.md) | `Views/WatchNowView.swift` | In-app live/recording playback picker |
| [VLCPlayerView.md](VLCPlayerView.md) | `Views/VLCPlayerView.swift` | VLC-backed player UI |
| [VLCBridge.md](VLCBridge.md) | `VLCBridge.swift` | VLCKit wrapper — playback engine behind VLCPlayerView |
| [ShowFormSection.md](ShowFormSection.md) | `Views/ShowFormSection.swift` | Shared form fields used by Add/Edit show views |
| [PlayerView.md](PlayerView.md) | — | Historical — pre-VLC AVKit player, superseded |

## Systems

| File | Source | Purpose |
|---|---|---|
| [AppState.md](AppState.md) | `AppState.swift` | Central app state, idle loop, scheduling logic |
| [GuideStore.md](GuideStore.md) | `GuideStore.swift` | Guide cache: fetch, index, query |
| [RecordingManager.md](RecordingManager.md) | `RecordingManager.swift` | curl process launch/stop, sleep-prevention |
| [Models.md](Models.md) | `Models.swift` | Data types + `glog()` |
| [Config.md](Config.md) | `ConfigManager.swift` | Config file format and read/write |
| [WebServer.md](WebServer.md) | `WebServer.swift` | LAN web server — guide HTML, JSON API, SSE push |
| [ChannelSignalStore.md](ChannelSignalStore.md) | `ChannelSignalStore.swift` | Per-channel SNQ signal history + stats |
| [HDHRFindings.md](HDHRFindings.md) | — | Live-tested HDHomeRun device/API behavior notes |

## Other

| File | Purpose |
|---|---|
| [Distribution.md](Distribution.md) | Shipping outside the App Store — notarization, updates, monetization |
| [WebServerPerfFindings.md](WebServerPerfFindings.md) | Point-in-time investigation into slow guide page loads |
| [WKWebView_guide_analysis.md](WKWebView_guide_analysis.md) | Feasibility analysis for the WKWebView guide implementation |

Root-level reference: [`CLAUDE.md`](../CLAUDE.md) — architecture overview, invariants, build/deploy.
