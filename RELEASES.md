# Release Notes

What's new in each version. For day-by-day implementation detail, see
[CHANGELOG.md](Sources/hdhr_VCR/CHANGELOG.md); for the full download, see the
[GitHub Releases page](https://github.com/identd113/hdhr_VCR_swift/releases).

---

## v2.0.0 — First Notarized Release (2026-08-08)

**This is the first hdhrVCRplus release signed with a Developer ID certificate and notarized by
Apple** — no more "unidentified developer" warning, no right-click-Open or `xattr` bypass step.
macOS accepts it as a normal app on first launch, verified offline via a stapled ticket.

### Added
- **Donation support** — an optional, dismissible in-app reminder (shown on launch and when
  scheduling a show) with a link to leave a voluntary tip. Not a paywall — every feature works
  identically whether you ever see it, dismiss it, or ignore it entirely. Settings → About shows
  your registered status if you've tipped.
- **Vertical time-axis mode for the mobile web guide** — on a portrait phone, the guide grid
  transposes so channels become side-by-side columns and time reads top-to-bottom, like a
  calendar view, instead of the usual side-scrolling horizontal grid.

### Removed
- **The "Cable Guide" pop-out window** — redundant since the Add Show wizard's guide step already
  embeds the full-size web guide directly; had no remaining way to open it.

### Fixed
- The app referred to itself by three different names ("hdhrVCRplus", "hdhrVCR+", "hdhr_VCR")
  depending on which screen you were looking at — standardized to "hdhrVCRplus" everywhere.
- Some Settings number fields could show their value doubled up (e.g. the web server port reading
  "1980  1980") on recent macOS — a redundant placeholder rendering alongside the real value.
- Narrow phones could overflow channel number/name text in the web guide's channel column.
- The web guide's "snap to now" button appeared later than it should have, and the summary panel
  had a leftover error from an earlier feature's removal.
- The About panel's changelog now renders markdown headers and numbered/bulleted lists properly
  instead of one flattened paragraph, and reads correctly in dark mode.
- Log files (`hdhrVCRplus.log`, the Discord activity log) now self-rotate instead of growing
  without bound over a long-running session.
- A recording resumed after an app restart could leave behind a stray temp file and silently lose
  error-code reporting for the rest of that recording — fixed by properly reattaching its curl
  header-file tracking. The channel-logo disk cache also now has a 150 MB ceiling (oldest logos
  evicted first) instead of growing without bound.

Full day-by-day detail: [CHANGELOG.md](Sources/hdhr_VCR/CHANGELOG.md)

### Installing

1. Download `hdhrVCRplus-v2.0.0.zip` from the
   [Releases page](https://github.com/identd113/hdhr_VCR_swift/releases) and unzip it.
2. Move `hdhrVCRplus.app` to `/Applications`.
3. Open it — no warning, no bypass step needed.
4. Requires macOS 15.0 (Sequoia) or later, and an HDHomeRun tuner on your local network. VLC is
   optional, for Watch Now playback.

---

*Releases before v2.0.0 were ad-hoc signed, not notarized — see that release's own notes on the
[Releases page](https://github.com/identd113/hdhr_VCR_swift/releases) for its Gatekeeper bypass
instructions.*
