# Mac App Store Compliance Notes

Status of each requirement for submitting hdhrVCR+ to the Mac App Store.

---

## Done ✅

### 3. Launch at Login — SMAppService
Replaced `~/Library/LaunchAgents/` plist with `SMAppService.mainApp.register()` / `.unregister()`.  
Requires bundle ID `com.hdhr.vcrplus` (already set in Info.plist).

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
**What:** `VLCBridge.swift` dlopens `libvlc.dylib` from `/Applications/VLC.app`. Two problems: (1) cross-app bundle file access is forbidden in sandbox; (2) `com.apple.security.cs.disable-library-validation` — which the current entitlements require — is forbidden in MAS builds.

**Options:**
- Drop in-app player for the MAS version. Show stream URL; let user open in external VLC.
- Bundle `libvlc.dylib` inside the app (~50 MB+; complex LGPL compliance).

Neither is trivial. AVPlayer cannot replace VLC because it does not support MPEG-2 (the transport format used by most HDHomeRun tuners).

### 4. `Process()` for brew installs
**What:** `SettingsView.swift` launches brew via `Process()`. Not allowed in sandbox.

**Fix (easy):** Remove the brew install UI; replace with instructions to run the commands manually in Terminal.

### 5. Arbitrary recording directory path
**What:** Config stores raw path strings. Sandbox only permits write access to directories the user explicitly selects via NSOpenPanel.

**Fix:** Security-scoped bookmarks. On folder selection: `url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)` → store bookmark `Data` in config. On each recording: `URL(resolvingBookmarkData: data, options: .withSecurityScope)` + `startAccessingSecurityScopedResource()`.  
Config migration required: existing path-string configs would lose their saved directory on first sandbox launch.

---

## Required Policy 📋

### 6. Remove Sparkle auto-updater
MAS handles all updates. Sparkle is not permitted.
- Remove `.package(url: "sparkle-project/Sparkle")` from `Package.swift`
- Remove Sparkle framework bundling from `deploy.sh` and `deploy_release.sh`
- Remove Sparkle update-check UI from `SettingsView` (About tab)
- Remove `SUFeedURL` and `SUPublicEDKey` from `Info.plist`

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
| Channel icon disk cache | Within sandbox container |
| Sparkle signature key in Info.plist | Harmless if Sparkle is removed |
