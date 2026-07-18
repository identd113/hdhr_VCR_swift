# Distribution & Monetization

A guide for shipping hdhrVCRplus outside the Mac App Store — notarization, costs, what users experience, and how to get paid.

---

## Costs

| Item | Cost | Notes |
|------|------|-------|
| Apple Developer Program | $99/year | Required for Developer ID cert + notarization. Renews annually — if you let it lapse, existing notarized copies still work but you can't ship new versions. |
| GitHub (hosting + releases) | Free | Public repo with release assets (DMG files) up to 2 GB each. |
| Auto-update | None | Releases are downloaded manually; no appcast, no updater framework. |
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
See "Release Checklist" below — build, sign, notarize, zip, publish as a GitHub Release.

The zip is the thing you hand users. Everything else (payment gate) is layered on top.

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
- No background update checks — users get new versions by downloading a new zip from GitHub Releases

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

## Release Checklist

There is no auto-updater and no appcast. A release is just a signed build
attached to a GitHub Release that users download manually.

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
| Auto-update | None — users download new releases manually |
| License enforcement | Optional — start without it, add later if needed |

Once you have the Developer ID cert, cutting a release is `deploy_release.sh` → zip → `gh release create` (minutes).
