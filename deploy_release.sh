#!/bin/bash
# Release build: Developer ID signing + notarization (or ad-hoc, before a Developer ID cert exists).
# Usage:
#   ./deploy_release.sh <version>                  # sign + notarize + staple + open
#   ./deploy_release.sh <version> --skip-notarize  # Developer ID sign only (for testing the signing step)
#   ./deploy_release.sh <version> --adhoc          # ad-hoc sign, no notarization — for shipping a
#                                                   # release before a Developer ID cert is set up.
#                                                   # Produces a distributable zip, but Gatekeeper
#                                                   # will warn "unidentified developer" on first
#                                                   # launch until a real notarized build replaces it.
#
# <version> is the semantic version string, e.g.: 1.3.0
#
# Prerequisites (--skip-notarize / full notarize modes only — --adhoc needs none of these):
#   1. Apple Developer Program membership ($99/year)
#   2. "Developer ID Application: <name> (<TEAM_ID>)" cert in your keychain
#   3. App-specific password stored in keychain:
#        xcrun notarytool store-credentials "hdhrVCR-notary" \
#          --apple-id "your@email.com" --team-id "XXXXXXXXXX" --password "xxxx-xxxx-xxxx-xxxx"
#   4. Bundle ID "com.hdhr.vcrplus" registered at developer.apple.com

set -e

APP="hdhrVCRplus.app"
BINARY="$APP/Contents/MacOS/hdhr_VCR"
ENTITLEMENTS="hdhrVCRplus.entitlements"
BUNDLE_ID="com.hdhr.vcrplus"
DIST_DIR="dist"

# ── Fill these in (unused in --adhoc mode) ──────────────────────────────────
SIGN_IDENTITY="Developer ID Application: YOUR NAME (XXXXXXXXXX)"
NOTARY_PROFILE="hdhrVCR-notary"   # name used in store-credentials above
# ─────────────────────────────────────────────────────────────────────────────

SKIP_NOTARIZE=0
ADHOC=0
RELEASE_VERSION=""
for _arg in "$@"; do
    case "$_arg" in
        --skip-notarize) SKIP_NOTARIZE=1 ;;
        --adhoc)         ADHOC=1; SKIP_NOTARIZE=1 ;;
        *) RELEASE_VERSION="$_arg" ;;
    esac
done
if [ -z "$RELEASE_VERSION" ]; then
    echo "Usage: ./deploy_release.sh <version> [--skip-notarize|--adhoc]"
    echo "       e.g.: ./deploy_release.sh 1.3.0"
    exit 1
fi

echo "==> Stopping running instance…"
pkill -x hdhr_VCR 2>/dev/null && echo "    Stopped." || echo "    Not running."

echo "==> Generating version…"
APP_VERSION="$(date +%y%m%d-%H%M)"
printf 'let appVersion = "%s"\n' "$APP_VERSION" > Sources/hdhr_VCR/Version.swift
# Derive a monotonic CFBundleVersion from the semver (e.g. 1.3.0 → 10300)
IFS='.' read -r _VER_MAJOR _VER_MINOR _VER_PATCH <<< "$RELEASE_VERSION"
_BUILD_NUM=$(( _VER_MAJOR * 10000 + _VER_MINOR * 100 + _VER_PATCH ))
_PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $RELEASE_VERSION" "$_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $_BUILD_NUM" "$_PLIST"
echo "    Build stamp:  $APP_VERSION"
echo "    Release:      $RELEASE_VERSION (CFBundleVersion $_BUILD_NUM)"

echo "==> Building (release)…"
swift build -c release

echo "==> Deploying binary…"
cp .build/release/hdhr_VCR "$BINARY"

echo "==> Deploying resources…"
mkdir -p "$APP/Contents/Resources"
cp Resources/app.jpg "$APP/Contents/Resources/app.jpg"
cp Resources/app-recording.jpg "$APP/Contents/Resources/app-recording.jpg"
cp Resources/app-upnext.jpg "$APP/Contents/Resources/app-upnext.jpg"
cp Resources/guide.css "$APP/Contents/Resources/guide.css"
cp Resources/guide-vertical.css "$APP/Contents/Resources/guide-vertical.css"
cp Resources/guide.js "$APP/Contents/Resources/guide.js"
cp Resources/guide-shell.html "$APP/Contents/Resources/guide-shell.html"
# Bundle.main.url(forResource:withExtension:) (SettingsView's in-app changelog) looks in
# Contents/Resources — SPM's Bundle.module resources: declaration in Package.swift never
# reaches there, so this copy is the only thing that actually makes it visible in-app.
cp CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"

echo "==> Generating app icon…"
# Built from AppIcon-source.png — a dedicated 1024x1024 master with transparent corners,
# not from app.jpg (flat/opaque, sized for the menu bar + About tab). See deploy.sh for why.
_ICONSET="$(mktemp -d)/hdhr_icon.iconset"
mkdir -p "$_ICONSET"
for _SZ in 16 32 128 256 512; do
    sips -z $_SZ $_SZ Resources/AppIcon-source.png --out "$_ICONSET/icon_${_SZ}x${_SZ}.png" > /dev/null
