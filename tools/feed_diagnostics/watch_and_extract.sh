#!/bin/bash
# Watches the client machine's log for a real [VLC] STALL, then automatically
# slices the matching window out of a running feed_capture_tagger.py capture
# and runs analyze_pcr.py on it -- closing issues_resolved.md's "VLC-side
# FEED playback stalls" entry's "next step 3": does the stall correspond to a
# genuine PCR discontinuity baked into the bytes, or is the content clean at
# that point (pointing at pure delivery jitter instead)?
#
# Run feed_capture_tagger.py FIRST, in parallel with your normal FEED viewing
# (it's a second, independent reader of the same relay -- doesn't disturb
# VLC's own connection). Then run this in another terminal:
#
#   tools/feed_diagnostics/watch_and_extract.sh \
#       ~/Library/Logs/hdhrVCRplus.log /tmp/feed_capture.ts /tmp/feed_capture.offsets.tsv /tmp
#
# Loops so it can fire on every stall in a session, not just the first.

set -u

LOG_FILE="${1:-$HOME/Library/Logs/hdhrVCRplus.log}"
CAPTURE_TS="${2:-/tmp/feed_capture.ts}"
OFFSETS_TSV="${3:-/tmp/feed_capture.offsets.tsv}"
OUT_DIR="${4:-/tmp}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[watch] tailing $LOG_FILE for [VLC] STALL events..."

stall_start_epoch=""

# ISO8601 -> epoch via python3, not `date -j -f`/`date -d` -- BSD date (real
# macOS default) and GNU date (e.g. homebrew coreutils ahead in PATH) take
# incompatible flags for this, and silently produce nothing on the wrong one.
iso_to_epoch() {
    python3 -c "import sys,calendar,time; print(calendar.timegm(time.strptime(sys.argv[1], '%Y-%m-%dT%H:%M:%SZ')))" "$1" 2>/dev/null
}
epoch_to_compact() {
    python3 -c "import sys,time; print(time.strftime('%Y%m%d_%H%M%S', time.gmtime(float(sys.argv[1]))))" "$1"
}

# `tail -F` (capital F) survives the log rotating mid-session
# (RotatingLogFile in Models.swift) by reopening on rename, unlike `-f`.
tail -F -n0 "$LOG_FILE" | while IFS= read -r line; do
    # Extract the leading "[2026-09-12T03:49:10Z]" ISO8601 timestamp glog() prefixes every line with.
    ts=$(echo "$line" | sed -n 's/^\[\([0-9T:-]*Z\)\].*/\1/p')
    [ -z "$ts" ] && continue

    if echo "$line" | grep -q '\[VLC\] STALL —'; then
        epoch=$(iso_to_epoch "$ts")
        [ -z "$epoch" ] && continue
        stall_start_epoch="$epoch"
        echo "[watch] STALL started at $ts (epoch $epoch)"

    elif echo "$line" | grep -q '\[VLC\] STALL resolved'; then
        epoch=$(iso_to_epoch "$ts")
        if [ -z "$epoch" ] || [ -z "$stall_start_epoch" ]; then
            continue
        fi
        echo "[watch] STALL resolved at $ts (epoch $epoch) -- extracting window"

        window_ts="$OUT_DIR/feed_stall_window_$(epoch_to_compact "$stall_start_epoch").ts"

        python3 "$SCRIPT_DIR/extract_window.py" \
            --src "$CAPTURE_TS" --offsets "$OFFSETS_TSV" \
            --start-epoch "$stall_start_epoch" --end-epoch "$epoch" --pad 3 \
            --out "$window_ts"

        if [ -f "$window_ts" ]; then
            echo "[watch] analyzing $window_ts"
            python3 "$SCRIPT_DIR/analyze_pcr.py" "$window_ts" | tee "${window_ts%.ts}.analysis.txt"
        fi

        stall_start_epoch=""
    fi
done
