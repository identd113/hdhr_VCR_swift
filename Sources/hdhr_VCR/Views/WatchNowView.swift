import SwiftUI
import AppKit

private let watchNowBlue   = Color(red: 0.2, green: 0.6, blue: 1.0)
private let watchNowOrange = Color(red: 1.0, green: 0.482, blue: 0.0)

// MARK: ── Window ──────────────────────────────────────────────────────────────

struct WatchNowView: View {
    @EnvironmentObject var state: AppState
    @State private var selectedDeviceId: String = ""
    @State private var now = Date()
    // Poster images keyed by ImageURL — persists across refreshes so rows don't flash
    @State private var posterCache: [String: NSImage] = [:]

    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var selectedDevice: HDHRDevice? {
        state.devices.first { $0.DeviceID == selectedDeviceId } ?? state.devices.first
    }

    // Returns one LineupEntry per unique on-air channel.
    // LineupEntry.id == GuideNumber — stable, unique per channel, safe as ForEach id.
    // GuideEntry.id == StartTime — NOT safe for ForEach (many channels share a start time).
    private var onAirChannels: [LineupEntry] {
        guard let device = selectedDevice else { return [] }
        var seen = Set<String>()
        return (state.lineups[device.DeviceID] ?? [])
            .filter { ch in
                // Keep first occurrence per GuideNumber to strip lineup duplicates
                guard seen.insert(ch.GuideNumber).inserted else { return false }
                // Only include channels with a currently-airing show
                return state.guideEntries(deviceId: device.DeviceID, channelNum: ch.GuideNumber)
                    .contains { $0.startDate <= now && $0.endDate > now }
            }
            .sorted { a, b in
                if a.isFavorite != b.isFavorite { return a.isFavorite }
                return a.GuideNumber.channelSortKey < b.GuideNumber.channelSortKey
            }
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
        .onReceive(refreshTimer) { t in now = t }
        .task(id: selectedDeviceId) { await prefetchPosters() }
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
    private func channelRow(_ ch: LineupEntry, device: HDHRDevice, snap: Date) -> some View {
        let entry = state.guideEntries(deviceId: device.DeviceID, channelNum: ch.GuideNumber)
            .first { $0.startDate <= snap && $0.endDate > snap }
        if let entry {
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
    }

    private func prefetchPosters() async {
        guard let device = selectedDevice else { return }
        let snap = now
        for ch in onAirChannels {
            guard let urlStr = state.guideEntries(deviceId: device.DeviceID, channelNum: ch.GuideNumber)
                .first(where: { $0.startDate <= snap && $0.endDate > snap })?.ImageURL,
                  posterCache[urlStr] == nil
            else { continue }
            if let img = await ChannelIconCache.shared.image(for: urlStr) {
                posterCache[urlStr] = img
            }
        }
    }

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.tv.fill")
                .foregroundStyle(watchNowBlue)
                .font(.title3)
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
                Text("Nothing on right now")
                    .foregroundStyle(.secondary)
                if let device = selectedDevice, state.isGuideLoading(for: device.DeviceID) {
                    ProgressView().padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let device = selectedDevice {
            let snap   = now
            let favs   = channels.filter(\.isFavorite)
            let others = channels.filter { !$0.isFavorite }

            ScrollView {
                VStack(spacing: 0) {
                    if !favs.isEmpty {
                        favTopBorder
                        ForEach(favs) { ch in
                            channelRow(ch, device: device, snap: snap)
                        }
                        favBottomBorder
                    }
                    ForEach(others) { ch in
                        channelRow(ch, device: device, snap: snap)
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

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()

    private var timeRange: String {
        "\(Self.timeFmt.string(from: entry.startDate)) – \(Self.timeFmt.string(from: entry.endDate))"
    }

    private var timeRemaining: String {
        let mins = Int(max(0, entry.endDate.timeIntervalSinceNow) / 60)
        if mins < 1  { return "ending soon" }
        if mins < 60 { return "\(mins)m left" }
        let h = mins / 60; let m = mins % 60
        return m == 0 ? "\(h)h left" : "\(h)h \(m)m left"
    }

    private var episodeSubtitle: String? {
        switch (entry.EpisodeNumber, entry.EpisodeTitle) {
        case (let n?, let t?): return "\(n)  \(t)"
        case (let n?, nil):    return n
        case (nil, let t?):    return t
        case (nil, nil):       return nil
        }
    }

    private var channelLogo: NSImage? {
        state.channelImageURLs["\(device.DeviceID):\(channel.GuideNumber)"]
            .flatMap { state.channelIconImages[$0] }
    }

    private var managedShow: Show? {
        if let sid = entry.SeriesID, !sid.isEmpty {
            return state.managedShowBySeriesID[sid]
        }
        return state.managedShowByTitle[entry.Title]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            posterThumb
            infoColumn
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var posterThumb: some View {
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
        .frame(width: 96, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topTrailing) {
            if managedShow != nil {
                Path { p in
                    p.move(to:    CGPoint(x: 0,  y: 0))
                    p.addLine(to: CGPoint(x: 18, y: 0))
                    p.addLine(to: CGPoint(x: 18, y: 18))
                    p.closeSubpath()
                }
                .fill(Color.yellow)
                .frame(width: 18, height: 18)
            }
        }
    }

    @ViewBuilder
    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let logo = channelLogo {
                    Image(nsImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                }
                Text("ch \(channel.GuideNumber)  \(channel.GuideName)\(channel.HD == 1 ? " HD" : "")")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                if managedShow?.show_recording == true {
                    Spacer(minLength: 6)
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption.bold())
                    Text("Recording")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
            }
            Text(entry.Title)
                .font(.subheadline.bold())
                .lineLimit(1)
            if let sub = episodeSubtitle {
                Text(sub)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text("\(timeRange)  ·  \(timeRemaining)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            actionRow
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 6) {
            if VLCBridge.shared.isAvailable {
                Button {
                    state.watchInApp(url: channel.URL ?? "", title: entry.Title, deviceId: device.DeviceID)
                } label: {
                    Label("Watch", systemImage: "play.tv.fill").font(.caption.bold())
                }
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
                .buttonStyle(.bordered)
                .tint(watchNowOrange)
                .controlSize(.small)
            }
            if let show = managedShow {
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
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button {
                    state.pendingAddEntry = (device, channel, entry)
                    state.pendingAddEntryGeneration += 1
                    DispatchQueue.main.async {
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
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
            }
        }
    }
}
