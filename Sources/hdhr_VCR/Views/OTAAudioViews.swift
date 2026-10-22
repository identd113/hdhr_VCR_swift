import SwiftUI

// The scan window's sound details (docs/OTAScanView.md "Sound"): a stream-budget bar for a whole multiplex, and for each channel its language,
// codec, a small drawing of the speaker layout, the bit rate as a bar and the dialogue level on a gauge.

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

/// A channel's speaker layout drawn as dots: the front speakers in a row, the surrounds behind them, a square for the subwoofer.
struct OTASpeakerLayout: View {
    let format: OTAAudioFormat

    var body: some View {
        let (front, rear) = format.speakers
        Canvas { ctx, size in
            let r: CGFloat = 3.2
            func dots(_ n: Int, y: CGFloat, margin: CGFloat) {
                for i in 0..<n {
                    let x = n == 1 ? size.width / 2 : margin + (size.width - 2 * margin) * CGFloat(i) / CGFloat(n - 1)
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(.accentColor))
                }
            }
            dots(front, y: 6, margin: 5)
            if rear > 0 { dots(rear, y: size.height - 6, margin: 9) }
            if format.lfe {
                ctx.fill(Path(roundedRect: CGRect(x: size.width - 10, y: size.height / 2 - 3, width: 7, height: 7), cornerRadius: 1.5), with: .color(.orange))
            }
        }
        .frame(width: 40, height: 28)
        .accessibilityHidden(true)
    }
}

/// Dialogue level (-31…-1 dB) on a small scale: a quieter mix sits to the left.
struct OTALevelGauge: View {
    let dialnorm: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                        .offset(x: max(0, (geo.size.width - 7) * CGFloat(dialnorm + 31) / 30))
                }
            }
            .frame(width: 56, height: 7)
            Text("dialogue \(dialnorm) dB").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dialogue level \(dialnorm) decibels")
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
                if sub.audioOnly { tag("radio", systemImage: "radio") }
                Spacer(minLength: 4)
                if showListings {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(sub.listings > 0 ? "\(sub.listings) episodes" : "no episodes").font(.caption.monospacedDigit())
                        Text(sub.reachText() ?? (waiting ? "" : "no guide")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(Array(sub.streams.filter(\.isAudio).enumerated()), id: \.offset) { _, st in audioLine(st) }
            if let video = sub.streams.first(where: \.isVideo) {
                HStack(spacing: 6) {
                    Image(systemName: "film").font(.caption2).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                    Text(video.codec).font(.caption2).foregroundStyle(.secondary)
                    if let k = video.kbps { Text(String(format: "%.1f Mbit/s", k / 1000)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(.vertical, 6)
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

    private func audioLine(_ st: OTAElementaryStream) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if let f = st.audio { OTASpeakerLayout(format: f).frame(width: 40) } else {
                Image(systemName: "speaker.wave.2").font(.caption).foregroundStyle(.secondary).frame(width: 40)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text([st.audio?.layout, st.codec].compactMap { $0 }.joined(separator: " ")).font(.caption.bold())
                    if !st.languageName.isEmpty { tag(st.languageName) }
                    if let f = st.audio, f.bsmod != 0 { tag(f.serviceText) }
                }
                if let f = st.audio {
                    Text("\(f.sampleRate / 1000) kHz · \(f.kbps) kbit/s\(st.kbps.map { String(format: " (%.0f measured)", $0) } ?? "")")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if let f = st.audio { OTALevelGauge(dialnorm: f.dialnorm) }
        }
    }
}
