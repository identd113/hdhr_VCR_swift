import AppKit
import CryptoKit

// ── Channel icon disk cache ───────────────────────────────────────────────────
// Images are downloaded once and stored in ~/Library/Caches/hdhr_VCR/channel_icons/
// so they survive app restarts without re-downloading.

actor ChannelIconCache {
    static let shared = ChannelIconCache()

    private var mem: [String: NSImage] = [:]
    // URL → when it last failed and how long to leave it alone. Logos live on a public CDN, so a
    // *permanent* failure (the server answered 404/403/410, or sent something that isn't an image)
    // is retried only after a day — long enough that dead URLs aren't re-requested on every guide
    // refresh nor re-counted as "missing" by countMissing — while a *transient* one (no network, a
    // 5xx, a timeout — e.g. the app launched before Wi-Fi was up) retries after ten minutes so logos
    // don't stay blank until relaunch.
    private var failedURLs: [String: (at: Date, retryAfter: TimeInterval)] = [:]
    static let transientRetryInterval: TimeInterval = 600
    static let permanentRetryInterval: TimeInterval = 24 * 3600
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let dir: URL
    // De-dupes concurrent callers requesting the same cold URL — without this, several views
    // referencing the same not-yet-cached icon (e.g. multiple shows sharing a station logo) could
    // each miss the mem/disk cache checks below (this actor yields at the network await) and
    // independently download + disk-write the same file.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    // cacheDir is a test seam only — production always passes nil and gets the real
    // ~/Library/Caches/. Same shape as ConfigManager(appSupportDir:); without this, any test
    // touching countMissing/image(for:)/pruneDiskCacheIfNeeded would read/write the live user's
    // icon cache.
    // session/now are test seams (a mocked session, a controllable clock); production uses the defaults.
    init(cacheDir: URL? = nil, session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.now = now
        let base = cacheDir ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("hdhr_VCR/channel_icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // SHA256 of the full URL, not just URL.lastPathComponent — two logo URLs sharing a basename
    // (or both lacking a path, falling to the "icon.png" default) previously collided on disk,
    // silently serving one channel's icon for another after a restart. Swift's built-in
    // .hashValue is randomized per-process, so it can't be used for an on-disk key that needs to
    // be stable across launches.
    private func cacheFileName(for urlString: String) -> String {
        let digest = SHA256.hash(data: Data(urlString.utf8)).map { String(format: "%02x", $0) }.joined()
        let ext = URL(string: urlString)?.pathExtension ?? ""
        return ext.isEmpty ? digest : "\(digest).\(ext)"
    }

    /// How many of these URLs are not yet on disk (need a download).
    /// Uses a single contentsOfDirectory call instead of one fileExists per URL —
    /// replaces ~400 individual disk stat calls with one directory scan after each guide load.
    func countMissing(in urlStrings: [String]) -> Int {
        let onDisk = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        return urlStrings.filter { url in
            guard !url.isEmpty else { return false }
            if mem[url] != nil { return false }
            // A URL that already failed once isn't "missing" in any sense a re-fetch would fix —
            // image(for:) short-circuits it to nil without even attempting the network call (see
            // its own failedURLs check above). Without this, a single URL that 404s once gets
            // counted as missing on every future prefetch pass forever, keeping AppState on the
            // "cold cache" branch (re-showing "Caching N channel icon(s)…") for nothing on every
            // guide refresh (found in code review 2026-09-25).
            if hasRecentFailure(url) { return false }
            return !onDisk.contains(cacheFileName(for: url))
        }.count
    }

    /// Single actor hop to read multiple entries from the mem cache — used by prefetchChannelIcons
    /// to avoid N individual async calls when all icons are already loaded.
    func allCachedImages(for urlStrings: [String]) -> [String: NSImage] {
        var result: [String: NSImage] = [:]
        for url in urlStrings {
            if let img = mem[url] { result[url] = img }
        }
        return result
    }

    /// True while `url`'s last failure is inside its retry window; an expired entry is dropped so
    /// the next call re-attempts the download.
    private func hasRecentFailure(_ url: String) -> Bool {
        guard let f = failedURLs[url] else { return false }
        if now().timeIntervalSince(f.at) < f.retryAfter { return true }
        failedURLs.removeValue(forKey: url)
        return false
    }

    /// 404/403/410 and "200 but not an image" won't fix themselves; everything else might.
    nonisolated static func isPermanentFailure(statusCode: Int?, gotImageData: Bool) -> Bool {
        guard let statusCode else { return false }                  // no HTTP response at all: network trouble
        if statusCode == 200 { return !gotImageData }
        return [403, 404, 410].contains(statusCode)
    }

    func image(for urlString: String) async -> NSImage? {
        if let hit = mem[urlString] { return hit }
        if hasRecentFailure(urlString) { return nil }

        // A second (or third...) concurrent caller for the same cold URL awaits the same in-flight
        // fetch instead of starting its own — see `inFlight`'s declaration for why.
        if let existing = inFlight[urlString] {
            return await existing.value
        }
        let task = Task<NSImage?, Never> { await self.fetchAndCache(urlString) }
        inFlight[urlString] = task
        defer { inFlight.removeValue(forKey: urlString) }
        return await task.value
    }

    private func fetchAndCache(_ urlString: String) async -> NSImage? {
        let diskPath = dir.appendingPathComponent(cacheFileName(for: urlString))

        if let data = try? Data(contentsOf: diskPath),
           let img  = NSImage(data: data) {
            mem[urlString] = img
            return img
        }

        guard let url = URL(string: urlString) else {
            failedURLs[urlString] = (now(), Self.permanentRetryInterval)
            glog("[Icons] bad URL, not retrying for a day: \(urlString)", level: .warning)
            return nil
        }
        let fetched = try? await session.data(from: url)
        let status = (fetched?.1 as? HTTPURLResponse)?.statusCode
        guard status == 200, let data = fetched?.0, let img = NSImage(data: data) else {
            let permanent = Self.isPermanentFailure(statusCode: status, gotImageData: false)
            failedURLs[urlString] = (now(), permanent ? Self.permanentRetryInterval : Self.transientRetryInterval)
            glog("[Icons] download failed (\(status.map { "HTTP \($0)" } ?? "no response"), retry in \(permanent ? "24h" : "10m")): \(urlString)", level: .warning)
            return nil
        }

        mem[urlString] = img
        if mem.count > 600 { mem.removeAll() }
        try? data.write(to: diskPath)
        return img
    }

    // Generous cap — real-world usage settles around 64 MB / ~2000 icons for a typical lineup;
    // this is a backstop against slow indefinite growth (e.g. a station's CDN logo URL changing
    // over months, leaving the old SHA256-keyed file orphaned) rather than a routine trim, so it
    // almost never fires. Evicts oldest-by-mtime first when it does.
    private let maxDiskCacheBytes: UInt64 = 150 * 1024 * 1024

    // Called once per prefetch batch (AppState.prefetchChannelIcons — startup, the periodic guide
    // refresh, and on-demand per-device retries) rather than after every individual disk write:
    // a bulk prefetch fans out one concurrent write per missing icon via withTaskGroup (up to the
    // ~2000-file cap), and since this cache is an actor, checking per-write would serialize every
    // one of those completions through a full directory scan + per-file stat — O(n²) I/O that
    // stalls unrelated cache-hit reads on the same actor during startup.
    func pruneDiskCacheIfNeeded() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }
        var items: [(url: URL, date: Date, size: UInt64)] = entries.compactMap { url in
            guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let date = vals.contentModificationDate, let size = vals.fileSize
            else { return nil }
            return (url, date, UInt64(size))
        }
        var total = items.reduce(UInt64(0)) { $0 + $1.size }
        guard total > maxDiskCacheBytes else { return }
        items.sort { $0.date < $1.date }
        for item in items {
            guard total > maxDiskCacheBytes else { break }
            try? fm.removeItem(at: item.url)
            total -= item.size
        }
    }
}
