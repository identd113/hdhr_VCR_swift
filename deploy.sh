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

echo "==> Signing…"
# Sign in /tmp to avoid iCloud Drive re-attaching com.apple.FinderInfo during codesign.
# codesign --options runtime rejects FinderInfo as "detritus"; iCloud races faster than
# a single xattr -cr call on the live bundle.
_TMP_DIR=$(mktemp -d)
[ -d "$_TMP_DIR" ] || { echo "==> ERROR: mktemp failed"; exit 1; }
_TMP_APP="$_TMP_DIR/hdhrVCRplus.app"
cp -R "$APP" "$_TMP_APP"
find "$_TMP_APP" -name "._*" -delete
find "$_TMP_APP" -name ".DS_Store" -delete
xattr -cr "$_TMP_APP"

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

echo "==> Waiting for web server…"
_WS_READY=0
for _i in $(seq 1 10); do
    if curl -sf -o /dev/null -m 1 http://localhost:1980/api/ping 2>/dev/null; then
        _WS_READY=1
        break
    fi
    sleep 0.5
done

if [ "$_WS_READY" = "1" ]; then
    echo "==> Running performance regression tests…"
    # Post-deploy only — WebServerPerfTests.swift skips itself if the web server isn't up,
    # but there's no point invoking swift test at all if we already know it's down. Failures
    # here are reported, not fatal: the app already deployed and is running successfully by
    # this point, a latency regression shouldn't make deploy.sh itself exit non-zero.
    if xcrun --find xctest &>/dev/null; then
        swift test --filter WebServerPerfTests || echo "    ⚠ perf tests failed or reported a regression — see output above"
    else
        # CommandLineTools-only toolchain (no full Xcode): swift test compiles the suite but
        # has no host to actually execute it in — see Tests/hdhr_VCRTests/WebServerPerfTests.swift.
        swift test --filter WebServerPerfTests || true
        echo "    (xctest unavailable in this toolchain — build verified but tests did not execute; install full Xcode for real pass/fail output)"
    fi
else
    echo "==> Web server not reachable on :1980 after 5s — skipping performance tests (enabled in Settings → Web Server?)"
fi

echo "==> Done."
