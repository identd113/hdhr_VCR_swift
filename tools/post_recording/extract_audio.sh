#!/bin/bash
# extract_audio.sh — extract the audio track from a recording to AAC .m4a
#
# Useful for talk shows, music programs, podcasts, or anything where you
# only want the audio. The video stream is dropped; audio is copied as-is
# when already AAC, or re-encoded to 256 kbps AAC otherwise.
# The original recording is left intact.
#
# Install:  brew install ffmpeg
# Set in:   Settings → Recording → Post-recording script
#
# Env vars supplied by hdhrVCRplus:
#   $1 / HDHR_PATH      full path to the recording file
#   HDHR_TITLE          show title
#   HDHR_EPISODE        episode tag, e.g. "S02E04" (empty if unknown)
#   HDHR_FILESIZE       file size in bytes

set -euo pipefail

FILE="${1:?HDHR_PATH not set}"
DIR="$(dirname "$FILE")"
BASE="$(basename "${FILE%.*}")"
OUT="$DIR/$BASE.m4a"
LOG="$DIR/extract_audio.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

log "extract_audio starting: $FILE"
log "  title=$HDHR_TITLE  episode=${HDHR_EPISODE:-—}  size=${HDHR_FILESIZE}B"

if ! command -v ffmpeg &>/dev/null; then
    log "ERROR: ffmpeg not found — run: brew install ffmpeg"
    exit 1
fi

# Probe the audio codec — copy if already AAC, re-encode otherwise
AUDIO_CODEC=$(ffprobe -v error -select_streams a:0 \
    -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 \
    "$FILE" 2>/dev/null || echo "unknown")

log "Audio codec: $AUDIO_CODEC"

if [ "$AUDIO_CODEC" = "aac" ]; then
    log "AAC source → stream copy (lossless)"
    AUDIO_ARGS="-c:a copy"
else
    log "Non-AAC source ($AUDIO_CODEC) → encoding to AAC 256k"
    AUDIO_ARGS="-c:a aac -b:a 256k"
fi

ffmpeg -i "$FILE" \
       -vn \
       $AUDIO_ARGS \
       -y "$OUT" \
    >> "$LOG" 2>&1

RC=$?
if [ $RC -eq 0 ]; then
    log "Done: $OUT ($(du -sh "$OUT" | cut -f1))"
else
    log "ERROR: ffmpeg exited $RC"
    rm -f "$OUT"
    exit $RC
fi
