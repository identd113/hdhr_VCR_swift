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
cp .build/debug/hdhr_VCR "$BINARY"

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
# Delete sidecar/junk files first, then clear xattrs, then sign.
# Retry up to 3 times — Finder/Spotlight can re-attach attributes in the
# brief window between xattr -cr and codesign on a busy system.
find "$APP" -name "._*" -delete
find "$APP" -name ".DS_Store" -delete
_signed=0
for _attempt in 1 2 3; do
    xattr -cr "$APP"
    # No --deep: this bundle has no nested frameworks, and --deep causes codesign
    # to reject com.apple.FinderInfo that iCloud re-attaches to the bundle root.
    codesign --force --sign - "$APP" && _signed=1 && break
    echo "    Attempt $_attempt failed, retrying…"
done
[ "$_signed" -eq 1 ] || { echo "ERROR: codesign failed after 3 attempts"; exit 1; }
touch "$APP"   # update bundle mtime so Finder shows today's date

echo "==> Launching $APP…"
open "$APP"

echo "==> Done."
