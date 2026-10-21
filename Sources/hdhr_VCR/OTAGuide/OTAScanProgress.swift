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
    var audioOnly = false
    /// End of the last program listed for this channel: how far ahead its guide reaches.
    var latestEnd: Date?

    /// "2.8 days" / "14 h" ahead of `now`; nil when nothing is listed.
    func reachText(now: Date = Date()) -> String? {
        guard listings > 0, let latestEnd else { return nil }
        return OTAScanView.hoursText(max(0, latestEnd.timeIntervalSince(now) / 3600))
    }
}

/// Facts about one station (multiplex), shown at the top of its section in the scan window.
struct OTAMuxInfo: Equatable {
    var frequencyMHz: Double
    var bytes = 0
    var seconds = 0.0
    var guideTablesAnnounced = 0        // the Master Guide Table's count of listing tables: 0 means the station sends no guide
    var broadcastTime: Date?            // the station's own clock (System Time Table)
    var episodes = 0
    var latestEnd: Date?
    var strength: Int?                  // the tuner's signal strength / quality readings, percent
    var quality: Int?
    var majors: [Int] = []              // virtual channel numbers carried (4, 23…)
    var videoChannels = 0
    var audioChannels = 0

    /// Average data rate of the stream while it was read (a full multiplex is about 19.4 Mbit/s).
    var mbps: Double? { seconds >= 1 && bytes > 0 ? Double(bytes) * 8 / seconds / 1_000_000 : nil }
    /// How far ahead the guide reaches from `now`, in hours; nil when there is none.
    func guideHoursAhead(now: Date = Date()) -> Double? { latestEnd.map { max(0, $0.timeIntervalSince(now) / 3600) } }
    /// The station's clock minus this Mac's, in seconds (a stream that is behind or a wrong clock shows here).
    func clockOffset(now: Date = Date()) -> Int? { broadcastTime.map { Int($0.timeIntervalSince(now).rounded()) } }
}

struct OTAMultiplexRow: Identifiable, Equatable {
    enum State: Equatable { case waiting, scanning, done, noGuide(String) }   // waiting = on the air, its guide not read yet
    var id: Int { rf }
    var rf: Int
    var state: State
    var subChannels: [OTASubChannelRow]
    var info: OTAMuxInfo
    var listings: Int { subChannels.reduce(0) { $0 + $1.listings } }
}

/// What one tuner is doing right now: the station it is on, when that read began and how long it can take at most.
struct OTAScanLane: Equatable {
    var rf: Int
    var startedAt: Date
    var expectedSeconds: Double

    func elapsed(now: Date = Date()) -> Double { max(0, now.timeIntervalSince(startedAt)) }
    /// 0...1 of the longest this read can take. A read often ends sooner (no guide, no signal), so the bar may jump to full.
    func fraction(now: Date = Date()) -> Double { expectedSeconds > 0 ? min(1, elapsed(now: now) / expectedSeconds) : 0 }
}

@MainActor
final class OTAScanProgress: ObservableObject {
    /// Tuner resource ("tuner0"…) → what it is reading. A tuner not in here is idle.
    @Published var lanes: [String: OTAScanLane] = [:]
    /// Why nothing is being read right now ("Stepped aside: …", "Waiting for a free tuner"), or nil.
    @Published var note: String?
    /// When a scan that has ended finished (nil while running).
    @Published var endedAt: Date?
    @Published var rows: [OTAMultiplexRow] = []
    /// RF channels a tuner is on right now, before or while they are read.
    @Published var tuning: Set<Int> = []
    /// The station most recently started or updated: the scan window selects its tab while it is being worked on.
    @Published var currentRF: Int?
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
    private var signals: [Int: (strength: Int?, quality: Int?)] = [:]

    var channelCount: Int { rows.reduce(0) { $0 + $1.subChannels.count } }
    var listingCount: Int { rows.reduce(0) { $0 + $1.listings } }

    func reset(lineupOnly: Bool, twoPass: Bool = false) {
        rows = []; tuning = []; currentRF = nil; signals = [:]; finished = 0; total = 0; withoutSignal = 0; summary = ""
        lanes = [:]; note = nil; endedAt = nil
        running = true
        startedAt = Date()
        self.lineupOnly = lineupOnly
        self.twoPass = twoPass
        pass = 1
        queuedCalls = 0
    }

