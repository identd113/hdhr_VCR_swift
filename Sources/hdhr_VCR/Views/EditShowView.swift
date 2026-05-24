import SwiftUI

struct EditShowView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss

    @State private var show: Show?
    @State private var originalShow: Show?
    @State private var seriesType: ShowState = .single
    @State private var airDays: Set<String> = []
    @State private var recordFolder: URL? = nil

    private var isDirty: Bool { show != nil && show != originalShow }

    private let weekdays = ["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"]

    var body: some View {
        Group {
            if let s = show {
                VStack(alignment: .leading, spacing: 0) {
                    form(for: s)
                        .overlay(alignment: .bottomTrailing) {
                            if show?.show_bonus_time == true && state.config.Sports_padding_enabled {
                                StarburstBadge(minutes: state.config.Sports_padding_minutes, size: 90)
                                    .padding(.trailing, 12).padding(.bottom, 12)
                                    .transition(.asymmetric(
                                        insertion: .identity,
                                        removal: .scale(scale: 0.05).combined(with: .opacity)
                                    ))
                            }
                        }
                    Divider()
                    navBar
                }
                .frame(width: 480, height: 520)
            } else {
                ProgressView("Loading…")
                    .frame(width: 480, height: 520)
            }
        }
        .onExitCommand {
            if isDirty {
                let alert = NSAlert()
                alert.messageText     = "Unsaved Changes"
                alert.informativeText = "Save your changes before closing?"
                alert.addButton(withTitle: "Save")
                alert.addButton(withTitle: "Discard")
                alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn:  saveWithoutDismiss(); dismiss()
                case .alertSecondButtonReturn: dismiss()
                default: break
                }
            } else {
                dismiss()
            }
        }
        .background(WindowCloseInterceptor(isDirty: isDirty, canSave: true, onSave: saveWithoutDismiss))
        .onAppear { loadShow() }
    }

    // MARK: - Form

    private func form(for s: Show) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Edit Show").font(.title2)

                ShowFormSection(
                    show: Binding($show)!,  // safe: called only inside `if let s = show` guard
                    seriesType: $seriesType,
                    airDays: $airDays,
                    recordFolder: $recordFolder,
                    folderButtonLabel: "Change…",
                    onSeriesTypeChange: { applySeriesType() },
                    onChooseFolder: { chooseFolder() }
                )

                LabeledContent("Channel") {
                    TextField("e.g. 5.4", text: Binding(
                        get: { show?.show_channel ?? "" },
                        set: { show?.show_channel = $0 }))
                        .frame(width: 80)
                }

                LabeledContent("Length (min)") {
                    TextField("60", value: Binding(
                        get: { show?.show_length ?? 60 },
                        set: { show?.show_length = $0 }), format: .number)
                        .frame(width: 60)
                }

                if s.show_fail_count > 0 {
                    LabeledContent("Failures") {
                        HStack {
                            Text("\(s.show_fail_count) — \(s.show_fail_reason)").foregroundStyle(.orange)
                            Button("Reset") {
                                show?.show_fail_count = 0
                                show?.show_fail_reason = ""
                                show?.show_active = true
                            }
                        }
                    }
                }

                LabeledContent("SeriesID") {
                    Text(s.show_seriesid.isEmpty ? "none" : s.show_seriesid).foregroundStyle(.secondary)
                }

                LabeledContent("Stream URL") {
                    Text(s.show_url.isEmpty ? "not set" : s.show_url)
                        .foregroundStyle(.secondary).font(.caption).lineLimit(1)
                }
            }
            .padding()
        }
    }

    private var navBar: some View {
        HStack {
            Button("Delete", role: .destructive) {
                let title = show?.show_title ?? "this show"
                let alert = NSAlert()
                alert.messageText     = "Delete \"\(title)\"?"
                alert.informativeText = "This cannot be undone."
                alert.addButton(withTitle: "Delete")
                alert.addButton(withTitle: "Cancel")
                alert.alertStyle = .warning
                if alert.runModal() == .alertFirstButtonReturn {
                    if let s = show { state.deleteShow(s) }
                    dismiss()
                }
            }
            Spacer()
            Button("Save") { save() }.buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Logic

    private func loadShow() {
        guard let id = state.editingShowId,
              let s = state.shows.first(where: { $0.show_id == id }) else { return }
        show = s
        originalShow = s   // snapshot for dirty tracking
        seriesType = s.state
        airDays = Set(s.show_air_date)
        // Use show's existing dir, fall back to default setting, then ~/Movies
        if !s.posixRecordDir.isEmpty {
            recordFolder = URL(fileURLWithPath: s.posixRecordDir)
        } else {
            recordFolder = state.defaultSaveDir
        }
    }

    private func applySeriesType() {
        show?.show_is_series        = seriesType != .single
        show?.show_use_seriesid     = seriesType == .seriesChannel || seriesType == .seriesAll
        show?.show_use_seriesid_all = seriesType == .seriesAll
        if seriesType == .seriesChannel || seriesType == .seriesAll {
            airDays = Set(weekdays)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { recordFolder = url }
    }

    private func saveWithoutDismiss() {
        guard var s = show else { return }
        s.show_air_date         = Array(airDays)
        s.show_is_series        = seriesType != .single
        s.show_use_seriesid     = seriesType == .seriesChannel || seriesType == .seriesAll
        s.show_use_seriesid_all = seriesType == .seriesAll
        if let folder = recordFolder {
            s.show_dir      = folder.path
            s.show_temp_dir = folder.path
        }
        state.updateShow(s)
        originalShow = s   // reset dirty tracking after save
    }

    private func save() {
        saveWithoutDismiss()
        dismiss()
    }
}
