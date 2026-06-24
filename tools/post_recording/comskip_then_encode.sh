#!/bin/bash
# comskip_then_encode.sh — commercial detection + encode to MP4 with chapter marks
#
# Runs comskip to detect commercials, then encodes to H.264 MP4 with the
# commercial boundaries embedded as chapters so players can jump over them
# even without native EDL support (QuickTime, VLC chapter menu, etc.).
# The original .m2ts file is removed after a successful encode.
#
# Only runs on MPEG-2 .m2ts recordings (HDHR_TRANSCODE=none); for
# pre-transcoded .mkv files it falls back to a plain MP4 remux.
#
# Install:  brew install comskip ffmpeg
# Set in:   Settings → Recording → Post-recording script
#
# Env vars supplied by hdhrVCRplus:
#   $1 / HDHR_PATH      full path to the recording file
#   HDHR_TITLE          show title
#   HDHR_TRANSCODE      "none" = MPEG-2 .m2ts  |  other = transcoded .mkv
#   HDHR_EPISODE        episode tag, e.g. "S02E04" (empty if unknown)
#   HDHR_FILESIZE       file size in bytes

set -euo pipefail

FILE="${1:?HDHR_PATH not set}"
DIR="$(dirname "$FILE")"
BASE="$(basename "${FILE%.*}")"
OUT="$DIR/$BASE.mp4"
EDL="$DIR/$BASE.edl"
FFMETA="$DIR/$BASE.ffmeta"
LOG="$DIR/post_recording.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

log "=== comskip_then_encode starting ==="
log "  file=$FILE"
log "  title=$HDHR_TITLE  episode=${HDHR_EPISODE:-—}  transcode=$HDHR_TRANSCODE"

for cmd in ffmpeg ffprobe; do
    command -v "$cmd" &>/dev/null || { log "ERROR: $cmd not found — brew install $cmd"; exit 1; }
done

# ── Step 1: comskip (MPEG-2 only) ───────────────────────────────────────────

# Probe actual video codec — never re-encode if already H.264
VIDEO_CODEC=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 \
    "$FILE" 2>/dev/null || echo "unknown")
log "Video codec: $VIDEO_CODEC"

if [ "$VIDEO_CODEC" != "h264" ]; then
    if command -v comskip &>/dev/null; then
        log "Running comskip…"
        INI="${COMSKIP_INI:-$HOME/.comskip.ini}"
        INI_ARG=""; [ -f "$INI" ] && INI_ARG="--ini=$INI"
        comskip $INI_ARG \
                --output="$DIR" \
                --output_filename="$BASE" \
                "$FILE" >> "$LOG" 2>&1 || log "comskip exited non-zero — continuing without EDL"
        [ -f "$EDL" ] && log "EDL written: $EDL" || log "No EDL produced"
    else
        log "comskip not found — skipping commercial detection (brew install comskip)"
    fi

    # ── Step 2: convert EDL → ffmpeg chapter metadata ───────────────────────
    if [ -f "$EDL" ]; then
        log "Converting EDL to ffmpeg chapters…"
        python3 - "$EDL" "$FFMETA" <<'PYEOF'
import sys, math

edl_path, meta_path = sys.argv[1], sys.argv[2]
segments = []
with open(edl_path) as f:
    for line in f:
        parts = line.strip().split()
        if len(parts) >= 3:
            segments.append((float(parts[0]), float(parts[1]), int(parts[2])))

# Build chapter list: program segments between/around commercials
chapters = []
prev = 0.0
for start, end, action in segments:
    if action == 0:  # cut
        if start > prev:
            chapters.append((prev, start, "Program"))
        chapters.append((start, end, "Commercial"))
        prev = end
# Final program segment
chapters.append((prev, 999999.0, "Program"))

with open(meta_path, "w") as f:
    f.write(";FFMETADATA1\n")
    for i, (s, e, title) in enumerate(chapters):
        f.write(f"\n[CHAPTER]\nTIMEBASE=1/1000\n"
                f"START={int(s*1000)}\nEND={int(e*1000)}\ntitle={title} {i+1}\n")
PYEOF
        log "Chapter metadata written: $FFMETA"
    fi

    # ── Step 3: encode MPEG-2 → H.264 MP4 ───────────────────────────────────
    log "Encoding MPEG-2 → H.264 MP4 (CRF 23)…"
    META_ARG=""; [ -f "$FFMETA" ] && META_ARG="-i $FFMETA -map_metadata 1"
    ffmpeg -i "$FILE" $META_ARG \
           -map 0:v:0 -map 0:a:0 \
           -c:v libx264 -preset medium -crf 23 \
           -c:a aac -b:a 192k \
           -movflags +faststart \
           -y "$OUT" >> "$LOG" 2>&1

else
    # Already H.264 — just remux to MP4 (fast, lossless)
    log "H.264 source → remuxing to MP4 (no re-encode)…"
    ffmpeg -i "$FILE" -c copy -movflags +faststart -y "$OUT" >> "$LOG" 2>&1
fi

RC=$?
if [ $RC -eq 0 ]; then
    log "Encode complete: $OUT ($(du -sh "$OUT" | cut -f1))"
    rm -f "$FILE" "$FFMETA"
    log "Removed original: $FILE"
else
    log "ERROR: ffmpeg exited $RC — original file kept"
    rm -f "$OUT" "$FFMETA"
    exit $RC
fi

log "=== Done ==="
