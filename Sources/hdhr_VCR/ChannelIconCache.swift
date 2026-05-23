import AppKit
import SwiftUI

// ── Channel icon disk cache ───────────────────────────────────────────────────
// Images are downloaded once and stored in ~/Library/Caches/hdhr_VCR/channel_icons/
// so they survive app restarts without re-downloading.

actor ChannelIconCache {
    static let shared = ChannelIconCache()

    private var mem: [String: NSImage] = [:]
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

    func image(for urlString: String) async -> NSImage? {
        if let hit = mem[urlString] { return hit }

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
              let img = NSImage(data: data) else { return nil }

        mem[urlString] = img
        try? data.write(to: diskPath)
        return img
    }
}

// ── SwiftUI view ──────────────────────────────────────────────────────────────

struct ChannelIcon: View {
    let urlString: String?
    let size: CGFloat

    @State private var img: NSImage? = nil

    var body: some View {
        Group {
            if let img {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .task(id: urlString) {
            guard let s = urlString, !s.isEmpty else { return }
            img = await ChannelIconCache.shared.image(for: s)
        }
    }
}
