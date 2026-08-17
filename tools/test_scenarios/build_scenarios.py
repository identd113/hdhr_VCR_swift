#!/usr/bin/env python3
"""build_scenarios.py — generates a custom guide.json + a matching mock_scenario.py `plant` file
covering the scheduling-engine edge cases most likely to hide a real bug, timed relative to
`time.time()` at generation time so re-running produces fresh, still-useful entries.

Pairs with tools/mock_hdhr.py --guide-file and tools/mock_scenario.py plant — see
tools/run_test_scenarios.sh for the orchestrated end-to-end flow. Run this alone if you just want
fresh fixture files without the live app dance (e.g. to eyeball the JSON, or drive your own flow).

Scenario coverage, and why each one is here rather than left to the existing `duplicate`/`conflict`
subcommands (which already exercise real live guide data well):
  - seriesChannel vs seriesAll cross-channel scoping — the 2026-08-15 bug class (issues_resolved.md)
    where a seriesChannel show's badge/scheduling could follow a same-SeriesID rerun onto a
    different channel. Needs a same-SeriesID entry on two channels, which real guides rarely offer
    on demand.
  - Bonus Time genre matching, plural AND singular — "Sports" (guide.php) vs "Sport" (XMLTV) are
    both supposed to default Bonus Time on (Show.genreImpliesBonusTime); the singular form is rare
    in real cloud-guide data, so it's easy for this to go untested against a live guide.
  - A genre that merely *contains* "sport" as a substring ("eSports") — genreImpliesBonusTime's
    match is deliberately loose; this surfaces whatever it actually does with the edge case rather
    than assuming.
  - Title-only fallback matching (no SeriesID) — exercises currentEntryByTitle/nextEntryByTitle,
    the tier GuideStore falls back to for guide providers that omit SeriesID.
  - A currently-airing entry — exercises the immediate on-air recording-start path without waiting
    for a real airing to line up.
  - A dateTime anchor entry — dateTime shows don't search the guide at all once scheduled (they're
    pure config + weekday arithmetic), but /api/record still requires an existing guide entry to
    create *any* show from, including the first dateTime one.

Output: tools/test_scenarios/generated_guide.json, tools/test_scenarios/generated_shows.json
(both gitignored-by-convention scratch output — regenerated fresh on every run, never hand-edited).
"""
import json
import os
import time

HERE = os.path.dirname(os.path.abspath(__file__))
GUIDE_OUT = os.path.join(HERE, "generated_guide.json")
SHOWS_OUT = os.path.join(HERE, "generated_shows.json")

MOCK_DEVICE_ID = "FFFF0001"  # must match mock_hdhr.py's MOCK_DEVICE_ID


def block(minutes_from_now, duration_min, title, **fields):
    start = int(time.time()) + minutes_from_now * 60
    entry = {"StartTime": start, "EndTime": start + duration_min * 60, "Title": title}
    entry.update(fields)
    return entry


def build_guide():
    return [
        {"GuideNumber": "5.1", "GuideName": "Scenario Channel A", "Guide": [
            block(10, 30, "Scenario Alpha Series", SeriesID="scn-alpha-001",
                  EpisodeNumber="S01E01", EpisodeTitle="Pilot", Filter=["Drama"]),
            block(130, 30, "Scenario Alpha Series", SeriesID="scn-alpha-001",
                  EpisodeNumber="S01E02", EpisodeTitle="Second Episode", Filter=["Drama"]),
        ]},
        {"GuideNumber": "9.9", "GuideName": "Scenario Channel B (rerun)", "Guide": [
            # Same SeriesID as 5.1 above, different channel — the seriesChannel-vs-seriesAll
            # cross-channel scoping case. A seriesChannel show anchored on 5.1 must NOT pick this
            # up; a seriesAll show anchored on 5.1 should.
            block(240, 30, "Scenario Alpha Series", SeriesID="scn-alpha-001",
                  EpisodeNumber="S01E01", EpisodeTitle="Pilot (rerun)", Filter=["Drama"]),
        ]},
        {"GuideNumber": "5.2", "GuideName": "Scenario Channel C", "Guide": [
            # Airing right now (StartTime in the past) — exercises the on-air/immediate-start path.
            block(-5, 30, "Scenario Now Airing", Filter=["News"]),
        ]},
        {"GuideNumber": "5.3", "GuideName": "Scenario Channel D", "Guide": [
            block(60, 30, "Scenario DateTime Anchor", Filter=["Talk"]),
            # No SeriesID at all — forces the title-only fallback matching tier.
            block(180, 30, "Scenario Title Only Show"),
        ]},
        {"GuideNumber": "5.4", "GuideName": "Scenario Channel E", "Guide": [
            block(80, 30, "Scenario Sports Plural", Filter=["Sports"]),
            block(150, 30, "Scenario Sports Singular", Filter=["Sport"]),
            # "sport" is a substring of "esports" — genreImpliesBonusTime's match is a plain
            # substring check, so this pins down what it actually does with the edge case rather
            # than assuming; not obviously right or wrong, worth eyeballing.
            block(200, 30, "Scenario Esports Event", Filter=["eSports"]),
        ]},
    ]


def build_shows():
    return [
        {"title": "Scenario Alpha Series", "channel": "5.1", "showType": "seriesChannel"},
        {"title": "Scenario Alpha Series", "channel": "5.1", "showType": "seriesAll"},
        {"title": "Scenario Now Airing", "channel": "5.2", "showType": "single"},
        {"title": "Scenario DateTime Anchor", "channel": "5.3", "showType": "dateTime",
         "airDays": ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]},
        {"title": "Scenario Title Only Show", "channel": "5.3", "showType": "seriesChannel"},
        {"title": "Scenario Sports Plural", "channel": "5.4", "showType": "single", "bonusTime": True},
        {"title": "Scenario Sports Singular", "channel": "5.4", "showType": "single", "bonusTime": True},
        {"title": "Scenario Esports Event", "channel": "5.4", "showType": "single", "bonusTime": True},
    ]


def main():
    guide = build_guide()
    shows = build_shows()
    with open(GUIDE_OUT, "w") as f:
        json.dump(guide, f, indent=2)
    with open(SHOWS_OUT, "w") as f:
        json.dump(shows, f, indent=2)
    entry_count = sum(len(ch.get("Guide") or []) for ch in guide)
    print(f"Wrote {GUIDE_OUT} — {len(guide)} channel(s), {entry_count} guide entr(y/ies)")
    print(f"Wrote {SHOWS_OUT} — {len(shows)} show(s) to plant")
    print(f"\nNote: two of the planted shows share the title \"Scenario Alpha Series\" on purpose")
    print(f"(one seriesChannel, one seriesAll) — that's the cross-channel-scoping scenario, not a mistake.")


if __name__ == "__main__":
    main()
