#!/bin/bash
set -e

APP="hdhr_VCR.app"
BINARY="$APP/Contents/MacOS/hdhr_VCR"

echo "==> Stopping running instance…"
pkill -x hdhr_VCR 2>/dev/null && echo "    Stopped." || echo "    Not running."

echo "==> Generating version…"
# Stamp the build time as YYMMDD-HHMM (e.g. "260521-2011") so About tab always shows when this build was made
printf 'let appVersion = "%s"\n' "$(date +%y%m%d-%H%M)" > Sources/hdhr_VCR/Version.swift
echo "    Version: $(date +%y%m%d-%H%M)"

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
