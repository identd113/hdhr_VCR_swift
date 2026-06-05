import Foundation

// ── Channel signal quality history ───────────────────────────────────────────
// Keyed by "\(frequency):\(guideName.lowercased())" so write-time (status.json
// tuner lock) and read-time (lineup GuideName) always match.
// Persists up to 50 samples per channel in ~/Library/Application Support/hdhrVCRplus/channel_signal_history.json.

actor ChannelSignalStore {
    static let shared = ChannelSignalStore()

    private var history: [String: [ChannelSignalSample]] = [:]
    private var savePending: Task<Void, Never>?
    private let filePath: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        filePath = base.appendingPathComponent("hdhrVCRplus/channel_signal_history.json")
        try? FileManager.default.createDirectory(at: filePath.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
    }

    func load() {
        guard let data    = try? Data(contentsOf: filePath),
              let decoded = try? JSONDecoder().decode([String: [ChannelSignalSample]].self, from: data)
        else { return }
        history = decoded.mapValues { Array($0.suffix(50)) }.filter { !$0.value.isEmpty }
    }

    // Rolling 20-sample average → bucket. Requires ≥3 samples to avoid noise from brief lock-ons.
    private func bucketFor(_ samples: [ChannelSignalSample]) -> SignalBucket {
        guard samples.count >= 3 else { return .noData }
        let window = samples.suffix(20)
        let avg    = Double(window.map { $0.snq }.reduce(0, +)) / Double(window.count) / 100.0
        return SignalBucket(avg)
    }

    // Adaptive sample frequency: healthy channels need far fewer checks than troubled ones.
    func needsSample(frequency: Int, guideName: String) -> Bool {
        let key = "\(frequency):\(guideName.trimmingCharacters(in: .whitespaces).lowercased())"
        guard let samples = history[key], let last = samples.last else { return true }
        let age = Date().timeIntervalSince(last.ts)
        switch bucketFor(samples) {
        case .poor:   return age > 86_400      // 1 day
        case .fair:   return age > 259_200     // 3 days
        case .good:   return age > 604_800     // 7 days
        case .noData: return true
        }
    }

    func record(frequency: Int, guideName: String, snq: Int) {
        let name = guideName.trimmingCharacters(in: .whitespaces).lowercased()
        guard frequency > 0, !name.isEmpty else { return }
        let key     = "\(frequency):\(name)"
        var samples = history[key, default: []]
        samples.append(ChannelSignalSample(ts: Date(), snq: min(100, max(0, snq))))
        history[key] = Array(samples.suffix(50))
        scheduleSave()
    }

    func allBuckets() -> [String: SignalBucket] {
        history.reduce(into: [:]) { out, pair in
            out[pair.key] = bucketFor(pair.value)
        }
    }

    private func scheduleSave() {
        savePending?.cancel()
        savePending = Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        guard let data = try? enc.encode(history) else { return }
        try? data.write(to: filePath, options: .atomic)
    }
}
