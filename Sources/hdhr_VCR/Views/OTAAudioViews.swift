import SwiftUI

// The scan window's sound details (docs/OTAScanView.md "Sound"): a stream-budget bar for a whole multiplex, and for each channel a compact
// text line per sound stream (layout, codec, language, sample rate, bit rate, dialogue level) and one for the picture.

/// How a multiplex spends its data rate: one bar split into video, sound, guide data, padding and other, with a legend.
struct OTAStreamBudgetBar: View {
    let budget: OTAStreamBudget
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var parts: [(label: String, value: Double, color: Color)] {
        [("video", budget.video, .blue), ("sound", budget.audio, .teal), ("guide data", budget.guide, .orange),
         ("other", budget.other, .purple), ("padding", budget.padding, .gray)].filter { $0.value > 0.005 }
    }

    var body: some View {
        let total = max(budget.total, 0.001)
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.label) { part in
                        RoundedRectangle(cornerRadius: 2).fill(part.color.opacity(0.85))
                            .frame(width: max(2, (geo.size.width - 4) * (shown || reduceMotion ? part.value / total : 0)))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .animation(.spring(response: 0.7, dampingFraction: 0.8), value: shown)
            HStack(spacing: 10) {
                ForEach(parts, id: \.label) { part in
                    HStack(spacing: 3) {
                        Circle().fill(part.color.opacity(0.85)).frame(width: 6, height: 6)
                        Text("\(part.label) \(String(format: "%.1f", part.value))").font(.caption2.monospacedDigit())
                    }
                }
                Spacer(minLength: 0)
                Text("Mbit/s").font(.caption2).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
        }
        .onAppear { shown = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stream budget")
        .accessibilityValue(parts.map { "\($0.label) \(String(format: "%.1f", $0.value)) megabits per second" }.joined(separator: ", "))
        .accessibilityIdentifier("ota-scan-budget")
    }
}

/// One channel: number, name, what it is (radio, language), its listings, then a line for each sound stream (and one for the picture).
struct OTAChannelRow: View {
    let sub: OTASubChannelRow
    let showListings: Bool
    let waiting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(sub.number).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                Text(sub.name).font(.callout.bold()).lineLimit(1)
                if sub.audioOnly, !sub.unlisted { tag("radio", systemImage: "radio") }
                if sub.hidden { tag("hidden", systemImage: "eye.slash") }
                if sub.protected { tag("encrypted", systemImage: "lock.fill") }
                if sub.isData { tag("data service", systemImage: "externaldrive") }
                if sub.unlisted { tag("not in the channel list", systemImage: "questionmark.circle") }
                // Announced in the tables but not a single packet arrived for it over the read: a placeholder that is not on the air.
                if !sub.streams.isEmpty, sub.streams.allSatisfy({ ($0.kbps ?? 1) == 0 }) { tag("not transmitting", systemImage: "antenna.radiowaves.left.and.right.slash") }
                Spacer(minLength: 4)
                if showListings, !sub.unlisted {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(sub.listings > 0 ? "\(sub.listings) episodes" : "no episodes").font(.caption.monospacedDigit())
                        Text(sub.reachText() ?? (waiting ? "" : "no guide")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(Array(sub.streams.filter(\.isAudio).enumerated()), id: \.offset) { _, st in
                Text(audioText(st)).font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.leading, 46)
            }
            if let video = sub.streams.first(where: \.isVideo) {
                Text([video.codec, video.kbps.map { String(format: "%.1f Mbit/s", $0 / 1000) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1).padding(.leading, 46)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ota-scan-sub-\(sub.number)")
    }

    private func tag(_ text: String, systemImage: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9)) }
            Text(text).font(.caption2)
        }
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }

    /// "5.1 AC-3 · English · 48 kHz · 384 kbit/s · dialogue -24 dB", plus the service type when it is not the main audio.
    private func audioText(_ st: OTAElementaryStream) -> String {
        var parts = [[st.audio?.layout, st.codec].compactMap { $0 }.joined(separator: " ")]
        if !st.languageName.isEmpty { parts.append(st.languageName) }
        if let f = st.audio {
            if f.bsmod != 0 { parts.append(f.serviceText) }
            parts.append(String(format: "%g kHz", Double(f.sampleRate) / 1000))
            parts.append("\(f.kbps) kbit/s")
            parts.append("dialogue \(f.dialnorm) dB")
        } else if let k = st.kbps { parts.append(String(format: "%.0f kbit/s", k)) }
        return parts.joined(separator: " · ")
    }
}
