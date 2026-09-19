import SwiftUI

// Compact picker for starting a Picture-in-Picture (corner-thumbnail) stream — reachable via
// VLCPlayerView's right-click context menu on the main video pane (the player window must already
// be open; there's no menu-bar entry point, removed 2026-09-19 as redundant with this one). Always
// starts fresh (no remembered source): lists shows currently recording, any discovered FEED
// (another Mac's in-progress recording) sources, and live-TV channels across recordable tuners, in
// that order — recording first since it's the most likely thing someone wants alongside whatever
// they're already watching, then FEED, then Live TV (itself favorites-first, then the rest, via
// AppState.allChannels — unchanged). Each row's action lands on AppState.watchAsSecondary/
// watchRemoteRelayAsSecondary/watchRecordingInAppAsSecondary — the same PIP slot WatchNowView's
// per-row "Watch alongside (PiP)" buttons already use. AppState.watchAsSecondary's
// ensureWindowForStandalonePiP branch still matters here even with the window already open — the
// primary can be open but idle/errored (hasPlayablePrimarySession false), not just literally absent.
// Whatever's already playing as the PRIMARY stream shows dimmed and unselectable (a "Now Playing"
// label instead of the Add button) rather than offering to add itself alongside itself — see
// pipActionTrailing(label:isCurrent:action:) and each row's own isCurrent check.
struct PiPPickerView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDeviceId: String = ""

    private var selectedDevice: HDHRDevice? {
        state.recordableDevices.first { $0.DeviceID == selectedDeviceId }
            ?? state.recordableDevices.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                recordingSection
                feedSection
                liveTVSection
            }
            .listStyle(.inset)
        }
        .onAppear {
            selectedDeviceId = state.recordableDevices.first?.DeviceID ?? ""
        }
        .frame(minWidth: 380, minHeight: 300)
    }

    // Shared trailing control for every row below — either the normal "Add as PIP" button, or, when
    // this row is what's already playing as the primary stream, a plain "Now Playing" label in its
    // place (no button at all, so it can't be re-selected).
    @ViewBuilder
    private func pipActionTrailing(label: String, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        if isCurrent {
            Text("Now Playing")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let vlcReady = VLCBridge.shared.isAvailable
            Button {
                action()
                dismiss()
            } label: {
                Label(gatedLabel("Add as PIP", met: vlcReady, requirement: "VLC"), systemImage: "pip.fill")
            }
            .accessibilityLabel(gatedLabel(watchAlongsideLabel(label), met: vlcReady, requirement: "VLC"))
            // Shared across every row (Recording Now/FEED/Live TV alike) — deliberately not
            // per-row-unique, since which specific show/channel is offered is live, real device
            // state a UI test has no control over (see WindowNavigationTests.swift's
            // vlcPlayerControlsAreAccessible doc comment for the same reasoning/precedent: an
            // explicit AXIdentifier is materially more robust than matching on help/label text,
            // which this button doesn't even carry). A test picks "the first one" to exercise the
            // add-as-PIP flow without needing to hardcode a specific channel name.
            .accessibilityIdentifier("pip-picker-add-button")
            .buttonStyle(.bordered)
            .tint(vlcReady ? watchNowBlue : .gray)
            .controlSize(.small)
            .disabled(!vlcReady)
        }
    }

    @ViewBuilder
    private var recordingSection: some View {
        let shows = state.recordingShows
        if !shows.isEmpty {
            Section("Recording Now") {
                ForEach(shows, id: \.show_id) { show in
                    recordingRow(show)
                }
            }
        }
    }

    /// Pure decisions, extracted for unit testing — see each row's own call site for context.
    nonisolated static func isCurrentRecording(recordingShowId: String?, showId: String) -> Bool {
        recordingShowId == showId
    }
    nonisolated static func isCurrentLiveChannel(currentDeviceID: String?, currentChannelNumber: String?,
                                                  targetDeviceID: String, targetChannelNumber: String) -> Bool {
        currentDeviceID == targetDeviceID && currentChannelNumber == targetChannelNumber
    }
    nonisolated static func isCurrentFeed(currentFeedRemoteURL: String?, entryURL: String?) -> Bool {
        // Explicit nil guards, not a bare `==` — two nils are NOT "the same feed": nil
        // currentFeedRemoteURL means no FEED is playing at all, and a row with a nil entryURL
        // (a malformed/incomplete lineup entry) has nothing to do with it. Found while writing
        // this function's own unit tests 2026-09-19 — a bare `currentFeedRemoteURL == entryURL`
        // would have made that row incorrectly read as "currently playing."
        guard let currentFeedRemoteURL, let entryURL else { return false }
        return currentFeedRemoteURL == entryURL
    }

    private func recordingRow(_ show: Show) -> some View {
        let isCurrent = Self.isCurrentRecording(recordingShowId: VLCBridge.shared.recordingShowId, showId: show.show_id)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(show.show_title).font(.subheadline.bold())
                Text("Ch \(show.show_channel)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            pipActionTrailing(label: show.show_title, isCurrent: isCurrent) {
                state.watchRecordingInAppAsSecondary(show)
            }
        }
        .padding(.vertical, 2)
        .opacity(isCurrent ? 0.4 : 1.0)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "pip.fill")
                .foregroundStyle(watchNowBlue)
                .font(.title3)
                .accessibilityHidden(true)
            Text("Add Picture-in-Picture")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var liveTVSection: some View {
        Section("Live TV") {
            if state.recordableDevices.isEmpty {
                Text("No tuners available").foregroundStyle(.secondary)
            } else {
                if state.recordableDevices.count > 1 {
                    Picker("Tuner", selection: $selectedDeviceId) {
                        ForEach(state.recordableDevices) { d in
                            Text(d.DeviceID).tag(d.DeviceID)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                if let device = selectedDevice {
                    let channels = state.allChannels(for: device, at: Date())
                    if channels.isEmpty {
                        Text("No channels available").foregroundStyle(.secondary)
                    } else {
                        // allChannels() is already favorites-first — split rather than resort, and
                        // label the favorites the same way every other favorite grouping in the app
                        // does (WatchNowView's favTopBorder, the web Guide's ★ FAVORITES separator,
                        // VLCPlayerView's own toolbar channel picker) rather than leaving them as an
                        // unlabeled top block indistinguishable from "the rest."
                        let favorites = channels.filter { $0.channel.isFavorite }
                        let others = channels.filter { !$0.channel.isFavorite }
                        if !favorites.isEmpty {
                            // Full-bleed edge to edge, matching WatchNowView's own favTopBorder —
                            // List's default row insets would otherwise double up with the amber
                            // band's own built-in horizontal padding.
                            favTopBorder.listRowInsets(EdgeInsets())
                        }
                        ForEach(favorites, id: \.channel.id) { pair in
                            liveChannelRow(pair, device: device)
                                // Matches the web guide's .g-row[data-fav="1"] row wash — the
                                // divider alone only marks where the group starts, not which rows
                                // are actually in it once you're scrolled past the header.
                                .listRowBackground(favAmber.opacity(0.16))
                        }
                        ForEach(others, id: \.channel.id) { pair in
                            liveChannelRow(pair, device: device)
                        }
                    }
                }
            }
        }
    }

    private func liveChannelRow(_ pair: (channel: LineupEntry, entry: GuideEntry?), device: HDHRDevice) -> some View {
        let title = pair.entry?.Title ?? pair.channel.GuideName
        let isCurrent = Self.isCurrentLiveChannel(currentDeviceID: VLCPlayerWindowManager.shared.currentDeviceID,
                                                   currentChannelNumber: VLCPlayerWindowManager.shared.currentChannelNumber,
                                                   targetDeviceID: device.DeviceID, targetChannelNumber: pair.channel.GuideNumber)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ch \(pair.channel.GuideNumber)  \(pair.channel.GuideName)")
                    .font(.subheadline.bold())
                if let entry = pair.entry {
                    Text(entry.Title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            pipActionTrailing(label: title, isCurrent: isCurrent) {
                state.watchAsSecondary(url: pair.channel.URL ?? "", title: title, device: device,
                                        channelNumber: pair.channel.GuideNumber)
            }
        }
        .padding(.vertical, 2)
        .opacity(isCurrent ? 0.4 : 1.0)
    }

    @ViewBuilder
    private var feedSection: some View {
        let entries = state.remoteRelayEntries
        if !entries.isEmpty {
            Section("Recording on Another Mac (FEED)") {
                ForEach(entries, id: \.entry.URL) { pair in
                    feedRow(pair)
                }
            }
        }
    }

    private func feedRow(_ pair: (device: HDHRDevice, entry: LineupEntry)) -> some View {
        let title = pair.entry.virtualRelayShowTitle ?? pair.entry.GuideName
        let isCurrent = Self.isCurrentFeed(currentFeedRemoteURL: VLCPlayerWindowManager.shared.currentFeedRemoteURL,
                                           entryURL: pair.entry.URL)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                if let hostname = pair.entry.virtualRelaySourceHostname {
                    Text("\(title) — \(hostname)").font(.subheadline.bold())
                } else {
                    Text(title).font(.subheadline.bold())
                }
            }
            Spacer()
            pipActionTrailing(label: title, isCurrent: isCurrent) {
                state.watchRemoteRelayAsSecondary(url: pair.entry.URL ?? "", title: title, device: pair.device)
            }
        }
        .padding(.vertical, 2)
        .opacity(isCurrent ? 0.4 : 1.0)
    }
}
