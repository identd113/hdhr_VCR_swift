import Testing
@testable import hdhr_VCR

@Suite("HLS playlist text and servable names")
struct HLSPlaylistTests {
    private let segments = [HLSSegment(name: "seg-00001.m4s", duration: 3.9), HLSSegment(name: "seg-00002.m4s", duration: 4.004)]

    @Test func finishedPlaylistIsVODWithEndList() {
        let text = HLSPlaylist.render(segments: segments, finished: true)
        #expect(text.hasPrefix("#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:5\n"))
        #expect(text.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        #expect(text.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        #expect(text.contains("#EXTINF:3.900,\nseg-00001.m4s\n"))
        #expect(text.hasSuffix("#EXT-X-ENDLIST\n"))
    }

    @Test func unfinishedPlaylistIsEventWithoutEndList() {
        let text = HLSPlaylist.render(segments: segments, finished: false)
        #expect(text.contains("#EXT-X-PLAYLIST-TYPE:EVENT"))
        #expect(!text.contains("#EXT-X-ENDLIST"))
    }

    @Test func emptyPlaylistStillHasAValidTargetDuration() {
        #expect(HLSPlaylist.render(segments: [], finished: false).contains("#EXT-X-TARGETDURATION:4"))
    }

    @Test(arguments: ["init.mp4", "index.m3u8", "seg-00001.m4s", "seg-123456.m4s"])
    func servableNames(_ name: String) { #expect(HLSPlaylist.isServableName(name)) }

    @Test(arguments: ["", "../seg-00001.m4s", "seg-1.m4s", "seg-00001.ts", "seg-0000a.m4s", "/etc/passwd", "seg-00001.m4s/..", "SEG-00001.m4s", "seg-٠٠٠٠١.m4s"])
    func unservableNames(_ name: String) { #expect(!HLSPlaylist.isServableName(name)) }
}
