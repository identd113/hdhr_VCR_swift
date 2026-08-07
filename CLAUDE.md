# hdhr_VCR Swift

macOS menu bar app (`LSUIElement`, no Dock icon) recording TV from HDHomeRun tuners via guide-based scheduling. Swift/SwiftUI rewrite of the original AppleScript app.

> Conventions, commits, deploy rules: [`.claude/CONVENTIONS.md`](.claude/CONVENTIONS.md)

---

## Build & Deploy

```bash
./deploy.sh          # stop → swift build → copy binary → ad-hoc sign → launch → WebServerPerfTests
swift build          # build only
swift test           # Tests/hdhr_VCRTests/ — full Xcode required (xctest); snapshot refs: RECORD_SNAPSHOTS=1 swift test
swift test --enable-code-coverage && xcrun llvm-cov report .build/*/debug/hdhr_VCRPackageTests.xctest/Contents/MacOS/hdhr_VCRPackageTests -instr-profile .build/*/debug/codecov/default.profdata -ignore-filename-regex='\.build|Tests/'
```

`.app` bundle at `hdhrVCRplus.app/` — binary replaced on each deploy; `Info.plist` there is live (not SPM-generated). `deploy_release.sh` = release build + Developer ID sign + notarize (`--skip-notarize` to sign only).

**Trust `swift build`, not SourceKit** — on macOS 26 Beta, SourceKit reports bogus cross-file errors ("Cannot find type X in scope", spurious "No such module" errors) for same-module types. If `swift build` passes, the diagnostics are noise.

**macOS 15.0 minimum** — use string literal `"15.0"` in `Package.swift` (enum form triggers false SourceKit diagnostic). `LazyVStack(pinnedViews:)` in a bidirectional ScrollView requires macOS 15+; do not lower target.

**Info.plist**: `LSUIElement = true` · `NSAllowsLocalNetworking = true` (required for WKWebView loading `localhost:1980`).

**Logs**: `~/Library/Logs/hdhrVCRplus.log` (via `glog()`). Always read with `tail -n N` / bounded grep, never open-ended. Discord sends/edits also log to a dedicated `~/Library/Logs/hdhrVCRplus-discord.log` (via `discordLog()` in `DiscordNotifier.swift`) — one line per SEND/CREATE/EDIT with embed title, HTTP result, and (for CREATE/EDIT) the message ID used, so retry/edit patterns can be reviewed without wading through the main log. Both files self-rotate via the shared `RotatingLogFile` (`Models.swift`) — one prior generation kept at `<name>.log.1` — so a months-long running session can't grow either log unbounded. Main log caps at 20 MB (sized off its measured ~1.2 MB/day real-world rate — roughly 2.5 weeks live + 2.5 weeks backup); the Discord log, running at ~1% of that volume, caps at 5 MB. A `tail`/bounded grep that needs history older than the current file should also check the `.1` sibling.

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

Systems: [AppState](docs/AppState.md) · [GuideStore](docs/GuideStore.md) · [RecordingManager](docs/RecordingManager.md) · [Models](docs/Models.md) · [Config](docs/Config.md) · [WebServer](docs/WebServer.md) · [ChannelSignalStore](docs/ChannelSignalStore.md) · [HDHRFindings](docs/HDHRFindings.md) (live-tested device/API behavior) · [WKWebView_guide_analysis](docs/WKWebView_guide_analysis.md) (historical)

---

## Invariants & Gotchas

