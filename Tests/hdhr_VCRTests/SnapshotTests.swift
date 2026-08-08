import Testing
import SwiftUI
import AppKit
@testable import hdhr_VCR

// Visual regression tests: render views to PNG and compare against stored references.
//
// On first run each test fails and saves a reference to __Snapshots__/ — commit
// those PNGs and re-run. From then on, any visual change (text, color, layout)
// that shifts >2% of pixels causes a test failure.
//
// To regenerate all references: RECORD_SNAPSHOTS=1 swift test

@Suite("UI Snapshots")
struct SnapshotTests {

    // ─── StarburstShape ───────────────────────────────────────────────────────
    // Tests the starburst star shape and its badge text. Excludes the keyframe
    // animation (which starts hidden), so we render the underlying shape directly.

    @Test("StarburstShape — badge appearance")
    @MainActor func starburstShape() {
        let view = StarburstShape()
            .fill(Color.orange)
            .frame(width: 100, height: 100)
            .overlay(Text("+15 min").font(.caption).bold().foregroundColor(.white))
            .padding(10)
            .background(Color.black)
        assertSnapshot(view, named: "StarburstShape", size: CGSize(width: 120, height: 120))
    }

    // ─── SettingsView ─────────────────────────────────────────────────────────
    // NavigationSplitView with General pane selected (the default).
    // onAppear (resetDrafts) won't fire in ImageRenderer so fields show AppConfig defaults.

    @Test("SettingsView — General pane")
    @MainActor func settingsGeneral() {
        let state = makeTestAppState()
        let view = SettingsView()
            .environmentObject(state)
        // SettingsView's frame is 560×520 (set inside the view itself)
        assertSnapshot(view, named: "SettingsView_General", size: CGSize(width: 600, height: 560))
    }

    // ─── WatchNowView ─────────────────────────────────────────────────────────

    @Test("WatchNowView — empty state (no devices)")
    @MainActor func watchNowEmpty() {
        let state = makeTestAppState()
        let view = WatchNowView()
            .environmentObject(state)
        assertSnapshot(view, named: "WatchNowView_empty", size: CGSize(width: 900, height: 600))
    }

    @Test("WatchNowView — device present, no guide data")
    @MainActor func watchNowWithDevice() {
        let device = HDHRDevice.test()
        let state = makeTestAppState(
            devices: [device],
            lineups: ["FFFFFFFF": [
                .test(number: "2.1", name: "KFOO", favorite: true),
                .test(number: "5.1", name: "KBAR"),
                .test(number: "7.1", name: "KBAZ"),
            ]]
        )
        let view = WatchNowView()
            .environmentObject(state)
        assertSnapshot(view, named: "WatchNowView_withDevice", size: CGSize(width: 900, height: 600))
    }

    // ─── MenuContent ──────────────────────────────────────────────────────────
    // MenuContent is designed for .menu-style MenuBarExtra; its body returns a
    // flat collection of buttons/text/dividers. Wrapping it in a VStack lets
    // ImageRenderer render the hierarchy as a column of views rather than a real
    // macOS menu. The output won't match the dropdown's exact appearance, but
    // changes to text content, item count, or colors still shift pixels and fail.

    @Test("MenuContent — idle (starting up, no devices)")
    @MainActor func menuContentIdle() {
        let state = makeTestAppState()
        state.isStartingUp = true
        state.statusMessage = "Discovering devices…"
        let view = menuContentWrapped(state)
        assertSnapshot(view, named: "MenuContent_idle", size: CGSize(width: 300, height: 300))
    }

    @Test("MenuContent — ready with scheduled and paused shows")
    @MainActor func menuContentWithShows() {
        let device = HDHRDevice.test()
        let state = makeTestAppState(
            shows: [.testActive(), .testActive(title: "PBS NewsHour", channel: "11.1"), .testPaused()],
            devices: [device],
            lineups: ["FFFFFFFF": [.test()]]
        )
        let view = menuContentWrapped(state)
        assertSnapshot(view, named: "MenuContent_withShows", size: CGSize(width: 300, height: 500))
    }

    @Test("MenuContent — recording in progress")
    @MainActor func menuContentRecording() {
        let device = HDHRDevice.test()
        let state = makeTestAppState(
            shows: [.testRecording(), .testActive()],
            devices: [device],
            lineups: ["FFFFFFFF": [.test()]]
        )
        let view = menuContentWrapped(state)
        assertSnapshot(view, named: "MenuContent_recording", size: CGSize(width: 300, height: 400))
    }

    @Test("MenuContent — inactive shows only")
    @MainActor func menuContentInactive() {
        let device = HDHRDevice.test()
        let state = makeTestAppState(
            shows: [.testInactive(), .testInactive(title: "Morning Edition")],
            devices: [device],
            lineups: ["FFFFFFFF": [.test()]]
        )
        let view = menuContentWrapped(state)
        assertSnapshot(view, named: "MenuContent_inactive", size: CGSize(width: 300, height: 350))
    }

