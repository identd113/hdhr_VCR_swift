import AppKit
import SwiftUI

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

    /// How many of these URLs are not yet on disk (need a download).
    /// Uses a single contentsOfDirectory call instead of one fileExists per URL —
    /// replaces ~400 individual disk stat calls with one directory scan after each guide load.
    func countMissing(in urlStrings: [String]) -> Int {
        let onDisk = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        return urlStrings.filter { url in
            guard !url.isEmpty else { return false }
            if mem[url] != nil { return false }
            let fileName = URL(string: url)?.lastPathComponent ?? "icon.png"
            return !onDisk.contains(fileName)
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

        let fileName = URL(string: urlString)?.lastPathComponent ?? "icon.png"
        let diskPath = dir.appendingPathComponent(fileName)

        if let data = try? Data(contentsOf: diskPath),
           let img  = NSImage(data: data) {
            mem[urlString] = img
            return img
        }

        guard let url = URL(string: urlString),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let img = NSImage(data: data) else { failedURLs.insert(urlString); return nil }

        mem[urlString] = img
        if mem.count > 600 { mem.removeAll() }
        try? data.write(to: diskPath)
        return img
    }
}

// ── SwiftUI view ──────────────────────────────────────────────────────────────

struct ChannelIcon: View {
    let urlString: String?
    let size: CGFloat
    var accessibilityLabel: String? = nil   // nil = decorative (hidden from VoiceOver)

    @State private var img: NSImage? = nil

    var body: some View {
        Group {
            if let img {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle().hidden()
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(accessibilityLabel.map(Text.init) ?? Text(""))
        .accessibilityHidden(accessibilityLabel == nil)
        .task(id: urlString) {
            guard let s = urlString, !s.isEmpty else { img = nil; return }
            img = await ChannelIconCache.shared.image(for: s)
        }
    }
}
