#!/bin/bash
# comskip.sh — commercial detection for hdhrVCRplus recordings
#
# Runs comskip on the recording and produces a .edl file alongside it.
# Plex, Emby, and Infuse all recognise .edl files for commercial skipping.
#
# Install:  brew install comskip
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
LOG="$(dirname "$FILE")/comskip.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

log "comskip starting: $FILE"
log "  title=$HDHR_TITLE  episode=${HDHR_EPISODE:-—}  transcode=$HDHR_TRANSCODE"

# comskip is most reliable on native MPEG-2 streams; skip on pre-transcoded files
if [ "$HDHR_TRANSCODE" != "none" ] && [ -n "$HDHR_TRANSCODE" ]; then
    log "Skipping — HDHR_TRANSCODE=$HDHR_TRANSCODE (not a raw MPEG-2 stream)"
    exit 0
fi

if ! command -v comskip &>/dev/null; then
    log "ERROR: comskip not found — run: brew install comskip"
    exit 1
fi

# --ini lets you override detection settings per machine (optional)
INI="${COMSKIP_INI:-$HOME/.comskip.ini}"
INI_ARG=""
[ -f "$INI" ] && INI_ARG="--ini=$INI"

comskip $INI_ARG \
        --output="$(dirname "$FILE")" \
        --output_filename="$(basename "${FILE%.*}")" \
        "$FILE" \
    >> "$LOG" 2>&1

log "comskip done (exit $?)"