    /// Rough time left: the time taken so far scaled by how much is done (`fraction`). Rough because stations with a guide take far
    /// longer than empty channels. Nil until there is something to go on.
    func estimatedSecondsRemaining(now: Date = Date()) -> TimeInterval? {
        let f = fraction(now: now)
        let elapsed = now.timeIntervalSince(startedAt)
        guard running, f >= 0.05, elapsed >= 8, f < 1 else { return nil }
        return elapsed / f * (1 - f)
    }

    private func freeLane(_ rf: Int) {
        for (tuner, lane) in lanes where lane.rf == rf { lanes[tuner] = nil }
    }

    /// Overall progress 0...1: stations finished plus the part-way reads on each tuner, so the bar moves smoothly instead of
    /// in steps of one station.
    func fraction(now: Date = Date()) -> Double {
        guard total > 0 else { return 0 }
        let partial = lanes.values.reduce(0.0) { $0 + min(0.95, $1.fraction(now: now)) }
        return min(1, (Double(finished) + partial) / Double(total))
    }

    func elapsedSeconds(now: Date = Date()) -> TimeInterval { (endedAt ?? now).timeIntervalSince(startedAt) }

    func apply(_ event: OTAScanEvent) {
        switch event {
        case .queued(let total):
            queuedCalls += 1
            pass = queuedCalls
            self.total = total
            finished = 0
            startedAt = Date()
        case .started(let rf, let tuner, let expected):
            tuning.insert(rf); currentRF = rf
            lanes[tuner] = OTAScanLane(rf: rf, startedAt: Date(), expectedSeconds: expected)
            note = nil
        case .note(let text): note = text
        case .paused(let rf):
            tuning.remove(rf)
            freeLane(rf)
            if let i = rows.firstIndex(where: { $0.rf == rf }), rows[i].state == .scanning { rows[i].state = .waiting }
        case .update(let rf, let result, let bytes, let seconds):
            currentRF = rf
            upsert(rf: rf, result: result, bytes: bytes, seconds: seconds, done: false)
        case .signal(let rf, let strength, let quality):
            signals[rf] = (strength, quality)
            if let i = rows.firstIndex(where: { $0.rf == rf }) { rows[i].info.strength = strength; rows[i].info.quality = quality }
        case .finished(let rf, let result, let bytes, let seconds):
            tuning.remove(rf)
            freeLane(rf)
            finished += 1
            upsert(rf: rf, result: result, bytes: bytes, seconds: seconds, done: true)
        case .skipped(let rf, let why):
            tuning.remove(rf)
            freeLane(rf)
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

    private func upsert(rf: Int, result: OTADecodeResult, bytes: Int, seconds: Double, done: Bool) {
        let bySource = Dictionary(grouping: result.events, by: \.sourceId)
        let counts = bySource.mapValues(\.count)
        let carried = result.channels.filter { $0.serviceType == 2 || $0.serviceType == 3 }
        let subs = carried.map {
            OTASubChannelRow(sourceId: $0.sourceId, number: $0.number, name: $0.name, listings: counts[$0.sourceId] ?? 0, done: done && !(twoPass && pass == 1),
                              audioOnly: $0.serviceType == 3, latestEnd: bySource[$0.sourceId]?.map(\.end).max())
        }.sorted { ($0.number.split(separator: ".").compactMap { Int($0) }).lexicographicallyPrecedes($1.number.split(separator: ".").compactMap { Int($0) }) }
        guard !subs.isEmpty else { return }
        var info = OTAMuxInfo(frequencyMHz: Double(OTAScanner.frequencyHz(rf: rf) ?? 0) / 1_000_000)
        info.bytes = bytes; info.seconds = seconds
        info.guideTablesAnnounced = result.announcedEITCount
        info.broadcastTime = result.broadcastTime
        info.episodes = result.events.count
        info.latestEnd = result.events.map(\.end).max()
        info.majors = Array(Set(carried.map(\.major))).sorted()
        info.videoChannels = carried.filter { $0.serviceType == 2 }.count
        info.audioChannels = carried.filter { $0.serviceType == 3 }.count
        info.strength = signals[rf]?.strength; info.quality = signals[rf]?.quality
        // A later pass reads for a different length of time: keep the figures from the longer, fuller read.
        if let old = rows.first(where: { $0.rf == rf })?.info, old.seconds > info.seconds, old.bytes > 0 { info.bytes = old.bytes; info.seconds = old.seconds }
        let row = OTAMultiplexRow(rf: rf, state: !done ? .scanning : (twoPass && pass == 1 ? .waiting : .done), subChannels: subs, info: info)
        if let i = rows.firstIndex(where: { $0.rf == rf }) { rows[i] = row }
        else { rows.append(row); rows.sort { $0.rf < $1.rf } }
    }
}
