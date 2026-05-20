import SwiftUI

struct EditShowView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss

    @State private var show: Show?
    @State private var seriesType: ShowState = .single
    @State private var airDays: Set<String> = []
    @State private var recordFolder: URL? = nil

    private let weekdays = ["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"]

    var body: some View {
        Group {
            if let s = show {
                VStack(alignment: .leading, spacing: 0) {
                    form(for: s)
                    Divider()
                    navBar
                }
                .frame(width: 480, height: 520)
            } else {
                ProgressView("Loading…")
                    .frame(width: 480, height: 520)
            }
        }
        .onAppear { loadShow() }
    }

    // MARK: - Form

    private func form(for s: Show) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Edit Show").font(.title2)

                LabeledContent("Title") {
                    TextField("Title", text: Binding(
                        get: { show?.show_title ?? "" },
                        set: { show?.show_title = $0 }))
                }

                LabeledContent("Channel") {
                    TextField("e.g. 5.4", text: Binding(
                        get: { show?.show_channel ?? "" },
                        set: { show?.show_channel = $0 }))
                        .frame(width: 80)
                }

                LabeledContent("Type") {
                    Picker("", selection: $seriesType) {
                        ForEach(ShowState.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: seriesType) { _, _ in applySeriesType() }
                }

                if seriesType == .dateTime || seriesType == .single {
                    let daysLabel = seriesType == .single ? "Day" : "Days"
                    LabeledContent(daysLabel) {
                        HStack {
                            ForEach(weekdays, id: \.self) { day in
                                let abbr = String(day.prefix(2))
                                Toggle(isOn: Binding(
                                    get: { airDays.contains(day) },
                                    set: { on in
                                        if seriesType == .single {
                                            airDays = on ? [day] : []
                                        } else {
                                            if on { airDays.insert(day) } else { airDays.remove(day) }
                                        }
                                    }
                                )) { Text(abbr).font(.caption) }
                                .toggleStyle(.button)
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                LabeledContent("Length (min)") {
                    TextField("60", value: Binding(
                        get: { show?.show_length ?? 60 },
                        set: { show?.show_length = $0 }), format: .number)
                        .frame(width: 60)
                }

                LabeledContent("Transcode") {
                    Picker("", selection: Binding(
                        get: { show?.show_transcode ?? "none" },
                        set: { show?.show_transcode = $0 })) {
                        Text("None").tag("none")
                        Text("Heavy").tag("heavy")
                        Text("Mobile").tag("mobile")
                        Text("Internet 720").tag("internet720")
                    }
                }

                LabeledContent("Folder") {
                    HStack {
                        Text(recordFolder?.lastPathComponent ?? (s.posixRecordDir.isEmpty ? "Not set" : (s.posixRecordDir as NSString).lastPathComponent))
                            .foregroundStyle(.secondary)
                        Button("Change…") { chooseFolder() }
                    }
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
                if let s = show { state.deleteShow(s) }
                dismiss()
            }
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Save") { save() }.buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Logic

    private func loadShow() {
        guard let id = state.editingShowId,
              let s = state.shows.first(where: { $0.show_id == id }) else { return }
        show = s
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
        guard show != nil else { return }
        show!.show_is_series        = seriesType != .single
        show!.show_use_seriesid     = seriesType == .seriesChannel || seriesType == .seriesAll
        show!.show_use_seriesid_all = seriesType == .seriesAll
        if seriesType == .seriesChannel || seriesType == .seriesAll {
            airDays = Set(weekdays)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { recordFolder = url }
    }

    private func save() {
        guard var s = show else { return }
        s.show_air_date = Array(airDays)
        s.show_is_series        = seriesType != .single
        s.show_use_seriesid     = seriesType == .seriesChannel || seriesType == .seriesAll
        s.show_use_seriesid_all = seriesType == .seriesAll
        if let folder = recordFolder {
            s.show_dir      = folder.path
            s.show_temp_dir = folder.path
        }
        state.updateShow(s)
        dismiss()
    }
}
