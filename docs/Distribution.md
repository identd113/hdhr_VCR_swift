# Distribution, Monetization & Auto-Update

A guide for shipping hdhrVCRplus outside the Mac App Store — notarization, costs, what users experience, how to get paid, and how to deliver updates automatically.

---

## Costs

| Item | Cost | Notes |
|------|------|-------|
| Apple Developer Program | $99/year | Required for Developer ID cert + notarization. Renews annually — if you let it lapse, existing notarized copies still work but you can't ship new versions. |
| GitHub (hosting + releases) | Free | Public repo with release assets (DMG files) up to 2 GB each. |
| Sparkle (auto-update) | Free | Open source, MIT licensed. |
| GitHub Pages (appcast feed) | Free | Static file hosting for the Sparkle update feed. |
| Payment processing | ~2.9% + $0.30/transaction | Stripe or Gumroad take a cut; no monthly fee on free tier. |

**Minimum cost to ship: $99/year.**

---

## Distribution Flow (Developer Side)

### One-time setup
1. Enroll in the Apple Developer Program at developer.apple.com ($99)
2. Create a "Developer ID Application" certificate (see `deploy_release.sh` header)
3. Register Bundle ID `com.hdhr.vcrplus` in the Developer Portal
4. Store notarization credentials: `xcrun notarytool store-credentials "hdhrVCR-notary" ...`
5. Fill in `SIGN_IDENTITY` in `deploy_release.sh`

### Each release
```bash
# 1. Build, sign, notarize, staple
./deploy_release.sh

# 2. Create a DMG
hdiutil create -volname "hdhrVCRplus" \
  -srcfolder hdhrVCRplus.app \
  -ov -format UDZO \
  ~/Desktop/hdhrVCRplus-1.0.dmg

# 3. Tag and push
git tag v1.0 && git push --tags

# 4. Create GitHub Release, attach the DMG
# github.com → your repo → Releases → Draft a new release
```

The DMG is the thing you hand users. Everything else (auto-update feed, payment gate) is layered on top.

---

## User Experience

### First install
1. User downloads `hdhrVCRplus.dmg` from your GitHub Releases page or website
2. Opens the DMG — sees the app icon and an alias to `/Applications`
3. Drags the app to Applications
4. Double-clicks to launch
5. macOS shows a one-time "downloaded from the internet" confirmation — they click **Open**
6. No "unidentified developer" warning because the app is notarized

### Ongoing use
- App lives in the menu bar (no Dock icon)
- Launches at login if the user enables it in Settings → General
- If auto-update is enabled (see below), the app checks for updates in the background and prompts when one is available — user clicks **Install & Relaunch**, done

---

## Monetization — How Users Pay You

You have a few options depending on how you want to handle access control.

### Option A: Honor system / donation (simplest)
- Put a **"Buy Me a Coffee"** or **Ko-fi** link in Settings → About
- App is free to use; payment is voluntary
- No license enforcement, no server, no complexity
- Works well for enthusiast tools with a small audience

