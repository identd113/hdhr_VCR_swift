import SwiftUI
import AppKit

// ── VLCVideoSurface ───────────────────────────────────────────────────────────
// Zero-overhead NSView that VLC renders video into.
// We call setDrawable() on the bridge (not updateNSView) so VLC keeps the view
// reference across channel switches — VLC holds a weak NSObject reference internally.

private struct VLCVideoSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        VLCBridge.shared.setDrawable(v)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// ── VLCPlayerView ─────────────────────────────────────────────────────────────
// SwiftUI content for the VLC player window.
// Hosted in an NSHostingView inside VLCPlayerWindowManager's NSWindow.

struct VLCPlayerView: View {
    @EnvironmentObject var state: AppState

    // The device whose lineup populates the channel picker.
    // Fixed at window-open time — no device switching in the player toolbar.
    let device: HDHRDevice
    // Stream URL active when the window opened; used to pre-select the channel picker.
    let initialURL: String

    @State private var selectedChannel: LineupEntry?
    @State private var volume: Double = 50
    @State private var audioOutputs: [(name: String, description: String)] = []
    @State private var selectedOutput: String = ""
    @State private var audioDevices: [(id: String, name: String)] = []
    @State private var selectedDevice: String = ""

    private var lineup: [LineupEntry] {
        (state.lineups[device.DeviceID] ?? []).sorted {
            $0.GuideNumber.localizedStandardCompare($1.GuideNumber) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            VLCVideoSurface()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            volume = Double(VLCBridge.shared.volume())
            audioOutputs = VLCBridge.shared.audioOutputs()
            if selectedOutput.isEmpty, let first = audioOutputs.first {
                selectedOutput = first.name
            }
            refreshAudioDevices()
            // Pre-select the channel matching the URL that was playing when the window opened.
            // Strip query params so "http://.../auto/v5.1?transcode=heavy" matches "http://.../auto/v5.1".
            if selectedChannel == nil, !initialURL.isEmpty {
                let baseURL = initialURL.components(separatedBy: "?").first ?? initialURL
                selectedChannel = lineup.first { ($0.URL ?? "").hasPrefix(baseURL) || baseURL.hasPrefix($0.URL ?? "") }
            }
        }
        .onDisappear {
            VLCBridge.shared.stop()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            // Channel picker — sorted by guide number
            Picker("Channel", selection: $selectedChannel) {
                ForEach(lineup, id: \.GuideNumber) { ch in
                    Text("\(ch.GuideNumber)  \(ch.GuideName)").tag(Optional(ch))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .onChange(of: selectedChannel) { _, ch in
                if let ch { playChannel(ch) }
            }

            Spacer()

            // Volume
            Image(systemName: "speaker.wave.2")
                .foregroundStyle(.secondary)
            Slider(value: $volume, in: 0...100)
                .frame(width: 100)
                .onChange(of: volume) { _, v in
                    VLCBridge.shared.setVolume(Int(v))
                }

            // Audio output picker (e.g. auhal / display)
            if !audioOutputs.isEmpty {
                Divider().frame(height: 18)
                Picker("Output", selection: $selectedOutput) {
                    ForEach(audioOutputs, id: \.name) { out in
                        Text(out.description).tag(out.name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 150)
                .onChange(of: selectedOutput) { _, name in
                    VLCBridge.shared.setAudioOutput(name)
                    refreshAudioDevices()
                }
            }

            // Audio device picker (e.g. Built-in Speakers, AirPods)
            // Only shown when there are multiple devices to choose from.
            if audioDevices.count > 1 {
                Picker("Device", selection: $selectedDevice) {
                    ForEach(audioDevices, id: \.id) { dev in
                        Text(dev.name).tag(dev.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
                .onChange(of: selectedDevice) { _, devId in
                    VLCBridge.shared.setAudioDevice(output: selectedOutput, deviceId: devId)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Helpers

    private func playChannel(_ ch: LineupEntry) {
        guard let rawURL = ch.URL, !rawURL.isEmpty else { return }
        let transcode = state.config.Default_transcode.lowercased()
        // VLC handles MPEG-2 natively — no forced transcode; "none" = raw stream
        let url = (transcode.isEmpty || transcode == "none")
            ? rawURL
            : "\(rawURL)?transcode=\(transcode)"
        VLCBridge.shared.play(url: url)
    }

    private func refreshAudioDevices() {
        audioDevices = VLCBridge.shared.audioDevices(forOutput: selectedOutput)
        if !audioDevices.isEmpty, !audioDevices.contains(where: { $0.id == selectedDevice }) {
            selectedDevice = audioDevices[0].id
        }
    }
}

// ── VLCPlayerWindowManager ────────────────────────────────────────────────────
// Singleton NSWindow manager. Keeps one reusable window alive (isReleasedWhenClosed
// = false) so re-opening doesn't create a second window.

@MainActor
final class VLCPlayerWindowManager {
    static let shared = VLCPlayerWindowManager()
    private var window: NSWindow?

    private init() {}

    /// Open (or bring forward) the player window and start playing url on device.
    /// If the window is already showing, the stream is switched immediately.
    func open(url: String, title: String, device: HDHRDevice, appState: AppState) {
        // Always start/switch the stream first
        VLCBridge.shared.play(url: url)

        if let win = window {
            win.title = title
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let playerView = VLCPlayerView(device: device, initialURL: url)
            .environmentObject(appState)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = title
        win.contentView = NSHostingView(rootView: playerView)
        win.isReleasedWhenClosed = false   // retain for reuse on next open()
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }
}
