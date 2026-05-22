#!/bin/bash
set -e

APP="hdhr_VCR.app"
BINARY="$APP/Contents/MacOS/hdhr_VCR"

echo "==> Stopping running instance…"
pkill -x hdhr_VCR 2>/dev/null && echo "    Stopped." || echo "    Not running."

echo "==> Generating version…"
# Read version from Info.plist so the About tab matches the release tag.
# To release a new version: bump CFBundleShortVersionString in Info.plist, then run deploy.sh.
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
printf 'let appVersion = "%s"\n' "$APP_VERSION" > Sources/hdhr_VCR/Version.swift
echo "    Version: $APP_VERSION"

echo "==> Building…"
swift build

echo "==> Deploying binary…"
cp .build/debug/hdhr_VCR "$BINARY"

echo "==> Signing…"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
touch "$APP"   # update bundle mtime so Finder shows today's date

echo "==> Launching $APP…"
open "$APP"

echo "==> Done."
