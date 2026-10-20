import Foundation

// Part of the over-the-air guide: what the scan window (Views/OTAScanView.swift, docs/OTAScanView.md) displays. Fed by the
// scanner's `OTAScanEvent`s on the main actor; holds multiplexes (RF channels that carry a station) and their sub-channels.

struct OTASubChannelRow: Identifiable, Equatable {
    var id: Int { sourceId }
    var sourceId: Int
    var number: String
    var name: String
    var listings: Int
    var done: Bool
}

struct OTAMultiplexRow: Identifiable, Equatable {
    enum State: Equatable { case waiting, scanning, done, noGuide(String) }   // waiting = on the air, its guide not read yet
    var id: Int { rf }
    var rf: Int
    var state: State
    var subChannels: [OTASubChannelRow]
    var listings: Int { subChannels.reduce(0) { $0 + $1.listings } }
}

@MainActor
final class OTAScanProgress: ObservableObject {
    @Published var rows: [OTAMultiplexRow] = []
    /// RF channels a tuner is on right now, before or while they are read.
    @Published var tuning: Set<Int> = []
    @Published var finished = 0
    @Published var total = 0
    @Published var withoutSignal = 0
    @Published var running = false
    @Published var lineupOnly = false
    /// A full scan reads the channel list of every RF channel first (pass 1), then the guide of the stations it found (pass 2).
    @Published var twoPass = false
    @Published var pass = 1
    private var queuedCalls = 0
    @Published var summary = ""
    private var startedAt = Date()

    var channelCount: Int { rows.reduce(0) { $0 + $1.subChannels.count } }
    var listingCount: Int { rows.reduce(0) { $0 + $1.listings } }

    func reset(lineupOnly: Bool, twoPass: Bool = false) {
        rows = []; tuning = []; finished = 0; total = 0; withoutSignal = 0; summary = ""
        running = true
        startedAt = Date()
        self.lineupOnly = lineupOnly
        self.twoPass = twoPass
        pass = 1
        queuedCalls = 0
    }

    /// Rough time left: the average time per RF channel so far, times those still to go. Rough because stations with a guide take
    /// far longer than empty channels, and the empty ones tend to be spread through the band. Nil until a few channels are done.
    func estimatedSecondsRemaining(now: Date = Date()) -> TimeInterval? {
        guard running, finished >= 3, total > finished else { return nil }
        return now.timeIntervalSince(startedAt) / Double(finished) * Double(total - finished)
    }

    func apply(_ event: OTAScanEvent) {
        switch event {
        case .queued(let total):
            queuedCalls += 1
            pass = queuedCalls
            self.total = total
            finished = 0
            startedAt = Date()
        case .started(let rf): tuning.insert(rf)
        case .update(let rf, let result): upsert(rf: rf, result: result, done: false)
        case .finished(let rf, let result):
            tuning.remove(rf)
            finished += 1
            upsert(rf: rf, result: result, done: true)
        case .skipped(let rf, let why):
            tuning.remove(rf)
            finished += 1
            if pass == 2 {
                if let i = rows.firstIndex(where: { $0.rf == rf }) { rows[i].state = .noGuide(why) }   // keeps its channel list from pass 1
            } else if why == "no signal" || why == "no free tuner" || why == "cancelled" || why.hasPrefix("a recording") || why == "tuner needed" {
                withoutSignal += 1
            } else if let i = rows.firstIndex(where: { $0.rf == rf }) {
                rows[i].state = .noGuide(why)
            }
        }
    }

    private func upsert(rf: Int, result: OTADecodeResult, done: Bool) {
        let counts = Dictionary(grouping: result.events, by: \.sourceId).mapValues(\.count)
        let subs = result.channels.filter { $0.serviceType == 2 || $0.serviceType == 3 }.map {
            OTASubChannelRow(sourceId: $0.sourceId, number: $0.number, name: $0.name, listings: counts[$0.sourceId] ?? 0, done: done && !(twoPass && pass == 1))
        }.sorted { ($0.number.split(separator: ".").compactMap { Int($0) }).lexicographicallyPrecedes($1.number.split(separator: ".").compactMap { Int($0) }) }
        guard !subs.isEmpty else { return }
        let row = OTAMultiplexRow(rf: rf, state: !done ? .scanning : (twoPass && pass == 1 ? .waiting : .done), subChannels: subs)
        if let i = rows.firstIndex(where: { $0.rf == rf }) { rows[i] = row }
        else { rows.append(row); rows.sort { $0.rf < $1.rf } }
    }
}
