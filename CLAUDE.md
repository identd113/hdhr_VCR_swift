# hdhr_VCR Swift

macOS menu bar app (`LSUIElement`, no Dock icon) recording TV from HDHomeRun tuners via guide-based scheduling. Swift/SwiftUI rewrite of the original AppleScript app.

> Conventions, commits, deploy rules: [`.claude/CONVENTIONS.md`](.claude/CONVENTIONS.md)

---

## Build & Deploy

```bash
./deploy.sh          # stop → swift build → copy binary → ad-hoc sign → launch → WebServerPerfTests
swift build          # build only
swift test           # Tests/hdhr_VCRTests/ (uses unsafeFlags for Swift Testing)
```

`.app` bundle at `hdhrVCRplus.app/` — binary replaced on each deploy; `Info.plist` there is live (not SPM-generated). `deploy_release.sh` = release build + Developer ID sign + notarize (`--skip-notarize` to sign only).

**Trust `swift build`, not SourceKit** — on macOS 26 Beta, SourceKit reports bogus cross-file errors ("Cannot find type X in scope", "No such module Sparkle") for same-module types. If `swift build` passes, the diagnostics are noise.

**macOS 15.0 minimum** — use string literal `"15.0"` in `Package.swift` (enum form triggers false SourceKit diagnostic). `LazyVStack(pinnedViews:)` in a bidirectional ScrollView requires macOS 15+; do not lower target.

**Info.plist**: `LSUIElement = true` · `NSAllowsLocalNetworking = true` (required for WKWebView loading `localhost:1980`).

**Logs**: `~/Library/Logs/hdhrVCRplus.log` (via `glog()`). Always read with `tail -n N` / bounded grep, never open-ended. Discord sends/edits also log to a dedicated `~/Library/Logs/hdhrVCRplus-discord.log` (via `discordLog()` in `DiscordNotifier.swift`) — one line per SEND/CREATE/EDIT with embed title, HTTP result, and (for CREATE/EDIT) the message ID used, so retry/edit patterns can be reviewed without wading through the main log.

---

## Architecture

```
hdhr_VCRApp.swift          Entry point — MenuBarExtra (.menu style — native NSMenu) + Windows (single-instance)
AppState.swift             @MainActor ObservableObject — all app logic, idle loop, state
HDHRManager.swift          Device discovery (concurrent known-hosts + mDNS + UDP) and lineup fetch
GuideStore.swift           Guide cache: fetch, index, query
RecordingManager.swift     Launches/stops curl processes, IOKit sleep-prevention assertions
ConfigManager.swift        Reads/writes ~/Library/Application Support/hdhrVCRplus/hdhr_VCR-{hostname}.json
WebServer.swift            NWListener LAN web server (port 1980) — guide HTML, JSON API, SSE push
Models.swift               All data types + glog() logging function
DiscordNotifier.swift      sendDiscordEmbed() — posts embeds to a Discord webhook URL
ChannelIconCache.swift     Actor: async disk-backed cache for channel logos
ChannelSignalStore.swift   Actor-like @MainActor store: per-channel SNQ history + stats
Views/
  MenuContent.swift        Menu bar dropdown (entire UI)
  AddShowView.swift        3-step Add Show wizard
  FloatingGuideView.swift  Browse-only guide window (WKWebView — embeds localhost:1980)
  EditShowView.swift       Edit existing show
  SettingsView.swift       NavigationSplitView settings window
  StarburstBadge.swift     Animated starburst badge for Bonus Time
  GuideViewHelpers.swift   Shared guide-view utilities + SignalBarsView
```

---

## Documentation

**`docs/*.md` are the source of truth for visual layout and style.** Read the matching doc before editing any view; cross-check after. If doc contradicts code, stop and flag — never silently reconcile. Any visual removal requires explicit approval.

Views: [MenuContent](docs/MenuContent.md) · [AddShowView](docs/AddShowView.md) · [FloatingGuideView](docs/FloatingGuideView.md) · [EditShowView](docs/EditShowView.md) · [SettingsView](docs/SettingsView.md) · [StarburstBadge](docs/StarburstBadge.md) · [WatchNowView](docs/WatchNowView.md) · [VLCPlayerView](docs/VLCPlayerView.md) · [VLCBridge](docs/VLCBridge.md) · [ShowFormSection](docs/ShowFormSection.md) · [PlayerView](docs/PlayerView.md) (historical)

Systems: [AppState](docs/AppState.md) · [GuideStore](docs/GuideStore.md) · [RecordingManager](docs/RecordingManager.md) · [Models](docs/Models.md) · [Config](docs/Config.md) · [WebServer](docs/WebServer.md) · [ChannelSignalStore](docs/ChannelSignalStore.md) · [HDHRFindings](docs/HDHRFindings.md) (live-tested device/API behavior)

---

## Invariants & Gotchas

