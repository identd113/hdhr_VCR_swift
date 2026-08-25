# Mac App Store Compliance Notes

Status of each requirement for submitting hdhrVCRplus to the Mac App Store.

> **This entire document is about App Store (sandboxed) submission — not plain notarization.**
> Notarized Developer ID distribution (the real, notarized release you get from
> `./deploy_release.sh` with no flags — already working and already shipping since v2.0.0, not the
> `--adhoc` build) does **not** require the App Sandbox, so none of the blockers below apply to it.
> `deploy_release.sh` and `tools/setup_signing.sh` already implement full sign + notarize + staple,
> and the Apple Developer Program membership + Developer ID cert are already set up — nothing is
> missing for that path. Everything on this page — subprocess spawning, dlopen, `Process()`,
> security-scoped bookmarks — is only a problem if the goal is the **Mac App Store** specifically.

---

## Done ✅

### 3. Launch at Login — SMAppService
Replaced `~/Library/LaunchAgents/` plist with `SMAppService.mainApp.register()` / `.unregister()`.  
Requires bundle ID `com.hdhr.vcrplus` (already set in Info.plist).

### 4. `Process()` for brew installs — resolved 2026-08-19
The brew install UI (`SettingsView.swift`'s `runBrew()`/`brewInstallRow`/Maintenance → Tools section) was removed entirely, not just for MAS — it wasn't pulling its weight generally (VLC is still detected via `NSWorkspace`/`VLCBridge.locateApp()` for the "Watch in VLC" toggle; only the install-it-for-me buttons and the `Process()` spawn of `brew` are gone). This blocker no longer applies to either distribution track.

### 7. Privacy Manifest
`Sources/hdhr_VCR/PrivacyInfo.xcprivacy` declares:
- `NSPrivacyAccessedAPICategoryUserDefaults` (CA92.1) — `@AppStorage` and `UserDefaults.standard`
- `NSPrivacyAccessedAPICategoryFileTimestamp` (C617.1) — `FileManager.attributesOfItem` for recording file sizes
- `NSPrivacyAccessedAPICategoryDiskSpace` (85F4.1) — `FileManager.attributesOfFileSystem` for pre-recording disk check

### 9. ATS Exception Narrowed
`NSAllowsArbitraryLoads` replaced with `NSAllowsLocalNetworking` in Info.plist.  
Covers all LAN device HTTP URLs (192.168.x.x, 10.x.x.x, 172.16–31.x.x). Guide API, Discord, and channel icons all use HTTPS.

---

## Blockers 🚧

### 1. Recording via curl subprocess
**What:** `RecordingManager.swift` spawns `/usr/bin/curl` via `posix_spawn`. Sandbox forbids subprocess spawning of external binaries.

**Option A — URLSession (recommended):** Replace with `URLSessionDataDelegate`; response headers come directly from `URLResponse` (no dump-header file); `task.cancel()` replaces `kill(pid, SIGTERM)`; `pids: [String: Int32]` becomes `tasks: [String: URLSessionDataTask]`. IOPMAssertion code unchanged. ~100–150 line rewrite.
- **Caveat:** URLSession tasks die with the app process. The current curl processes survive app crashes and are reattached on restart via `reattach(showId:pid:)`. That feature is lost with URLSession.

**Option B — XPC Service:** A separate helper process inside the bundle handles streams independently. Preserves crash-resilience. Significant architecture change.

**Option C — Bundle curl:** Place a signed curl binary at `Contents/Helpers/curl`, launch via `Bundle.main.bundleURL`. Sandboxed apps may execute binaries within their own bundle. Adds ~2.5 MB, requires ongoing security updates.

### 2. VLC in-app player (dlopen)
**What:** `VLCBridge.swift` dlopens `libvlc.dylib`/`libvlccore.dylib` from VLC.app, located via `NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.videolan.vlc")` (wherever it's installed — Homebrew cask, `~/Applications`, etc., not a hardcoded `/Applications/VLC.app` path). Two problems either way: (1) cross-app bundle file access is forbidden in sandbox; (2) `com.apple.security.cs.disable-library-validation` — which the current entitlements require — is forbidden in MAS builds.

**Options:**
- Drop in-app player for the MAS version. Show stream URL; let user open in external VLC.
- Bundle `libvlc.dylib` inside the app (~50 MB+; complex LGPL compliance).

Neither is trivial. AVPlayer cannot replace VLC because it does not support MPEG-2 (the transport format used by most HDHomeRun tuners).

### 5. Arbitrary recording directory path
**What:** Config stores raw path strings. Sandbox only permits write access to directories the user explicitly selects via NSOpenPanel (or a folder covered by a specific asset entitlement — see below). Switching path *storage* from an absolute string to a "well-known folder" API (e.g. `FileManager.default.urls(for: .documentDirectory, ...)`) does **not** help on its own — under sandbox that API silently redirects to the app's own private container-scoped folder, not the real shared one, regardless of how the path is written. Access is entitlement/bookmark-based, not syntax-based.

**Refined two-tier fix (2026-08-19 discussion), smaller in practice than it first looks:**
- **Default location (`~/Movies/hdhr_videos`, this app's existing `Show.localFallbackDir`)**: request `com.apple.security.assets.movies.read-write` (verify exact key against current Apple docs before implementing). Grants access to the real `~/Movies` with **no picker, no bookmark, no migration** — invisible to any user who never overrides the folder. Since this is already the app's fallback default, this alone covers the common case for free.
- **Custom/override locations** (this app already supports both a global `Hdhr_setup_folder` default and a per-show `show_dir` override, each picked via the existing `chooseFolder()` `NSOpenPanel` in Settings/`AddShowView`/`EditShowView`): security-scoped bookmarks, but keyed **per distinct folder actually chosen**, not per show — multiple shows pointed at the same custom folder share one bookmark. Capture `url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)` at the exact moment each existing `chooseFolder()` panel already returns a URL (no new UI step), store alongside the plain path string in a small `[folderPath: Data]` map. On each recording: resolve the bookmark matching that show's `posixRecordDir`, `URL(resolvingBookmarkData:options:)` + `startAccessingSecurityScopedResource()` around the write, `stopAccessingSecurityScopedResource()` after.
- **New, genuinely user-visible surface**: a bookmark can fail to resolve (OS security reset, app moved, corrupted data) — needs a friendly "we lost access to `X` — please re-select this folder" recovery prompt instead of a silent failure, not just a one-time migration screen.

**Migration note**: this only matters for a *new* MAS install to begin with — MAS and direct-distribution are separate sandbox containers, so an existing direct-distribution user moving to MAS starts with a genuinely empty container regardless (no config, no folder access, nothing carries over automatically). See TODO.md's "First-run/onboarding flow" entry, which folds this folder-picker/bookmark-capture step into a broader first-launch experience, including an Import Config path for exactly this migration case (Export/Import Config shipped 2026-08-19).

---

## Required Policy 📋

### 6. Remove Sparkle auto-updater ✅ Done
Sparkle was removed from the app entirely (commit `6e9dca8`) — no `Package.swift`
dependency, no framework bundling in the deploy scripts, no About-tab update UI,
and no `SUFeedURL`/`SUPublicEDKey` in `Info.plist`. Nothing further needed here.

### 8. App Store Connect registration
Bundle ID `com.hdhr.vcrplus` must be registered in App Store Connect under your Apple Developer account before submission. Entitlements file will also need `com.apple.application-identifier` and `com.apple.developer.team-identifier` keys (replaced the current ad-hoc `–` signing).

---

## Already Fine ✅

| Feature | Why it's fine |
|---|---|
| IOPMAssertion (sleep prevention) | IOKit framework call, not a subprocess |
| NWListener web server | `network.server` entitlement present |
| NWBrowser + UDP device discovery | `network.client` entitlement present |
| `~/Library/Application Support/` config | Standard sandbox-accessible path |
| Discord webhook | Outbound HTTPS, `network.client` covers it |
| GitHub Releases update check (`UpdateChecker.swift`) | Outbound HTTPS to `api.github.com`, same `network.client` coverage; read-only, no download/install |
| Channel icon disk cache | Within sandbox container |
| Sparkle signature key in Info.plist | Harmless if Sparkle is removed |
| `hdhr_guide` bundled CLI | No subprocess spawn, no dlopen — fine as-is for a future MAS build too. |
