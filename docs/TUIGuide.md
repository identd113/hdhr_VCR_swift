# hdhr_guide — bundled terminal guide client

Binary: `hdhrVCRplus.app/Contents/Helpers/hdhr_guide`. Source: `Sources/hdhr_guide/`
(`main.swift`, `Terminal.swift`, `API.swift`, `DebugLog.swift`) — a separate SPM executable
target, not part of the `hdhr_VCR` module. Run it directly from a terminal; there is no menu bar
entry point that launches it (it's a standalone CLI, not a window).

**Pure logic lives in a separate library target, `Sources/hdhr_guide_core/`, specifically so it's
unit-testable** — a `main.swift`-based executable target can't be `@testable import`ed, so before
this split nothing in `hdhr_guide` had any automated test coverage at all; every fix described
below was verified by hand against a real pty, not by `swift test`. `hdhr_guide` (terminal I/O,
global mutable UI state, network calls) depends on `hdhr_guide_core`; `hdhr_guide_core` has no
dependency back the other way. Tested by `Tests/hdhr_guide_coreTests/` (50 tests as of this
writing — `StringLayoutTests`, `GenreTests`, `GuideDTOsTests`, `GuideLogicTests`), which `swift
test` runs alongside the rest of the project's suite.

| File | Contents |
|---|---|
| `StringLayout.swift` | `pad`/`truncate`/`wordWrap` — fixed-width text layout, no terminal I/O |
| `Genre.swift` | `genreBackground(_:)` — the genre-tint palette, mirrors `guide.js`'s `_gcDk` |
| `GuideDTOs.swift` | `GuidePayload`/`GuideChannelDTO`/`GuideEntryDTO`/etc. — the `/api/guide.json` response shape, each with an explicit `public init(from decoder:)` (Decodable's synthesized initializer stays `internal` even on a `public` type, so relying on synthesis here would make these types undecodable from the executable target) |
| `GuideLogic.swift` | `genreImpliesBonusTime`, `computeVisibleCols`, `entryIndex(nearestTo:in:)`, `layoutRowBlocks` — the pure math behind Bonus Time auto-detection, the horizontal column budget, anchor-time channel switching, and the row block layout (including the overlap clamp) |

## What it is

A full-screen terminal view of the guide for one tuner at a time — browse channels/times and
schedule a recording without opening the app UI or a browser. It talks only to hdhrVCRplus's own
LAN web server over plain HTTP (`127.0.0.1:1980`, hardcoded — a custom `Web_server_port` isn't
supported yet), the same way `AppState.watchRecordingInApp`'s relay URL does. See "MAS Compliance"
below for why bundling a second executable here doesn't add a sandbox blocker.

**Prerequisite:** `Web_server_enabled` defaults to `false` (`Models.swift`). hdhrVCRplus must be
running with **Settings → Sharing** enabled (the Settings section's own label — the underlying
`Web_server_enabled` config key is unchanged), or `hdhr_guide` prints an actionable message and
exits immediately (no retry loop, no attempt to launch the app or flip the setting itself — it is
a pure HTTP client with no control-plane surface into the running app).

**Sub-switch:** `Terminal_guide_enabled` (`Models.swift`, defaults `true`) — Settings → Sharing →
**Terminal Guide**'s own toggle, nested under (only shown/relevant when) `Web_server_enabled`.
`hdhr_guide` reads it back from `/api/guide.json`'s `terminalGuideEnabled` field right after its
first successful fetch and exits immediately if false ("disabled — Settings → Sharing → Terminal
Guide is off."). This is a courtesy/discoverability gate only, **not a security boundary**:
`/api/guide.json` (and `/api/record`, `/api/delete`, `/api/toggle-favorite`) are the same endpoints
the browser guide already uses, already reachable to any device on the LAN once `Web_server_enabled`
is on regardless of this flag (`CLAUDE.md`'s "No auth beyond LAN-subnet matching" invariant) —
turning this off doesn't restrict what the *server* returns to a caller that ignores it (e.g. via
`curl`), only whether the bundled `hdhr_guide` binary itself chooses to proceed. It exists for
someone who wants the web guide shared with the household without also advertising/allowing the
terminal client specifically.

## MAS Compliance

A second executable inside the bundle, but unlike the curl/VLC cases in `docs/MAS_COMPLIANCE.md`,
it never spawns a subprocess and never dlopens anything — it's a plain `URLSession` HTTP client
talking only to the app's own local web server (`network.client`, already granted). Sandboxed apps
may execute binaries within their own bundle, so this pattern is fine as-is for a future MAS build
too.

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

**Every glyph is plain ASCII, deliberately** — `>`/`*`/`o` for the selection marker/favorite
star/status dot, `+`/`=`/`|` for the selection box and gutter rules, `-` for every dash/separator,
`.` for the truncation ellipsis. This app used to use the obvious Unicode choices (▶/★/●, ┏━┓/┃/
┗━┛, –/—/·, …) until a real report through a multi-hop chain (browser → Raspberry Pi → SSH → this
Mac) kept showing lines still wrapping even after the underlying character-count math was verified
correct with a real pty. The cause: essentially every one of those glyphs — including the entire
box-drawing block and even the plain arrows (↑↓←→) — is Unicode "Ambiguous width," meaning whether
a given terminal/font renders it in 1 column or 2 is unspecified and terminal-dependent. Native
macOS terminals (Terminal.app/iTerm2) almost always render them narrow, which is why testing there
never caught it, but a web-based terminal emulator partway down a chain like this is a common place
for that assumption to not hold — every such glyph then silently costs 1 extra column, and a row
with a dozen box-drawing characters in it overflows the terminal width by a dozen columns. ASCII
has no ambiguous-width case on any terminal, so it's the only choice that's correct everywhere
rather than "correct on the terminals tested so far." Only `✓`/`✗`/`⚠` (the status-line prefixes)
stayed Unicode — confirmed Narrow width, unlike the rest.

- **Header row 1:** `HDHR-{deviceId}` + `active/total` tuner count + the current terminal size
  (`{cols}x{rows}`, straight from `Terminal.size()` — a quick way to see what `render()` thinks it
  has to work with when a short terminal is dropping panel content) + the current wall-clock time
  (`clockFormatter`, `"EEE h:mm a"`, re-read every redraw) + the Tab hint (dimmed, dropped first on
  a narrow terminal). Built from whole colored segments joined and dropped from the end (least
  essential — the Tab hint, then clock, then size, then tuner count — first) once they stop
  fitting `cols`, rather than `truncate()`-ing one long pre-colored string: `truncate()` measures
  raw characters, so running it over a string that already has ANSI escape codes woven through it
  risks cutting mid-code, unlike the plain-text substrings `truncate()` is normally applied to
  before they get wrapped in color.
- **Summary panel (`buildSummaryLines(maxLines:cols:)`):** the selected channel + program, spelled
  out in full — the grid cell for it below is often truncated (`"Sesame S."`), so this panel is
  always the unambiguous answer to "what's selected right now." Fixed at `summaryLines = 8` lines
  rather than scaling with terminal height — an earlier `(rows - 16) / 3` formula (capped 2...8)
  hit its own cap on any terminal taller than ~40 rows, which in practice meant most real terminals
  always rendered the same max-size panel anyway, just via a formula instead of a plain constant;
  a fixed-10 revision after that still looked too tall in practice. Still protected by the same
  shrink-loop described under "Redraw model" below: a terminal too short to fit 8 lines shrinks
  this down (as low as 0, hiding the panel) before conceding any overflow. On a terminal tall
  enough to fit it, this gives real detail (like the web guide's
  `#sum` panel: episode, genre, tags, status, synopsis); on a short one it still shows just
  title + channel/time before shrinking further. Content is added in fixed priority order — title
  (badge + status-colored,
  listed *first* so it's the one line guaranteed to survive when the panel is squeezed to its
  floor: on a 1-line panel, showing which show is selected matters more than the channel/time line
  after it), channel+time+duration, episode (`episodeNumber - episodeTitle`), genre+tags+status —
  and any leftover lines are filled with word-wrapped synopsis; unused room becomes blank padding
  lines rather than stretching earlier content, since `buildSummaryLines` always returns *exactly*
  `maxLines` lines (never fewer) to keep the layout's line-count budget below exact, and every
  line is `truncate()`-clamped to `cols` for the same reason the footer hint is (a wrapped line
  here would silently add an extra screen line, the same bug class as the footer overflow fixed
  earlier). `render()`'s floor of 2 can still shrink further — down to 0, hiding the panel
  entirely — on a terminal too short to fit the rest of the fixed layout budget around it; see
  "Redraw model" below for why that shrink exists instead of a hard floor of 1. Reads
  `currentEntry()` the same as navigation, so it's always in sync with whatever's actually
  selected. Genre and tags render as small color chips (`genreBackground`),
  not plain text — the same tile-background color the grid uses for that genre, so "Kids" reads in
  the same color here as a Kids tile does below, not an independent text-color pick. Genre comes
  first, then any tags not already equal to it (case-insensitive — they commonly overlap, since
  genre is just tags' own first non-generic entry); a chip that would overflow `cols` is dropped
  entirely rather than cut in half mid-color-code.
- **Hour ruler:** hour labels above their column (only at `:00`, half-hour columns blank)
- **Body:** one row per channel, ordered Recording → Favorite → `channelSortKey` (same three-tier
  precedence as the web guide's own Recording/Favorites/rest sections, `buildGuideJSON` in
  `WebServer.swift`) — a single sort over the whole lineup, so a channel that's both recording and
  favorited sorts under Recording only, never appearing in more than one place. The gutter is 5
  fixed-width columns, each reserving its slot whether active or
  not so the channel number always starts at the same character position on every row: selection
  marker (`>`), favorite star (`*`, `favoriteColor` — the same amber `--fav`/`favAmber` value the
  web guide and native app use, not an independent pick), the channel number+name, then a signal
  dot (`o`, colored by `/api/signal`'s bucket — green/yellow/red matching the web guide's own
  channel-column bars, blank when there's no sample yet). A single `|` divider closes the gutter
  (the only grid line kept for non-selected rows — program cells are separated by color and a
  blank space, not more box-drawing, see "Coloring" below), then that channel's guide entries as
  fixed-width (`slotWidth` = 14 chars/half-hour) cells, title truncated with `.` to fit. Each
  row's block layout clamps a program's start to wherever the previous block's own end already
  put the cursor (`colStart + cursorCol`, not just the visible window's left edge, in the block-
  layout loop) — real-world guide data occasionally carries overlapping/duplicate entries for one
  channel (confirmed live: a channel with two back-to-back identically-titled listings whose slot
  ranges actually overlapped by one slot), and without the clamp an overlapping entry rendered
  starting before the prior block had finished, pushing the row's total content past `vc` slots
  and wrapping the line past the terminal's width.
- **Selection box:** the selected tile gets a full box — top, bottom, and both sides
  (`+=+`/`|`/`+=+`, plain ASCII — see the note at the top of this section), pure 24-bit white
  (`38;2;255;255;255`, not the 16-color "bright white" code
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
  (✓/✗/⚠ prefix). Both lines are `truncate()`-clamped to `cols` — the status line embeds the
  show's own title (e.g. `✓ Scheduled: <title>`), which is unbounded unlike the fixed hint text,
  so without the clamp a long title could wrap it past the terminal width.

**No client-side time cap** — selection and paging range over the server's own full guide window
(`payload.winSec`, `maxSlot()` in `main.swift`), same as the web guide. An earlier 8-hour cap here
(`visibleEntries(_:)` filtering to `startTime < winStart + 8h`, `visibleCols()` additionally
clamped to it) caused a real, confirmed bug on a terminal wide enough to fit all 8 hours in one
screen: `visibleCols()`'s own cap meant `vc` could never exceed the 8h ceiling, so
`pageTime`'s `cap = maxSlot() - vc` bottomed out at exactly 0 — paging could never advance a
single column past the cap, regardless of how much later guide data the server actually had.
Confirmed via `DebugLog.swift`'s output on the reporter's own terminal (`vc=16 cap=0` — 16
half-hour slots is exactly 8 hours) before being removed. See "Debug log" below.

## Coloring

Program cells are tinted by genre (`Genre.swift`), reusing the exact same palette as the web
guide's `gc()` (`Resources/guide.js`'s `_gcDk`, dark-mode HSL values converted to 24-bit ANSI) —
a show's color here matches its color there.

Recording/scheduled status is shown two ways at once, so it's obvious rather than something you
have to spot: an `o` badge in front of the title, *and* the whole title recolored to match, instead
of the default white — on top of the genre tint, mirroring the web guide's own "ring + badge over
genre tint" model (`CLAUDE.md`'s "Status ring + badge"), just carried further than a single small
icon since a 1-glyph badge alone wasn't reliably noticeable against a busy grid. Colors are the
web guide's own status-ring colors (`Resources/guide.css`'s `--vc-rec`/`--vc-sched`), not
independent ANSI picks — `recordingColor`/`scheduledColor` in `main.swift` — bold bright red
(close enough to `--vc-rec`'s `#ff5a5a` to skip truecolor) for recording, and 24-bit
`#3b93ff` for scheduled (matching `--vc-sched` exactly — an earlier cyan here was a mismatch,
not a deliberate choice). Both use the same `o` badge glyph, not the web guide's own `⏺`/`⏱`
pair (nor this app's own earlier `●` — see the note at the top of "Layout") — the color carries
the meaning here, and a uniform dot reads better than a stopwatch at this width. The same
badge/color pairing is applied to the title in the "selected program" header line and the summary
screen's title banner, so it's consistent everywhere the title appears.

## Redraw model

**Resizing the terminal redraws immediately** — a `SIGWINCH` handler (`main.swift`, installed
next to the existing `SIGINT`/`SIGTERM` ones) sets a `resized` flag, checked at the top of the
main loop before the next `pollStdin` wait; the loop calls `render()` right away when it's set,
rather than waiting for the next keypress or the 20s poll tick to happen to re-read the new size.
Like the `SIGINT`/`SIGTERM` handlers, it only sets a flag — a signal handler can't safely call
arbitrary Swift code (`render()` included) directly. Verified via a real pty: resizing mid-session
and sending `SIGWINCH` updates the header's own `{cols}x{rows}` readout with no keypress needed.

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
`\u{1B}[2J` in sight — visibly, the top of the frame (the summary panel included) looks like it
climbs off-screen a little further on every subsequent redraw, since each one's cursor-home lands
one row later than the last. `render()`'s `topFixedLines` (`3 + summaryLines` — the summary
panel's height is the one variable piece, everything else is fixed) / `bottomFixedLines` /
`boxLines` are an exact count of every non-body line the function emits — they previously
undercounted by 3 (the "+" gutter rule up top, and the "+" rule + blank line at the bottom weren't
included in the old `headerRows`/`footerRows` estimate), so every frame rendered 3 lines taller
than the terminal and scrolled on every single redraw. Verified via a real pty at a fixed size:
frame line count must equal the terminal's row count exactly, not merely fit within it with room
to spare — a smaller frame would just leave stale content below it (which `writeFrame`'s trailing
`\u{1B}[J` already handles), but a larger one scrolls, which is the actual bug class here.

A second, narrower version of the same bug lived in `visibleRows`' own floor: `max(1, rows -
topFixedLines - bottomFixedLines - boxLines)` guarantees at least one data row, but on a terminal
short enough that the fixed overhead alone (summary panel + header/ruler/gutter/box lines) already
meets or exceeds `rows`, that floor silently let the total emitted line count exceed `rows` anyway
— the same overflow-and-drift failure described above, just triggered by terminal *height* rather
than a stale line-count estimate. `render()` now shrinks `summaryLines` first (down to 0, hiding
the panel entirely) before falling back to the `visibleRows` floor of 1, so the fixed layout always
fits exactly, or the summary panel — not the channel grid — is what gives up room on a terminal too
short for both.

## Recording summary screen

`Enter` on a selected program replaces the grid entirely (`Mode.recordSummary`,
`renderSummaryScreen()` in `main.swift`) with a dedicated screen, rather than squeezing the
recording options into the footer:

- The title on its genre-tinted background, then labeled fields: **Channel**, **Time** (with
  duration in minutes), **Episode** (`episodeNumber - episodeTitle`, e.g. `S01E29 - Sticker
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

**Bonus Time is auto-detected for sports, same as the native wizard — and gated on the same
setting.** `addShowFromGuide` (what both the web Record modal and `POST /api/record` ultimately
call) defaults `bonusTime` to `false` and does not look at genre itself — that auto-default
(`CLAUDE.md`'s "Bonus Time" invariant) lives only in `applyGuideEntry()`, the *native* Add Show
wizard's own path; the web modal covers the gap with its own checkbox. `confirmRecord` mirrors
this via `genreImpliesBonusTime(_:)` (matching `Show.genreImpliesBonusTime`'s `"sport"`-not-
`"sports"` substring check, duplicated rather than imported since `hdhr_VCR` is an executable,
not a library), but only passes it through when `payload.sportsPaddingEnabled` is also true — the
`/api/guide.json` field mirroring `Sports_padding_enabled` (`docs/WebServer.md`), the same setting
every other client already gates this on (`AddShowView.swift`'s `genreImpliesBonusTime &&
Sports_padding_enabled` pattern). Before this gate, scheduling a sports show from the TUI while
the setting was off still stored `show_bonus_time=true` — unlike an equivalent show scheduled from
the web guide or native wizard at the same moment — and would start actually padding the instant
the user later re-enabled the setting, for a show they never opted in. The summary panel's
**Bonus Time** field (unmanaged sports entries only) is gated the same way, so it never promises
padding that `confirmRecord` won't actually apply. `POST /api/record`'s own `tunerFull` response
field is also surfaced now: the status line appends `" - tuner full, queued"` when `true`, instead
of showing the identical `✓ Scheduled` message a queued show and a confirmed one previously got.

## Keybindings

Mouse/trackpad scroll wheel also moves the selected channel row, same as `↑`/`↓` — `Terminal.enterRawScreen()`
sends `\u{1B}[?1007h` ("alternate scroll mode"), which tells the terminal itself to translate a
scroll gesture into plain arrow-key bytes while the alternate screen buffer is active, rather than
trying to scroll a scrollback buffer that doesn't apply here. No mouse-report protocol parsing on
this end at all — the terminal does the translation, so this only works in terminals that support
the mode (most do: iTerm2, Terminal.app, xterm, VTE-based ones). A fast scroll gesture translates
into a *burst* of these arrow-key bytes arriving nearly all at once, not one at a time — the main
loop (bottom of `main.swift`) drains everything already waiting on stdin and applies all of it
before the next `render()`, capped at 200 keys per redraw, rather than rendering once per byte. A
fast scroll then jumps the selection multiple rows in one redraw, the way a normal scrollable list
does, instead of crawling one row per full-frame rewrite — and collapsing many redraws into one
also means far fewer chances for a slow or multi-hop connection to drop, delay, or interleave one
of those frames mid-write, which is a very plausible way for the terminal's own view to end up
desynced from what this app thinks row 1 currently is (see "Redraw model" above).

`Terminal.readKey()`'s escape-sequence disambiguation was also hardened for the same class of
connection: the byte *after* a recognized `ESC [` was previously read with a plain blocking
`read()` — no poll, no timeout — so if a 3-byte arrow sequence got split across two network
packets (plausible on any laggy or multi-hop link, not just this one), the entire render loop
would hang indefinitely — no redraws at all, however long the last byte took to arrive — until it
showed up. It's now polled with the same 80ms window as the byte before it (bumped from 40ms),
falling back to `.escape` (dropping the partial sequence) rather than blocking forever.

Table entries below name the physical keys; the footer's own on-screen hint spells them as ASCII
(`^`/`v`/`<`/`>`) rather than the Unicode arrow glyphs, for the same reason given at the top of
"Layout".

| Key | Action |
|---|---|
| `↑` / `↓` | Move the selected channel row — re-selects whichever program is airing at the *same time* you were already looking at (`currentAnchorTime()`/`entryIndex(nearestTo:in:)`, `main.swift`), not that channel's own first visible entry, so switching channels while scrolled later in the day keeps the horizontal (time) position instead of resetting it back to the start of the guide window. `ensureEntryVisible()` still nudges `colStart` if the new channel has a schedule gap right at that time, but only by however far the nearest available program actually is — never a full jump back to column 1. |
| `←` / `→` | Move the selected program within that channel — at the first/last entry, pages the shared timeline viewport instead of stopping, so holding the key scrolls continuously across the whole grid to later/earlier times (`moveEntry(_:)`, `main.swift`) |
| `[` / `]` | Page the visible time window by one screen-width directly, without needing to reach a channel's edge first |
| `f` | Toggle favorite for the selected channel (`POST /api/toggle-favorite`, same endpoint the web guide's star buttons use) |
| `Tab` | Switch to the next tuner |
| `Enter` | Open the recording summary screen for the selected program |
| `1`–`4` (unmanaged entry) | Once / Weekly / Series (this channel) / Series (any channel on this tuner) — POSTs immediately with server-side defaults (e.g. weekly's day-of-week defaults to the entry's own weekday, same as the web Record modal). No transcode/title override in this client — use the web guide or native UI afterward for anything non-default |
| `d` (already-managed entry) | Remove the scheduled recording, or Stop & Delete if it's currently recording |
| `Esc` (on the summary screen) | Cancel without changes, back to the grid |
| `q` / `Ctrl-C` | Quit — restores the terminal (leaves raw mode + the alternate screen buffer) before exiting either way |

## Debug log

`DebugLog.swift` writes to `~/Library/Logs/hdhrVCRplus-guide-debug.log` — separate from
`hdhr_VCR`'s own `glog()`/`RotatingLogFile` (a different module; not worth importing `hdhr_VCR`,
an executable not a library, just for this) and truncated at launch past 2MB rather than using
`RotatingLogFile`'s full generation-rotation scheme, since this is meant for a short debugging
session, not unbounded-runtime logging. Printing to stdout isn't an option — it would corrupt the
alternate-screen display — so this goes to its own file, tailable from a second terminal
(`tail -f ~/Library/Logs/hdhrVCRplus-guide-debug.log`) while the app runs in the first.

Logs every raw byte `Terminal.readKey()` reads (hex), the escape-sequence disambiguation outcome
(which byte failed to match and why, or which arrow it resolved to), every `handle(_:)` call with
the current `mode`, and `moveEntry(_:)`/`pageTime(_:)`'s state transitions (`selEntry`/`colStart`
before → after, or why they no-opped). Added when "the right arrow doesn't scroll to later shows"
couldn't be reproduced through direct pty testing (the mechanism worked reliably — 5/5 in a row —
with the standard `\u{1B}[C` sequence on a narrow terminal). The reporter's own log showed the
real cause on the first read: `pageTime(1): vc=16 cap=0 colStart 0 -> 0`, repeated on every
keypress — the 8-hour cap bug described above. Left in place (not removed once the bug was found)
since it's cheap and generically useful for the next thing that doesn't behave as expected.

## Robustness fixes (code review follow-up)

A full review of this file found several real issues beyond the wrapping/redraw bugs already
covered above. Fixed, low-code (no architecture change):

- **Signal dot silently blank for whitespace-padded channel names** — the gutter's signal lookup
  (`main.swift`, the row-render loop) only lowercased `ch.guideName` before looking it up in
  `signalMap`, but the canonical key (`ChannelSignalStore.key(for:)`, what `/api/signal`'s keys are
  actually built from) also trims whitespace first (`CLAUDE.md`'s "Signal keys" invariant). Now
  matches: `.trimmingCharacters(in: .whitespaces).lowercased()`.
- **Ctrl-C ignored, whole app frozen, for up to ~9s** if the web server was slow or hung —
  `API.syncData()` waited on its semaphore once for the full timeout with nothing checking
  `interrupted` in between. Now waited for in 100ms slices, checking `interrupted` each time, so
  Ctrl-C is responsive within about that long even mid-request.
- **A data race in that same function** — `result` (written from the URLSession completion
  handler's background queue) was read on the caller's thread regardless of whether the semaphore
  wait actually succeeded or merely timed out, with no synchronization between the two in the
  timeout case. Now only read on the `.success` branch, which is the only case `sem.wait`/
  `sem.signal` actually guarantees a happens-before ordering for.
- **The 20s background poll could reassign `payload` while the record/manage confirmation screen
  (`Mode.recordSummary`) was open**, contradicting that screen's own "selRow/selEntry don't change
  while this mode is active" assumption — a user who paused ≥20s on that screen could have it
  silently start showing a different program, or go blank if `currentEntry()` stopped resolving.
  The poll tick (bottom of `main.swift`) now skips itself entirely (fetch and `lastPoll` both) while
  that mode is active, so the next eligible poll just fires as soon as the screen closes instead.
- **`wordWrap()` didn't break a single word longer than the wrap width** (a long URL or
  hyphen-less compound token in a synopsis — real EPG data, not app-controlled) — it emitted such a
  word as one line wider than requested regardless, and neither caller re-truncated the result.
  Now hard-breaks any such word into width-sized chunks before falling back to normal wrapping.
- **A terminal narrower than the fixed 20-column channel gutter plus one 14-column slot** (34 cols)
  still overflowed — `visibleCols()`'s own `max(1, ...)` floor forced at least 1 grid column
  regardless of whether there was actually room. `render()` now refuses to attempt the grid below
  that width and shows a short "Terminal too narrow" message (itself `truncate()`-clamped) instead
  of a guaranteed-to-overflow one.

**Deliberately left as a known tradeoff, not fixed** — would require an actual refactor rather than
a small change: `genreImpliesBonusTime(_:)` (now `Sources/hdhr_guide_core/GuideLogic.swift` — moved
there along with the rest of this file's testable logic, see the top of this doc, but not
consolidated with its counterpart) is a 4th independent copy of `Show.genreImpliesBonusTime`'s
matching logic (see that function's own doc comment in `Models.swift` for the other three, and its
own history of drift). Consolidating it would mean `hdhr_VCR` and `hdhr_guide_core` sharing a
target, which `hdhr_VCR` being an executable rather than a library still rules out — the
`hdhr_guide_core` split fixed hdhr_guide's *own* lack of test coverage, but doesn't reach across
that boundary. Worth doing if this logic needs to change again; not on its own.

## Known limitations

- Fixed `127.0.0.1:1980` — doesn't read `Web_server_port` from config
- Polling only, no `/api/events` SSE subscription — up to ~20s of staleness between actions
- Offline/undetected devices *are* now listed (`/api/guide.json`'s `devices` field unions in any
  device referenced by a show's `hdhr_record` but never discovered — mirrors `buildDevBarHTML`'s
  own union, CLAUDE.md's "Web guide offline devices" invariant) — `Tab` will cycle to one, but
  since it was never discovered there's no lineup/guide data for it, so it just shows an empty
  grid rather than anything useful about what's actually stuck there. Real parity needs the
  "no overview of everything scheduled/recording on this tuner" gap below closed first.
- A terminal narrower than 34 columns shows a "too narrow" message instead of the grid — the fixed
  20-column channel gutter isn't adaptive (see "Robustness fixes" above)

## Deferred ideas

**No channel jump/search — arrow-key-only navigation doesn't scale past ~20 channels.** Reaching a
channel near the bottom of a real lineup (100+ channels is common) means holding ↓ dozens of times
— confirmed painfully directly while testing the recording-status fix (channel 21.11 needed 61
presses from the top). The web guide has no search either (see its own "No guide search" gap), but
it at least has a mouse/scrollbar; a keyboard-only TUI without a jump mechanism is worse off by
comparison, not on par. Two independent, both-worth-having options: (1) type-ahead — start typing a
channel number/name, jump to the first match, `Esc` clears (same idiom as `less`/`vim`'s `/`); (2) a
"jump to next managed entry" key (`n`/`N`) that skips the selection straight to the next
scheduled/recording tile anywhere in the list, without needing to know which channel it's on first —
directly useful once the overview list below exists, since that's how you'd act on what it shows you.

**No overview of everything scheduled/recording on this tuner.** The web guide's summary panel and
per-tuner dropdown (`buildTunerShowsHTML`, `docs/WebServer.md`) list every Recording/Up
Next/Scheduled/Paused show for a tuner in one place — `hdhr_guide` has no equivalent. Auditing
what's scheduled today means scrolling the entire channel list looking for blue tiles.
`/api/guide.json` already carries enough (`isScheduled`/`isRecording`/`scheduledShowId` per entry)
to build this without a new endpoint — just needs client-side aggregation across all channels'
entries into a separate list screen (a natural companion to the type-ahead/jump-to-next idea above).

**No skip-already-recorded (duplicate) indicator.** The web guide's slate `.g-st-skip` ring/⏭ badge
(`buildGuideGridHTML`'s `willSkip` computation, `CLAUDE.md`) tells you a managed block will be
silently skipped as an on-disk duplicate — this isn't in `/api/guide.json` at all yet
(`buildGuideJSON` doesn't run the `recordedEpisodeTags` scan `buildGuideGridHTML` does), so
`hdhr_guide` has no way to show it even client-side. Meaningfully heavier than the other items here:
needs a new per-managed-series directory scan added to `buildGuideJSON` itself, not just a new field
threaded through existing data. Worth doing eventually for parity, but the smallest-effort/
highest-value items above should come first.
