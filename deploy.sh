#!/bin/bash
set -e

APP="hdhr_VCR.app"
BINARY="$APP/Contents/MacOS/hdhr_VCR"

echo "==> Stopping running instance…"
pkill -x hdhr_VCR 2>/dev/null && echo "    Stopped." || echo "    Not running."

echo "==> Building…"
swift build

echo "==> Deploying binary…"
cp .build/debug/hdhr_VCR "$BINARY"

echo "==> Launching $APP…"
open "$APP"

echo "==> Done."
