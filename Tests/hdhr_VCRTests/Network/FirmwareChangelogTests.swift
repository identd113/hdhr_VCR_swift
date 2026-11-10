import Foundation
import Testing
@testable import hdhr_VCR

@Suite("FirmwareChangelog")
struct FirmwareChangelogTests {
    // Trimmed copy of silicondust.com/support/downloads/firmware-changelog.html (2026-11-09), with a nav <li> before and a footer <li> after.
    private let page = """
    <html><body><header><ul><li>Support</li></ul></header><main id="content">
    <h1>Firmware Changelog</h1>
    <h4>Release 20261107:</h4>
    <ul>
      <li>ATSC3 models: Fix problem where the channel scan could miss information used to make the channel change faster if that information didn't arrive in the expected order.</li>
      <li>ATSC3 models: Fix problem where Symbol Error Quality could incorrectly bounce to zero on low bitrate PLPs.</li>
      <li>ATSC3 TECH/DEV models: Change IPv4 PCAP format to RAW IP for better compatibility with PCAP apps.</li>
      <li>Models with DVB-C support: Support detecting channel numbers on DIGI based cable systems.</li>
      <li>HDHR5-2DT/4DT: Improvements to HAM radio support.</li>
      <li>Detect and report 1440p and 2160p UHD channels as UHD rather than HD.</li>
      <li>Improvements to TLS.</li>
    </ul>
    <h4>Release 20260326:</h4>
    <ul>
      <li>HDHR5-2DT/4DT: Add channel scan mode for 2MHz wide 420-450MHz DVB-T amateur radio used in North America.</li>
      <li>ATSC3 models: Security update.</li>
    </ul>
    <h4>Release 20260313:</h4>
    <ul>
      <li>HDHR5-2DT/4DT: Add support for narrow band (1/2/3/4MHz) DVB-T/T2 used in amateur radio. HDHR5-2DT/4DT model only.</li>
      <li>ATSC3 TECH/DEV models: Add new fmt=ethernet-pcap mode that outputs IPv4 traffic in PCAP packet capture format with artificially generated Ethernet headers for use with software that expects Ethernet frames.</li>
      <li>All models: Upgrade TLS root certificates.</li>
    </ul>
    
    </main><footer><ul><li>Privacy</li></ul></footer></body></html>
    """

    @Test func parsesReleasesNewestFirstAndIgnoresPageChrome() {
        let r = FirmwareChangelog.parse(page)
        #expect(r.map(\.version) == ["20261107", "20260326", "20260313"])
        #expect(r[0].changes.count == 7)
        #expect(r[0].changes.last == "Improvements to TLS.")
        #expect(!r.flatMap(\.changes).contains("Privacy") && !r.flatMap(\.changes).contains("Support"))
    }

    @Test func releasesBetweenInstalledAndOffered() {
        let all = FirmwareChangelog.parse(page)
        #expect(FirmwareChangelog.releases(all, after: "20260313", upTo: "20261107").map(\.version) == ["20261107", "20260326"])
        #expect(FirmwareChangelog.releases(all, after: nil, upTo: "20261107").map(\.version) == ["20261107"])
        #expect(FirmwareChangelog.releases(all, after: "20261107", upTo: "20261107").isEmpty)
    }

    @Test func entitiesAreDecodedAndTheTooltipIsCapped() {
        let r = FirmwareChangelog.parse("<main><h4>Release 1:</h4><ul><li>Fix &#8220;forward&#8221; &amp; <b>more</b></li></ul></main>")
        #expect(r[0].changes == ["Fix \u{201C}forward\u{201D} & more"])
        let big = [FirmwareChangelog.Release(version: "1", changes: (0..<30).map { "c\($0)" })]
        let t = FirmwareChangelog.tooltip(big, maxLines: 5)
        #expect(t?.hasSuffix("…") == true && t?.split(separator: "\n").count == 6)
        #expect(FirmwareChangelog.tooltip([]) == nil)
    }
}
