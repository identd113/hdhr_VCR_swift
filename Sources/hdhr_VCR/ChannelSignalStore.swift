import Foundation
import Observation

// ── Channel signal quality history ───────────────────────────────────────────
// Keyed by guideName.lowercased() — available at both write time (from LineupEntry
// during recording) and read time (views). GuideName is device-agnostic: the same
// call sign appears on every device tuned to that multiplex.
// Persists up to 50 samples per channel in ~/Library/Application Support/hdhrVCRplus/channel_signal_history.json.

@Observable @MainActor
final class ChannelSignalStore {
    static let shared = ChannelSignalStore()

    // Views observe this directly via @Observable — no snapshot relay needed.
    private(set) var buckets: [String: SignalBucket] = [:]

    private var history: [String: [ChannelSignalSample]] = [:]
    private var savePending: Task<Void, Never>?
    private let filePath: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        filePath = base.appendingPathComponent("hdhrVCRplus/channel_signal_history.json")
        try? FileManager.default.createDirectory(at: filePath.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
    }

    func load() async {
        let path = filePath
        guard let h = await Task.detached(priority: .utility) { () -> [String: [ChannelSignalSample]]? in
            guard let data    = try? Data(contentsOf: path),
                  let decoded = try? JSONDecoder().decode([String: [ChannelSignalSample]].self, from: data)
            else { return nil }
            return decoded.mapValues { Array($0.suffix(50)) }.filter { !$0.value.isEmpty }
        }.value else { return }
        history = h
        buckets = computeAllBuckets()
    }

    // Adaptive re-sample frequency: poor channels checked daily, good channels weekly.
    func needsSample(guideName: String) -> Bool {
        let key = guideName.trimmingCharacters(in: .whitespaces).lowercased()
        guard let samples = history[key], let last = samples.last else { return true }
        let age = Date().timeIntervalSince(last.ts)
        switch bucketFor(samples) {
        case .poor:   return age > 86_400
        case .fair:   return age > 259_200
        case .good:   return age > 604_800
        case .noData: return true
        }
    }

    func record(guideName: String, snq: Int) {
        let key = guideName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return }
        var samples = history[key, default: []]
        samples.append(ChannelSignalSample(ts: Date(), snq: min(100, max(0, snq))))
        history[key] = Array(samples.suffix(50))
        buckets[key] = bucketFor(history[key]!)
        scheduleSave()
    }

    private func computeAllBuckets() -> [String: SignalBucket] {
        history.reduce(into: [:]) { out, pair in out[pair.key] = bucketFor(pair.value) }
    }

    // Rolling 20-sample average → bucket. Requires ≥3 samples to avoid noise from brief lock-ons.
    private func bucketFor(_ samples: [ChannelSignalSample]) -> SignalBucket {
        guard samples.count >= 3 else { return .noData }
        let window = samples.suffix(20)
        let avg    = Double(window.map { $0.snq }.reduce(0, +)) / Double(window.count) / 100.0
        return SignalBucket(avg)
    }

    // Immediate save — call after a user-triggered scan so data survives a quick quit.
    func flush() {
        savePending?.cancel()
        savePending = nil
        let snapshot = history
        let path     = filePath
        Task.detached(priority: .utility) {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .secondsSince1970
            guard let data = try? enc.encode(snapshot) else { return }
            try? data.write(to: path, options: .atomic)
        }
    }

    private func scheduleSave() {
        guard savePending == nil else { return }
        savePending = Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            let snapshot = history
            let path     = filePath
            Task.detached(priority: .utility) {
                let enc = JSONEncoder()
                enc.dateEncodingStrategy = .secondsSince1970
                guard let data = try? enc.encode(snapshot) else { return }
                try? data.write(to: path, options: .atomic)
            }
            savePending = nil
        }
    }
}
