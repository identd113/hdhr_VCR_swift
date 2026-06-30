import SwiftUI

// White-filled button with a colored border + matching label color.
// Standard SwiftUI styles can't separate fill from border color, so we need a custom style.
struct WhiteOutlineButtonStyle: ButtonStyle {
    var borderColor: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(borderColor)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.white, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderColor, lineWidth: 1.5))
            .opacity(configuration.isPressed ? 0.65 : isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct ShowFormSection: View {
    @EnvironmentObject var state: AppState

    @Binding var show: Show
    @Binding var seriesType: ShowState
    @Binding var airDays: Set<String>
    @Binding var recordFolder: URL?

    var folderButtonLabel: String
    var onSeriesTypeChange: () -> Void
    var onChooseFolder: () -> Void

    private let weekdays = ["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"]

    var body: some View {
        Group {
            LabeledContent("Title") {
                TextField("Title", text: $show.show_title)
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
