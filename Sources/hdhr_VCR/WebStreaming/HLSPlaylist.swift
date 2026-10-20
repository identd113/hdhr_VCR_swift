import Foundation

// Part of the web-streaming feature (docs/WebStreaming.md). Pure text, no I/O, so it is unit-tested alone.

/// One finished media segment of an HLS stream.
struct HLSSegment: Equatable {
    let name: String
    let duration: Double
}

enum HLSPlaylist {
    /// A live (not yet ended) playlist is not published until it lists this many segments: Chrome's built-in HLS player
    /// keeps three segments back from the live edge and fails with a demuxer parse error on a shorter one (found in
    /// the live test, docs/WebStreaming.md). A finished playlist is fine at any length.
    static let minLiveSegments = 3

    /// A fragmented-MP4 HLS media playlist (version 7: `#EXT-X-MAP` points at the init segment).
    /// `finished` adds `#EXT-X-ENDLIST` and marks it VOD; an unfinished one is an EVENT playlist that keeps growing.
    static func render(segments: [HLSSegment], initName: String = "init.mp4", finished: Bool) -> String {
        let target = max(1, Int((segments.map(\.duration).max() ?? 4).rounded(.up)))
        // Old segments may have been deleted to bound disk use: the first one still listed sets the media sequence,
        // and a playlist that has dropped its start can no longer claim to be EVENT/VOD (those only ever grow).
        let first = segments.first.flatMap { sequenceNumber(of: $0.name) } ?? 1
        var out = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:\(first)\n"
        if first == 1 { out += "#EXT-X-PLAYLIST-TYPE:\(finished ? "VOD" : "EVENT")\n" }
        out += "#EXT-X-MAP:URI=\"\(initName)\"\n"
        for s in segments { out += "#EXTINF:\(String(format: "%.3f", s.duration)),\n\(s.name)\n" }
        if finished { out += "#EXT-X-ENDLIST\n" }
        return out
    }

    /// The number in `seg-00042.m4s` (42), or nil for any other name.
    static func sequenceNumber(of name: String) -> Int? {
        guard name.hasPrefix("seg-"), name.hasSuffix(".m4s") else { return nil }
        return Int(name.dropFirst(4).dropLast(4))
    }

    /// Segment file names the web server may serve: `seg-00001.m4s` and the init segment — nothing else, no paths.
    static func isServableName(_ name: String) -> Bool {
        if name == "init.mp4" || name == "index.m3u8" { return true }
        guard name.hasPrefix("seg-"), name.hasSuffix(".m4s") else { return false }
        let digits = name.dropFirst(4).dropLast(4)
        return digits.count >= 5 && digits.count <= 9 && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber)
    }
}
