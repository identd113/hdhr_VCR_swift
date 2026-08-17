#!/usr/bin/env bash
# run_test_scenarios.sh — end-to-end scheduling-engine scenario test.
#
# Generates a custom guide (tools/test_scenarios/build_scenarios.py), serves it via a mock
# HDHomeRun device (mock_hdhr.py --guide-file), restarts the real app so it picks the mock device
# up fresh, then schedules a batch of edge-case shows against that custom guide
# (mock_scenario.py plant) — all deterministic, none dependent on what's actually airing right now.
#
# Repeatable: fixture timestamps are relative to "now" at generation time, so re-running this
# script produces fresh, still-useful entries every time.
#
# WHAT THIS DOES TO YOUR MACHINE, so there are no surprises:
#   - Requires sudo (mock_hdhr.py needs it for port 80 + a loopback interface alias).
#   - STOPS AND RESTARTS the real running app (`pkill -x hdhr_VCR` + `open`), the same way
#     deploy.sh does — needed so the app does a fresh device-discovery pass and actually notices
#     the mock device (it otherwise only re-scans for new devices every 5 minutes). Refuses to run
#     if any show is currently show_recording=true, so it can't kill an in-progress recording.
#   - Schedules real [MOCK]-prefixed shows in your live config via the same /api/record path the
#     app's own UI uses — reversible any time with `tools/mock_scenario.py clean`.
#   - Leaves mock_hdhr.py running in the background when it exits — see the teardown note it
#     prints at the end. Until you stop it and relaunch the app again, this Mac will keep
#     advertising a second, fake HDHomeRun device (FFFF0001) with fully custom guide data.
#
# Usage: tools/run_test_scenarios.sh [--port 1980]

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
cd "$REPO_ROOT"

PORT=1980
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PORT="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

GUIDE_FILE="$HERE/test_scenarios/generated_guide.json"
SHOWS_FILE="$HERE/test_scenarios/generated_shows.json"
MOCK_LOG="$HERE/test_scenarios/mock_hdhr.log"

echo "==> Checking for an in-progress recording (this script restarts the app)…"
CONFIG_JSON="$(find "$HOME/Library/Application Support/hdhrVCRplus" -maxdepth 1 -name 'hdhr_VCR-*.json' 2>/dev/null | sort | head -1 || true)"
if [[ -n "$CONFIG_JSON" ]]; then
    if python3 -c "
import json, sys
shows = json.load(open('$CONFIG_JSON')).get('shows', [])
sys.exit(1 if any(s.get('show_recording') for s in shows) else 0)
"; then
        echo "    OK — nothing recording."
    else
        echo "ERROR: a show is currently recording. Restarting the app would kill it." >&2
        echo "        Wait for it to finish, or stop it yourself, then re-run this script." >&2
        exit 1
    fi
else
    echo "    No config file found yet — assuming nothing is recording."
fi

echo "==> Generating fresh scenario fixtures…"
python3 "$HERE/test_scenarios/build_scenarios.py"

echo "==> Starting mock_hdhr.py --guide-file (needs sudo; logging to $MOCK_LOG)…"
sudo -v   # prime the sudo timestamp now, with a real prompt, before backgrounding anything
sudo python3 "$HERE/mock_hdhr.py" --guide-file "$GUIDE_FILE" >"$MOCK_LOG" 2>&1 &
MOCK_PID=$!
echo "    mock_hdhr.py running as PID $MOCK_PID"

echo "==> Waiting for the mock device to come up…"
for _ in $(seq 1 15); do
    if curl -fsS "http://127.0.0.2/discover.json" >/dev/null 2>&1; then
        echo "    OK."
        break
    fi
    sleep 1
done
if ! curl -fsS "http://127.0.0.2/discover.json" >/dev/null 2>&1; then
    echo "ERROR: mock_hdhr.py never came up — check $MOCK_LOG" >&2
    sudo kill "$MOCK_PID" 2>/dev/null || true
    exit 1
fi

echo "==> Restarting the app so it rediscovers devices fresh (normally only rescans every 5 min)…"
pkill -x hdhr_VCR 2>/dev/null && echo "    Stopped." || echo "    Was not running."
sleep 1
open "$REPO_ROOT/hdhrVCRplus.app"

echo "==> Waiting for the app's web server…"
for _ in $(seq 1 30); do
    if curl -fsS "http://localhost:$PORT/api/ping" >/dev/null 2>&1; then
        echo "    OK."
        break
    fi
    sleep 1
done
if ! curl -fsS "http://localhost:$PORT/api/ping" >/dev/null 2>&1; then
    echo "ERROR: app web server never came up on port $PORT." >&2
    exit 1
fi

echo "==> Giving startup discovery + guide fetch a moment to settle…"
sleep 5

echo "==> Planting scenario shows…"
python3 "$HERE/mock_scenario.py" plant --file "$SHOWS_FILE" --port "$PORT" || true

cat <<EOF

==============================================================================
Scenario shows planted. Things worth checking in the web guide
(http://localhost:$PORT/):

  - "Scenario Alpha Series" on channel 5.1 (seriesChannel + seriesAll badges):
    the blue managed-ring badge should appear on BOTH airings on channel 5.1.
    On channel 9.9's rerun (same SeriesID), only the seriesAll show's version
    should ever be eligible to badge/follow it — seriesChannel must not.
  - "Scenario Sports Plural" / "Scenario Sports Singular" / "Scenario Esports
    Event" (channel 5.4) — check each show's Bonus Time flag (Edit modal) came
    through as expected; the esports one is a genuine edge case, not a known-
    right-or-wrong answer.
  - "Scenario Title Only Show" (channel 5.3) — has no SeriesID in the guide;
    confirms title-only fallback matching found and scheduled it at all.
  - "Scenario Now Airing" (channel 5.2) — StartTime is in the past; should
    already show as on-air / eligible to start recording on the next idle
    tick (it won't actually produce real video — the mock's channel numbers
    don't correspond to real tuner content).
  - "Scenario DateTime Anchor" (channel 5.3) — a dateTime show with weekday
    recurrence; confirm it scheduled onto the correct next weekday/time.

Teardown when done:
  tools/mock_scenario.py clean          # removes the planted [MOCK] shows
  sudo kill $MOCK_PID                   # stops mock_hdhr.py
  (then restart the app again — pkill -x hdhr_VCR && open hdhrVCRplus.app —
   so it rediscovers your real devices without the mock one in the mix)
==============================================================================
EOF
