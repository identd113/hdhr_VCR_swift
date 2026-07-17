import SwiftUI

struct ShowFormSection: View {
    @EnvironmentObject var state: AppState

    @Binding var show: Show
    @Binding var seriesType: ShowState
    @Binding var airDays: Set<String>
    @Binding var recordFolder: URL?

    var folderButtonLabel: String
    var onSeriesTypeChange: () -> Void
    var onChooseFolder: () -> Void

    private let weekdays = ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"]

    // Signal quality for the selected channel, resolved from the same call-sign-keyed store the
    // guide/menu use. nil when the feature is off or the channel/GuideName can't be resolved;
    // .noData when the channel has never been recorded or scanned (nothing to show).
    private var channelSignal: (name: String, bucket: SignalBucket)? {
        guard state.config.Signal_quality_enabled,
              let gn = state.lineups[show.hdhr_record]?
                         .first(where: { $0.GuideNumber == show.show_channel })?.GuideName
        else { return nil }
        return (gn, signalBucket(guideName: gn))
    }

    var body: some View {
        Group {
            LabeledContent("Title") {
                TextField("Title", text: $show.show_title)
            }

            if let sig = channelSignal, sig.bucket != .noData {
                if sig.bucket == .poor {
                    Label("Weak signal on this channel — recordings may drop out or fail.",
                          systemImage: "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Color.orange.cornerRadius(8))
                        .font(.callout)
                }
                LabeledContent("Signal") {
                    SignalBarsView(bucket: sig.bucket, guideName: sig.name)
                }
            }

            LabeledContent("Type") {
                Picker("", selection: $seriesType) {
                    ForEach(ShowState.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: seriesType) { onSeriesTypeChange() }
                .help("Single: one recording on a specific date and time. DateTime: repeats weekly on selected days. Series Channel: records new episodes on this channel via SeriesID matching. Series All: records new episodes on any channel.")
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
                .help(seriesType == .single
                      ? "The day of the week this one-time recording will air."
                      : "All days of the week this show airs — select every applicable day.")
            }

            LabeledContent("Transcode") {
                Picker("", selection: $show.show_transcode) {
                    Text("None").tag("none")
                    Text("Heavy").tag("heavy")
                    Text("Mobile").tag("mobile")
                    Text("Internet 720").tag("internet720")
                }
                .help("None keeps the raw MPEG stream (recommended). Heavy, Mobile, and Internet 720 transcode the stream to reduce file size or target a specific playback device.")
            }

            if state.config.Sports_padding_enabled {
                LabeledContent("Bonus Time") {
                    Toggle("+\(state.config.Sports_padding_minutes) min past guide end",
                           isOn: Binding(
                        get: { show.show_bonus_time },
                        set: { val in
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                                show.show_bonus_time = val
                            }
                        }
                    ))
                }
            }

            LabeledContent("Folder") {
                HStack {
                    Text(recordFolder?.lastPathComponent ?? "Not set").foregroundStyle(.secondary)
                    Button(folderButtonLabel) { onChooseFolder() }
                }
            }
        }
    }
}
