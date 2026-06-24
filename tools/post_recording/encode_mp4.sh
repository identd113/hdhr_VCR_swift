#!/bin/bash
# encode_mp4.sh — convert a recording to H.264/AAC MP4 using ffmpeg
#
# MPEG-2 .m2ts recordings are re-encoded to H.264 (CRF 23, medium preset).
# Already-transcoded .mkv recordings are remuxed to .mp4 without re-encoding,
# since they're already H.264/AAC — fast, lossless, no quality hit.
# The original file is removed after a successful encode.
#
# Install:  brew install ffmpeg
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
LOG="$DIR/encode.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

log "encode_mp4 starting: $FILE"
log "  title=$HDHR_TITLE  episode=${HDHR_EPISODE:-—}  transcode=$HDHR_TRANSCODE  size=${HDHR_FILESIZE}B"

for cmd in ffmpeg ffprobe; do
    command -v "$cmd" &>/dev/null || { log "ERROR: $cmd not found — run: brew install ffmpeg"; exit 1; }
done

# Probe actual video codec — never re-encode if already H.264
VIDEO_CODEC=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 \
    "$FILE" 2>/dev/null || echo "unknown")

log "Video codec: $VIDEO_CODEC"

if [ "$VIDEO_CODEC" = "h264" ]; then
    # Already H.264 — just remux to MP4 container (fast, lossless)
    log "H.264 source → remuxing to MP4 (no re-encode)"
    ffmpeg -i "$FILE" \
           -c copy \
           -movflags +faststart \
           -y "$OUT" \
        >> "$LOG" 2>&1
else
    # MPEG-2 (or other) — encode to H.264
    log "MPEG-2 source ($VIDEO_CODEC) → encoding to H.264 CRF 23"
    ffmpeg -i "$FILE" \
           -c:v libx264 -preset medium -crf 23 \
           -c:a aac -b:a 192k \
           -movflags +faststart \
           -y "$OUT" \
        >> "$LOG" 2>&1
fi

RC=$?
if [ $RC -eq 0 ]; then
    log "Encode complete: $OUT ($(du -sh "$OUT" | cut -f1))"
    rm -f "$FILE"
    log "Removed original: $FILE"
else
    log "ERROR: ffmpeg exited $RC — original file kept"
    rm -f "$OUT"
    exit $RC
fi
