#!/bin/bash
set -e

APP="hdhrVCRplus.app"
BINARY="$APP/Contents/MacOS/hdhr_VCR"

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

echo "==> Signing…"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
touch "$APP"   # update bundle mtime so Finder shows today's date

echo "==> Launching $APP…"
open "$APP"

echo "==> Done."
