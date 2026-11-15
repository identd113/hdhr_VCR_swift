# FeedPlaylist

`Sources/hdhr_VCR/FeedPlaylist.swift` builds an M3U playlist and an XMLTV guide of the channels this Mac is **recording right now**, for apps that take a playlist + guide instead of an HDHomeRun: Channels DVR (custom channels), Jellyfin, TiviMate, VLC.

## Why a playlist and not an HDHomeRun
Third-party HDHomeRun clients cannot be fully satisfied by the relay: SiliconDust's own app takes its guide from the cloud, keyed to the real DeviceID (`docs/VirtualTunerService.md`, "Third-party HDHomeRun clients"). A playlist + XMLTV has no vendor or cloud check.

## Routes (WebServer)
- `GET /feed.m3u` — one `#EXTINF` per recording channel (`tvg-id`, `tvg-chno`, `tvg-name`, `tvg-logo`, `group-title="Recording Now"`), stream URL = the existing `/auto/v<ch>?dev=<deviceId>` relay stream. The header carries `x-tvg-url` pointing at `/feed.xml`.
- `GET /feed.xml` — XMLTV: a `<channel>` per recording channel and a `<programme>` for every guide entry still to end (title, sub-title, desc, categories, icon, episode number). Times are UTC.
- Both answer 404 unless `Other_apps_feed_enabled` is on. Neither is cached (`okNoStore`). The list changes as recordings start and stop.

## Setting
`Other_apps_feed_enabled` (default off): Settings → Sharing → "Other apps" (needs Web LAN) and a first-run wizard step, "Other Apps", saved only when Web LAN is on, like the terminal guide.

## Not done
Non-recording channels are not listed; a full lineup would need a redirect to the real tuner. HDHomeRun emulation for Plex/Jellyfin (own DeviceID, no borrowed DeviceAuth) is a possible next step (`TODO.md`).

Tests: `Tests/hdhr_VCRTests/WebServer/FeedPlaylistTests.swift`.
