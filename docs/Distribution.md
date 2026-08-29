# Distribution & Monetization

A guide for shipping hdhrVCRplus outside the Mac App Store — notarization, costs, what users experience, and how to get paid.

---

## Costs

| Item | Cost | Notes |
|------|------|-------|
| Apple Developer Program | $99/year | Required for Developer ID cert + notarization. Renews annually — if you let it lapse, existing notarized copies still work but you can't ship new versions. |
| GitHub (hosting + releases) | Free | Public repo with release assets (DMG files) up to 2 GB each. |
| Auto-update | Check only | App checks GitHub Releases once a day and shows a link (About tab + menu bar) when a newer version exists (`UpdateChecker.swift`) — no appcast, no updater framework, no download/install automation. Sparkle was tried twice and parked; see git history on commits `1376dc6`/`6e9dca8`/`39f1419`. |
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
See "Release Checklist" below — build, sign, notarize, package as a DMG, publish as a GitHub Release.

The DMG is the thing you hand users. Everything else (payment gate) is layered on top.

---

## User Experience

### First install
1. User downloads `hdhrVCRplus-<version>.dmg` from your GitHub Releases page or website
2. Opens the DMG — a classic-Mac-styled window (`tools/build_dmg.sh`, "DMG assembly" below) shows
   the app icon, an alias to `/Applications`, and a **Read Me** (custom-iconed, with real
   screenshots) covering first-run setup
3. Drags the app to Applications (or skips this — see below)
4. Double-clicks to launch
5. macOS shows a one-time "downloaded from the internet" confirmation — they click **Open**
6. No "unidentified developer" warning because the app is notarized

If a user launches the app directly from the DMG or an unzipped Downloads folder instead of
dragging it to Applications first, `AppRelocator.swift` catches this on launch: an alert offers to
copy the app into `/Applications`, trash the original (skipped for a Gatekeeper-translocated
source — nothing real to trash there), and relaunch from the new location. Release builds only
(`#if DEBUG`) — `./deploy.sh`'s dev workflow always runs the app in place from the repo root and is
unaffected.

### Ongoing use
- App lives in the menu bar (no Dock icon)
- Launches at login if the user enables it in Settings → General
- A once-a-day background check (About tab + menu bar link) tells them a newer version exists, but they still download and install the new DMG from GitHub Releases manually — nothing auto-downloads or auto-installs

---

## Monetization — How Users Pay You

You have a few options depending on how you want to handle access control.

### Option A: Honor system / donation (simplest) — implemented
- App is free to use; payment is voluntary
- No license enforcement, no server, no complexity
- Works well for enthusiast tools with a small audience
- **Implemented as an in-app nag window**, not a Settings → About link — see
  [`DonationNagView.md`](DonationNagView.md). Shows on app launch and whenever a show is
  scheduled (native or web), with a PayPal link and an unlock code entered after a tip.

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

There is no auto-updater and no appcast. A release is just a signed, notarized build
attached to a GitHub Release that users download manually. Every release from v2.0.0
onward follows this full notarized path — the Developer ID cert and notary credential
are already set up (see `tools/setup_signing.sh`), so this is the normal flow, not an
aspirational one.

**Every release — not just the first — goes through a pre-release pass before `deploy_release.sh`
runs, scoped to whatever's landed since the last tag** (`git log <last-tag>..main`):

0. **Review, document, test, then commit any fixes** — in this order, before touching `deploy_release.sh`:
   1. Code review the unreleased commits (`invariants-reviewer` and/or `swift-quality-reviewer` against `git diff <last-tag>..main`) — catches regressions/hackiness before they ship, not after.
   2. Update documentation for anything the reviewed commits touched (`docs-auditor`, or a manual pass) — `docs/*.md` should already describe the current behavior by the time a release ships, not lag behind it.
   3. Run the full test suite: `swift build && swift test`, **and** the UI/window-navigation suite (`RUN_WINDOW_NAV_TESTS=1 swift test --filter WindowNavigationTests` — needs the app running + Accessibility permission granted to whatever runs the tests, see the root `CLAUDE.md`). Don't skip the UI pass just because the unit suite is green — it catches a different class of regression (real window/menu interaction, not just logic).
   4. Fix anything the above finds, commit those fixes, and re-run step 3 until clean.