**Tuner occupancy** — watching and recording both occupy a tuner, *except* watching a currently-recording show via Watch Now! (`AppState.watchRecordingInApp`), which plays it back from disk through the local relay (`docs/WebServer.md`'s `/api/watch-recording`) and consumes none. Always use `AppState.tunersFull(for:)`, which delegates to `activeTunerCount(for:)` = `max(status.json hardware-polled count, recordingShows + in-app VLC stream)` (VLC via the private `vlcOccupiesTuner(for:)` helper that excludes a relay session — checks `VLCBridge.shared.recordingShowId == nil`). The hardware-polled half matters when multiple machines run this app against the same physical HDHomeRun device — local `recordingShows` alone only sees this instance's own recordings. Never count recordings alone, and never count the VLC stream unconditionally — check whether it's the relay first.

**Web guide rows are never hidden** — guide filtering (genre, infomercial) dims individual `.g-prog` blocks via `.g-prog-dim`; `.g-row` elements stay visible at all times. Never add `display:none` to a row as a filter mechanism.

**Web guide managed markers are tuner-scoped** — `seriesChannel` yellow diamonds use `"deviceId:SeriesID"` / `"deviceId:title"` keys in `ManagedGuideMatcher`; they only appear on the assigned tuner. `seriesAll` shows use bare keys and appear on all tuners. `dateTime` slot keys include weekday (`"device:channel:Weekday:HH:MM"`) so a Wednesday-only show doesn't flag Friday reruns.

**Web guide offline devices** — devices referenced in `show.hdhr_record` but absent from `state.devices` get a dashed "not detected" button in the guide device bar. Never silently omit them.

**Web guide is per-tuner** — no global schedule popover. Each tuner gets a box in `#dev-bar` (`tunerBox`): name (a `setDev` guide filter when active), live count badge (→ `#t-pop`), and a **▾** that toggles a per-tuner dropdown (`#tdrop-{devId}`) of that tuner's own Recording/Up Next/Scheduled/Paused, built by `buildTunerShowsHTML(state:, deviceId:)`. With >1 tuner there is no combined "All" view; the grid bootstraps to `defaultDev` (first device with lineup+guide data) via `setDev('<id>')`. Inactive tuners — not in `state.usableDeviceIDs` (offline/absent or unreachable) — render dimmed (`.tuner-off`) with a non-clickable name and an "offline" badge, but their ▾ still lists assigned shows. Dropdowns update via `refreshGuide` (swaps each `.tdrop` body) and the recording-event SSE (`tdrop`/`tdropDev` → swaps `#tdrop-{device}`).

**Web guide now-line origin** — the live now-line plots `Date.now()` against JS `_winStart`/`_winSec`. `refreshGuide()` swaps in a grid the server rendered against a *fresh* `winStart` (advances each hour boundary), so it must re-read `data-winstart`/`data-winsec` from the new `.g-hdr` to resync those vars — else the now-line drifts ahead on the new grid. The hourly `guide_refreshed` SSE event is the background trigger.

**New show field** — (1) add to `Show` in `Models.swift` (2) `CodingKeys` entry (3) `init(from:)` with fallback default (4) update `Show.blank()`.

**Bonus Time** — `show_bonus_time` extends past guide end; sports genres default `true` via `applyGuideEntry()` (genre comes from guide `Filter` tags). Duration = `Sports_padding_minutes`.

**Web UI push** — after any state change the web UI should reflect, call `webServer.broadcastEvent(...)`; for recording start/stop use `broadcastRecordingEvent(...)` (embeds pre-rendered HTML fragments). External browsers and in-app WKWebView windows share the same SSE stream.

**WebServer.swift is ~half JavaScript** inside Swift multiline strings — regex metachars need double escaping (`\\W`), and `node --check` on extracted `<script>` blocks is the fast way to validate JS edits.

**Signal keys** — every signal-history read/write derives its key via `ChannelSignalStore.key(for:)` (trim+lowercase). A reader that only lowercases silently misses data.

**Guide API** — cloud `guide.php` caps a single call at ~29h regardless of `Duration`; `DeviceAuth` rotates (re-fetch from `/discover.json`). Details + untapped endpoints: `docs/HDHRFindings.md`.

**Menu rebuild churn** — frequent `@Published` mutations while the NSMenu is open cause rebuild glitches; batch/coalesce assignments (see `prefetchChannelIcons`).

**Testing recordings** — set `show_next = now+30s`, `show_end = now+2min`; check `show_fail_reason`; enable verbose curl (Settings → Advanced).

**Issue tracking** — bugs found during work → `ISSUES.md` (note commit hash on resolve). Deferred features → `TODO.md`.

---

## Tools

| | |
|---|---|
| `tools/setup_signing.sh` | One-time: Developer ID cert + notarization creds (run before first `deploy_release.sh`) |
| `tools/generate_sparkle_keys.sh` | One-time: EdDSA Sparkle keys → `Info.plist` / `~/.sparkle_private_key` |
| `tools/mock_hdhr.py` | Fake HDHomeRun device for discovery/guide/fault-injection testing |

## Agents (`.claude/agents/`)

| | |
|---|---|
| `log-detective` | Answers "what happened?" from `hdhrVCRplus.log` — knows prefixes, benign noise, healthy-session signatures, bounded-read rule |
| `docs-auditor` | Cross-checks `docs/*.md` claims against code; reports drift, never reconciles (flag-and-stop rule) |
| `invariants-reviewer` | Reviews a diff against the Invariants & Gotchas above — use as an extra finder angle in `/code-review` or standalone pre-commit |
| `swift-quality-reviewer` | Swift/SwiftUI/network craftsmanship review — hacks, diff scope, dead code, efficiency, notarization/App Store fitness; appends observations to `.claude/CODE_NOTES.md` |
