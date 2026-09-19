import SwiftUI

// Compact picker for starting a Picture-in-Picture (corner-thumbnail) stream — reachable both from
// MenuContent's "Add Picture-in-Picture…" button and from VLCPlayerView's right-click context menu
// on the main video pane. Always starts fresh (no remembered source): lists live-TV channels across
// recordable tuners and any discovered FEED (another Mac's in-progress recording) sources, each with
// a button that lands on AppState.watchAsSecondary/watchRemoteRelayAsSecondary — the same PIP slot
// WatchNowView's per-row "Watch alongside (PiP)" buttons already use. Unlike those, this works with
// no primary session open yet (see AppState.watchAsSecondary's ensureWindowForStandalonePiP branch).
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
                liveTVSection
                feedSection
            }
            .listStyle(.inset)
        }
        .onAppear {
            selectedDeviceId = state.recordableDevices.first?.DeviceID ?? ""
        }
        .frame(minWidth: 380, minHeight: 300)
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
                        ForEach(channels, id: \.channel.id) { pair in
                            liveChannelRow(pair, device: device)
                        }
                    }
                }
            }
        }
    }

    private func liveChannelRow(_ pair: (channel: LineupEntry, entry: GuideEntry?), device: HDHRDevice) -> some View {
        let vlcReady = VLCBridge.shared.isAvailable
        let title = pair.entry?.Title ?? pair.channel.GuideName
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
            Button {
                state.watchAsSecondary(url: pair.channel.URL ?? "", title: title, device: device,
                                        channelNumber: pair.channel.GuideNumber)
                dismiss()
            } label: {
                Label(gatedLabel("Add as PIP", met: vlcReady, requirement: "VLC"), systemImage: "pip.fill")
            }
            .accessibilityLabel(gatedLabel(watchAlongsideLabel(title), met: vlcReady, requirement: "VLC"))
            .buttonStyle(.bordered)
            .tint(vlcReady ? watchNowBlue : .gray)
            .controlSize(.small)
            .disabled(!vlcReady)
        }
        .padding(.vertical, 2)
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
        let vlcReady = VLCBridge.shared.isAvailable
        let title = pair.entry.virtualRelayShowTitle ?? pair.entry.GuideName
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                if let hostname = pair.entry.virtualRelaySourceHostname {
                    Text("\(title) — \(hostname)").font(.subheadline.bold())
                } else {
                    Text(title).font(.subheadline.bold())
                }
            }
            Spacer()
            Button {
                state.watchRemoteRelayAsSecondary(url: pair.entry.URL ?? "", title: title, device: pair.device)
                dismiss()
            } label: {
                Label(gatedLabel("Add as PIP", met: vlcReady, requirement: "VLC"), systemImage: "pip.fill")
            }
            .accessibilityLabel(gatedLabel(watchAlongsideLabel(title), met: vlcReady, requirement: "VLC"))
            .buttonStyle(.bordered)
            .tint(vlcReady ? watchNowBlue : .gray)
            .controlSize(.small)
            .disabled(!vlcReady)
        }
        .padding(.vertical, 2)
    }
}
