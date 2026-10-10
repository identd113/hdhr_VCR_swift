import Foundation

/// Conservative age-based sweeps of the app's own regenerable files (guide disk cache, `--dump-header`
/// temp files) so nothing grows forever. Pure over a directory + `now` +
/// an injected "in use" set of file names, so tests drive it with temp dirs. Never recurses, never
/// follows symlinks, never removes a name in `inUse`, and is never pointed at a user recordings
/// folder — callers pass only app-owned cache/temp directories.
enum CachePruner {
    struct Result: Equatable {
        var removed = 0
        var bytes: Int64 = 0
    }

    /// Regular files in `dir` that `prune` would remove: matching `matching`, not in `inUse`, and
    /// either older than `maxAge` (by mtime) or zero-byte and older than `zeroByteGrace` (a puller or
    /// atomic writer may have just created the file and not yet written to it).
    nonisolated static func candidates(in dir: URL, now: Date, maxAge: TimeInterval,
                                       zeroByteGrace: TimeInterval = 300,
                                       inUse: Set<String> = [],
                                       matching: (String) -> Bool = { _ in true }) -> [(url: URL, size: Int64)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return [] }
        var out: [(URL, Int64)] = []
        for url in entries {
            let name = url.lastPathComponent
            guard matching(name), !inUse.contains(name),
                  let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.isRegularFile == true, v.isSymbolicLink != true,
                  let mtime = v.contentModificationDate else { continue }
            let size = Int64(v.fileSize ?? 0)
            let age = now.timeIntervalSince(mtime)
            if age > maxAge || (size == 0 && age > zeroByteGrace) { out.append((url, size)) }
        }
        return out
    }

    @discardableResult
    nonisolated static func prune(in dir: URL, now: Date = Date(), maxAge: TimeInterval,
                                  zeroByteGrace: TimeInterval = 300,
                                  inUse: Set<String> = [],
                                  matching: (String) -> Bool = { _ in true }) -> Result {
        var r = Result()
        for c in candidates(in: dir, now: now, maxAge: maxAge, zeroByteGrace: zeroByteGrace, inUse: inUse, matching: matching) {
            if (try? FileManager.default.removeItem(at: c.url)) != nil { r.removed += 1; r.bytes += c.size }
        }
        return r
    }

    /// One INFO summary line for a sweep that removed something (silent otherwise).
    nonisolated static func logSummary(_ what: String, _ r: Result) {
        guard r.removed > 0 else { return }
        glog("[Prune] removed \(r.removed) stale \(what) file(s), \(r.bytes / 1024) KB")
    }

    // MARK: - Rules per folder

    /// Guide disk cache: restore only ever uses a copy up to `GuideStore.staleFallbackMaxAge` (36 h) old, so
    /// anything older — including files left by a changed GuideHours/XML setting or a departed device — is dead.
    nonisolated static func pruneGuideCache(in dir: URL, now: Date = Date()) -> Result {
        prune(in: dir, now: now, maxAge: GuideStore.staleFallbackMaxAge) { $0.hasSuffix(".guide") }
    }

    /// `--dump-header` files RecordingManager leaves in the temp folder when a recording's curl was
    /// never cleanly stopped (crash, force-quit): `hdhrVCRplus-<showId>.headers`, 48 h grace.
    nonisolated static let headerFileMaxAge: TimeInterval = 48 * 3600
    nonisolated static func pruneHeaderFiles(in dir: URL, now: Date = Date(), inUse: Set<String>) -> Result {
        prune(in: dir, now: now, maxAge: headerFileMaxAge, inUse: inUse) {
            $0.hasPrefix("hdhrVCRplus-") && $0.hasSuffix(".headers")
        }
    }
}
