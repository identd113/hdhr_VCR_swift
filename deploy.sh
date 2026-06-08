#!/bin/bash
set -e

APP="hdhrVCRplus.app"
BINARY="$APP/Contents/MacOS/hdhr_VCR"

echo "==> Checking prerequisites…"
if ! xcode-select -p &>/dev/null || ! command -v swift &>/dev/null; then
    echo "    Xcode Command Line Tools not found. Launching installer…"
    xcode-select --install
    echo "    Complete the installer dialog, then re-run ./deploy.sh"
    exit 1
fi
echo "    Xcode Command Line Tools: OK"

echo "==> Stopping running instance…"
pkill -x hdhr_VCR 2>/dev/null && echo "    Stopped." || echo "    Not running."

echo "==> Generating version…"
# Stamp the build time as YYMMDD-HHMM (e.g. "260521-2011") so About tab always shows when this build was made
APP_VERSION="$(date +%y%m%d-%H%M)"
printf 'let appVersion = "%s"\n' "$APP_VERSION" > Sources/hdhr_VCR/Version.swift
echo "    Version: $APP_VERSION"

echo "==> Building…"
swift build

echo "==> Deploying binary…"
mkdir -p "$APP/Contents/MacOS"
cp .build/debug/hdhr_VCR "$BINARY"
# Add rpath so the binary finds Sparkle.framework in Contents/Frameworks at runtime.
# SPM builds against @rpath/Sparkle.framework; @loader_path alone won't reach Contents/Frameworks.
install_name_tool -add_rpath @executable_path/../Frameworks "$BINARY" 2>/dev/null || true

echo "==> Bundling Sparkle framework…"
_FW_DEST="$APP/Contents/Frameworks"
rm -rf "$_FW_DEST/Sparkle.framework"
mkdir -p "$_FW_DEST"
cp -R .build/debug/Sparkle.framework "$_FW_DEST/"
# Strip xattrs that SPM (or iCloud) attached to the source tree — cp -R copies them verbatim
# and codesign --options runtime rejects com.apple.FinderInfo as "detritus".
xattr -cr "$_FW_DEST/Sparkle.framework"

echo "==> Deploying resources…"
mkdir -p "$APP/Contents/Resources"
cp Resources/app.jpg "$APP/Contents/Resources/app.jpg"

echo "==> Generating app icon…"
# Build AppIcon.icns from app.jpg so the bundle icon in Finder stays current
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

echo "==> Signing…"
# Sign in /tmp to avoid iCloud Drive re-attaching com.apple.FinderInfo during codesign.
# codesign --options runtime rejects FinderInfo as "detritus"; iCloud races faster than
# a single xattr -cr call between the Sparkle component signs and the bundle sign.
_TMP_DIR=$(mktemp -d)
[ -d "$_TMP_DIR" ] || { echo "==> ERROR: mktemp failed"; exit 1; }
_TMP_APP="$_TMP_DIR/hdhrVCRplus.app"
cp -R "$APP" "$_TMP_APP"
find "$_TMP_APP" -name "._*" -delete
find "$_TMP_APP" -name ".DS_Store" -delete
xattr -cr "$_TMP_APP"

# Sign Sparkle internals inside-out: XPC services → Updater.app → Autoupdate → framework.
_SPKL="$_TMP_APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --options runtime --sign - "$_SPKL/XPCServices/Downloader.xpc"
codesign --force --options runtime --sign - "$_SPKL/XPCServices/Installer.xpc"
codesign --force --options runtime --sign - "$_SPKL/Updater.app"
codesign --force --options runtime --sign - "$_SPKL/Autoupdate"
codesign --force --options runtime --sign - "$_TMP_APP/Contents/Frameworks/Sparkle.framework"

# Sign the main bundle — /tmp is not iCloud-synced so FinderInfo won't be re-attached.
# Ad-hoc identity (-) for local dev; --options runtime enables Hardened Runtime so the
# binary behaves identically to a notarized release build.  Entitlements grant
# disable-library-validation so dlopen of VLC.app's libvlc.dylib is allowed under HR.
codesign --force --options runtime \
         --entitlements hdhrVCRplus.entitlements \
         --sign - "$_TMP_APP"

# Overwrite the in-repo bundle with the freshly signed copy.
rm -rf "$APP"
cp -R "$_TMP_APP" "$APP"
rm -rf "$_TMP_DIR"
touch "$APP"   # update bundle mtime so Finder shows today's date

echo "==> Launching $APP…"
open "$APP"

echo "==> Done."
