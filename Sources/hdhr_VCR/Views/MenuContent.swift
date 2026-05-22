import SwiftUI
import AppKit

struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) var openWindow
    @AppStorage("addShowMode") private var addShowMode: AddShowMode = .menu

    // Static so DateFormatter is created once for the app lifetime, not once per guide entry shown
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE"; return f
    }()

    /// Open a WindowGroup scene reliably from a .menu-style MenuBarExtra.
    /// The menu dismisses synchronously; deferring to the next run loop tick
    /// ensures the window request fires after the menu is fully gone.
    private func open(_ id: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let title: String
            switch id {
            case "add-show":  title = "Add Show"
            case "edit-show": title = "Edit Show"
            case "settings":  title = "Settings"
            default:          title = id
            }
            if let w = NSApp.windows.first(where: { $0.title == title }) {
                w.makeKeyAndOrderFront(nil)
                return
            }
            openWindow(id: id)
        }
    }

    var body: some View {

        // Compute derived show lists once — each is a filter/sort over shows[];
        // binding to let avoids re-running the filter for every reference below
        let recordingShows = state.recordingShows
        let activeShows    = state.activeShows
        let inactiveShows  = state.inactiveShows

        // ── Header ────────────────────────────────────────────────────────
        ForEach(state.devices) { device in
            let slots  = device.TunerCount ?? 1
            let active = recordingShows.filter { $0.hdhr_record == device.DeviceID }.count
            Text("\(device.DeviceID)  \(active)/\(slots)")
                .foregroundStyle(active > 0 ? Color(NSColor.labelColor) : Color(NSColor.secondaryLabelColor))
        }
        Text(state.statusMessage).foregroundStyle(Color(NSColor.secondaryLabelColor))
        Divider()

        // ── Recording now ─────────────────────────────────────────────────
        if !recordingShows.isEmpty {
            Section("Recording Now") {
                ForEach(recordingShows) { show in
                    recordingMenu(show)
                }
            }
            Divider()
        }

        // ── Scheduled shows ───────────────────────────────────────────────
        if activeShows.isEmpty && inactiveShows.isEmpty {
            Text("No shows scheduled").foregroundStyle(.secondary)
        } else {
            if !activeShows.isEmpty {
                Section("Scheduled") {
                    ForEach(activeShows) { show in scheduledMenu(show) }
                }
            }
            if !inactiveShows.isEmpty {
                Section("Paused") {
                    ForEach(inactiveShows) { show in pausedMenu(show) }
                }
            }
        }
        Divider()

        // ── Add Show ──────────────────────────────────────────────────────
        if addShowMode == .menu {
            addShowMenu
        } else {
            Button("Add Show…") { open("add-show") }
        }
        Button("Refresh Guide") { state.refreshAll() }
        Button("Settings…")    { open("settings") }
        Divider()

        Button("Quit hdhr_VCR", role: .destructive) { state.quit() }
    }

    // MARK: ── Level 1: Add Show ──────────────────────────────────────────
    // If only 1 device, skip the device level and go straight to channels.

    @ViewBuilder
    private var addShowMenu: some View {
        let menuLabel = "Add Show"
        if state.devices.isEmpty {
            Text("No tuners detected").foregroundStyle(.secondary)
        } else if state.devices.count == 1, let device = state.devices.first {
            Menu(menuLabel) {
                // Trigger guide fetch as soon as this menu renders
                let _ = { state.ensureGuideLoaded(for: device.DeviceID) }()
                channelMenus(for: device)
            }
        } else {
            // Level 2: device chooser
            Menu(menuLabel) {
                ForEach(state.devices) { device in
                    Menu(device.DeviceID) {
                        let _ = { state.ensureGuideLoaded(for: device.DeviceID) }()
                        channelMenus(for: device)
                    }
                }
            }
        }
    }

    // MARK: ── Level 2 (or 3): Channel list ──────────────────────────────

    @ViewBuilder
    private func channelMenus(for device: HDHRDevice) -> some View {
        let channels = state.lineups[device.DeviceID] ?? []
        if channels.isEmpty {
            Text("No channels — try Refresh Guide").foregroundStyle(.secondary)
        } else {
            ForEach(channels, id: \.GuideNumber) { ch in
                channelMenu(device: device, channel: ch)
            }
        }
    }

    // MARK: ── Level 3 (or 4): Guide entries for a channel ───────────────

    @ViewBuilder
    private func channelMenu(device: HDHRDevice, channel: LineupEntry) -> some View {
        let entries   = state.guideEntries(deviceId: device.DeviceID, channelNum: channel.GuideNumber)
        let loading   = state.isGuideLoading(for: device.DeviceID)
        let hdBadge   = channel.HD == 1 ? " HD" : ""
        let label     = "\(channel.GuideNumber)  \(channel.GuideName)\(hdBadge)"
        let now       = Date()
        let onAir     = entries.filter { $0.startDate <= now && $0.endDate > now }
        let upcoming  = entries.filter { $0.startDate > now }

        Menu(label) {
            if entries.isEmpty {
                if loading {
                    Text("Fetching guide…").foregroundStyle(.secondary)
                } else {
                    Text("No upcoming shows").foregroundStyle(.secondary)
                    Button("Load guide") { state.ensureGuideLoaded(for: device.DeviceID) }
                }
            } else {
                ForEach(onAir) { entry in
                    entryMenu(entry: entry, device: device, channel: channel, isOnAir: true)
                }
                if !onAir.isEmpty && !upcoming.isEmpty { Divider() }
                ForEach(upcoming) { entry in
                    entryMenu(entry: entry, device: device, channel: channel, isOnAir: false)
                }
            }
        }
    }

    // MARK: ── Level 4 (or 5): Show entry + type selection ───────────────
    // Label in the parent menu: "8:00 PM  Jeopardy! (30 min)"
    // Submenu: synopsis, divider, Add as Single / Add as Series → (3 types)

    @ViewBuilder
    private func entryMenu(entry: GuideEntry, device: HDHRDevice, channel: LineupEntry, isOnAir: Bool = false) -> some View {
        let entryColor = guideEntryColor(for: entry, onAir: isOnAir)
        Menu {

            // Info (disabled) ─────────────────────────────────────────────
            // Poster image (best-effort — NSMenu rendering of AsyncImage varies)
            if let urlStr = entry.ImageURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
                AsyncImage(url: url) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 200, height: 120).clipped().cornerRadius(4)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(NSColor.separatorColor))
                        .frame(width: 200, height: 120)
                }
            }
            Text(entry.Title).font(.headline)
                .foregroundColor(Color(NSColor.labelColor))
            if let ep = episodeInfoLabel(entry) {
                // labelColor, not secondaryLabelColor — NSMenu auto-dims non-interactive items
                // so secondary would be doubly-dimmed and nearly invisible
                Text(ep).font(.caption)
                    .foregroundColor(Color(NSColor.labelColor))
            }
            // Same reason: labelColor so the time range stays readable after NSMenu dimming
            Text(timeRange(entry))
                .foregroundColor(Color(NSColor.labelColor))
            if let syn = entry.Synopsis, !syn.isEmpty {
                Text(syn).font(.caption).lineLimit(3)
                    .foregroundColor(Color(NSColor.labelColor))
            }
            Divider()

            // Single ───────────────────────────────────────────────────────
            Button("Record once (Single)") {
                state.addShowFromGuide(entry: entry, type: .single, device: device, channel: channel)
            }

            // Series submenu ───────────────────────────────────────────────
            Menu("Record as series…") {

                // DateTime: repeats this same day + time on this channel
                Button {
                    state.addShowFromGuide(entry: entry, type: .dateTime, device: device, channel: channel)
                } label: {
                    VStack(alignment: .leading) {
                        Text("DateTime — same day & time")
                        Text("Repeats on \(weekdayName(entry.startDate))s at \(state.shortTime(entry.startDate)) on ch \(channel.GuideNumber)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                // SeriesID Channel: any episode, this channel only
                Button {
                    state.addShowFromGuide(entry: entry, type: .seriesChannel, device: device, channel: channel)
                } label: {
                    VStack(alignment: .leading) {
                        Text("SeriesID — this channel")
                        Text("Any episode on ch \(channel.GuideNumber)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                // SeriesID All: any episode, any channel
                Button {
                    state.addShowFromGuide(entry: entry, type: .seriesAll, device: device, channel: channel)
                } label: {
                    VStack(alignment: .leading) {
                        Text("SeriesID — all channels")
                        if let sid = entry.SeriesID {
                            Text("Matches \(sid) anywhere in the guide")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if state.config.Watch_in_VLC && isOnAir {
                Button("Watch in VLC") { state.watchInVLC(url: channel.URL ?? "") }
            }
        } label: {
            Label {
                Text(entryLabel(entry, isOnAir: isOnAir))
            } icon: {
                Image(systemName: "square.fill")
                    .foregroundStyle(entryColor)
            }
        }
    }

    // MARK: ── Existing show menus ────────────────────────────────────────

    @ViewBuilder
    private func recordingMenu(_ show: Show) -> some View {
        Menu("🔴 \(show.show_title)") {
            let now     = Date()
            let started = show.show_next.date ?? now
            let ends    = show.show_end.date   ?? now

            // Item 1: look up the current guide entry from the in-memory cache so we can show
            // episode info and synopsis — same data the cable guide summary panel displays
            let guideEntries = state.guideEntries(deviceId: show.hdhr_record, channelNum: show.show_channel)
            let currentEntry = guideEntries.first { $0.startDate <= now && $0.endDate > now }

            // Poster image when available (same pattern as entryMenu in Add Show)
            if !show.show_logo_url.isEmpty, let url = URL(string: show.show_logo_url) {
                AsyncImage(url: url) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 120, height: 80).clipped().cornerRadius(4)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(NSColor.separatorColor))
                        .frame(width: 120, height: 80)
                }
            }

            // Title + episode info from guide (e.g. "S02E05 · Overtime")
            Text(show.show_title).font(.headline)
                .foregroundColor(Color(NSColor.labelColor))
            if let entry = currentEntry, let ep = episodeInfoLabel(entry) {
                Text(ep).font(.caption)
                    .foregroundColor(Color(NSColor.labelColor))
            }

            // Synopsis from guide (up to 3 lines so menu doesn't get too tall)
            if let synopsis = currentEntry?.Synopsis, !synopsis.isEmpty {
                Text(synopsis).font(.caption).lineLimit(3)
                    .foregroundColor(Color(NSColor.labelColor))
            }

            Divider()
            Text("ch \(show.show_channel) · \(show.state.rawValue)")
                .foregroundColor(Color(NSColor.secondaryLabelColor))
            Text("\(elapsedLabel(since: started)) elapsed · \(remainingLabel(until: ends)) left")
                .foregroundColor(Color(NSColor.secondaryLabelColor))
            Divider()
            Button("Stop Recording") { state.stopRecording(showId: show.show_id) }
            if state.config.Watch_in_VLC {
                Button("Watch in VLC") { state.watchInVLC(url: show.show_url) }
            }
            Button("Edit…") { editShow(show) }
        }
    }

    @ViewBuilder
    private func scheduledMenu(_ show: Show) -> some View {
        Menu("\(stateIcon(show)) \(show.show_title)") {
            let now    = Date()
            let next   = show.show_next.date ?? .distantFuture
            let ends   = show.show_end.date  ?? .distantFuture

            // Item 5: look up the guide entry at the scheduled time so we can display episode
            // title/number — this is a sync read from the in-memory guide cache
            let guideEntries = state.guideEntries(deviceId: show.hdhr_record, channelNum: show.show_channel)
            let scheduledEntry = guideEntries.first {
                // Match the entry whose start time is within 5 minutes of show_next
                abs($0.startDate.timeIntervalSince(next)) < 5 * 60
            }

            // Type + channel — full-brightness so it reads clearly in the menu
            Text("\(show.state.rawValue) · ch \(show.show_channel)")
                .foregroundColor(Color(NSColor.labelColor))

            // Episode info from the guide (season/episode number · episode title)
            if let entry = scheduledEntry, let epInfo = episodeInfoLabel(entry) {
                Text(epInfo).font(.caption)
                    .foregroundColor(Color(NSColor.labelColor))
            }

            // Timing: starts in / ended
            if next > now {
                Text("In \(relativeLabel(next.timeIntervalSince(now))) · \(show.show_length) min")
                    .foregroundColor(Color(NSColor.labelColor))
            } else if ends > now {
                Text("Started \(relativeLabel(now.timeIntervalSince(next))) ago · \(remainingLabel(until: ends)) left")
                    .foregroundColor(Color(NSColor.labelColor))
            }

            // For SeriesID shows: augment with the next guide episode from the series index
            if show.show_use_seriesid, let ep = state.nextGuideEpisode(for: show) {
                Divider()
                // Full label color so the episode line stands out — was secondaryLabelColor before
                Text("Next: ch \(ep.channel) · \(state.shortTime(ep.entry.startDate))")
                    .foregroundColor(Color(NSColor.labelColor))
                if let epInfo = episodeInfoLabel(ep.entry) {
                    Text(epInfo).font(.caption)
                        .foregroundColor(Color(NSColor.labelColor))
                }
            }

            if show.show_fail_count > 0 {
                Divider()
                Text("⚠️ \(show.show_fail_count) failure(s): \(show.show_fail_reason)")
                    .foregroundColor(Color(NSColor.systemOrange))
            }
            Divider()
            Button("Edit…")      { editShow(show) }
            Button("Deactivate") { state.toggleActive(show) }
            Button("Delete…", role: .destructive) { state.deleteShow(show) }
        }
    }

    @ViewBuilder
    private func pausedMenu(_ show: Show) -> some View {
        Menu("⏸ \(show.show_title)") {
            if !show.show_fail_reason.isEmpty {
                Text("Last error: \(show.show_fail_reason)").foregroundStyle(.secondary)
            }
            Divider()
            Button("Activate")  { state.toggleActive(show) }
            Button("Edit…")     { editShow(show) }
            Button("Delete…", role: .destructive) { state.deleteShow(show) }
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
        case .seriesChannel: return "📺"
        case .seriesAll:     return "🔁"
        }
    }

    /// "2h 15m", "45m", "30s" — for a positive interval
    private func relativeLabel(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600; let m = (total % 3600) / 60; let s = total % 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    private func elapsedLabel(since start: Date) -> String {
        relativeLabel(Date().timeIntervalSince(start))
    }

    private func remainingLabel(until end: Date) -> String {
        relativeLabel(end.timeIntervalSince(Date()))
    }

    // "▶ 8:00 PM  Jeopardy! (30 min)" or "8:00 PM  Jeopardy! (30 min)"
    private func entryLabel(_ entry: GuideEntry, isOnAir: Bool = false) -> String {
        let prefix = isOnAir ? "▶ " : ""
        return "\(prefix)\(Self.timeFormatter.string(from: entry.startDate))  \(entry.Title) (\(entry.durationMinutes)m)"
    }

    // "8:00 PM – 8:30 PM"
    private func timeRange(_ entry: GuideEntry) -> String {
        return "\(Self.timeFormatter.string(from: entry.startDate)) – \(Self.timeFormatter.string(from: entry.endDate))"
    }

    private func weekdayName(_ date: Date) -> String {
        return Self.weekdayFormatter.string(from: date)
    }

    private func episodeInfoLabel(_ entry: GuideEntry) -> String? {
        let parts = [entry.EpisodeNumber, entry.EpisodeTitle]
            .compactMap { s -> String? in
                guard let s, !s.isEmpty else { return nil }
                return s
            }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }
}
