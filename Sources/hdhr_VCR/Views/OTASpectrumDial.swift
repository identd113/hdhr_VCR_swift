import SwiftUI

// The scan window's picture of the airwaves (docs/OTAScanView.md "The dial"): one slim bar per RF channel, left to right in frequency order,
// grouped under the three broadcast bands. A bar starts as a faint tick, a small arrow in the tuner's colour bobs above the one being read,
// and a station that is found springs up to a height that grows with the number of channels it carries. Tapping a bar selects that station.
struct OTASpectrumDial: View {
    @ObservedObject var progress: OTAScanProgress
    let selectedRF: Int?
    let laneColor: (Int) -> Color
    let onSelect: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bob = false

    private let rfs = OTAScanner.allRFChannels
    private let gap: CGFloat = 2
    private let dialHeight: CGFloat = 104

    /// The three broadcast bands (RF channel ranges and the frequencies they cover), as drawn under the bars.
    static let bands: [(name: String, range: ClosedRange<Int>, mhz: String)] = [
        ("VHF low", 2...6, "54–88 MHz"), ("VHF high", 7...13, "174–216 MHz"), ("UHF", 14...51, "470–698 MHz")]

    var body: some View {
        GeometryReader { geo in
            let barW = max(3, (geo.size.width - gap * CGFloat(rfs.count - 1)) / CGFloat(rfs.count))
            VStack(spacing: 4) {
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(rfs, id: \.self) { rf in column(rf, width: barW) }
                }
                .frame(height: dialHeight, alignment: .bottom)
                axis(barW: barW)
            }
        }
        .frame(height: dialHeight + 30)
        .onAppear(perform: syncBob)
        .onChange(of: progress.running) { _, _ in syncBob() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The airwaves: one bar for each RF channel")
        .accessibilityIdentifier("ota-scan-dial")
    }

    // MARK: one RF channel

    private func readers(of rf: Int) -> [Int] {
        progress.lanes.filter { $0.value.rf == rf }.keys.compactMap { Int($0.dropFirst("tuner".count)) }.sorted()
    }

    private func barHeight(_ rf: Int, row: OTAMultiplexRow?) -> CGFloat {
        if let row { return 26 + CGFloat(min(row.subChannels.count, 6)) * 9 }
        if !readers(of: rf).isEmpty { return 16 }
        return progress.listenedRF.contains(rf) ? 4 : 8
    }

    private func column(_ rf: Int, width: CGFloat) -> some View {
        let row = progress.rows.first { $0.rf == rf }
        let reading = readers(of: rf)
        let selected = rf == selectedRF
        let height = barHeight(rf, row: row)
        let tint: Color = row == nil ? (reading.first.map(laneColor) ?? .secondary) : (row?.state == .done ? .green : Color.accentColor)
        return Button { if row != nil { onSelect(rf) } } label: {
            VStack(spacing: 3) {
                Spacer(minLength: 0)
                ZStack {
                    ForEach(reading, id: \.self) { i in
                        Image(systemName: "arrowtriangle.down.fill").font(.system(size: 8)).foregroundStyle(laneColor(i))
                            .offset(y: reduceMotion ? 0 : (bob ? -2 : 2))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(height: 9)
                RoundedRectangle(cornerRadius: min(3, width / 2))
                    .fill(tint.opacity(row == nil ? (reading.isEmpty ? (progress.listenedRF.contains(rf) ? 0.18 : 0.3) : 0.9) : 0.9))
                    .frame(height: height)
                    .overlay(RoundedRectangle(cornerRadius: min(3, width / 2)).stroke(Color.primary.opacity(selected ? 0.9 : 0), lineWidth: 1.5))
            }
            .frame(width: width, height: dialHeight, alignment: .bottom)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(selected ? 0.14 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row == nil)
        .animation(.spring(response: 0.55, dampingFraction: 0.6), value: height)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: reading)
        .animation(.easeOut(duration: 0.2), value: selected)
        .accessibilityHidden(row == nil)
        .accessibilityLabel(row.map { "RF \(rf), \($0.subChannels.count) channels" } ?? "RF \(rf)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("ota-scan-tab-\(rf)")
    }

    // MARK: band labels

    private func axis(barW: CGFloat) -> some View {
        HStack(spacing: gap) {
            ForEach(Self.bands, id: \.name) { band in
                let n = rfs.filter { band.range.contains($0) }.count
                VStack(spacing: 1) {
                    Rectangle().fill(Color.secondary.opacity(0.4)).frame(height: 1)
                    Text(band.name).font(.caption2.bold()).lineLimit(1)
                    Text(band.mhz).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: barW * CGFloat(n) + gap * CGFloat(max(0, n - 1)))
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    /// The arrows bob only while a scan runs, and not at all with "Reduce motion".
    private func syncBob() {
        if progress.running, !reduceMotion {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { bob = true }
        } else {
            withTransaction(Transaction(animation: nil)) { bob = false }
        }
    }
}