1. `./deploy_release.sh <version>` — builds a **universal binary** (`swift build -c release --arch arm64 --arch x86_64`, SwiftPM combines both slices itself — no manual `lipo` step; verify with `lipo -info` on the built `.app`'s binary if in doubt), Developer-ID signs, notarizes, staples, sets `CFBundleShortVersionString`/`CFBundleVersion`, and packages the finished, stapled app into a DMG (`tools/build_dmg.sh`, see "DMG assembly" below) — look for the printed `Artifact: dist/hdhrVCRplus-<version>.dmg` line (no `v` prefix in the filename, unlike the git tag). Needs the Apple Developer cert + a stored notary credential; `--skip-notarize` signs only, for testing. **Developer ID signing prompts for Touch ID/password on every run** (not just first use) — whoever runs this needs to be physically at the machine (or have real remote screen access) to clear it; it will hang otherwise. (`./deploy.sh`, the dev-loop script, deliberately stays arm64-only for build speed — only the shipped release build needs to run on Intel.)
2. **Add a `## v<version> (<date>)` entry to [`RELEASES.md`](../RELEASES.md)**, condensed and
   end-user-facing (see existing entries for the house style) from what actually landed since the
   last tag (`git log <last-tag>..main` / `Sources/hdhr_VCR/CHANGELOG.md`'s entries for this
   release). `deploy_release.sh` does **not** touch this file — it only bundles
   `CHANGELOG.md` into the app for the in-app About screen (see root `CLAUDE.md`'s "Guide page
   CSS/JS/HTML" note and `SettingsView.swift`'s `changelogText`). Skipping this step is how
   RELEASES.md fell two versions behind (v2.0.3, v2.0.4) before a manual audit caught it in
   2026-08-17 — do this before publishing the GitHub Release below, and use the new RELEASES.md
   section as the basis for that release's notes.
3. Publish the GitHub Release with notes + that DMG:
   `gh release create v<version> --title "…" --notes-file notes.md dist/hdhrVCRplus-<version>.dmg`
   (or, if a draft already exists: `gh release upload v<version> …dmg --clobber` then `gh release edit v<version> --draft=false --latest`).
4. **Update `README.md`'s "📦 Latest" section** — the version number + download link (both hardcoded,
   `hdhrVCRplus-<version>.dmg` under `/releases/download/v<version>/`) and its 3-4 bullet highlights,
   condensed even further than the `RELEASES.md` entry those bullets come from (see existing
   entries for the house style — this is the punchiest, most-condensed tier of the three release-note
   surfaces: `CHANGELOG.md` full detail → `RELEASES.md` condensed → README 3-4 bullets). The
   `[![Latest Release]` shields.io badge near the top is dynamic (queries the GitHub API), so it
   updates itself — only this hardcoded section needs a manual edit. Easy to forget since nothing
   breaks if it's skipped, just goes stale (this is a real, not hypothetical, gap: only fixed for
   v2.1.0 after being asked to explicitly, not caught by the checklist itself).
5. Users download the DMG and install manually; existing installs don't self-update.

### DMG assembly (`tools/build_dmg.sh`)

Called automatically by `deploy_release.sh` (both the full-notarize and `--skip-notarize`/`--adhoc`
paths) right after the `.app` is in its final signed (and, unless skipped, stapled) form — it's
also directly runnable on its own (`tools/build_dmg.sh <version> <path-to-app>`) against *any*
`.app`, a plain `./deploy.sh` dev build included, which is how its layout/background/manual get
iterated on without waiting through a real Developer ID signature or a notary round trip each time.

