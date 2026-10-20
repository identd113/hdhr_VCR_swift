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

    /// Name of the audio-only twin of the stream: `audio.m3u8` lists `a-seg-00001.m4s`… with `a-init.mp4`.
    static let audioPlaylistName = "audio.m3u8"

    /// The number in `seg-00042.m4s` or `a-seg-00042.m4s` (42), or nil for any other name.
    static func sequenceNumber(of name: String) -> Int? {
        let base = name.hasPrefix("a-") ? String(name.dropFirst(2)) : name
        guard base.hasPrefix("seg-"), base.hasSuffix(".m4s") else { return nil }
        return Int(base.dropFirst(4).dropLast(4))
    }

    /// Segment file names the web server may serve: the playlists, the init segments and `seg-00001.m4s` / `a-seg-00001.m4s` — nothing else, no paths.
    static func isServableName(_ name: String) -> Bool {
        if ["init.mp4", "index.m3u8", "a-init.mp4", audioPlaylistName].contains(name) { return true }
        guard let number = sequenceNumber(of: name) else { return false }
        let digits = String(number).count
        // The file name must be exactly the canonical zero-padded form: 5–9 ASCII digits.
        let base = name.hasPrefix("a-") ? String(name.dropFirst(2)) : name
        let text = base.dropFirst(4).dropLast(4)
        return digits >= 1 && text.count >= 5 && text.count <= 9 && text.allSatisfy(\.isASCII) && text.allSatisfy(\.isNumber)
    }
}
