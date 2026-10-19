import Foundation

// Part of the web-streaming feature (docs/WebStreaming.md). Pure text, no I/O, so it is unit-tested alone.

/// One finished media segment of an HLS stream.
struct HLSSegment: Equatable {
    let name: String
    let duration: Double
}

enum HLSPlaylist {
    /// A fragmented-MP4 HLS media playlist (version 7: `#EXT-X-MAP` points at the init segment).
    /// `finished` adds `#EXT-X-ENDLIST` and marks it VOD; an unfinished one is an EVENT playlist that keeps growing.
    static func render(segments: [HLSSegment], initName: String = "init.mp4", finished: Bool) -> String {
        let target = max(1, Int((segments.map(\.duration).max() ?? 4).rounded(.up)))
        var out = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:1\n"
        out += "#EXT-X-PLAYLIST-TYPE:\(finished ? "VOD" : "EVENT")\n#EXT-X-MAP:URI=\"\(initName)\"\n"
        for s in segments { out += "#EXTINF:\(String(format: "%.3f", s.duration)),\n\(s.name)\n" }
        if finished { out += "#EXT-X-ENDLIST\n" }
        return out
    }

    /// Segment file names the web server may serve: `seg-00001.m4s` and the init segment — nothing else, no paths.
    static func isServableName(_ name: String) -> Bool {
        if name == "init.mp4" || name == "index.m3u8" { return true }
        guard name.hasPrefix("seg-"), name.hasSuffix(".m4s") else { return false }
        let digits = name.dropFirst(4).dropLast(4)
        return digits.count >= 5 && digits.count <= 9 && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber)
    }
}
