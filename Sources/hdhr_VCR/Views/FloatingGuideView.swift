import SwiftUI

// Standalone cable guide browser — opened from the Add Show wizard via the pop-out button.
// Browse-only: no Record button, no wizard navigation. Escape closes the window.
struct FloatingGuideView: View {

    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDevice: HDHRDevice? = nil
    @State private var allChannels: [GuideChannel] = []
    @State private var selectedChannel: LineupEntry? = nil
    @State private var selectedEntry: GuideEntry? = nil
    @State private var isLoadingGuide = false
    @State private var refreshToken = UUID()
    @State private var snapToNow = false
    @State private var genreFilter: String? = nil

    private var taskId: String { "\(selectedDevice?.DeviceID ?? ""):\(refreshToken)" }

    private var availableGenres: [String] {
        var seen = Set<String>()
        return allChannels.flatMap { $0.Guide ?? [] }
            .compactMap { $0.firstGenre }
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted()
    }

    private var managedMatcher: ManagedGuideMatcher {
        ManagedGuideMatcher(activeManagedShows: state.shows.filter { $0.show_active && !$0.show_paused })
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    summaryPanel
                        .frame(height: proxy.size.height / 3)
                    Divider()
                    if allChannels.isEmpty && !isLoadingGuide {
                        EmptyStateView(title: "No guide data", systemImage: "tv.slash",
                                   description: "Guide data unavailable — tap Refresh to retry.")
                    } else {
                        // managedMatcher is a computed property shared with summaryPanel.
                        let recordingSeriesIDs = Set(state.recordingShows.compactMap { $0.show_seriesid.isEmpty ? nil : $0.show_seriesid })
                        let recordingTitles = Set(state.recordingShows.map { $0.show_title })
                        let now30 = Date()
                        let nextUpShows = state.activeShows.filter {
                            guard let d = $0.show_next else { return false }
                            return d > now30 && d.timeIntervalSince(now30) <= 30 * 60
                        }
                        let nextUpSeriesIDs = Set(nextUpShows.compactMap { $0.show_seriesid.isEmpty ? nil : $0.show_seriesid })
                        let nextUpTitles = Set(nextUpShows.map { $0.show_title })
                        let bonusShows = state.shows.filter { $0.show_bonus_time }
                        let bonusSeriesIDs = Set(bonusShows.compactMap { $0.show_seriesid.isEmpty ? nil : $0.show_seriesid })
                        let bonusTitles = Set(bonusShows.map { $0.show_title })

                        CableGuideView(
                            allChannels:        allChannels,
                            lineup:             state.lineups[selectedDevice?.DeviceID ?? ""] ?? [],
                            guideHours:         state.config.GuideHours,
                            selectedEntry:      $selectedEntry,
                            selectedChannel:    $selectedChannel,
                            snapToNow:          $snapToNow,
                            deviceId:                selectedDevice?.DeviceID ?? "",
                            managedMatcher:  managedMatcher,
                            recordingSeriesIDs: recordingSeriesIDs,
                            recordingTitles:    recordingTitles,
                            nextUpSeriesIDs:    nextUpSeriesIDs,
                            nextUpTitles:       nextUpTitles,
                            bonusSeriesIDs:     bonusSeriesIDs,
                            bonusTitles:        bonusTitles,
                            bonusMinutes:       state.config.Sports_padding_minutes,
                            genreFilter:        genreFilter,
                            onConfirm:          {},  // no-op — browse only
                            onToggleFavorite: { lu in
                                guard let device = selectedDevice else { return }
                                state.toggleFavorite(device: device, channel: lu)
                            }
                        )
                    }
                }
            }
        }
        .frame(minWidth: 1100, minHeight: 720)
        .background(FloatingWindowLevelSetter())   // keep above other windows
        .onExitCommand { dismiss() }
        .onAppear {
            if selectedDevice == nil { selectedDevice = state.devices.first }
        }
        .task(id: taskId) { await loadGuide() }
        .onChange(of: selectedDevice) { newDevice in
            // Lineups are stable (loaded during discovery) — don't clear them or
            // CableGuideView gets an empty lineup and the Record button stays disabled.
            guard let id = newDevice?.DeviceID else { return }
            state.guideStore.invalidate(deviceId: id)
            allChannels = []
            genreFilter = nil
            refreshToken = UUID()
        }
        .onChange(of: state.lineups[selectedDevice?.DeviceID ?? ""] ?? []) { newLineup in
            guard let id = selectedDevice?.DeviceID, !allChannels.isEmpty else { return }
            allChannels = sortedGuideChannels(allChannels, favorites: Set((state.lineups[id] ?? []).filter(\.isFavorite).map(\.GuideNumber)))
        }
        .onChange(of: allChannels.count) { count in
            guard count > 0, selectedEntry == nil else { return }
            let now = Date()
            guard let firstCh = allChannels.first,
                  let entry = firstCh.Guide?.first(where: { $0.startDate <= now && $0.endDate > now })
            else { return }
            selectedEntry = entry
            selectedChannel = (state.lineups[selectedDevice?.DeviceID ?? ""] ?? [])
                .first(where: { $0.GuideNumber == firstCh.GuideNumber })
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            if state.devices.count > 1 {
                Text("Tuner:").foregroundStyle(.secondary).fixedSize()
                Picker("", selection: $selectedDevice) {
                    ForEach(state.devices) { device in
                        Text(device.DeviceID).tag(Optional(device))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 170)
            }

            if !availableGenres.isEmpty {
                Text("Genre:").foregroundStyle(.secondary).fixedSize()
                Picker("", selection: $genreFilter) {
                    Text("All").tag(String?.none)
                    ForEach(availableGenres, id: \.self) { g in
                        Text(g).tag(Optional(g))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
            }

            Spacer()

            if isLoadingGuide { ProgressView().scaleEffect(0.7) }
            Button { snapToNow = true } label: {
                Label("Now", systemImage: "clock.arrow.circlepath")
            }
            Button {
                if let id = selectedDevice?.DeviceID {
                    state.guideStore.invalidate(deviceId: id)
                }
                refreshToken = UUID()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isLoadingGuide)
            Text("[\(allChannels.count) ch]").font(.caption2).foregroundStyle(.orange)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: - Summary panel

    @ViewBuilder
    private var summaryPanel: some View {
        if let entry = selectedEntry {
            let onAir  = entry.startDate <= Date() && entry.endDate > Date()
            let bgColor = guideEntryColor(for: entry, onAir: onAir)
            let channelIcon = allChannels.first(where: { $0.GuideNumber == selectedChannel?.GuideNumber })?.ImageURL
            let isRecordingNow = state.recordingShows.contains { show in
                show.show_channel == selectedChannel?.GuideNumber &&
                (show.show_next ?? .distantFuture) <= Date() &&
                (show.show_end  ?? .distantPast)   >  Date()
            }
            let isSportsBonusEntry = entry.firstGenre?.lowercased().contains("sports") == true
                                  && state.config.Sports_padding_enabled
            let isManaged = managedMatcher.isManaged(entry: entry)

            ZStack(alignment: .topTrailing) {
                HStack(alignment: .top, spacing: 14) {
                    if let urlStr = entry.ImageURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
                        AsyncImage(url: url) { img in
                            img.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Color.white.opacity(0.2)
                        }
                        .accessibilityLabel("\(entry.Title) poster")
                        .frame(width: 140, height: 100)
                        .cornerRadius(7)
                        .clipped()
                        .overlay(alignment: .topTrailing) { if isManaged { ManagedFlagView() } }
                    } else {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 140, height: 100)
                            .overlay(alignment: .topTrailing) { if isManaged { ManagedFlagView() } }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.Title)
                            .font(.title3).bold()
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.4), radius: 1, x: 0, y: 1)
                        if isRecordingNow {
                            Label("Recording Now", systemImage: "record.circle.fill")
                                .font(.caption).bold()
                                .foregroundColor(.red)
                        }

                        if let genre = entry.firstGenre, genre.lowercased() != "series" {
                            Text(genre.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.white.opacity(0.20))
                                .cornerRadius(3)
                                .foregroundColor(.white.opacity(0.90))
                                .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
                        }

                        if let ep = entry.episodeInfoLabel {
                            Text(ep)
                                .font(.subheadline)
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
                        }

                        if let airdate = entry.OriginalAirdate {
                            Text("Orig. \(origAirdateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(airdate))))")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.80))
                                .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
                        }

                        if let syn = entry.Synopsis, !syn.isEmpty {
                            Text(syn)
                                .font(.callout)
                                .foregroundColor(.white)
                                .lineLimit(3)
                                .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
                        }
                        if let sid = entry.SeriesID, !sid.isEmpty {
                            let upcoming = state.upcomingGuideEpisodes(seriesID: sid)
                            if !upcoming.isEmpty {
                                let labels = upcoming.map { "Channel \($0.channel) \(upcomingFormatter.string(from: $0.entry.startDate))" }
                                Text(labels.joined(separator: "  ·  "))
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.85))
                                    .lineLimit(2)
                                    .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
                            }
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 8) {
                            ChannelIcon(urlString: channelIcon, size: 18)
                            Text("Channel \(selectedChannel?.GuideNumber ?? "?")  ·  \(guideTimeRange(entry))")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.85))
                                .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
                            Spacer()
                            if onAir,
                               state.config.Watch_in_VLC,
                               FileManager.default.fileExists(atPath: "/Applications/VLC.app") {
                                Button {
                                    state.watchInVLC(url: selectedChannel?.URL ?? "", deviceId: selectedDevice?.DeviceID)
                                } label: {
                                    Label {
                                        Text("Watch in VLC")
                                    } icon: {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: "/Applications/VLC.app"))
                                            .resizable().scaledToFit().frame(width: 16, height: 16)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .accessibilityLabel(watchInVLCLabel(entry.Title))
                                .buttonStyle(WhiteOutlineButtonStyle(borderColor: Color(red: 1.0, green: 0.482, blue: 0.0)))
                                .disabled(selectedChannel == nil)
                            }
                            if onAir, VLCBridge.shared.isAvailable {
                                Button {
                                    state.watchInApp(url: selectedChannel?.URL ?? "",
                                                     title: entry.Title,
                                                     deviceId: selectedDevice?.DeviceID)
                                } label: {
                                    Label("Watch Now!", systemImage: "play.tv.fill")
                                }
                                .accessibilityLabel(watchInAppLabel(entry.Title))
                                .buttonStyle(WhiteOutlineButtonStyle(borderColor: .blue))
                                .disabled(selectedChannel == nil)
                            }
                            // No Record button — floating guide is browse-only
                        }
                        // Overlap warning: shown when this show's start falls inside another show's bonus-time extension
                        if let device = selectedDevice,
                           let ch = selectedChannel,
                           let warning = state.bonusOverlapWarning(for: entry, channel: ch, deviceId: device.DeviceID) {
                            Text(warning)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.90))
                                .padding(.horizontal, 4)
                        }
                    }
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.black.opacity(0.28), Color.black.opacity(0.04)]),
                            startPoint: .leading, endPoint: .trailing
                        )
                        .cornerRadius(8)
                        .blendMode(.multiply)
                    )
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bgColor.opacity(0.90))
                .cornerRadius(10)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                if isSportsBonusEntry {
                    StarburstBadge(minutes: state.config.Sports_padding_minutes, size: 100)
                        .padding(.trailing, 18).padding(.top, 8)
                }
            }
        } else {
            Text("Select a show from the grid")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadGuide() async {
        guard let device = selectedDevice else { return }
        isLoadingGuide = true
        // Guarantee lineup is present before loading guide — recovers from silent startup fetch failures
        await state.ensureLineupLoaded(for: device)
        let id = device.DeviceID
        defer { isLoadingGuide = false }

        if state.guideStore.isFresh(deviceId: id) {
            allChannels = sortedGuideChannels(state.guideStore.channels(deviceId: id), favorites: Set((state.lineups[id] ?? []).filter(\.isFavorite).map(\.GuideNumber)))
            state.guideByDevice = state.guideStore.channelsByDevice
            return
        }
        if state.guideStore.isLoading(deviceId: id) {
            while state.guideStore.isLoading(deviceId: id) {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            let ch = state.guideStore.channels(deviceId: id)
            if !ch.isEmpty { allChannels = sortedGuideChannels(ch, favorites: Set((state.lineups[id] ?? []).filter(\.isFavorite).map(\.GuideNumber))); return }
        }
        state.guideStore.verbose = state.config.Verbose_curl
        await state.guideStore.load(for: device, hours: state.config.GuideHours)
        state.guideByDevice = state.guideStore.channelsByDevice
        allChannels = sortedGuideChannels(state.guideStore.channels(deviceId: id), favorites: Set((state.lineups[id] ?? []).filter(\.isFavorite).map(\.GuideNumber)))
    }
}

// Raises the host NSWindow to the floating level so the guide stays above regular windows.
private struct FloatingWindowLevelSetter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            v.window?.level = .floating
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
