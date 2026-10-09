# What's New in v2.6.0 — DRAFT

*Covers everything since v2.5.0 (2026-09-19): ~175 commits. Draft for `RELEASES.md` (house style: condensed,
end-user-facing). Not yet in `CHANGELOG.md`'s "Unreleased" section: the items marked ◆ (fixed during the
2026-10-08 pre-release review) — add them there too. Version number and date are placeholders.*

---

## v2.6.0 (2026-10-__)

**Highlights:** a much smoother and more capable player (pause, resizable picture-in-picture, scrub back
through another Mac's recording, Chromecast), a significantly faster FEED, Time Machine exclusion for your
recordings, and a round of recording-reliability and security fixes — including one that made every
series recording start a few seconds late.

### New features

**Player & picture-in-picture**
- **Space bar pauses and resumes** a recording or a FEED (live TV can't be paused — there's no buffer).
- **Open a picture-in-picture exactly where you want it** — right-click the video and choose
  "Add Picture-in-Picture…"; it opens in the quadrant you clicked.
- **Resize the picture-in-picture by dragging its corner**, always at the stream's own proportions. Your
  size is remembered (and travels with Export/Import Config).
- **Streams start by themselves** — no Start button. Picture and sound arrive together as soon as the first
  frame is decoded.
- **An info banner for what you're watching** — press `i` for the show, episode and source
  ("Live OTA · Ch 5.1 KMSP", "Recording", or "FEED").
- **The player window settles to the video's native shape** after you resize it — no black bars.
- **Cast to Chromecast (Beta)** — the player's "…" menu finds Chromecasts on your LAN and sends Watch Now /
  FEED playback to them. *Built and unit-tested, but not yet verified against real Chromecast hardware.*

**FEED (watching another Mac's in-progress recording)**
- **Scrub back and forward while watching a FEED**, the same way you can scrub a recording — bounded by how
  much you've watched so far.
- **A FEED survives a network blip** — the background download reconnects on its own instead of ending.
- **Only one Mac's FEED can be live per shared tuner** at a time; whichever started recording first keeps it.

**Recording**
- **Exclude recordings from Time Machine** — Settings → Recording (and the first-run wizard): Off, Each
  Recording, or Show's Folder. Keeps multi-terabyte recordings out of your backup.
- **A heads-up ~3 minutes before a scheduled recording needs the tuner you're watching.** Nothing stops until
  the recording actually starts; if you're on the same channel, playback simply switches to the recording.

**Guide & integrations**
- **Adjustable guide auto-refresh** — Settings → Guide: 1/2, 1/4 or 1/8 of the guide window (default 1/8).
- **`/api/tuner-status.json`** for Home Assistant and other pollers — per-tuner occupancy plus Recording /
  Up Next / Scheduled / Paused shows with poster art. Off by default (Settings → Sharing → Home Assistant).
- **A station with no logo shows the app icon** instead of a blank, everywhere logos appear.
- **Terminal Guide: `HDHR_GUIDE_PORT`** lets `hdhr_guide` talk to a web server on a non-default port.

### Important fixes

**Recording reliability**
- ◆ **Series recordings no longer start late or get a false "Recording Skipped."** Every series show with
  guide matching used to be skipped once at its start, losing the first 5–10 seconds of the broadcast.
- ◆ **A recording that ended naturally is no longer logged as a failure.** It used to show "curl exited
  unexpectedly," skip the completion card and post-recording script, and — repeated — could auto-pause a
  healthy show.
- ◆ **Bonus Time padding is no longer applied twice after a restart** mid-airing.
- ◆ **A partial recording from a failed attempt no longer counts as "already recorded,"** which could skip
  the retry and leave the airing truncated.
- **No more refused recordings on a "93% full" big drive** — only your "Minimum free disk" setting decides.
- Scheduling fixes: a recurring show no longer drifts a minute early; editing a weekly show no longer skips
  tonight's airing; a late show ending after midnight no longer skips the next night; a recording picked up
  after an app restart can no longer be confused with a finished one (recycled process ID).
- **Deleting a recording no longer leaves its FEED running** — which had also blocked another Mac's FEED.

**Security & privacy**
- ◆ **Your Discord webhook URL is no longer written to the logs** when a send fails (the webhook token is a
  secret). Old log lines can be scrubbed; consider rotating the webhook if you've shared logs.
- **The web guide refuses requests made by other websites** (cross-site requests and DNS-rebinding tricks).
  ◆ Malformed request headers are now rejected too — they could previously slip past that check.
- ◆ **Show titles sent to the web guide are cleaned up** (length, control characters, leading dots) so a
  title can't break a show's recordings or point outside its folder.

**Everyday reliability**
- ◆ **Your shows survive a hostname change.** The config is named after your Mac's hostname; if that changed
  (new network, rename), the app used to start empty with the setup wizard. It now finds and adopts your
  existing config.
- ◆ **"Move to Applications" can no longer leave you without the app** — a failed copy now leaves any
  existing install untouched, and it never offers to move a developer build.
- ◆ **A bad guide response can't wipe your guide** — an empty reply (e.g. an expired token) keeps the
  previous guide instead of replacing it with nothing; a settings change mid-refresh no longer triggers a
  false "Guide Load Failed."
- ◆ **Edit Show no longer saves a recording Length of 0 or less.** ◆ **Importing a config now tells you to
  restart** (saves are paused until you do). ◆ **Launch-at-login** no longer leaves Settings stuck on
  "unsaved changes" while macOS waits for you to approve it. ◆ **Add Show** uses your current default folder.
- ◆ **A misleading "Primary folder unavailable" warning** is gone for shows migrated from the original
  AppleScript app (recordings were always going to the right place).
- Settings and Edit Show no longer overwrite changes made elsewhere (donation unlock, a recording that began
  while you were editing, an imported config at quit).

**Player**
- **Switching channels while a tuner is busy no longer ends playback** — it waits for the tuner to free up.
- **Switching from a FEED to a real channel keeps the FEED playing** until the new stream is ready.
- **Fewer false "playback stalled" reconnects**, and audio no longer stays silent after a PiP swap and
  channel switch; your chosen audio output is kept across swaps.

### Other improvements

- **FEED playback is much smoother.** The built-in web server was delivering to other Macs at ~1.6 Mbps
  (a macOS dual-stack networking issue), starving every FEED viewer and slowing the web guide from other
  devices. It now listens on IPv4 and delivers at full network speed. FEED streaming also no longer slowly
  leaks memory, and works with Sharing turned off.
- **Faster and lighter:** quicker startup, guides decoded off the main thread, cached web-guide icon, batched
  signal-history saves, and failed logos retried on a sensible schedule.
- **Fewer calls to the public guide service:** a guide downloaded within the last hour is reused on relaunch.
- **Discovery is more resilient:** one malformed guide entry or tuner reply no longer discards a whole fetch,
  a single lost reply no longer makes a tuner flicker away, and discovery gives up after a fixed deadline.
- **The web guide's tuner count updates within a couple of seconds** (it trailed by up to ~12), and a change
  inside the refresh throttle is no longer dropped.
- **Menu bar polish:** the "FEED available" light now means someone is actually watching; shows on a
  never-detected tuner are listed under "Unavailable Tuner"; "Watching" stays visible when only the PiP is
  playing; Up Next shows times inline; the menu no longer flickers during a recording.
- **Clearer details:** AirPlay speakers are labeled; the Display menu explains Screen Mirroring; FEED viewers
  see the right episode title/description even after the source app restarts.
- **Diagnostics:** `[TunerAudit]` now counts PiP streams.
- **Testing:** over 840 automated tests now, including real-binary smoke tests of the terminal
  guide and new opt-in live window/PiP/FEED soak tests.

### Removed
- **Intel Mac support.** Release builds are Apple Silicon (arm64) only. macOS 15.0 or later is required.

### Known limitations
- Chromecast casting is Beta and hasn't been tested against real hardware.
- Recording FEED remains Beta (carried over from v2.5.0).
- Shows with no airing in the guide (e.g. a seasonal sports package) are skipped at record time with a
  "guide no longer confirms" log line and retried every 12 hours — expected, not a fault.
