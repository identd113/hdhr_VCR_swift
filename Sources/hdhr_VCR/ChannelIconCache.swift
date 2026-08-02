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

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
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
}