Built with [`create-dmg`](https://github.com/create-dmg/create-dmg) (`brew install create-dmg`),
not hand-rolled `hdiutil`/Finder-AppleScript automation — that class of Finder scripting has a real,
observed failure mode in this environment (a hung AppleEvent, `execution error: … timed out`,
requiring a manual force-quit) that a well-tested existing tool sidesteps entirely. Assembles:

- The `.app` itself, plus an `Applications` symlink (`--app-drop-link`) — the classic drag-to-install
  affordance `AppRelocator.swift`'s own fallback exists to catch when someone skips it.
- **`Read Me.rtfd`** (`tools/build_readme_manual.swift`) — a short manual built fresh from
  `docs/screenshots/` on every run via Cocoa's own `NSAttributedString` RTFD writer (not hand-written
  RTF markup — three earlier attempts at that, including `textutil`'s own HTML→RTFD image
  conversion, silently dropped or corrupted the embedded images). Carries a custom icon
  (`tools/dmg_assets/readme_icon.svg`, `tools/apply_finder_icon.swift`) — an original "EXTRA"
  newspaper-page design recreating the *layout* of the classic Mac "Read Me" document icon (masthead
  rules, headline banner, a checkerboard photo placeholder, flanking text columns), not a
  reproduction of Apple's own artwork, which remains their copyrighted asset regardless of its age.
- A custom background (`tools/dmg_assets/dmg_background.svg`, a soft modern echo of the classic
  desktop's own dithered checkerboard texture) with a drag arrow between the app and Applications
  icons — window size and all three icon positions are hardcoded in `build_dmg.sh` to match this
  file's own layout exactly; **edit them together** if either one's coordinates change.
- The volume icon (`--volicon`) is the app's own `AppIcon.icns`, already baked into the signed
  `.app` — no separate asset needed for that piece.

Nothing here is tracked as a pre-built binary — `tools/dmg_assets/generated/` (the rendered
icons/background PNGs and the built `Read Me.rtfd`) is gitignored and rebuilt from the `.svg`
sources and the two build scripts every single run, the same "regenerate from source at release
time" approach `deploy_release.sh` already uses for `AppIcon.icns`/`favicon.ico`.

**Signing note:** the DMG container itself is neither signed nor notarized separately by default —
the `.app`'s own stapled notarization ticket (checked when it's actually launched) is what Gatekeeper
relies on for a normal, non-airgapped install; that's unchanged from the zip artifact this replaced.
`create-dmg` does support `--codesign`/`--notarize` flags for also stapling a ticket to the DMG
container itself (useful for a fully-offline "mounting this disk image" check), but that's a second,
optional notarization round trip this script doesn't perform — add it later if that specific gap
ever actually matters in practice.

**Housekeeping, not a checklist step**: both deploy scripts now clean up any stray
`hdhrVCRplus 2.app`/`3.app`/etc. duplicate the repo root accumulates on their own, right after
stopping the running instance — macOS occasionally creates one of these mid-run when the
bundle-replace step races a lingering handle on the process `pkill` just stopped. Untracked either
way (git never sees them), but left alone they just keep piling up across a session's worth of
deploys; automatic now, nothing to remember here.

**Emergency-only, un-notarized fallback:** if the notary service is down or the cert/credential is
temporarily unavailable and a release genuinely can't wait, use `./deploy_release.sh <version>
--adhoc` instead — it's the same script, still sets the real version and packages a DMG to `dist/`,
just skips the Developer ID signing/notarizing steps in favor of an ad-hoc signature. (`./deploy.sh`,
the everyday dev-loop script, is a different thing — a debug build with no version-stamping or
release DMG at all; don't use it for this.) Gatekeeper will
block it, so put bypass instructions in the release body — on **macOS 15 / 26** that's
`xattr -dr com.apple.quarantine …` (run against the mounted `.app`, after opening the DMG) or
**System Settings → Privacy & Security → Open Anyway** (right-click → Open no longer works). Swap
in the notarized DMG as soon as possible with `gh release upload v<version> …dmg --clobber`.

---

## Recommended Starting Point

For a first release:

| Decision | Recommendation |
|----------|---------------|
| Payment | Gumroad, $10–$15 one-time |
| Distribution | GitHub Releases (`.dmg` of the notarized `.app`, `tools/build_dmg.sh`) |
| Auto-update | Check-only notice (GitHub Releases API) — users still download and install manually |
| License enforcement | Optional — start without it, add later if needed |

Once you have the Developer ID cert, cutting a release is `deploy_release.sh` (DMG included) → `gh release create` (minutes).