done
sips -z 32   32   Resources/AppIcon-source.png --out "$_ICONSET/icon_16x16@2x.png"   > /dev/null
sips -z 64   64   Resources/AppIcon-source.png --out "$_ICONSET/icon_32x32@2x.png"   > /dev/null
sips -z 256  256  Resources/AppIcon-source.png --out "$_ICONSET/icon_128x128@2x.png" > /dev/null
sips -z 512  512  Resources/AppIcon-source.png --out "$_ICONSET/icon_256x256@2x.png" > /dev/null
sips -z 1024 1024 Resources/AppIcon-source.png --out "$_ICONSET/icon_512x512@2x.png" > /dev/null
iconutil --convert icns "$_ICONSET" --output Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
python3 - "$_ICONSET/icon_16x16.png" "$_ICONSET/icon_32x32.png" Resources/favicon.ico <<'PYEOF'
import sys, struct
paths_sizes = [(sys.argv[1], 16), (sys.argv[2], 32)]
images = [(sz, open(p, 'rb').read()) for p, sz in paths_sizes]
hdr = struct.pack('<HHH', 0, 1, len(images))
off = 6 + len(images) * 16
dirs, blobs = b'', b''
for sz, data in images:
    dirs += struct.pack('<BBBBHHII', sz, sz, 0, 0, 1, 32, len(data), off)
    off += len(data); blobs += data
open(sys.argv[3], 'wb').write(hdr + dirs + blobs)
PYEOF
cp Resources/favicon.ico "$APP/Contents/Resources/favicon.ico"

find "$APP" -name "._*" -delete
find "$APP" -name ".DS_Store" -delete
xattr -cr "$APP"

if [ "$ADHOC" -eq 1 ]; then
    echo "==> Signing ad-hoc (no Developer ID cert configured)…"
    codesign --force --options runtime \
             --entitlements "$ENTITLEMENTS" \
             --sign - \
             "$APP"
else
    echo "==> Signing with Hardened Runtime…"
    _signed=0
    for _attempt in 1 2 3; do
        find "$APP" -name "._*" -delete 2>/dev/null || true
        find "$APP" -print0 | xargs -0 xattr -d com.apple.FinderInfo 2>/dev/null || true
        codesign --force --options runtime \
                 --entitlements "$ENTITLEMENTS" \
                 --sign "$SIGN_IDENTITY" \
                 "$APP" && _signed=1 && break
        echo "    Attempt $_attempt failed, retrying…"
    done
    [ "$_signed" -eq 1 ] || { echo "ERROR: codesign failed after 3 attempts"; exit 1; }
fi

echo "==> Verifying signature…"
# --strict is omitted: iCloud file provider continuously re-attaches com.apple.FinderInfo
# to .app bundles in this directory, causing false failures on the local bundle.
# The notarization zip is created with `ditto -c -k` which strips all resource forks,
# so Apple's notarization service sees a clean bundle. That is the authoritative check.
xattr -cr "$APP"
codesign --verify --deep --verbose=2 "$APP"
spctl --assess --type execute --verbose "$APP" 2>&1 || true   # will say "rejected" until notarized — that's expected (ad-hoc/unnotarized always does)

if [ "$SKIP_NOTARIZE" -eq 1 ]; then
    mkdir -p "$DIST_DIR"
    ZIP_PATH="$DIST_DIR/hdhrVCRplus-${RELEASE_VERSION}.zip"
    echo "==> Zipping for distribution…"
    ditto -c -k --keepParent "$APP" "$ZIP_PATH"
    if [ "$ADHOC" -eq 1 ]; then
        echo "==> Skipping notarization (ad-hoc build — no Developer ID cert configured)."
        echo "    NOTE: recipients will see an 'unidentified developer' Gatekeeper warning on"
        echo "    first launch — right-click > Open, or run 'xattr -cr hdhrVCRplus.app' after"
        echo "    unzipping. Re-release with real Developer ID signing + notarization once a"
        echo "    cert is available (tools/setup_signing.sh, then this script without --adhoc)."
    else
        echo "==> Skipping notarization (--skip-notarize)."
    fi
    echo "    Artifact: $ZIP_PATH"
    echo "==> Launching $APP…"
    open "$APP"
    echo "==> Done."
    exit 0
fi

echo "==> Zipping for notarization…"
ZIP_PATH="/tmp/${BUNDLE_ID}-notarize.zip"
ditto -c -k --keepParent "$APP" "$ZIP_PATH"

echo "==> Submitting to Apple notary service…"
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "==> Stapling notarization ticket…"
xcrun stapler staple "$APP"

echo "==> Final Gatekeeper check…"
spctl --assess --type execute --verbose "$APP"

mkdir -p "$DIST_DIR"
FINAL_ZIP="$DIST_DIR/hdhrVCRplus-${RELEASE_VERSION}.zip"
echo "==> Zipping notarized build for distribution…"
ditto -c -k --keepParent "$APP" "$FINAL_ZIP"
echo "    Artifact: $FINAL_ZIP"

touch "$APP"
echo "==> Launching $APP…"
open "$APP"
echo "==> Done."