### Option B: One-time purchase via Gumroad (recommended for solo dev)
- Create a product on [gumroad.com](https://gumroad.com) — set a price (e.g. $10–$15)
- Buyer gets a download link for the DMG and a license key
- In the app, add a license key check on first launch — validate the key format locally (no server needed with a simple scheme) or call Gumroad's API
- Gumroad takes ~10% (free plan) or flat $10/month (Pro plan, ~3.5% + fees)

### Option C: One-time purchase via Stripe + your own page
- Build a minimal checkout page (or use Stripe Payment Links — no code)
- On payment, email the buyer a download link + license key
- Stripe takes 2.9% + $0.30 per transaction
- More work upfront, more control, lower fees at scale

### Option D: Subscription via Stripe
- Monthly or annual fee
- Requires a server to validate subscription status on app launch (or use RevenueCat which handles this)
- Overkill for an app like this unless you plan ongoing feature development

**Practical recommendation:** Start with Gumroad (Option B) — lowest friction to get your first dollar. Move to Stripe if volume warrants it.

### License key validation (no server required)
A simple approach: generate keys as `HDHR-XXXX-XXXX-XXXX` where the segments are derived from a secret + a counter, hashed and base-32 encoded. Validate the format + checksum locally in the app. Nobody can generate valid keys without your secret; you never need a server call.

Libraries that handle this cleanly:
- [Paddle](https://www.paddle.com) — handles payment + license validation + VAT, higher fees
- [DevMate](https://devmate.com) — discontinued, but the pattern is well documented
- Roll your own with CryptoKit (HMAC-SHA256 over a counter, encode as base-32)

---

## Auto-Update with Sparkle

> **Status: removed.** Sparkle was integrated and then removed (commit `6e9dca8`); the app currently has **no auto-updater** — updates are distributed as GitHub releases that users download and install manually. The section below is retained as reference for if/when auto-update is reintroduced.

[Sparkle](https://sparkle-project.org) is the standard auto-update framework for Mac apps outside the App Store. It's what 1Password, BBEdit, and most indie Mac apps use.

### How it works
1. Your app bundles the Sparkle framework
2. On launch (or periodically), Sparkle fetches an **appcast** — an XML file you host — and compares the latest version to the running version
3. If an update is available, Sparkle shows a dialog: "A new version is available — install now?"
4. User clicks Install; Sparkle downloads the new DMG/zip, verifies its signature, replaces the app, and relaunches

### Integration overview

**Step 1: Add Sparkle to the project**

Sparkle ships as a pre-built `.xcframework`. Since this project uses Swift Package Manager:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0")
],
targets: [
    .executableTarget(
        name: "hdhr_VCR",
        dependencies: [
            .product(name: "Sparkle", package: "Sparkle")
        ],
        path: "Sources/hdhr_VCR"
    )
]
```

**Step 2: Generate an EdDSA key pair**

Sparkle 2 uses EdDSA signatures to verify update packages — prevents someone from serving a malicious update through your appcast URL.

```bash
# Run once — save the private key somewhere safe (NOT in the repo)
./Sparkle/bin/generate_keys
```

Add the public key to `Info.plist`:
```xml
<key>SUPublicEDKey</key>
<string>YOUR_PUBLIC_KEY_HERE</string>
```

**Step 3: Wire Sparkle into the app**

In `hdhr_VCRApp.swift`:
```swift
import Sparkle

@main
struct hdhr_VCRApp: App {
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    // ...
}
```

Add a "Check for Updates…" menu item in `MenuContent.swift`:
```swift
Button("Check for Updates…") {
    updaterController.updater.checkForUpdates()
}
```

Add the appcast URL to `Info.plist`:
```xml
<key>SUFeedURL</key>
<string>https://YOUR_GITHUB_USERNAME.github.io/hdhr_VCR_swift/appcast.xml</string>
```

**Step 4: Host the appcast on GitHub Pages**

Enable GitHub Pages on your repo (Settings → Pages → branch: `main`, folder: `/docs`).

Create `docs/appcast.xml`:
```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>hdhrVCRplus</title>
    <item>
      <title>Version 1.0</title>
      <pubDate>Sat, 24 May 2026 00:00:00 +0000</pubDate>
      <sparkle:version>260524-1926</sparkle:version>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://github.com/YOUR_USERNAME/hdhr_VCR_swift/releases/download/v1.0/hdhrVCRplus-1.0.dmg"
        sparkle:edSignature="YOUR_SIGNATURE_HERE"
        length="6919280"
        type="application/octet-stream"
      />
    </item>
  </channel>
</rss>
```

Generate the `edSignature` for each release:
```bash
./Sparkle/bin/sign_update hdhrVCRplus-1.0.dmg
# Paste the output into sparkle:edSignature above
```

**Step 5: Update the entitlements**

Sparkle needs outbound network access (already covered by `network.client`) and the ability to update the app bundle. Add to `hdhrVCRplus.entitlements`:
```xml
<!-- Sparkle: needed to replace the app bundle during update -->
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

### Release checklist (current — no auto-updater)

Sparkle was removed; there is no appcast and no auto-update. A release is just a
signed build attached to a GitHub Release that users download manually.

1. `./deploy_release.sh <version>` — builds, Developer-ID signs, notarizes, staples, and sets `CFBundleShortVersionString`/`CFBundleVersion` (needs the Apple Developer cert + a stored notary credential; `--skip-notarize` signs only, for testing).
2. Zip the stapled app: `ditto -c -k --keepParent hdhrVCRplus.app hdhrVCRplus-v<version>.zip`.
3. Publish the GitHub Release with notes + the zip:
   `gh release create v<version> --title "…" --notes-file notes.md hdhrVCRplus-v<version>.zip`
   (or, if a draft already exists: `gh release upload v<version> …zip --clobber` then `gh release edit v<version> --draft=false --latest`).
4. Users download the zip and install manually; existing installs don't self-update.

**Un-notarized fallback:** if you can't notarize yet, ship an **ad-hoc** build (rebuild via `deploy.sh` after bumping the plist version, then zip as above). Gatekeeper will block it, so put bypass instructions in the release body — on **macOS 15 / 26** that's `xattr -dr com.apple.quarantine …` or **System Settings → Privacy & Security → Open Anyway** (right-click → Open no longer works). Swap in the notarized zip later with `gh release upload v<version> …zip --clobber`.

---

## Recommended Starting Point

For a first release:

| Decision | Recommendation |
|----------|---------------|
| Payment | Gumroad, $10–$15 one-time |
| Distribution | GitHub Releases (`.zip` of the notarized `.app`) |
| Auto-update | None — Sparkle was removed; users download new releases manually |
| License enforcement | Optional — start without it, add later if needed |

Once you have the Developer ID cert, cutting a release is `deploy_release.sh` → zip → `gh release create` (minutes). Re-adding auto-update later would mean reintroducing Sparkle (see the reference section above).