**Tuner occupancy** — watching and recording both occupy a tuner, *except* watching a currently-recording show via Watch Now! (`AppState.watchRecordingInApp`), which plays it back from disk through the local relay (`docs/WebServer.md`'s `/api/watch-recording`) and consumes none. Always use `AppState.tunersFull(for:)`, which delegates to `activeTunerCount(for:)` = `max(status.json hardware-polled count, recordingShows + in-app VLC stream)` (VLC via the `vlcOccupiesTuner(for:)` helper that excludes a relay session — checks `VLCBridge.shared.recordingShowId == nil`). The hardware-polled half matters when multiple machines run this app against the same physical HDHomeRun device — local `recordingShows` alone only sees this instance's own recordings. Never count recordings alone, and never count the VLC stream unconditionally — check whether it's the relay first.

**Web guide rows are never hidden** — guide filtering (genre, infomercial) dims individual `.g-prog` blocks via `.g-prog-dim`; `.g-row` elements stay visible at all times. Never add `display:none` to a row as a filter mechanism.

**Web guide managed markers are tuner-scoped** — `seriesChannel` shows (blue `.g-st-sched` status ring + ⏱ badge, see `docs/WebServer.md`'s "Status ring + badge") use `"deviceId:SeriesID"` / `"deviceId:title"` keys in `ManagedGuideMatcher`; they only appear on the assigned tuner. `seriesAll` shows use bare keys and appear on all tuners. `dateTime` slot keys include weekday (`"device:channel:Weekday:HH:MM"`) so a Wednesday-only show doesn't flag Friday reruns. When **Skip already-recorded episodes** is on (with Series subfolders), a managed block whose `SxxExx` is already on disk shows the slate `.g-st-skip` ring + ⏭ badge (`data-skip=1`) *instead of* the blue `.g-st-sched` one — computed in `buildGuideGridHTML` via `AppState.recordedEpisodeTags(...)`, one scan per managed series per build.

**Web guide offline devices** — devices referenced in `show.hdhr_record` but absent from `state.devices` get a dashed "not detected" button in the guide device bar, and its ▾ dropdown still lists that tuner's own shows. Never silently omit them. Opening a show assigned to an undetected tuner from that dropdown shows an amber `#em-dev-warn` banner in the edit modal ("Tuner HDHR-XXXX is no longer detected…") and hides the Pause button (pausing a phantom tuner's show does nothing useful) — Cancel/Delete stay as the only meaningful actions.

**Web guide is per-tuner** — no global schedule popover. Each tuner gets a box in `#dev-bar` (`tunerBox`): name (a `setDev` guide filter when active), live count badge (→ `#t-pop`), and a **▾** that toggles a per-tuner dropdown (`#tdrop-{devId}`) of that tuner's own Recording/Up Next/Scheduled/Paused, built by `buildTunerShowsHTML(state:, deviceId:)`. With >1 tuner there is no combined "All" view; the grid bootstraps to `defaultDev` (first device with lineup+guide data) via `setDev('<id>')`. Inactive tuners — not in `state.usableDeviceIDs` (offline/absent or unreachable) — render dimmed (`.tuner-off`) with a non-clickable name and an "offline" badge, but their ▾ still lists assigned shows. Dropdowns update via `refreshGuide` (swaps each `.tdrop` body) and the recording-event SSE (`tdrop`/`tdropDev` → swaps `#tdrop-{device}`).

**Web guide now-line origin** — the live now-line plots `Date.now()` against JS `_winStart`/`_winSec`. `refreshGuide()` swaps in a grid the server rendered against a *fresh* `winStart` (advances each hour boundary), so it must re-read `data-winstart`/`data-winsec` from the new `.g-hdr` to resync those vars — else the now-line drifts ahead on the new grid. The hourly `guide_refreshed` SSE event is the background trigger.

**New show field** — (1) add to `Show` in `Models.swift` (2) `CodingKeys` entry (3) `init(from:)` with fallback default (4) update `Show.blank()`.

**New show_id-keyed tracking table** — any new `Set<String>`/`[String: X]` in `AppState` keyed by `show_id` (there are over a dozen: `showRetryAfter`, `conflictNotifiedEpochs`, `discordCardTasks`, etc.) must also be cleared in `deleteShow`, or it leaks for the life of the app session.

**Bonus Time** — `show_bonus_time` extends past guide end; sports genres default `true` via `applyGuideEntry()` (genre comes from guide `Filter` tags). Duration = `Sports_padding_minutes`.

**Web UI push** — after any state change the web UI should reflect, call `webServer.broadcastEvent(...)`; for recording start/stop use `broadcastRecordingEvent(...)` (embeds pre-rendered HTML fragments). External browsers and in-app WKWebView windows share the same SSE stream. `addShow`/`updateShow`/`deleteShow`/`pauseShow`/`resumeShow` broadcast themselves — don't rely on the caller to do it.

**Discord card sends** — always go through `fireDiscordCard(...)`, never call `discordRecordingCard` directly. `fireDiscordCard` chains per-show sends behind each other via `discordCardTasks` (mirrors `ensureLineupLoaded`'s `loadingLineupTasks` idiom) so two lifecycle events for the same show (e.g. a "Recording Started" confirmation racing a "Paused" card) can't race and orphan/duplicate a Discord message.

**Guide page CSS/JS/HTML live in `Resources/guide.css`/`guide.js`/`guide-shell.html`/`guide-vertical.css`** — real files, not Swift string literals, loaded once via `Bundle.main` (`WebServer.swift`'s `cachedGuideCSS`/`cachedGuideJS`/`cachedGuideShellHTML`/`cachedGuideVerticalCSS`) and stitched together in `buildHTML()` via `fillTemplate(_:_:)` — a single left-to-right pass that substitutes `{{TOKEN}}` placeholders for the ~18 dynamic values (tuner JSON, guide window, config flags, pre-rendered fragments, etc) without rescanning already-substituted content, so a value containing literal `{{...}}`-shaped text (e.g. a user-entered show title) can't trigger an accidental second substitution. `guide-vertical.css` is a second, separate `<style>` block (not concatenated into `guide.css`) holding only vertical time-axis mode's rules, every selector scoped under `@media (orientation:portrait)` (automatic, no manual toggle) — and it's a distinct file specifically so editing horizontal-mode CSS can't accidentally touch vertical-mode CSS or vice versa. It's per-route, not global: `buildHTML(includeVerticalCSS:)` only embeds it (and bakes `guide.js`'s `VT_ELIGIBLE` token as `true`) on `GET /vertical`; `GET /` never ships it at all, so `/` shows the standard horizontal grid regardless of device orientation — only `/vertical` responds to rotation. See `docs/WebServer.md`'s "Vertical time-axis mode" section. Normal JS/CSS escaping rules apply — no more Swift-string double-escaping — but `node --check Resources/guide.js` fails as-is since the raw template still has unfilled `{{TOKEN}}` placeholders; validate JS syntax against the *served* output instead (`curl -s localhost:1980/ | awk '/^<script>$/{f=1;next}/^<\/script>$/{f=0}f' | node --check /dev/stdin`), or strip tokens first. `deploy.sh`/`deploy_release.sh` must copy all four into `Contents/Resources/` alongside the other bundled resources; a `#if DEBUG` fallback in `templateURL(_:_:)` lets a plain `swift build` + direct binary run still find them via a source-relative path when there's no `.app` bundle. **No auth beyond LAN-subnet matching** on any endpoint — validate inputs defensively (paths, IDs, ranges) on any new mutating route rather than trusting the caller.

**Signal keys** — every signal-history read/write derives its key via `ChannelSignalStore.key(for:)` (trim+lowercase). A reader that only lowercases silently misses data.

**Guide API** — cloud `guide.php` caps a single call at ~29h regardless of `Duration`; `GuideHours` setting is clamped to 28 to stay within it (`GuideStore.load()` makes one call, no pagination); `DeviceAuth` rotates (re-fetch from `/discover.json`). Details + untapped endpoints: `docs/HDHRFindings.md`.

**Idle-loop show-array safety** — `idleLoop()` guards against overlapping runs (`idleLoopRunning`). Its passes, plus `scheduleNextAir`/`stopRecording(showId:)`, re-resolve `shows` by `show_id` after any `await` — never reuse a captured `Int` index, since `shows` can mutate (a web-UI delete, another show's own reschedule) while suspended.

**Menu rebuild churn** — frequent `@Published` mutations while the NSMenu is open cause rebuild glitches; batch/coalesce assignments (see `prefetchChannelIcons`).

**Testing recordings** — set `show_next = now+30s`, `show_end = now+2min`; check `show_fail_reason`; enable verbose curl (Settings → Advanced).

**Issue tracking** — bugs found during work → `ISSUES.md` (note commit hash on resolve). Deferred features → `TODO.md`.

---

## Tools

| | |
|---|---|
| `tools/setup_signing.sh` | One-time: Developer ID cert + notarization creds (run before first `deploy_release.sh`) |
| `tools/mock_hdhr.py` | Fake HDHomeRun device for discovery/guide/fault-injection testing |
| `tools/mock_scenario.py` | Plant mock app states via the live guide API to demo/test behavior, then clean up. Subcommands: `duplicate` (fake "already recorded" file → green skip flag), `conflict` (schedule >tuner-count overlapping shows → conflict), `record-test` (schedule a now-airing entry, verify it records, self-clean), `list`, `clean`. Safety markers: planted files carry the `19700101_0000` date signature; scheduled shows are titled `[MOCK] …`; `clean` removes only those. Needs the app running (web server on); `duplicate` also needs Series-subfolders + Skip-already-recorded on. |
| `tools/test_favorite.sh [device-ip] [channel]` | Manual diagnostic against a **real** HDHomeRun device (not a mock) — toggles a channel's favorite via `/lineup.post`, verifies via `/lineup.json`, restores the original state. Standalone bash+curl+python3, no app instance needed. Useful for confirming the device's own favorite-toggle API still behaves as expected, independent of this app's code. |

## Agents (`.claude/agents/`)

| | |
|---|---|
| `log-detective` | Answers "what happened?" from `hdhrVCRplus.log` — knows prefixes, benign noise, healthy-session signatures, bounded-read rule |
| `docs-auditor` | Cross-checks `docs/*.md` claims against code; reports drift, never reconciles (flag-and-stop rule) |
| `invariants-reviewer` | Reviews a diff against the Invariants & Gotchas above — use as an extra finder angle in `/code-review` or standalone pre-commit |
| `swift-quality-reviewer` | Swift/SwiftUI/network craftsmanship review — hacks, diff scope, dead code, efficiency, notarization/App Store fitness; appends observations to `.claude/CODE_NOTES.md` |
