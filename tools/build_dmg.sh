#!/bin/bash
# Assembles the classic-Mac-style installer DMG: the given .app, a Read Me.rtfd (custom icon,
# rebuilt fresh from docs/screenshots/ every run — never a tracked, staleness-prone binary), an
# /Applications alias, and a custom background. See docs/Distribution.md's "DMG assembly" section.
#
# Deliberately independent of deploy_release.sh's own sign/notarize steps — takes an
# already-built .app as input rather than building/signing one itself — so the DMG layout,
# background, and manual can be iterated on and tested against any .app (a plain dev build
# included) without a real Developer ID signature or a notary round trip each time.
#
# Usage: tools/build_dmg.sh <version> <path-to-app>
#   e.g.: tools/build_dmg.sh 2.2.0 hdhrVCRplus.app

set -e

VERSION="$1"
APP_PATH="$2"
if [ -z "$VERSION" ] || [ -z "$APP_PATH" ]; then
    echo "Usage: tools/build_dmg.sh <version> <path-to-app>"
    exit 1
fi
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: $APP_PATH not found"
    exit 1
fi
command -v create-dmg >/dev/null || { echo "ERROR: create-dmg not installed — run: brew install create-dmg"; exit 1; }
python3 -c "import PIL" 2>/dev/null || { echo "ERROR: Pillow not installed — run: pip3 install Pillow"; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$REPO_ROOT/tools/dmg_assets"
GEN="$ASSETS/generated"
DIST_DIR="$REPO_ROOT/dist"
APP_NAME="$(basename "$APP_PATH")"
APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$APP_NAME"   # absolute — create-dmg/ditto below need it

rm -rf "$GEN"
mkdir -p "$GEN"

echo "==> Rendering Read Me icon…"
# readme_icon.svg is itself square (1:1), so — unlike the background below — the square canvas
# qlmanage's thumbnail renderer always produces needs no cropping back to a different aspect ratio.
# Rendered straight into $GEN (gitignored), never $ASSETS (tracked, holds only the hand-authored
# .svg sources) — qlmanage names its output <input-basename>.png in whatever -o dir is given, so
# rendering into the tracked dir and rm -f'ing it after each size would leave a stray renderer
# output sitting next to the source art if the script ever died between those two steps.
ICONSET="$GEN/readme_icon.iconset"
mkdir -p "$ICONSET"
for SZ in 16 32 64 128 256 512 1024; do
    rm -f "$GEN/readme_icon.svg.png"
    qlmanage -t -s "$SZ" -o "$GEN" "$ASSETS/readme_icon.svg" >/dev/null 2>&1
    mv "$GEN/readme_icon.svg.png" "$GEN/size_${SZ}.png"
done
cp "$GEN/size_16.png"   "$ICONSET/icon_16x16.png"
cp "$GEN/size_32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$GEN/size_32.png"   "$ICONSET/icon_32x32.png"
cp "$GEN/size_64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$GEN/size_128.png"  "$ICONSET/icon_128x128.png"
cp "$GEN/size_256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$GEN/size_256.png"  "$ICONSET/icon_256x256.png"
cp "$GEN/size_512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$GEN/size_512.png"  "$ICONSET/icon_512x512.png"
cp "$GEN/size_1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$GEN/readme.icns"

echo "==> Building Read Me manual from docs/screenshots/…"
swift "$REPO_ROOT/tools/build_readme_manual.swift" "$REPO_ROOT"

echo "==> Applying Read Me icon…"
swift "$REPO_ROOT/tools/apply_finder_icon.swift" "$GEN/readme.icns" "$GEN/Read Me.rtfd"

echo "==> Rendering DMG background…"
# Same $GEN-not-$ASSETS reasoning as the icon render above.
rm -f "$GEN/dmg_background.svg.png"
qlmanage -t -s 1320 -o "$GEN" "$ASSETS/dmg_background.svg" >/dev/null 2>&1
python3 - "$GEN/dmg_background.svg.png" "$GEN/dmg_background.png" <<'PYEOF'
import sys
from PIL import Image
im = Image.open(sys.argv[1])
# dmg_background.svg is 660x500 — qlmanage renders any non-square SVG into a square canvas at the
# requested size, content top/left-aligned at its real aspect ratio, so crop back to 660:500
# before use (verified empirically against this exact file, not assumed from qlmanage's docs).
crop = im.crop((0, 0, 1320, 1000))
crop.resize((660, 500), Image.LANCZOS).save(sys.argv[2])
PYEOF
rm -f "$GEN/dmg_background.svg.png"

echo "==> Staging DMG contents…"
STAGE="$(mktemp -d)/dmg-stage"
mkdir -p "$STAGE"
# Otherwise leaves a full copy of the (potentially universal-binary, VLCKit-framework-carrying)
# signed .app sitting under $TMPDIR indefinitely — harmless in the sense that macOS eventually
# reclaims $TMPDIR on its own schedule, but cheap enough to just clean up immediately instead.
trap 'rm -rf "$(dirname "$STAGE")"' EXIT
# ditto, not cp -R — cp -R does not reliably preserve the custom-icon extended attribute on a
# bundle/folder (confirmed directly: an earlier cp -R silently dropped it), so the icon is
# re-applied fresh at the actual staged path below rather than trusting either copy to carry it.
ditto "$APP_PATH" "$STAGE/$APP_NAME"
ditto "$GEN/Read Me.rtfd" "$STAGE/Read Me.rtfd"
swift "$REPO_ROOT/tools/apply_finder_icon.swift" "$GEN/readme.icns" "$STAGE/Read Me.rtfd"

mkdir -p "$DIST_DIR"
DMG_PATH="$DIST_DIR/hdhrVCRplus-${VERSION}.dmg"
rm -f "$DMG_PATH"

echo "==> Building DMG…"
# Icon positions are chosen to match tools/dmg_assets/dmg_background.svg's own arrow/text
# layout — edit them together if either one's coordinates change. Window is 660x500 to match the
# background exactly; icon-size 96 leaves a clean gap on both sides of the arrow at these positions.
create-dmg \
    --volname "hdhrVCRplus" \
    --volicon "$APP_PATH/Contents/Resources/AppIcon.icns" \
    --background "$GEN/dmg_background.png" \
    --window-size 660 500 \
    --window-pos 200 120 \
    --icon-size 96 \
    --text-size 12 \
    --icon "$APP_NAME" 170 170 \
    --app-drop-link 490 170 \
    --icon "Read Me.rtfd" 330 370 \
    --hide-extension "$APP_NAME" \
    "$DMG_PATH" \
    "$STAGE"

echo "    Artifact: $DMG_PATH"
echo "==> Done."
