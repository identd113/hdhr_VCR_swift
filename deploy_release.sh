#!/bin/bash
# Release build: Developer ID signing + notarization.
# Usage:
#   ./deploy_release.sh <version>                  # sign + notarize + staple + open
#   ./deploy_release.sh <version> --skip-notarize  # sign only (for testing the signing step)
#
# <version> is the semantic version string, e.g.: 1.3.0
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
RELEASE_VERSION=""
for _arg in "$@"; do
    case "$_arg" in
        --skip-notarize) SKIP_NOTARIZE=1 ;;
        *) RELEASE_VERSION="$_arg" ;;
    esac
done
if [ -z "$RELEASE_VERSION" ]; then
    echo "Usage: ./deploy_release.sh <version> [--skip-notarize]"
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
# Add rpath so the binary finds Sparkle.framework in Contents/Frameworks at runtime.
install_name_tool -add_rpath @executable_path/../Frameworks "$BINARY" 2>/dev/null || true

echo "==> Bundling Sparkle framework…"
_FW_DEST="$APP/Contents/Frameworks"
rm -rf "$_FW_DEST/Sparkle.framework"
mkdir -p "$_FW_DEST"
cp -R .build/release/Sparkle.framework "$_FW_DEST/"
xattr -cr "$_FW_DEST/Sparkle.framework"

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
xattr -cr "$APP"
# Sign Sparkle internals inside-out before signing the framework and then the main app.
_SPKL="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$_SPKL/XPCServices/Downloader.xpc"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$_SPKL/XPCServices/Installer.xpc"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$_SPKL/Updater.app"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$_SPKL/Autoupdate"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
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

echo "==> Verifying signature…"
# --strict is omitted: iCloud file provider continuously re-attaches com.apple.FinderInfo
# to .app bundles in this directory, causing false failures on the local bundle.
# The notarization zip is created with `ditto -c -k` which strips all resource forks,
# so Apple's notarization service sees a clean bundle. That is the authoritative check.
xattr -cr "$APP"
codesign --verify --deep --verbose=2 "$APP"
spctl --assess --type execute --verbose "$APP" 2>&1 || true   # will say "rejected" until notarized — that's expected

if [ "$SKIP_NOTARIZE" -eq 1 ]; then
    echo "==> Skipping notarization (--skip-notarize)."
    echo "==> Launching $APP…"
    open "$APP"
    echo "==> Done."
    exit 0
fi

echo "==> Zipping for notarization and Sparkle distribution…"
ZIP_PATH="/tmp/${BUNDLE_ID}-notarize.zip"
ditto -c -k --keepParent "$APP" "$ZIP_PATH"

echo "==> Signing zip for Sparkle…"
# Find sign_update from the SPM Sparkle artifact bundle.
SIGN_UPDATE=$(find .build/artifacts -name "sign_update" -type f 2>/dev/null | head -1)
if [ -z "$SIGN_UPDATE" ]; then
    echo "    WARNING: sign_update not found in .build/artifacts — run 'swift package resolve' first."
    echo "    Skipping Sparkle signature. The update will fail verification if published."
else
    SPARKLE_SIG=$("$SIGN_UPDATE" "$ZIP_PATH" 2>/dev/null)
    ZIP_SIZE=$(stat -f%z "$ZIP_PATH")
    echo "    Signature: $SPARKLE_SIG"
    echo "    Size:      $ZIP_SIZE bytes"
    echo
    echo "    Add this <item> block to appcast.xml (or run tools/publish_release.sh):"
    echo "    ─────────────────────────────────────────────────────────────────────"
    printf '    <item>\n'
    printf '        <title>Version %s</title>\n' "$RELEASE_VERSION"
    printf '        <pubDate>%s</pubDate>\n' "$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
    printf '        <sparkle:version>%s</sparkle:version>\n' "$_BUILD_NUM"
    printf '        <sparkle:shortVersionString>%s</sparkle:shortVersionString>\n' "$RELEASE_VERSION"
    printf '        <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>\n'
    printf '        <description><![CDATA[<ul><li>See Settings → About for changelog</li></ul>]]></description>\n'
    printf '        <enclosure\n'
    printf '            url="https://github.com/identd113/hdhr_VCR_swift/releases/download/v%s/hdhrVCRplus.zip"\n' "$RELEASE_VERSION"
    printf '            length="%s"\n' "$ZIP_SIZE"
    printf '            type="application/octet-stream"\n'
    printf '            sparkle:edSignature="%s"\n' "$SPARKLE_SIG"
    printf '        />\n'
    printf '    </item>\n'
    echo "    ─────────────────────────────────────────────────────────────────────"
fi
echo

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
