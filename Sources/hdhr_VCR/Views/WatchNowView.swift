import SwiftUI
import AppKit

// MARK: ── Window ──────────────────────────────────────────────────────────────

struct WatchNowView: View {
    @EnvironmentObject var state: AppState
    @State private var selectedDeviceId: String = ""
    @State private var now = Date()
    // Poster images keyed by ImageURL — persists across refreshes so rows don't flash
    @State private var posterCache: [String: NSImage] = [:]

    // Seconds until the next :00 or :30 boundary from the given date.
    private static func nextBoundary(from date: Date = Date()) -> Date {
        let cal = Calendar.current
        let minute = cal.component(.minute, from: date)
        let second = cal.component(.second, from: date)
        let elapsed = minute * 60 + second
        let secsToNext = minute < 30 ? (30 * 60 - elapsed) : (60 * 60 - elapsed)
        return date.addingTimeInterval(TimeInterval(max(1, secsToNext)))
    }

    private var selectedDevice: HDHRDevice? {
        state.devices.first { $0.DeviceID == selectedDeviceId } ?? state.devices.first
    }

    // Returns one (channel, entry) pair per unique on-air channel.
    // Keyed by LineupEntry.id (GuideNumber) — stable, unique per channel, safe as ForEach id.
    // GuideEntry.id == StartTime — NOT safe for ForEach (many channels share a start time).
    private var onAirChannels: [(channel: LineupEntry, entry: GuideEntry)] {
        guard let device = selectedDevice else { return [] }
        return state.onAirNow(for: device, at: now)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .onAppear {
            selectedDeviceId = state.watchNowDeviceId ?? state.devices.first?.DeviceID ?? ""
        }
        .onChange(of: state.watchNowDeviceId) { _, newId in
            if let id = newId { selectedDeviceId = id }
        }
        .task(id: selectedDeviceId) { await prefetchPosters() }
        .task { await boundaryRefreshLoop() }
    }

    private static let favAmber = Color(hue: 0.13, saturation: 0.85, brightness: 0.80)

