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

    @Test func onlyTheOfferedReleaseIsUsed() {
        let all = FirmwareChangelog.parse(page)
        #expect(FirmwareChangelog.releases(all, offered: "20261107").map(\.version) == ["20261107"])
        #expect(FirmwareChangelog.releases(all, offered: "20990101").isEmpty)
    }

    @Test func entitiesAreDecodedAndTheTooltipIsCapped() {
        let r = FirmwareChangelog.parse("<main><h4>Release 1:</h4><ul><li>Fix &#8220;forward&#8221; &amp; <b>more</b></li></ul></main>")
        #expect(r[0].changes == ["Fix \u{201C}forward\u{201D} & more"])
        let big = [FirmwareChangelog.Release(version: "1", changes: (0..<30).map { "c\($0)" })]
        let t = FirmwareChangelog.tooltip(big, maxLines: 5)
        #expect(t?.hasSuffix("…") == true && t?.split(separator: "\n").count == 6)
        #expect(FirmwareChangelog.tooltip([]) == nil)
    }

    @Test func tooltipIsDatedAndGroupsChangesForEveryTunerBeforeModelSpecificOnes() {
        let r = FirmwareChangelog.Release(version: "20261107", changes: [
            "ATSC3 models: Fix scan.", "Improvements to TLS.", "HDHR5-2DT/4DT: Ham radio.", "Detect UHD channels as UHD rather than HD."])
        let lines = FirmwareChangelog.tooltip([r])?.split(separator: "\n").map(String.init)
        #expect(lines == ["Firmware 20261107 · Nov 7, 2026", "• Improvements to TLS.", "• Detect UHD channels as UHD rather than HD.",
                          "Only some models:", "• ATSC3 models: Fix scan.", "• HDHR5-2DT/4DT: Ham radio."])
    }

    @Test func longChangesWrapUnderTheBulletAndNoLineIsWide() {
        let long = Array(repeating: "word", count: 40).joined(separator: " ")
        let lines = FirmwareChangelog.bulletLines(long)
        #expect(lines.count > 1 && lines[0].hasPrefix("• ") && lines[1].hasPrefix("   ") && !lines[1].hasPrefix("• "))
        #expect(lines.allSatisfy { $0.count <= 64 })
        #expect(FirmwareChangelog.bulletLines("short") == ["• short"])
    }

    @Test func releasesAreSeparatedByABlankLine() {
        let t = FirmwareChangelog.tooltip([.init(version: "20261107", changes: ["a"]), .init(version: "20260326", changes: ["b"])])
        #expect(t == "Firmware 20261107 · Nov 7, 2026\n• a\n\nFirmware 20260326 · Mar 26, 2026\n• b")
    }

    @Test func modelsNamedInALineAreRecognised() {
        #expect(FirmwareChangelog.namesModel("HDHR5-2DT/4DT: Ham radio.", model: "HDHR5-4DT"))
        #expect(FirmwareChangelog.namesModel("HDHR5-2DT/4DT: Ham radio.", model: "HDHR5-2DT"))
        #expect(!FirmwareChangelog.namesModel("HDHR5-2DT/4DT: Ham radio.", model: "HDTC-2US"))
        #expect(FirmwareChangelog.namesModel("HDTC, HDHR4 models: Fix.", model: "HDTC-2US"))
        #expect(!FirmwareChangelog.namesModel("ATSC3 models: Fix.", model: "HDTC-2US"))
        #expect(!FirmwareChangelog.namesModel("Improvements to TLS.", model: "HDTC-2US"))
        #expect(!FirmwareChangelog.namesModel("HDTC: x", model: nil))
    }

    @Test func linesNamingThisTunersModelGetTheirOwnBoldGroup() {
        let r = FirmwareChangelog.Release(version: "20261107", changes: ["HDTC models: Fix X.", "ATSC3 models: Fix Y.", "Z."])
        let lines = FirmwareChangelog.tooltip([r], model: "HDTC-2US")?.split(separator: "\n").map(String.init)
        #expect(lines == ["Firmware 20261107 · Nov 7, 2026", "• Z.", "For your HDTC-2US:", "• " + FirmwareChangelog.bold("HDTC models: Fix X."),
                          "Only some models:", "• ATSC3 models: Fix Y."])
        #expect(FirmwareChangelog.bold("Ab1 ") == "𝗔𝗯𝟭 ")
    }
}
