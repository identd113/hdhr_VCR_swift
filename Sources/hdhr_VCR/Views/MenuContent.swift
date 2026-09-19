import SwiftUI
import AppKit


struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) var openWindow

    // Static so DateFormatter is created once for the app lifetime, not once per guide entry shown
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()
    // "Thu" abbreviation for compact upcoming-slot labels in scheduledMenu
    private static let shortWeekdayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()

    /// Open a single-instance Window scene reliably from a .menu-style MenuBarExtra.
    /// The menu dismisses synchronously; deferring to the next run loop tick
    /// ensures the window request fires after the menu is fully gone.
    /// The title lookup is redundant reinforcement — Window scenes can't duplicate.
    private func open(_ id: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let title: String
            switch id {
            case "add-show":   title = "Add Show"
            case "edit-show":  title = "Edit Show"
            case "settings":   title = "Settings"
            case "watch-now":  title = "Watch Now"
            case "pip-picker": title = "Add Picture-in-Picture"
            default:          title = id
            }
            if let w = NSApp.windows.first(where: { $0.title == title }) {
                w.makeKeyAndOrderFront(nil)
                return
            }
            openWindow(id: id)
        }
    }

    // Returns the device + channel + current guide entry for the active VLC stream, or nil when
    // nothing is playing. Matches against VLCPlayerWindowManager.currentFeedRemoteURL when a FEED
    // session is active, falling back to state.vlcCurrentURL otherwise — not vlcCurrentURL alone
    // (a direct mirror of VLCBridge.currentURL, AppState.swift:585-590). Once the FEED client-side
    // local relay is in play, VLCBridge.currentURL/vlcCurrentURL hold a LOCAL
    // http://127.0.0.1/api/feed-local-relay?... URL that never matches any device's own real
    // lineup entry — same gotcha VLCPlayerView's own currentFeedEntry already documents and works
    // around. Before this fix, this menu's "Now Watching" section (and, added 2026-09-12, the
    // header's own "Watching FEED from <host>" line below) silently showed nothing at all while
    // actually watching a remote FEED.
    private var nowWatchingInfo: (device: HDHRDevice, channel: LineupEntry, entry: GuideEntry?)? {
        let rawURL = VLCPlayerWindowManager.shared.currentFeedRemoteURL ?? state.vlcCurrentURL
        guard !rawURL.isEmpty else { return nil }
        let base = rawURL.urlBase
        for device in state.devices {
            guard let channel = (state.lineups[device.DeviceID] ?? []).first(where: {
                let u = $0.URL ?? ""
                return !u.isEmpty && u == base
            }) else { continue }
            let now   = Date()
            let entry = state.guideEntries(deviceId: device.DeviceID, channelNum: channel.GuideNumber)
                .first { $0.startDate <= now && $0.endDate > now }
            return (device, channel, entry)
        }
        return nil
    }

    // THIS Mac watching another instance's FEED right now — the "tuner is a shared resource"
    // counterpart to the header's per-device rows above (which only ever reflect this Mac's own
    // real tuners) and the separate "FEED: N watching" line below (which only reflects OTHER Macs
    // watching THIS Mac's own relay). Added 2026-09-12, explicit request. Reuses nowWatchingInfo's
    // already-corrected URL matching rather than re-deriving device/channel identity a second way.
    private var watchingRemoteFeedHostname: String? {
        guard let info = nowWatchingInfo, info.device.isVirtualRelay else { return nil }
        return info.channel.virtualRelaySourceHostname ?? info.device.DeviceID
    }

    var body: some View {

        // Compute derived show lists once — each is a filter/sort over shows[];
        // binding to let avoids re-running the filter for every reference below
        let recordingShows       = state.recordingShows
        let activeShows          = state.activeShows
        let pausedShows          = state.pausedShows
        let unavailableShows     = state.unavailableDeviceShows
        let unavailableDeviceIDs = state.unavailableDeviceIDs
        let availableDevices     = state.recordableDevices.filter { $0.isAvailable }

        // ── Header ────────────────────────────────────────────────────────
        // recordableDevices — a discovered virtual relay device has no real lineup/guide data (see
        // AppState.performFetchAllGuides's own comment on why its guide fetch is skipped entirely),
        // so an unfiltered loop here would show a permanent, unfixable "⚠ no guide" warning for a
        // tuner the user never added. It already gets its own correct, dedicated treatment in the
        // "Recording on Another Mac" section below.
        ForEach(state.recordableDevices) { device in
            let slots       = device.TunerCount ?? 1
            // Sums both slots, matching AppState.activeTunerCount(for:)'s own vlc term — a PiP
            // secondary stream watching a real live-tuner channel occupies a tuner exactly like
            // the primary would (docs/VLCPlayerView.md's "Picture-in-picture" section).
            let vlcUsing    = (state.vlcOccupiesTuner(for: device.DeviceID) ? 1 : 0)
                            + (state.secondaryVlcOccupiesTuner(for: device.DeviceID) ? 1 : 0)
            let appCount    = recordingShows.filter { $0.hdhr_record == device.DeviceID }.count + vlcUsing
            let liveInfo    = state.deviceTunerOccupancy[device.DeviceID]
            let hwCount     = liveInfo?.filter { $0.VctNumber != nil }.count ?? appCount
            // max(hw, appCount), matching AppState.activeTunerCount(for:)'s documented contract —
            // not hwCount alone. Right after a recording or in-app VLC stream starts but before the
            // next status.json poll lands, hwCount is still the stale pre-start value; showing it
            // as the headline number (with the correction relegated to the secondary "⚠ app expects
            // N" suffix below) under-reported true occupancy for that window. mismatch still
            // compares the raw hwCount, not this corrected liveCount, so the warning keeps firing in
            // both directions — hw briefly lower than expected (this transient window) and hw
            // higher than expected (e.g. another process/instance also using the tuner).
            let liveCount   = max(hwCount, appCount)
            let mismatch    = liveInfo != nil && hwCount != appCount
            let offline     = !device.isAvailable
            let noLineup    = !state.isStartingUp && !offline && (state.lineups[device.DeviceID]?.isEmpty ?? true)
            let noGuide     = !state.isStartingUp && !offline && (state.guideByDevice[device.DeviceID]?.isEmpty ?? true)
            let warnings    = [offline   ? "unavailable" : nil,
                               noLineup  ? "no lineup"   : nil,
                               noGuide   ? "no guide"    : nil]
                                .compactMap { $0 }.joined(separator: ", ")
            let hasWarn     = !warnings.isEmpty
            Text("\(device.DeviceID)  \(offline ? "—" : "\(liveCount)/\(slots)")" +
                 (mismatch ? "  ⚠ app expects \(appCount)" : "") +
                 (hasWarn  ? "  ⚠ \(warnings)" : ""))
                .foregroundStyle(offline  ? Color(NSColor.systemRed) :
                                 hasWarn  ? Color(NSColor.systemOrange) :
                                 liveCount > 0 ? Color(NSColor.labelColor) :
                                                 Color(NSColor.secondaryLabelColor))
        }
        if let hostname = watchingRemoteFeedHostname {
            Text("Watching FEED from \(hostname)")
                .foregroundStyle(Color(NSColor.secondaryLabelColor))
        }
        Text(state.statusMessage).foregroundStyle(Color(NSColor.secondaryLabelColor))
        // ── Relay stats ───────────────────────────────────────────────────
        // Shown only while this instance's own virtual tuner is actually advertised (a show is
        // recording + the relay is enabled) — not a permanent row, since there's nothing to report
        // otherwise. Sums relayRawViewerCount (raw-passthrough relay connections) with
        // transcodeViewerCount (transcode/H.264 relay connections) — both @Published on AppState,
        // both updated at the moment a viewer actually connects/disconnects, so this row stays live
        // without needing an unrelated AppState mutation to force a menu rebuild first (was reading
        // VLCBridge.shared.transcodeViewerCount(showId:) directly here before, which is correct but
        // not itself @Published — see AppState.transcodeViewerCount's own doc comment on why a
        // second, reactive copy of that aggregate lives there now). Shown even at 0 watching, as
        // confirmation the relay itself is up and reachable, not just once someone connects.
        if state.activeVirtualTunerDeviceID != nil {
            let totalViewers = state.relayRawViewerCount + state.transcodeViewerCount
            Text("FEED: \(totalViewers) watching")
                .foregroundStyle(Color(NSColor.secondaryLabelColor))
        }
        // ── Add Show ──────────────────────────────────────────────────────
        Button { open("add-show") } label: { Label("Add Show…", systemImage: "plus") }
        // ── Watch Now ─────────────────────────────────────────────────────
        watchNowMenu
        // ── Add Picture-in-Picture ────────────────────────────────────────
        // Standalone-capable: unlike the inline "Watch alongside (PiP)" buttons elsewhere (gated on
        // hasPlayablePrimarySession), this opens a picker that can start a PIP with nothing already
        // playing — AppState.watchAsSecondary brings up an idle primary window for it as needed.
        if !state.recordableDevices.isEmpty || !state.remoteRelayEntries.isEmpty {
            Button { open("pip-picker") } label: { Label("Add Picture-in-Picture…", systemImage: "pip.fill") }
        }
        Divider()

        Button("Settings…")    { open("settings") }
        if let update = state.updateCheckResult {
            Button {
                NSWorkspace.shared.open(update.releaseURL)
            } label: {
                Label("Update Available: v\(update.latestVersion)", systemImage: "arrow.down.circle.fill")
            }
        }
        Divider()

        // ── Now Watching ──────────────────────────────────────────────────
        if let info = nowWatchingInfo {
            let watchDeviceId = VLCPlayerWindowManager.shared.currentDeviceID ?? ""
            Section("Watching" + (watchDeviceId.isEmpty ? "" : " · \(watchDeviceId)")) {
                Button {
                    DispatchQueue.main.async { VLCPlayerWindowManager.shared.focus() }
                } label: {
                    Label {
                        // entry is always nil for a remote FEED device (guideByDevice[relayId]
                        // never populates — see docs/VirtualTunerService.md's "Known limitation");
                        // falls back to the relay's own lineup extra instead of showing just the
                        // bare channel with no show name, same source VLCPlayerView's poster
                        // overlay fallback already uses.
                        let showName = info.entry?.Title ?? (info.device.isVirtualRelay ? info.channel.virtualRelayShowTitle : nil)
                        Text("Ch \(info.channel.GuideNumber)  \(info.channel.GuideName)" +
                             (showName.map { " · \($0)" } ?? ""))
                    } icon: {
                        Image(systemName: "play.tv.fill").foregroundStyle(watchNowBlue)
                    }
                }
            }
        }
        // ── Recording now ─────────────────────────────────────────────────
        let availableRecording = recordingShows.filter { !unavailableDeviceIDs.contains($0.hdhr_record) }
        if !availableRecording.isEmpty {
            if state.recordableDevices.count > 1 {
                ForEach(availableDevices) { device in
                    let recs = availableRecording.filter { $0.hdhr_record == device.DeviceID }
                    if !recs.isEmpty {
                        Section("Recording · \(device.DeviceID)") {
                            ForEach(recs) { recordingMenu($0) }
                        }
                    }
                }
            } else {
                Section("Recording Now") {
                    ForEach(availableRecording) { recordingMenu($0) }
                }
            }
            Divider()
        }

        // ── Remote relays (another hdhrVCRplus instance's in-progress recording) ────────────
        // state.remoteRelayEntries is the shared source of truth (also drives the menu bar's own
        // blue blink, hdhr_VCRApp.swift's statusLabel) — read here rather than recomputing the
        // same filter/flatMap locally, so the two surfaces can't drift apart.
        let remoteRelayEntries = state.remoteRelayEntries
        if !remoteRelayEntries.isEmpty {
            Section("Recording on Another Mac (Beta)") {
                ForEach(remoteRelayEntries, id: \.entry.URL) { pair in
                    let title = pair.entry.virtualRelayShowTitle ?? pair.entry.GuideName
                    let vlcReady = VLCBridge.shared.isAvailable
                    let codec = pair.entry.VideoCodec ?? "unknown"
                    // Only offer a second, H.264-transcode-request button when the source isn't
                    // already a modern codec — the remote relay's own "Already-modern-codec skip"
                    // (docs/VirtualTunerService.md) would just relay it as-is regardless of this
                    // request, making a second, functionally identical button pointless.
                    // VideoCodec being unset/"unknown" (an older firmware, or this app's own
                    // synthetic virtual-relay lineup entries never setting it) is treated as "not
                    // confirmed modern" — offer it, don't hide it.
                    let alreadyModern = MPEGVideoStreamType.isAlreadyModernCodec(codec)
                    // When already modern, the plain Watch button *is* the H.264 stream — label it
                    // that way directly instead of a plain "Watch" plus a separate "You'll get:
                    // H264" footnote explaining what you're about to click. Added 2026-09-13,
                    // explicit user request: two ways of saying the same thing was more confusing
                    // than one clear one.
                    let watchLabel = alreadyModern ? "Watch (\(VLCPlayerView.displayCodecName(codec)))" : "Watch"
                    let watchAccessibilityLabel = alreadyModern
                        ? watchInAppCodecLabel(title, codec: VLCPlayerView.displayCodecName(codec))
                        : watchInAppLabel(title)
                    Menu {
                        Button {
                            state.watchRemoteRelay(url: pair.entry.URL ?? "", title: title, device: pair.device)
                        } label: {
                            Label(gatedLabel(watchLabel, met: vlcReady, requirement: "VLC"), systemImage: "play.tv.fill")
                        }
                        .disabled(!vlcReady)
                        .accessibilityLabel(gatedLabel(watchAccessibilityLabel, met: vlcReady, requirement: "VLC"))
                        if !alreadyModern {
                            Button {
                                // "auto" (any non-empty, non-"none" string) only tells the remote
                                // relay "transcode this" — it never decides the actual level;
                                // that's the *source* Mac's own configured "Default transcode
                                // level" (Settings → Sharing → Recording FEED), by design (see
                                // WebServer.effectiveTranscodeProfile's own doc comment).
                                let url = (pair.entry.URL ?? "") + "&transcode=auto"
                                state.watchRemoteRelay(url: url, title: title, device: pair.device)
                            } label: {
                                Label(gatedLabel("Watch (H.264)", met: vlcReady, requirement: "VLC"), systemImage: "play.tv.fill")
                            }
                            .disabled(!vlcReady)
                            .accessibilityLabel(gatedLabel(watchInAppH264Label(title), met: vlcReady, requirement: "VLC"))
                        }
                        if state.hasPlayablePrimarySession {
                            Button {
                                state.watchRemoteRelayAsSecondary(url: pair.entry.URL ?? "", title: title, device: pair.device)
                            } label: {
                                Label(gatedLabel("Watch alongside current (PiP)", met: vlcReady, requirement: "VLC"), systemImage: "pip.fill")
                            }
                            .disabled(!vlcReady)
                            .accessibilityLabel(gatedLabel(watchAlongsideLabel(title), met: vlcReady, requirement: "VLC"))
                        }
                        Divider()
                        menuInfo("Source: \(codec)", font: .footnote, secondary: true)
                        // Reflects an already-active remote transcode session (any viewer of THIS
                        // show on the remote Mac, not just this instance) — see
                        // VirtualTunerService.transcodeViewersKey's own doc comment. Omitted
                        // entirely (not "0 viewers") when nothing is transcoding.
                        if let viewers = pair.entry.virtualRelayTranscodeViewers, viewers > 0 {
                            menuInfo("Transcoding: \(viewers) viewer\(viewers == 1 ? "" : "s")", font: .footnote, secondary: true)
                        }
                        // Estimated signal on the *remote* Mac's real tuner actually recording this
                        // show — see VirtualTunerService.signalQualityKey's own doc comment for
                        // where this comes from (piggybacked on /lineup.json, not a separate
                        // /status.json fetch this instance doesn't otherwise make for a relay
                        // device). Omitted entirely rather than "0%" when not yet known, same
                        // convention as the viewer count above.
                        if let snq = pair.entry.virtualRelaySignalQualityPercent {
                            menuInfo("Signal: \(snq)%", font: .footnote, secondary: true)
                        }
                    } label: {
                        Label {
                            // Hostname suffix added 2026-09-07, explicit user request — without it,
                            // two relays from two different Macs both just read "Recording on
                            // <title>" with nothing distinguishing which physical Mac either comes
                            // from. Omitted (not "Recording on <title> — unknown") on the rare
                            // chance an older build on the source Mac never set the field.
                            if let hostname = pair.entry.virtualRelaySourceHostname {
                                Text("Recording on \(title) — \(hostname)")
                            } else {
                                Text("Recording on \(title)")
                            }
                        } icon: {
                            Image(systemName: "play.tv.fill").foregroundStyle(watchNowBlue)
                        }
                    }
                }
            }
            Divider()
        }

        // ── Next Up ────────────────────────────────────────────────────────
        // "Up Next" means any show scheduled to record later today — not a fixed lookahead
        // window — grouped by start time (bucketed to minute). Standardized to match the same
        // "next show today, else nothing" definition used by the web guide's tuner dropdowns and
        // summary panel (WebServer.swift's buildTunerShowsHTML/buildSumPhHTML). This is distinct
        // from the menu bar status light itself, which keeps its own fixed one-hour window (see
        // AppState.statusLightCandidates) since it's an imminent-start alert, not a listing.
        let now = Date()
        let availableActive = activeShows.filter { !unavailableDeviceIDs.contains($0.hdhr_record) }
        let nextUpGroups: [(time: Date, shows: [Show])] = {
            let cal = Calendar.current
            let cutoff = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now) ?? now)
            var byMinute: [Date: [Show]] = [:]
            for show in availableActive {
                guard let d = show.show_next, d > now, d < cutoff else { continue }
                // Series shows without a confirmed guide entry are in retry/scan mode — keep
                // them in Scheduled rather than Up Next until a real episode is confirmed.
                if show.isSeries, state.menuScheduledEntry[show.show_id] == nil { continue }
                var c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
                c.second = 0
                let bucket = cal.date(from: c) ?? d
                byMinute[bucket, default: []].append(show)
            }
            return byMinute.sorted { $0.key < $1.key }.map { (time: $0.key, shows: $0.value) }
        }()
        let nextUpIds       = Set(nextUpGroups.flatMap { $0.shows }.map { $0.show_id })
        let remainingActive = availableActive.filter { !nextUpIds.contains($0.show_id) }

        if !nextUpGroups.isEmpty {
            if state.recordableDevices.count > 1 {
                ForEach(availableDevices) { device in
                    let deviceGroups = nextUpGroups
                        .map { (time: $0.time, shows: $0.shows.filter { $0.hdhr_record == device.DeviceID }) }
                        .filter { !$0.shows.isEmpty }
                    if !deviceGroups.isEmpty {
                        Section("Up Next · \(device.DeviceID)") {
                            ForEach(deviceGroups, id: \.time) { group in
                                Section(Self.timeFormatter.string(from: group.time)) {
                                    ForEach(group.shows) { scheduledMenu($0, showChannel: true) }
                                }
                            }
                        }
                    }
                }
            } else {
                Section("Up Next") {
                    ForEach(nextUpGroups, id: \.time) { group in
                        Section(Self.timeFormatter.string(from: group.time)) {
                            ForEach(group.shows) { scheduledMenu($0, showChannel: true) }
                        }
                    }
                }
            }
            Divider()
        }

        // ── Scheduled shows ───────────────────────────────────────────────
        let availablePaused = pausedShows.filter { !unavailableDeviceIDs.contains($0.hdhr_record) }
        if availableActive.isEmpty && availablePaused.isEmpty && unavailableShows.isEmpty {
            Text("No shows scheduled").foregroundStyle(.secondary)
        } else {
            if !remainingActive.isEmpty {
                if state.recordableDevices.count > 1 {
                    ForEach(availableDevices) { device in
                        let deviceShows = remainingActive.filter { $0.hdhr_record == device.DeviceID }
                        if !deviceShows.isEmpty {
                            Section("Scheduled · \(device.DeviceID)") {
                                ForEach(deviceShows) { scheduledMenu($0) }
                            }
                        }
                    }
                } else {
                    Section("Scheduled") {
                        ForEach(remainingActive) { scheduledMenu($0) }
                    }
                }
            }
            if !availablePaused.isEmpty {
                if state.recordableDevices.count > 1 {
                    ForEach(availableDevices) { device in
                        let devicePaused = availablePaused.filter { $0.hdhr_record == device.DeviceID }
                        if !devicePaused.isEmpty {
                            Section("Paused · \(device.DeviceID)") {
                                ForEach(devicePaused) { pausedMenu($0) }
                            }
                        }
                    }
                } else {
                    Section("Paused") {
                        ForEach(availablePaused) { pausedMenu($0) }
                    }
                }
            }
        }

        // ── Unavailable Tuner ──────────────────────────────────────────────
        if !unavailableShows.isEmpty {
            Divider()
            let unavailableDevices = state.devices.filter { !$0.isAvailable }
            if unavailableDevices.count > 1 {
                ForEach(unavailableDevices) { device in
                    let deviceShows = unavailableShows.filter { $0.hdhr_record == device.DeviceID }
                    if !deviceShows.isEmpty {
                        Section("Unavailable Tuner · \(device.DeviceID)") {
                            ForEach(deviceShows) { show in
                                if show.show_recording { recordingMenu(show) } else { scheduledMenu(show) }
                            }
                        }
                    }
                }
            } else {
                Section("Unavailable Tuner") {
                    ForEach(unavailableShows) { show in
                        if show.show_recording { recordingMenu(show) } else { scheduledMenu(show) }
                    }
                }
            }
        }
        Divider()

        Button("Quit hdhrVCRplus", role: .destructive) { state.quit() }
    }

    // MARK: ── Watch Now ───────────────────────────────────────────────────
    // Opens a dedicated window with poster-card grid; no cascade needed.

    @ViewBuilder
    private var watchNowMenu: some View {
        if !state.devices.isEmpty {
            let vlcReady = VLCBridge.shared.isAvailable
            Button {
                state.watchNowDeviceId = nil
                open("watch-now")
            } label: {
                Label(gatedLabel("Watch Now…", met: vlcReady, requirement: "VLC"), systemImage: "play.tv.fill")
                    .foregroundStyle(vlcReady ? watchNowBlue : Color(NSColor.disabledControlTextColor))
            }
            .disabled(!vlcReady)
        }
    }

    // MARK: ── Existing show menus ────────────────────────────────────────

    @ViewBuilder
    private func recordingMenu(_ show: Show) -> some View {
        let recNow       = Date()
        let recEntries   = state.guideEntries(deviceId: show.hdhr_record, channelNum: show.show_channel)
        // Anchored to the show's own scheduled start (show_next), not wall-clock `recNow` — a
        // Bonus Time recording keeps running past its guide slot's own end time, so querying "what's
        // airing on this channel right now" once `recNow` passes that end time resolves to whatever
        // *different* program the channel has since moved on to, not the one actually being
        // recorded. Confirmed live 2026-09-13: a Bonus Time NFL Football recording started showing
        // a completely unrelated news-magazine episode's title/episode info mid-recording once the
        // channel's own guide entry rolled over, even though the recording itself correctly kept
        // capturing the football game. Using the show's own start time instead always resolves to
        // the entry that was airing when recording began, which never changes for the life of the
        // recording regardless of how long Bonus Time extends past it.
        let anchorTime   = show.show_next ?? recNow
        let currentEntry = recEntries.first { $0.startDate <= anchorTime && $0.endDate > anchorTime }
        let recEp        = currentEntry.flatMap { $0.episodeInfoLabel }
        let menuTitle    = recEp.map { "🔴 \(show.show_title) · \($0)" } ?? "🔴 \(show.show_title)"
        let isSportsBonus = state.config.Sports_padding_enabled && show.show_bonus_time
        Menu(menuTitle) {
            let started     = show.show_next ?? recNow
            let guideEnd    = show.show_end  ?? recNow
            let inBonusTime = isSportsBonus && recNow > guideEnd

            showInfoHeader(show, entry: currentEntry)
            Divider()
            Button(action: {}) {
                HStack(spacing: 6) {
                    Text("\(show.state.rawValue) · Channel \(show.show_channel)")
                        .font(.footnote)
                        .foregroundColor(Color(NSColor.labelColor))
                    if state.config.Signal_quality_enabled,
                       let lu = state.lineups[show.hdhr_record]?.first(where: { $0.GuideNumber == show.show_channel }) {
                        SignalBarsView(bucket: signalBucket(guideName: lu.GuideName))
                    }
                }
            }
            menuInfo("\(Self.timeFormatter.string(from: started)) · \(show.show_length) min", font: .footnote, secondary: true)
            if inBonusTime {
                menuInfo("Bonus Time (+\(state.config.Sports_padding_minutes) min)", font: .footnote, secondary: true)
            }
            menuInfo("tuner \(show.hdhr_record)", font: .footnote, secondary: true)
            if let sig = state.tunerStatus[show.show_id] {
                menuInfo(sig.displayString, font: .footnote, secondary: true)
            }
            Divider()
            let vlcReady = VLCBridge.shared.isAvailable
            Button(action: { state.watchRecordingInApp(show) }) {
                Label { Text(gatedLabel("Watch Now!", met: vlcReady, requirement: "VLC")).foregroundColor(vlcReady ? watchNowBlue : Color(NSColor.disabledControlTextColor)) }
                      icon: { Image(systemName: "play.tv.fill").foregroundColor(vlcReady ? watchNowBlue : Color(NSColor.disabledControlTextColor)) }
            }
            .disabled(!vlcReady)
            .accessibilityLabel(gatedLabel(watchLiveLabel(show.show_title), met: vlcReady, requirement: "VLC"))
            Button(action: { state.watchRecordingInApp(show, fromBeginning: true) }) {
                Label { Text(gatedLabel("Watch from Beginning", met: vlcReady, requirement: "VLC")).foregroundColor(vlcReady ? watchNowBlue : Color(NSColor.disabledControlTextColor)) }
                      icon: { Image(systemName: "backward.end.fill").foregroundColor(vlcReady ? watchNowBlue : Color(NSColor.disabledControlTextColor)) }
            }
            .disabled(!vlcReady)
            .accessibilityLabel(gatedLabel(watchFromBeginningLabel(show.show_title), met: vlcReady, requirement: "VLC"))
            if state.hasPlayablePrimarySession {
                Button(action: { state.watchRecordingInAppAsSecondary(show) }) {
                    Label { Text(gatedLabel("Watch alongside current (PiP)", met: vlcReady, requirement: "VLC")).foregroundColor(vlcReady ? watchNowBlue : Color(NSColor.disabledControlTextColor)) }
                          icon: { Image(systemName: "pip.fill").foregroundColor(vlcReady ? watchNowBlue : Color(NSColor.disabledControlTextColor)) }
                }
                .disabled(!vlcReady)
                .accessibilityLabel(gatedLabel(watchAlongsideLabel(show.show_title), met: vlcReady, requirement: "VLC"))
            }
            Button("Skip", role: .destructive) { Task { await state.skipRecording(showId: show.show_id) } }
            Button("Delete…", role: .destructive) { state.confirmAndDeleteShow(show) }
            if !show.show_recording_path.isEmpty {
                Button("Show Recording in Finder") {
                    NSWorkspace.shared.selectFile(show.show_recording_path,
                                                  inFileViewerRootedAtPath: "")
                }
            }
            Button("Edit…") { editShow(show) }
        }
    }

    @ViewBuilder
    private func scheduledMenu(_ show: Show, showChannel: Bool = false) -> some View {
        // Pre-computed in AppState.rebuildMenuEntries() every idle tick and after guide loads —
        // avoids O(series entries) scan per show per menu open.
        let conflict  = state.showRuntime[show.show_id]?.isConflicting == true
        let prefix    = conflict ? "⚠️ " : ""
        let schEntry  = state.menuScheduledEntry[show.show_id]
        let schEp     = schEntry.flatMap { $0.episodeInfoLabel }
        let chSuffix  = showChannel ? "  ch \(show.show_channel)" : ""
        let schLabel  = schEp.map { "\(prefix)\(stateIcon(show)) \(show.show_title) · \($0)\(chSuffix)" }
                    ?? "\(prefix)\(stateIcon(show)) \(show.show_title)\(chSuffix)"

        Menu(schLabel) {
            let next = show.show_next ?? .distantFuture

            showInfoHeader(show, entry: schEntry)
            Divider()

            menuInfo("\(show.state.rawValue) · Channel \(show.show_channel)", font: .footnote)
            if conflict {
                let conflictMsg = state.showRuntime[show.show_id]?.conflictBeatenByFavorite == true
                    ? "⚠️ Conflict — a favorited channel has priority for this tuner"
                    : "⚠️ Conflict — all tuners busy at this time"
                menuInfo(conflictMsg, font: .footnote, secondary: true)

                let others = state.conflictingShows(for: show)
                if !others.isEmpty {
                    Divider()
                    menuInfo("Conflicts with:", font: .caption, secondary: true)
                    ForEach(others, id: \.show_id) { other in
                        let otherEp = state.menuScheduledEntry[other.show_id]?.episodeInfoLabel
                        menuInfo("Ch \(other.show_channel) — \(other.show_title)" +
                                 (otherEp.map { " · \($0)" } ?? ""), font: .footnote)
                    }
                }
            }

            // Timing: start time · duration
            menuInfo("\(Self.timeFormatter.string(from: next)) · \(show.show_length) min", font: .footnote, secondary: true)

            // Upcoming recording slots — source depends on show type
            let upcoming: [(channel: String, date: Date)] = {
                switch show.state {
                case .single:
                    if let d = show.show_next { return [(show.show_channel, d)] }
                    return []
                case .dateTime:
                    return state.nextDateTimeOccurrences(for: show, after: Date(), count: 3).map { (show.show_channel, $0) }
                case .seriesChannel, .seriesAll:
                    return state.menuUpcomingSlots[show.show_id] ?? []
                }
            }()
            if !upcoming.isEmpty {
                Divider()
                if upcoming.count > 1 {
                    menuInfo("Upcoming", font: .caption, secondary: true)
                }
                ForEach(upcoming, id: \.date) { slot in
                    menuInfo(upcomingLabel(channel: slot.channel, date: slot.date), font: .footnote)
                }
            }

            if show.show_fail_count > 0 {
                Divider()
                menuInfo("⚠️ \(show.show_fail_count) failure(s): \(show.show_fail_reason)", font: .footnote)
            }
            Divider()
            Button("Edit…")      { editShow(show) }
            Button("Pause") { state.pauseShow(show) }
            Button("Delete…", role: .destructive) { state.confirmAndDeleteShow(show) }
        }
    }

    @ViewBuilder
    private func pausedMenu(_ show: Show) -> some View {
        Menu("⏸ \(show.show_title)") {
            let pausedEntries = state.guideEntries(deviceId: show.hdhr_record, channelNum: show.show_channel)
            let pausedEntry   = pausedEntries.first {
                abs($0.startDate.timeIntervalSince(show.show_next ?? .distantPast)) < 5 * 60
            }
            showInfoHeader(show, entry: pausedEntry)
            Divider()
            menuInfo("\(show.state.rawValue) · Channel \(show.show_channel)", font: .footnote, secondary: true)
            if !show.show_fail_reason.isEmpty {
                menuInfo("Reason: \(show.show_fail_reason)", font: .footnote, secondary: true)
            }
            if let next = show.show_next, next > Date() {
                menuInfo("Next attempt: \(Self.timeFormatter.string(from: next))", font: .footnote, secondary: true)
            }
            Divider()
            Button("Resume Now") { state.resumeShow(show) }
            Button("Edit…") { editShow(show) }
            Button("Delete…", role: .destructive) { state.confirmAndDeleteShow(show) }
        }
    }

    // MARK: ── Helpers ────────────────────────────────────────────────────

    private func editShow(_ show: Show) {
        state.editingShowId = show.show_id
        open("edit-show")
    }

    private func stateIcon(_ show: Show) -> String {
        switch show.state {
        case .single:        return "1️⃣"
        case .dateTime:      return "📅"
        case .seriesChannel: return "🔂"
        case .seriesAll:     return "🔁"
        }
    }

    // "ch 5.1 · 8:00 PM" (today) or "ch 5.1 · Thu 8:00 PM" (future day)
    private func upcomingLabel(channel: String, date: Date) -> String {
        let t = Self.timeFormatter.string(from: date)
        if Calendar.current.isDateInToday(date) { return "Channel \(channel) · \(t)" }
        return "Channel \(channel) · \(Self.shortWeekdayFormatter.string(from: date)) \(t)"
    }

    // Shared show-info panel used by recordingMenu, scheduledMenu, and pausedMenu.
    // Renders poster (460×258), title, episode info, and synopsis in a consistent layout.
    @ViewBuilder
    private func showInfoHeader(_ show: Show, entry: GuideEntry?) -> some View {
        if !show.show_logo_url.isEmpty, URL(string: show.show_logo_url) != nil {
            MenuPosterImage(urlString: show.show_logo_url)
                .accessibilityLabel("\(show.show_title) poster")
        }
        menuInfo(show.show_title, font: .title3, maxWidth: 460)
        if let ep = entry?.episodeInfoLabel {
            menuInfo(ep, font: .callout, maxWidth: 460)
        }
        if let syn = entry?.Synopsis, !syn.isEmpty {
            menuInfo(truncateSynopsis(syn), font: .callout, maxWidth: 460)
        }
    }

    // Universal helper: wraps info text in a no-op Button so AppKit renders it at full
    // brightness. Plain Text views in Menu {} blocks are auto-disabled by NSMenu and drawn
    // at ~50% opacity regardless of the foreground color — Button avoids that treatment.
    // Pass maxWidth to constrain width and allow the text to wrap (up to 4 lines).
    @ViewBuilder
    private func menuInfo(_ string: String, font: Font = .body, secondary: Bool = false, maxWidth: CGFloat? = nil) -> some View {
        Button(action: {}) {
            Text(string).font(font)
                .foregroundColor(secondary ? Color(NSColor.secondaryLabelColor) : Color(NSColor.labelColor))
                .lineLimit(maxWidth == nil ? nil : 4)
                // Fixed width (not maxWidth) forces NSMenu items to wrap rather than
                // expanding the menu horizontally to fit a single long line.
                .frame(width: maxWidth, alignment: .leading)
        }
    }

    private func truncateSynopsis(_ text: String, limit: Int = 160) -> String {
        guard text.count > limit else { return text }
        let cut = text.index(text.startIndex, offsetBy: limit)
        if let space = text[..<cut].lastIndex(of: " ") {
            return String(text[..<space]) + "…"
        }
        return String(text[..<cut]) + "…"
    }

}

// showInfoHeader's poster, routed through ChannelIconCache's disk+memory cache instead of
// AsyncImage's own per-instance fetch — this .menu-style MenuBarExtra rebuilds its whole view
// graph fresh every time the dropdown opens, so a raw AsyncImage would re-download/re-decode
// the same poster over the network on every single menu open.
private struct MenuPosterImage: View {
    let urlString: String
    @State private var img: NSImage? = nil

    var body: some View {
        Group {
            if let img {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.separatorColor))
            }
        }
        .frame(width: 460, height: 258)
        .clipped()
        .cornerRadius(6)
        .task(id: urlString) {
            img = await ChannelIconCache.shared.image(for: urlString)
        }
    }
}

