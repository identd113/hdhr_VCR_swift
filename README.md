# hdhr_VCR

A macOS menu bar app for recording live TV from [HDHomeRun](https://www.silicondust.com) network tuners. Lives in your menu bar — no Dock icon — and records in the background while you work.

This is a Swift/SwiftUI rewrite of the original [hdhr_VCR AppleScript app](https://github.com/identd113/hdhr_VCR-AS), which has been running since 2016. It reads and writes the same config file format, so both versions can coexist.

---

## Features

- **Menu bar recording** — start, monitor, and stop recordings from the menu bar without opening a full app window
- **Cable TV-style guide** — scrollable grid showing all channels and upcoming shows, color-coded by genre
- **Four recording modes**:
  - **Single** — record one episode, then done
  - **DateTime** — repeat every week on the same day and time
  - **SeriesID (Channel)** — any episode of a series on a specific channel
  - **SeriesID (All Channels)** — any episode of a series on any channel
- **Multi-device support** — discovers and manages multiple HDHomeRun tuners on the network
- **EXTEND support** — uses SiliconDust's cloud guide API for HDTC-2US devices
- **Notifications** — "Up Next" and "Recording Soon" alerts before each show
- **Sleep prevention** — uses `caffeinate` so recordings survive display sleep
- **Transcode options** — none (`.m2ts`), heavy, mobile, or internet720 (`.mkv` via the device)
- **Watch in VLC** — open any live stream in VLC directly from the menu
- **Launch at Login** — stay running in the background automatically
- **Survives restarts** — reattaches to in-progress recordings after a crash or relaunch

---

## Requirements

- **macOS 15.0** (Sequoia) or later
- An **HDHomeRun** network tuner (CONNECT, PRIME, EXTEND, FLEX, etc.)
- The tuner must be reachable on your local network

Optional:
- **VLC** (`/Applications/VLC.app`) for live stream preview

---

## Installation

1. Clone or download this repository
2. Open Terminal in the project folder
3. Run:

```bash
./deploy.sh
```

This builds the app, copies the binary into `hdhr_VCR.app`, signs it, and launches it. The app will appear in your menu bar as a TV icon.

> **Note**: The `.app` bundle is included in the repository. If you don't want to build from source, you can try launching `hdhr_VCR.app` directly — you may need to right-click → Open the first time to bypass Gatekeeper.

---

## Setup

On first launch, the app will search for HDHomeRun tuners on your network automatically. If none are found:

1. Make sure your HDHomeRun is powered on and connected to the same network
2. Click **Refresh Guide** in the menu to retry discovery

The config file is created automatically at:
```
~/Documents/hdhr_VCR-{hostname}.json
```

---

## Adding Shows

### Wizard mode (default)

Click the menu bar icon → **Add Show…** to open the 3-step wizard:

1. **Select Tuner** — choose which HDHomeRun device to record from (skipped if you only have one)
2. **Guide** — browse the cable TV-style grid; click a show to select it, double-click to advance
3. **Details** — set the recording type, air days, transcode, and save folder

### Menu mode

Switch to menu mode in **Settings → General → Add Show Method** for a faster inline flow: click the menu bar icon → **Add Show** → Channel → Guide Entry → recording type.

---

## Menu Bar Icon

| Icon | Meaning |
|------|---------|
| 📺 (dim) | App is starting up |
| 📺 | Idle — no upcoming shows within 30 minutes |
| 🕐 (orange) | A show starts within 30 minutes |
| ⏺ (red) | Recording in progress |

---

## Recording Modes

| Mode | Description |
|------|-------------|
| **Single** | Records once. Show is deactivated after the recording completes. |
| **DateTime** | Repeats on the same weekday(s) and time each week on a fixed channel. |
| **SeriesID (Channel)** | Records any episode of the series that airs on a specific channel. |
| **SeriesID (All)** | Records any episode of the series on any channel. |

Shows that fail more than the configured threshold (default: 3) are automatically paused and can be reactivated from the **Paused** section of the menu.

---

## Settings

Open via the menu bar icon → **Settings…**

| Category | Key Options |
|----------|-------------|
| **General** | Launch at Login; Add Show mode (wizard vs menu) |
| **Recording** | Default save folder; transcode profile; minimum free disk space; failure threshold; Watch in VLC |
| **Guide** | Hours of guide data to fetch; series scan retry interval |
| **Notifications** | "Up Next" alert timing; "Recording Soon" alert timing |
| **Advanced** | Idle check interval; verbose curl logging; config file location |
| **About** | App history, version, GitHub link |

Settings use a **draft/save** pattern — changes are not applied until you click **Save** (⌘S). Closing the window with unsaved changes prompts to save or discard.

---

## Config File

The config file is shared with the original AppleScript version:

```
~/Documents/hdhr_VCR-{hostname}.json
```

A `.json.bak` backup is created before each save. You can copy a config from the AppleScript version and it will load correctly.

---

## Recordings

By default, recordings are saved to `~/Movies`. You can set a different folder in **Settings → Recording → Default folder**, or per-show via **Edit…** in the menu.

File naming: `ShowTitle_Channel_YYYYMMDD_HHmm.m2ts` (or `.mkv` for transcoded recordings).

---

## Building from Source

```bash
# Build and launch
./deploy.sh

# Build only
swift build

# Run tests
swift test
```

Requires Xcode Command Line Tools. The minimum deployment target is macOS 15.0.

---

## Background

hdhr_VCR started in 2016 as an AppleScript application to fill the gap left by discontinued HDHomeRun recording software. This Swift/SwiftUI rewrite brings a native menu bar UI, a cable-guide grid, and modern macOS features while keeping full compatibility with the original config format.

Original AppleScript version: [identd113/hdhr_VCR-AS](https://github.com/identd113/hdhr_VCR-AS)
