#!/usr/bin/env bash
# Test HDHomeRun favorite toggle for a given channel.
# Usage: ./test_favorite.sh [device-ip] [channel-number]
# Defaults: hdhomerun.local, first channel in lineup

set -euo pipefail

DEVICE="${1:-hdhr-105404be.local}"
CHANNEL="${2:-}"
LINEUP_URL="http://${DEVICE}/lineup.json"
TOGGLE_URL="http://${DEVICE}/lineup.post"

# Fetch lineup and extract favorites
get_favorite() {
    local ch="$1"
    curl -sf "$LINEUP_URL" | \
        python3 -c "
import json, sys
lineup = json.load(sys.stdin)
for e in lineup:
    if e.get('GuideNumber') == '$ch':
        print(e.get('Favorite', 0))
        sys.exit(0)
print('NOT_FOUND')
sys.exit(1)
"
}

# Fetch lineup JSON
echo "Fetching lineup from $LINEUP_URL ..."
LINEUP_JSON=$(curl -sf "$LINEUP_URL")

# Pick channel to test
if [[ -z "$CHANNEL" ]]; then
    CHANNEL=$(echo "$LINEUP_JSON" | python3 -c "
import json, sys
lineup = json.load(sys.stdin)
if lineup:
    print(lineup[0]['GuideNumber'])
")
    echo "No channel specified — using first channel: $CHANNEL"
fi

# Show channel info
CHANNEL_NAME=$(echo "$LINEUP_JSON" | python3 -c "
import json, sys
lineup = json.load(sys.stdin)
for e in lineup:
    if e.get('GuideNumber') == '$CHANNEL':
        fav = e.get('Favorite', 0)
        print(f\"{e.get('GuideName','?')}  favorite={fav}\")
        sys.exit(0)
print('Channel not found')
sys.exit(1)
")
echo "Channel $CHANNEL: $CHANNEL_NAME"

# Read initial state
INITIAL=$(get_favorite "$CHANNEL")
echo ""
echo "Initial favorite value: $INITIAL"

# --- Toggle ON ---
echo ""
echo "--- Setting favorite ON (+$CHANNEL) ---"
curl -sf -X POST "${TOGGLE_URL}?favorite=%2B${CHANNEL}" -o /dev/null
sleep 0.5

AFTER_ON=$(get_favorite "$CHANNEL")
echo "Favorite after +: $AFTER_ON"
if [[ "$AFTER_ON" == "1" ]]; then
    echo "  PASS: favorite is now 1"
else
    echo "  FAIL: expected 1, got $AFTER_ON"
fi

# --- Toggle OFF ---
echo ""
echo "--- Setting favorite OFF (-$CHANNEL) ---"
curl -sf -X POST "${TOGGLE_URL}?favorite=-${CHANNEL}" -o /dev/null
sleep 0.5

AFTER_OFF=$(get_favorite "$CHANNEL")
echo "Favorite after -: $AFTER_OFF"
if [[ "$AFTER_OFF" == "0" ]]; then
    echo "  PASS: favorite is now 0"
else
    echo "  FAIL: expected 0, got $AFTER_OFF"
fi

# --- Restore original ---
echo ""
echo "--- Restoring original state (was $INITIAL) ---"
if [[ "$INITIAL" == "1" ]]; then
    curl -sf -X POST "${TOGGLE_URL}?favorite=%2B${CHANNEL}" -o /dev/null
    sleep 1.5
    RESTORED=$(get_favorite "$CHANNEL")
    echo "Restored to: $RESTORED"
    [[ "$RESTORED" == "1" ]] && echo "  PASS: restored to 1" || echo "  FAIL: expected 1, got $RESTORED"
else
    echo "  Already off — no restore needed"
fi

echo ""
echo "Done."