    // ─── AddShowView ──────────────────────────────────────────────────────────
    // Step defaults to .guide. onAppear sets selectedDevice = state.devices.first
    // and kicks off guide loading (async), so the guide pane starts empty.

    @Test("AddShowView — guide step (no guide loaded)")
    @MainActor func addShowViewGuideStep() {
        let device = HDHRDevice.test()
        let state = makeTestAppState(devices: [device], lineups: ["FFFFFFFF": [.test()]])
        let view = AddShowView()
            .environmentObject(state)
        // Frame matches AddShowView's guide-step minWidth/minHeight
        assertSnapshot(view, named: "AddShowView_guideStep", size: CGSize(width: 1100, height: 720))
    }

    // ─── EditShowView ─────────────────────────────────────────────────────────
    // loadShow() runs in onAppear (not fired by ImageRenderer), so show == nil
    // and the view renders its ProgressView("Loading…") placeholder.

    @Test("EditShowView — loading state")
    @MainActor func editShowViewLoading() {
        let state = makeTestAppState(shows: [.testActive()])
        state.editingShowId = state.shows.first?.show_id
        let view = EditShowView()
            .environmentObject(state)
        assertSnapshot(view, named: "EditShowView_loading", size: CGSize(width: 480, height: 520))
    }

    // ─── ShowFormSection ──────────────────────────────────────────────────────
    // Tests the shared form fields (used by both AddShowView and EditShowView).
    // Rendered standalone in a Form so LabeledContent rows lay out correctly.

    @Test("ShowFormSection — Single show type")
    @MainActor func showFormSectionSingle() {
        let state = makeTestAppState()
        let view = ShowFormSectionPreview(
            showTitle: "The Tonight Show",
            seriesType: .single,
            airDays: ["Friday"]
        )
        .environmentObject(state)
        assertSnapshot(view, named: "ShowFormSection_single", size: CGSize(width: 500, height: 420))
    }

    @Test("ShowFormSection — Series (channel) type")
    @MainActor func showFormSectionSeries() {
        let state = makeTestAppState()
        let view = ShowFormSectionPreview(
            showTitle: "NCIS",
            seriesType: .seriesChannel,
            airDays: []
        )
        .environmentObject(state)
        assertSnapshot(view, named: "ShowFormSection_series", size: CGSize(width: 500, height: 380))
    }

    // ─── VLCPlayerView ────────────────────────────────────────────────────────
    // The video surface (NSViewRepresentable) renders as a black NSView — no VLC
    // needed. onAppear hooks (audio device discovery, Now Playing setup) don't fire.
    // Captures the toolbar and player chrome layout.

    @Test("VLCPlayerView — toolbar and empty player")
    @MainActor func vlcPlayerView() {
        let device = HDHRDevice.test()
        let state = makeTestAppState(
            devices: [device],
            lineups: ["FFFFFFFF": [
                .test(number: "2.1", name: "KFOO"),
                .test(number: "5.1", name: "KBAR"),
            ]]
        )
        let view = VLCPlayerView(device: device, initialURL: "")
            .environmentObject(state)
        assertSnapshot(view, named: "VLCPlayerView", size: CGSize(width: 960, height: 540))
    }
}

// MARK: - Helpers

// Wraps MenuContent in a fixed-width VStack with a window background for ImageRenderer.
@MainActor
private func menuContentWrapped(_ state: AppState) -> some View {
    VStack(alignment: .leading, spacing: 0) {
        MenuContent()
    }
    .environmentObject(state)
    .frame(width: 300)
    .background(Color(NSColor.windowBackgroundColor))
}

// MARK: - @Binding wrapper views
// ImageRenderer can't carry @State across a function boundary, so views that
// need @Binding parameters get a private wrapper struct with @State fields.

// Drives ShowFormSection with @State + @EnvironmentObject for the form fields.
private struct ShowFormSectionPreview: View {
    @EnvironmentObject var state: AppState

    let showTitle: String
    let seriesType: ShowState
    let airDays: Set<String>

    @State private var show: Show        = Show.blank(channel: "5.1", device: "FFFFFFFF")
    @State private var st:   ShowState   = .single
    @State private var days: Set<String> = []
    @State private var folder: URL?      = FileManager.default.homeDirectoryForCurrentUser
                                               .appendingPathComponent("Documents/hdhr_videos")

    init(showTitle: String, seriesType: ShowState, airDays: Set<String>) {
        self.showTitle  = showTitle
        self.seriesType = seriesType
        self.airDays    = airDays
    }

    var body: some View {
        // Seed @State from the initializer values. Since onAppear doesn't fire in
        // ImageRenderer we use a computed body that overwrites the initial defaults.
        Form {
            ShowFormSection(
                show: .constant({
                    var s = Show.blank(channel: "5.1", device: "FFFFFFFF")
                    s.show_title = showTitle
                    return s
                }()),
                seriesType: .constant(seriesType),
                airDays: .constant(airDays),
                recordFolder: $folder,
                folderButtonLabel: "Choose…",
                onSeriesTypeChange: {},
                onChooseFolder: {}
            )
        }
        .frame(width: 500)
        .padding()
    }
}