    private var favTopBorder: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Self.favAmber).frame(height: 2)
            HStack(spacing: 5) {
                Text("★  Favorites")
                    .font(.caption.bold())
                    .foregroundStyle(Self.favAmber)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(Self.favAmber.opacity(0.08))
            Rectangle().fill(Self.favAmber).frame(height: 1)
        }
    }

    private var favBottomBorder: some View {
        Rectangle().fill(Self.favAmber).frame(height: 2)
    }

    @ViewBuilder
    private func channelRow(_ pair: (channel: LineupEntry, entry: GuideEntry), device: HDHRDevice) -> some View {
        let (ch, entry) = pair
        WatchNowRow(
            device: device,
            channel: ch,
            entry: entry,
            posterImage: entry.ImageURL.flatMap { posterCache[$0] }
        )
        .task(id: entry.ImageURL) {
            guard let urlStr = entry.ImageURL,
                  posterCache[urlStr] == nil else { return }
            if let img = await ChannelIconCache.shared.image(for: urlStr) {
                posterCache[urlStr] = img
            }
        }
        Divider().padding(.leading, 14)
    }

    private func prefetchPosters() async {
        let urls = onAirChannels.compactMap { $0.entry.ImageURL }

        // Single actor hop: everything already in memory appears immediately.
        let cached = await ChannelIconCache.shared.allCachedImages(for: urls)
        posterCache.merge(cached) { existing, _ in existing }

        // Fetch any disk/network misses concurrently rather than one at a time.
        let missing = urls.filter { posterCache[$0] == nil }
        await withTaskGroup(of: (String, NSImage)?.self) { group in
            for url in missing {
                group.addTask {
                    guard let img = await ChannelIconCache.shared.image(for: url) else { return nil }
                    return (url, img)
                }
            }
            for await result in group {
                if let (url, img) = result { posterCache[url] = img }
            }
        }
    }

    // Runs until the view disappears. Keeps now fresh every 30s (so mid-half-hour show endings
    // clear promptly), pre-fetches upcoming posters before each boundary to avoid placeholder flash.
    private func boundaryRefreshLoop() async {
        while !Task.isCancelled {
            let boundary = Self.nextBoundary()
            // Sleep in 30s chunks to keep now within 30s of real time.
            while boundary.timeIntervalSinceNow > 60 {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
                now = Date()
            }
            // Pre-fetch posters for shows turning over at this boundary.
            await prefetchPostersForDate(boundary)
            let remaining = boundary.timeIntervalSinceNow
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            if Task.isCancelled { return }
            now = Date()
        }
    }

    // Pre-fetches poster images for shows airing at a future date so the cache is warm
    // before the list turns over, preventing the placeholder flash at each half-hour boundary.
    private func prefetchPostersForDate(_ date: Date) async {
        guard let device = selectedDevice else { return }
        let urls = state.onAirNow(for: device, at: date).compactMap { $0.entry.ImageURL }
        let missing = urls.filter { posterCache[$0] == nil }
        await withTaskGroup(of: (String, NSImage)?.self) { group in
            for url in missing {
                group.addTask {
                    guard let img = await ChannelIconCache.shared.image(for: url) else { return nil }
                    return (url, img)
                }
            }
            for await result in group { if let (url, img) = result { posterCache[url] = img } }
        }
    }

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.tv.fill")
                .foregroundStyle(watchNowBlue)
                .font(.title3)
                .accessibilityHidden(true)
            Text("Watch Now")
                .font(.headline)
            Spacer()
            if state.devices.count > 1 {
                Picker("Tuner", selection: $selectedDeviceId) {
                    ForEach(state.devices) { d in
                        Text(d.DeviceID).tag(d.DeviceID)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            Button { now = Date() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        let channels = onAirChannels
        if channels.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "tv.slash")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text("Nothing on right now")
                    .foregroundStyle(.secondary)
                if let device = selectedDevice, state.isGuideLoading(for: device.DeviceID) {
                    ProgressView().padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let device = selectedDevice {
            let favs   = channels.filter { $0.channel.isFavorite }
            let others = channels.filter { !$0.channel.isFavorite }

            ScrollView {
                VStack(spacing: 0) {
                    if !favs.isEmpty {
                        favTopBorder
                        ForEach(favs, id: \.channel.id) { pair in
                            channelRow(pair, device: device)
                        }
                        favBottomBorder
                    }
                    ForEach(others, id: \.channel.id) { pair in
                        channelRow(pair, device: device)
                    }
                }
            }
        }
    }
}

// MARK: ── Row card ────────────────────────────────────────────────────────────

struct WatchNowRow: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    let device: HDHRDevice
    let channel: LineupEntry
    let entry: GuideEntry
    let posterImage: NSImage?

    @State private var showTunerFullAlert = false

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()

    private var timeRange: String {
        "\(Self.timeFmt.string(from: entry.startDate)) – \(Self.timeFmt.string(from: entry.endDate))"
    }

    private var timeRemainingStr: String { timeRemaining(until: entry.endDate) }

    private var channelLogo: NSImage? {
        state.channelImageURLs["\(device.DeviceID):\(channel.GuideNumber)"]
            .flatMap { state.channelIconImages[$0] }
    }

    private var managedShow: Show? {
        if let sid = entry.SeriesID, !sid.isEmpty {
            return state.managedShowBySeriesID[sid]
        }
        // Multiple shows can share a title (e.g. "News" on different channels).
        // For series shows any match by title is correct; for single-slot shows
        // narrow to the specific device+channel so the wrong entry doesn't win.
        return state.managedShowByTitle[entry.Title]?.first {
            $0.isSeries || ($0.hdhr_record == device.DeviceID && $0.show_channel == channel.GuideNumber)
        }
    }

    var body: some View {
        let managed = managedShow
        let scheduled: Bool = {
            guard let show = managed else { return false }
            if show.isSeries { return true }
            // Guard explicitly — ?? -1 would spuriously match a guide entry with StartTime == -1.
            guard let nextDate = show.show_next else { return false }
            return show.hdhr_record  == device.DeviceID
                && show.show_channel == channel.GuideNumber
                && Int(nextDate.timeIntervalSince1970) == entry.StartTime
        }()
        HStack(alignment: .top, spacing: 10) {
            posterThumb(isScheduled: scheduled)
            infoColumn(managed: managed, isScheduled: scheduled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("All Tuners Busy", isPresented: $showTunerFullAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            let count = device.TunerCount.map { "\($0)" } ?? "all"
            Text("\(entry.Title) is on now, but \(count) tuner(s) on \(device.DeviceID) are occupied. Free a tuner first, then add this show.")
        }
    }

    @ViewBuilder
    private func posterThumb(isScheduled: Bool) -> some View {
        ZStack {
            guideEntryColor(for: entry, onAir: true).opacity(0.55)
            if let img = posterImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "tv")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .containerRelativeFrame(.horizontal) { w, _ in min(w * 0.34, 220) }
        .aspectRatio(96.0/68.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
        .overlay(alignment: .topTrailing) {
            if isScheduled { ManagedFlagView(size: 18) }
        }
    }

    @ViewBuilder
    private func infoColumn(managed: Show?, isScheduled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let logo = channelLogo {
                    Image(nsImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                }
                Text("ch \(channel.GuideNumber)  \(channel.GuideName)\(channel.HD == 1 ? " HD" : "")")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                if state.config.Signal_quality_enabled {
                    // guideName makes the bars tappable for a signal-stats popover (window-only).
                    SignalBarsView(bucket: signalBucket(guideName: channel.GuideName),
                                   guideName: channel.GuideName)
                }
                if managed?.show_recording == true {
                    Spacer(minLength: 6)
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption.bold())
                        .accessibilityHidden(true)
                    Text("Recording")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
            }
            HStack(spacing: 4) {
                Text(entry.Title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                    .accessibilityLabel(isScheduled ? "\(entry.Title), scheduled" : entry.Title)
                if isNewEpisode(entry) {
                    Text("NEW")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color(red: 0.18, green: 0.65, blue: 0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .accessibilityLabel("New episode")
                }
            }
            if let sub = entry.episodeInfoLabel {
                Text(sub)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text("\(timeRange)  ·  \(timeRemainingStr)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            actionRow(managed: managed)
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func actionRow(managed: Show?) -> some View {
        HStack(spacing: 6) {
            if VLCBridge.shared.isAvailable {
                Button {
                    state.watchInApp(url: channel.URL ?? "", title: entry.Title, deviceId: device.DeviceID,
                                     guideNumber: channel.GuideNumber)
                } label: {
                    Label("Watch", systemImage: "play.tv.fill").font(.caption.bold())
                }
                .accessibilityLabel(watchInAppLabel(entry.Title))
                .buttonStyle(.borderedProminent)
                .tint(watchNowBlue)
                .controlSize(.small)
            }
            if state.config.Watch_in_VLC {
                Button {
                    state.watchInVLC(url: channel.URL ?? "", deviceId: device.DeviceID)
                } label: {
                    Label("VLC", systemImage: "arrow.up.forward.app").font(.caption.bold())
                }
                .accessibilityLabel(watchInVLCLabel(entry.Title))
                .buttonStyle(.borderedProminent)
                .tint(watchNowOrange)
                .controlSize(.small)
            }
            if let show = managed {
                Button {
                    state.editingShowId = show.show_id
                    NSApp.activate(ignoringOtherApps: true)
                    if let w = NSApp.windows.first(where: { $0.title == "Edit Show" }) {
                        w.makeKeyAndOrderFront(nil)
                    } else {
                        openWindow(id: "edit-show")
                    }
                } label: {
                    Label("Edit", systemImage: "pencil").font(.caption.bold())
                }
                .accessibilityLabel("Edit \(entry.Title)")
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button {
                    if state.tunersFull(for: device.DeviceID) {
                        showTunerFullAlert = true
                    } else {
                        state.pendingAddEntry = (device, channel, entry)
                        state.pendingAddEntryGeneration += 1
                        NSApp.activate(ignoringOtherApps: true)
                        if let w = NSApp.windows.first(where: { $0.title == "Add Show" }) {
                            w.makeKeyAndOrderFront(nil)
                        } else {
                            openWindow(id: "add-show")
                        }
                    }
                } label: {
                    Label("Record", systemImage: "record.circle").font(.caption.bold())
                }
                .accessibilityLabel("Record \(entry.Title)")
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            }
        }
    }
}
