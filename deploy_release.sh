#!/bin/bash
# Release build: Developer ID signing + notarization.
# Usage:
#   ./deploy_release.sh                  # sign + notarize + staple + open
#   ./deploy_release.sh --skip-notarize  # sign only (for testing the signing step)
#
# Prerequisites:
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

# ── Fill these in ────────────────────────────────────────────────────────────
SIGN_IDENTITY="Developer ID Application: YOUR NAME (XXXXXXXXXX)"
NOTARY_PROFILE="hdhrVCR-notary"   # name used in store-credentials above
# ─────────────────────────────────────────────────────────────────────────────

SKIP_NOTARIZE=0
[[ "$1" == "--skip-notarize" ]] && SKIP_NOTARIZE=1

echo "==> Stopping running instance…"
pkill -x hdhr_VCR 2>/dev/null && echo "    Stopped." || echo "    Not running."

echo "==> Generating version…"
APP_VERSION="$(date +%y%m%d-%H%M)"
printf 'let appVersion = "%s"\n' "$APP_VERSION" > Sources/hdhr_VCR/Version.swift
echo "    Version: $APP_VERSION"

echo "==> Building (release)…"
swift build -c release

echo "==> Deploying binary…"
cp .build/release/hdhr_VCR "$BINARY"

echo "==> Deploying resources…"
mkdir -p "$APP/Contents/Resources"
cp Resources/app.jpg "$APP/Contents/Resources/app.jpg"

echo "==> Generating app icon…"
_ICONSET="$(mktemp -d)/hdhr_icon.iconset"
mkdir -p "$_ICONSET"
sips -s format png Resources/app.jpg --out /tmp/hdhr_src.png > /dev/null
sips --padToHeightWidth 507 507 --padColor 1A1A1A /tmp/hdhr_src.png --out /tmp/hdhr_sq.png > /dev/null
for _SZ in 16 32 128 256 512; do
    sips -z $_SZ $_SZ /tmp/hdhr_sq.png --out "$_ICONSET/icon_${_SZ}x${_SZ}.png" > /dev/null
done
sips -z 32   32   /tmp/hdhr_sq.png --out "$_ICONSET/icon_16x16@2x.png"   > /dev/null
sips -z 64   64   /tmp/hdhr_sq.png --out "$_ICONSET/icon_32x32@2x.png"   > /dev/null
sips -z 256  256  /tmp/hdhr_sq.png --out "$_ICONSET/icon_128x128@2x.png" > /dev/null
sips -z 512  512  /tmp/hdhr_sq.png --out "$_ICONSET/icon_256x256@2x.png" > /dev/null
sips -z 1024 1024 /tmp/hdhr_sq.png --out "$_ICONSET/icon_512x512@2x.png" > /dev/null
iconutil --convert icns "$_ICONSET" --output Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing with Hardened Runtime…"
find "$APP" -name "._*" -delete
find "$APP" -name ".DS_Store" -delete
_signed=0
for _attempt in 1 2 3; do
    xattr -cr "$APP"
    codesign --force --options runtime \
             --entitlements "$ENTITLEMENTS" \
             --sign "$SIGN_IDENTITY" \
             "$APP" && _signed=1 && break
    echo "    Attempt $_attempt failed, retrying…"
done
[ "$_signed" -eq 1 ] || { echo "ERROR: codesign failed after 3 attempts"; exit 1; }

echo "==> Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose "$APP" 2>&1 || true   # will say "rejected" until notarized — that's expected

if [ "$SKIP_NOTARIZE" -eq 1 ]; then
    echo "==> Skipping notarization (--skip-notarize)."
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

touch "$APP"
echo "==> Launching $APP…"
open "$APP"
echo "==> Done."
