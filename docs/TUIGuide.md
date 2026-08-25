# hdhr_guide — bundled terminal guide client

Binary: `hdhrVCRplus.app/Contents/Helpers/hdhr_guide`. Source: `Sources/hdhr_guide/`
(`main.swift`, `Terminal.swift`, `API.swift`) — a separate SPM executable target, not part of the
`hdhr_VCR` module. Run it directly from a terminal; there is no menu bar entry point that launches
it (it's a standalone CLI, not a window).

## What it is

A full-screen terminal view of the guide for one tuner at a time — browse channels/times and
schedule a recording without opening the app UI or a browser. It talks only to hdhrVCRplus's own
LAN web server over plain HTTP (`127.0.0.1:1980`, hardcoded — a custom `Web_server_port` isn't
supported yet), the same way `AppState.watchRecordingInApp`'s relay URL does. It never spawns a
subprocess and never dlopens anything, so — unlike the curl-subprocess/VLC-dlopen cases in
`docs/MAS_COMPLIANCE.md` — bundling it adds no App Sandbox blocker; see that doc's "Already Fine"
table.

**Prerequisite:** `Web_server_enabled` defaults to `false` (`Models.swift`). hdhrVCRplus must be
running with **Settings → Web Server** enabled, or `hdhr_guide` prints an actionable message and
exits immediately (no retry loop, no attempt to launch the app or flip the setting itself — it is
a pure HTTP client with no control-plane surface into the running app).

## Data source

`GET /api/guide.json` (optionally `/api/guide.json/{deviceId}`) — see `docs/WebServer.md`'s schema
section. Fetched once at launch (device omitted → server picks the first usable device, mirroring
the web guide's own `defaultDev`), then re-polled every 20s, plus once immediately after a
successful record/delete/favorite action. `GET /api/signal` (the bulk `{guideName: bucket}` map,
not the per-channel `/api/signal-stats/{guideName}`) is fetched on the same schedule for the
gutter's signal dot. Scheduling/deleting/favoriting all go straight to the existing
`POST /api/record`/`/api/delete`/`/api/toggle-favorite` — `hdhr_guide` has added no new mutating
endpoint of its own, only the read-side `/api/guide.json`.

**Per-tuner, like the web guide** (see `CLAUDE.md`'s "Web guide is per-tuner" invariant) — no
combined multi-device view. `Tab` re-fetches the next device in the roster returned alongside the
current one.

## Layout

- **Header row 1:** `HDHR-{deviceId}` + `active/total` tuner count + the Tab hint (dimmed) + the
  current wall-clock time (`clockFormatter`, `"EEE h:mm a"`, re-read every redraw)
- **Header row 2 — selected program:** the selected channel + program spelled out in full (title,
  episode, start–end time), not truncated — the grid cell for it below often is (`"Sesame S…"`),
  so this line is always the unambiguous answer to "what's selected right now." Reads `visibleEntries(ch)`
  the same as navigation, so it never shows a program that's actually outside the 8-hour cap.
- **Header row 3:** hour labels above their column (only at `:00`, half-hour columns blank)
- **Body:** one row per channel, sorted by `channelSortKey` (same numeric-aware channel order the
  web guide uses). The gutter is 5 fixed-width columns, each reserving its slot whether active or
  not so the channel number always starts at the same character position on every row: selection
  marker (`▶`), favorite star (`★`, `favoriteColor` — the same amber `--fav`/`favAmber` value the
  web guide and native app use, not an independent pick), the channel number+name, then a signal
  dot (`●`, colored by `/api/signal`'s bucket — green/yellow/red matching the web guide's own
  channel-column bars, blank when there's no sample yet). A single `│` divider closes the gutter
  (the only grid line kept for non-selected rows — program cells are separated by color and a
  blank space, not more box-drawing, see "Coloring" below), then that channel's guide entries as
  fixed-width (`slotWidth` = 14 chars/half-hour) cells, title truncated with `…` to fit.
- **Selection box:** the selected tile gets a full heavy-line box — top, bottom, and both sides
  (`┏━┓`/`┃`/`┗━┛`), pure 24-bit white (`38;2;255;255;255`, not the 16-color "bright white" code
  some terminal themes remap to off-white/gray). The verticals are drawn *inside* the tile's own
  content span (2 of its character budget, same way the status badge already claims some) rather
  than on the separator character shared with the next tile — that left a full character of plain
  background between the colored tile and the white line on each side, so the box looked like it
  was floating off the tile instead of hugging it. `frameEdge(_:_:_:_:_:_:)`'s top/bottom rows are
  filled with that same tile's genre background before drawing the white line, so the border reads
  as traced onto the tile's own color rather than sitting on the plain terminal background. The
  top/bottom edges cost 2 extra terminal lines, permanently reserved in `visibleRows`' budget
  (`render()` in `main.swift`) rather than only when a box is actually drawn, so the layout never
  jumps by two lines depending on where the selection happens to sit. Both the border rows and the
  content row's verticals derive their exact character-column span arithmetically from the
  slot-unit block widths already computed for that row, rather than scanning the rendered
  (ANSI-laden) line string for it — verified to land on the identical column in both by a real pty
  capture, not just visually.
- **Footer:** keybinding hint + a status/error line, colored green/red/yellow by outcome
  (✓/✗/⚠ prefix)

**Time window is capped at `maxVisibleHours` (8, `main.swift`)** — `visibleEntries(_:)` filters
every channel's entries to `startTime < winStart + 8h` before selection, paging (`[`/`]`), or
rendering ever sees them, and `visibleCols()` additionally caps the column count itself so a wide
terminal can't stretch past the cap on its own. The server still returns the full ~28h guide
window (`/api/guide.json` is unchanged) — this is a client-side navigation limit only, not a
smaller fetch, so raising it later is a one-constant change.

## Coloring

Program cells are tinted by genre (`Genre.swift`), reusing the exact same palette as the web
guide's `gc()` (`Resources/guide.js`'s `_gcDk`, dark-mode HSL values converted to 24-bit ANSI) —
a show's color here matches its color there.

Recording/scheduled status is shown two ways at once, so it's obvious rather than something you
have to spot: a `●` badge in front of the title, *and* the whole title recolored to match, instead
of the default white — on top of the genre tint, mirroring the web guide's own "ring + badge over
genre tint" model (`CLAUDE.md`'s "Status ring + badge"), just carried further than a single small
icon since a 1-glyph badge alone wasn't reliably noticeable against a busy grid. Colors are the
web guide's own status-ring colors (`Resources/guide.css`'s `--vc-rec`/`--vc-sched`), not
independent ANSI picks — `recordingColor`/`scheduledColor` in `main.swift` — bold bright red
(close enough to `--vc-rec`'s `#ff5a5a` to skip truecolor) for recording, and 24-bit
`#3b93ff` for scheduled (matching `--vc-sched` exactly — an earlier cyan here was a mismatch,
not a deliberate choice). Both use the same `●` badge glyph, not the web guide's own `⏺`/`⏱`
pair — the color carries the meaning here, and a uniform dot reads better than a stopwatch at this
width. The same badge/color pairing is applied to the title in the "selected program" header line
and the summary screen's title banner, so it's consistent everywhere the title appears.

## Redraw model

Every redraw (a keypress, a poll tick) goes through `Terminal.writeFrame(_:)`, not a full-screen
clear — it homes the cursor (`\u{1B}[H`), overwrites each line in place with a trailing
`\u{1B}[K` (erase-to-end-of-line, so a shorter new line doesn't leave a stale tail from a longer
previous one), then a final `\u{1B}[J` (erase-to-end-of-screen, covering a frame that got shorter,
e.g. after a terminal resize). A leading full clear (`\u{1B}[2J`) blanks every cell immediately, so
redrawing on every arrow-key press produced a visible flash between the blank frame and the
repaint; overwriting in place removes that step entirely.

The whole body is further wrapped in `\u{1B}[?2026h`…`\u{1B}[?2026l` — the "synchronized output"
DEC private mode most modern terminal emulators (iTerm2, Kitty, WezTerm, Windows Terminal,
ghostty) honor by buffering everything between the two and painting it as one atomic update. A
colored frame runs to several KB, past what a single `write()` is guaranteed to deliver to the far
end in one piece, so a terminal that repaints incrementally as bytes arrive could flash a partial
frame (e.g. just the header line, landing first) before the rest caught up. A terminal that
doesn't recognize the mode just ignores the escape sequence — safe to send unconditionally.

Overwrite-in-place only holds if the frame's line count never exceeds the terminal's row count —
one line too many forces the terminal itself to scroll, and since every redraw starts by homing
the cursor to what is *currently* row 1 (not row 1 of the original, unscrolled buffer), a
scrolling viewport makes the top of the screen appear to jump on every keypress even with no
`\u{1B}[2J` in sight. `render()`'s `topFixedLines`/`bottomFixedLines`/`boxLines` constants are an
exact count of every fixed (non-body) line the function emits — they previously undercounted by
3 (the "┬" gutter rule up top, and the "┴" rule + blank line at the bottom weren't included in the
old `headerRows`/`footerRows` estimate), so every frame rendered 3 lines taller than the terminal
and scrolled on every single redraw. Verified via a real pty at a fixed size: frame line count must
equal the terminal's row count exactly, not merely fit within it with room to spare — a smaller
frame would just leave stale content below it (which `writeFrame`'s trailing `\u{1B}[J` already
handles), but a larger one scrolls, which is the actual bug class here.

## Recording summary screen

`Enter` on a selected program replaces the grid entirely (`Mode.recordSummary`,
`renderSummaryScreen()` in `main.swift`) with a dedicated screen, rather than squeezing the
recording options into the footer:

- The title on its genre-tinted background, then labeled fields: **Channel**, **Time** (with
  duration in minutes), **Episode** (`episodeNumber · episodeTitle`, e.g. `S01E29 · Sticker
  Monster Storytime; Count to 10!`, omitted if neither is present), **Genre** (the single color-
  driving value), **Tags** (the raw `Filter` list, e.g. `Kids, Series` — can differ from Genre,
  which is just the first non-generic tag), **Bonus Time** (unmanaged sports entries only — see
  below), and **Status** (recording now / already scheduled / not scheduled)
- **Synopsis**, word-wrapped (`wordWrap(_:width:)`, `Terminal.swift`) to the terminal width (capped
  at 76 columns) — omitted when the guide entry has none
- Either the four recording-scope options (a fresh, unmanaged entry), or a single **[d]**
  Remove/Stop & Delete option (an entry that's already managed — see below), then `[Esc]` to cancel

`selRow`/`selEntry` don't change while this screen is up — only the option keys and `Esc` are
handled — so it's safe for `renderSummaryScreen()`/`handle(_:)` to re-resolve the same entry each
redraw via `currentEntry()` rather than snapshotting it.

**Already-managed entries offer delete, not another schedule.** `isScheduled` covers both a
future scheduled airing *and* one currently recording — both are owned by the same managed show
(`ManagedGuideMatcher.owner(for:)`), so `/api/guide.json` now also carries `scheduledShowId` (that
owner's `Show.show_id`) for exactly this case. When `isScheduled` is true, the screen title
becomes "Manage Recording" and the options collapse to one: **[d]** labeled `Stop & Delete` when
`isRecording`, `Remove` otherwise (mirroring the web guide's own delete-confirmation wording,
`docs/WebServer.md`'s "POST /api/delete" section) — scheduling an already-managed entry again
would just be confusing. `confirmDelete()` POSTs `/api/delete` with that `showId`, same endpoint
the web guide's Delete/Stop & Delete buttons use; `hdhr_guide` added no new mutating endpoint for
this, only the `scheduledShowId` field needed to address the existing one.

**Bonus Time is auto-detected for sports, same as the native wizard.** `addShowFromGuide` (what
both the web Record modal and `POST /api/record` ultimately call) defaults `bonusTime` to `false`
and does not look at genre itself — that auto-default (`CLAUDE.md`'s "Bonus Time" invariant) lives
only in `applyGuideEntry()`, the *native* Add Show wizard's own path; the web modal covers the gap
with its own checkbox. `confirmRecord` mirrors this via `genreImpliesBonusTime(_:)` (matching
`Show.genreImpliesBonusTime`'s `"sport"`-not-`"sports"` substring check, duplicated rather than
imported since `hdhr_VCR` is an executable, not a library) and always passes the result — a sports
entry gets Bonus Time with no extra keypress, shown as a **Bonus Time** field on the summary
screen. `POST /api/record`'s own `tunerFull` response field is also surfaced now: the status line
appends `" — tuner full, queued"` when `true`, instead of showing the identical `✓ Scheduled`
message a queued show and a confirmed one previously got.

## Keybindings

| Key | Action |
|---|---|
| `↑` / `↓` | Move the selected channel row |
| `←` / `→` | Move the selected program within that channel |
| `[` / `]` | Page the visible time window by one screen-width |
| `f` | Toggle favorite for the selected channel (`POST /api/toggle-favorite`, same endpoint the web guide's star buttons use) |
| `Tab` | Switch to the next tuner |
| `Enter` | Open the recording summary screen for the selected program |
| `1`–`4` (unmanaged entry) | Once / Weekly / Series (this channel) / Series (any channel on this tuner) — POSTs immediately with server-side defaults (e.g. weekly's day-of-week defaults to the entry's own weekday, same as the web Record modal). No transcode/title override in this client — use the web guide or native UI afterward for anything non-default |
| `d` (already-managed entry) | Remove the scheduled recording, or Stop & Delete if it's currently recording |
| `Esc` (on the summary screen) | Cancel without changes, back to the grid |
| `q` / `Ctrl-C` | Quit — restores the terminal (leaves raw mode + the alternate screen buffer) before exiting either way |

## Known limitations

- Fixed `127.0.0.1:1980` — doesn't read `Web_server_port` from config
- Polling only, no `/api/events` SSE subscription — up to ~20s of staleness between actions
- No offline/undetected-device listing (the web guide's "never silently omit them" invariant for
  a device referenced by a show but not currently discovered isn't mirrored here yet — `Tab` only
  cycles devices the server currently reports as online)
