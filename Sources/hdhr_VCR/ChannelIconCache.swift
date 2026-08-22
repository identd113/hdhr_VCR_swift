import AppKit
import CryptoKit

// ── Channel icon disk cache ───────────────────────────────────────────────────
// Images are downloaded once and stored in ~/Library/Caches/hdhr_VCR/channel_icons/
// so they survive app restarts without re-downloading.

actor ChannelIconCache {
    static let shared = ChannelIconCache()

    private var mem: [String: NSImage] = [:]
    private var failedURLs: Set<String> = []
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
    init(cacheDir: URL? = nil) {
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

    func image(for urlString: String) async -> NSImage? {
        if let hit = mem[urlString] { return hit }
        if failedURLs.contains(urlString) { return nil }

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

        guard let url = URL(string: urlString),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let img = NSImage(data: data) else {
            failedURLs.insert(urlString)
            glog("[Icons] download failed: \(urlString)", level: .warning)
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

    // Called once per prefetch batch (AppState.prefetchChannelIcons — startup, the hourly guide
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
