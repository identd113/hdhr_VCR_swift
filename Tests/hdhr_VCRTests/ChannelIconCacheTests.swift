import Testing
import Foundation
import CryptoKit
@testable import hdhr_VCR

// MARK: - ChannelIconCache
//
// 12.77% covered, blocked the same way ChannelSignalStore was: `static let shared`'s
// `private init()` always resolved to the real ~/Library/Caches/. Fixed by widening init to
// accept a cacheDir seam (same shape as ConfigManager's own). image(for:)'s network-download path
// still isn't covered here (no URLSession injection seam on this actor) — every case below hits
// the disk-cache path instead, which returns before that code runs, so no test makes a real
// network call.

// Mirrors ChannelIconCache's own private cacheFileName(for:) exactly, so tests can prime the
// disk cache at the same path the real code would use, without widening that method's visibility.
private func cacheFileName(for urlString: String) -> String {
    let digest = SHA256.hash(data: Data(urlString.utf8)).map { String(format: "%02x", $0) }.joined()
    let ext = URL(string: urlString)?.pathExtension ?? ""
    return ext.isEmpty ? digest : "\(digest).\(ext)"
}

// 1x1 pixel PNG — smallest valid image data NSImage(data:) will decode.
private let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

private struct TestIconCache {
    let cache: ChannelIconCache
    let subdir: URL  // matches ChannelIconCache.init(cacheDir:)'s own "hdhr_VCR/channel_icons" append

    init() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cache = ChannelIconCache(cacheDir: base)
        subdir = base.appendingPathComponent("hdhr_VCR/channel_icons", isDirectory: true)
    }

    @discardableResult
    func primeDisk(url: String) throws -> URL {
        let dest = subdir.appendingPathComponent(cacheFileName(for: url))
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try tinyPNG.write(to: dest)
        return dest
    }
}

@Suite("ChannelIconCache")
struct ChannelIconCacheTests {
    @Test func countMissing_emptyCache_allMissing() async {
        let t = TestIconCache()
        let count = await t.cache.countMissing(in: ["https://a/1.png", "https://a/2.png"])
        #expect(count == 2)
    }

    @Test func countMissing_ignoresEmptyURLs() async {
        let t = TestIconCache()
        let count = await t.cache.countMissing(in: ["", "https://a/1.png"])
        #expect(count == 1)
    }

    @Test func image_diskCacheHit_returnsWithoutNetwork() async throws {
        let t = TestIconCache()
        let url = "https://a.example.com/logo.png"
        try t.primeDisk(url: url)
        let img = await t.cache.image(for: url)
        #expect(img != nil, "should have found the primed file on disk without any network call")
    }

    @Test func countMissing_afterDiskPrime_dropsToZero() async throws {
        let t = TestIconCache()
        let url = "https://a.example.com/logo2.png"
        try t.primeDisk(url: url)
        let count = await t.cache.countMissing(in: [url])
        #expect(count == 0)
    }

    @Test func countMissing_differentURLsSameBasename_notCollided() async throws {
        // Historical bug (see ChannelIconCache.swift's cacheFileName comment): two logo URLs
        // sharing a basename must not collide on disk. Prime one, confirm the other still reports
        // missing (a collision would make countMissing return 0 for both).
        let t = TestIconCache()
        let urlA = "https://cdnA.example.com/icon.png"
        let urlB = "https://cdnB.example.com/icon.png"
        try t.primeDisk(url: urlA)
        let count = await t.cache.countMissing(in: [urlA, urlB])
        #expect(count == 1, "urlB should still be missing — collided with urlA's cache file if this is 0")
    }

    @Test func allCachedImages_returnsOnlyMemHits() async throws {
        let t = TestIconCache()
        let url = "https://a.example.com/logo3.png"
        try t.primeDisk(url: url)
        // Priming disk alone doesn't populate the in-memory cache — only image(for:) does.
        let beforeLoad = await t.cache.allCachedImages(for: [url])
        #expect(beforeLoad.isEmpty)

        _ = await t.cache.image(for: url)  // disk hit → also populates mem
        let afterLoad = await t.cache.allCachedImages(for: [url])
        #expect(afterLoad[url] != nil)
    }

    @Test func pruneDiskCacheIfNeeded_underCap_removesNothing() async throws {
        let t = TestIconCache()
        try t.primeDisk(url: "https://a/1.png")
        try t.primeDisk(url: "https://a/2.png")
        await t.cache.pruneDiskCacheIfNeeded()
        let count = await t.cache.countMissing(in: ["https://a/1.png", "https://a/2.png"])
        #expect(count == 0, "well under the 150MB cap — nothing should have been evicted")
    }
}
