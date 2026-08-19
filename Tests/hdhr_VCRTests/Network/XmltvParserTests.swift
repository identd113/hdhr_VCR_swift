import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - XmltvParser
//
// Entirely uncovered before this: the XMLTV ingestion path (Guide_use_xml) has to produce the
// same [GuideChannel] shape as the JSON guide.php decoder, and a subtly wrong date/timezone
// parse or channel-number fallback would silently corrupt every downstream schedule computed
// from it. Covers the pure static helpers (parseDateTime/parseDate/extractGuideName) plus a
// couple of full parse() passes for the shape/sort/error-signaling contract described in the
// `parse(_:)` doc comment.

@Suite("XmltvParser static helpers")
struct XmltvParserStaticHelperTests {

    @Test func parseDateTime_utcOffset_and_negativeOffset_agreeOnSameInstant() {
        // 11:00 UTC and 06:00 at -0500 are the same instant — proves the embedded timezone
        // offset is actually applied, not just stripped.
        let utc     = XmltvParser.parseDateTime("20260618110000 +0000")
        let eastern = XmltvParser.parseDateTime("20260618060000 -0500")
        #expect(utc != nil)
        #expect(utc == eastern)
    }

    @Test func parseDateTime_matchesManuallyComputedEpoch() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 18
        comps.hour = 6; comps.minute = 0; comps.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let expected = Int(cal.date(from: comps)!.timeIntervalSince1970)
        #expect(XmltvParser.parseDateTime("20260618060000 +0000") == expected)
    }

    @Test func parseDateTime_malformedString_returnsNil() {
        #expect(XmltvParser.parseDateTime("not-a-date") == nil)
        #expect(XmltvParser.parseDateTime("") == nil)
    }

    @Test func parseDate_matchesManuallyComputedMidnightUTC() {
        var comps = DateComponents()
        comps.year = 1994; comps.month = 2; comps.day = 2
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let expected = Int(cal.date(from: comps)!.timeIntervalSince1970)
        #expect(XmltvParser.parseDate("19940202") == expected)
    }

    @Test func parseDate_malformedString_returnsNil() {
        #expect(XmltvParser.parseDate("not-a-date") == nil)
    }

    // One (names, lcn → expected) table — every row is a single extractGuideName call + compare.
    @Test(arguments: [
        // Real-world shape: ["11.1 KAREHD", "NBC"] — last entry is the affiliate, not a channel name.
        (names: ["11.1 KAREHD", "NBC"],       lcn: "11.1" as String?, expected: "KAREHD"),        // stripsLCNPrefixAndDropsTrailingAffiliate
        (names: ["Some Channel", "Affiliate"], lcn: "99.9",           expected: "Some Channel"),  // noLCNMatch_fallsBackToFirstCandidate
        // count <= 1 means nothing gets dropped as a trailing affiliate.
        (names: ["Solo Channel"],              lcn: nil,              expected: "Solo Channel"),  // singleName_keptAsIs
        (names: [],                            lcn: "5.1",            expected: ""),              // emptyNames_returnsEmpty
    ])
    func extractGuideName(_ row: (names: [String], lcn: String?, expected: String)) {
        #expect(XmltvParser.extractGuideName(row.names, lcn: row.lcn) == row.expected)
    }
}

@Suite("XmltvParser full parse()")
struct XmltvParserFullParseTests {

    private let sampleXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tv>
      <channel id="I11.1.hdhomerun.com">
        <display-name>11.1 KAREHD</display-name>
        <display-name>NBC</display-name>
        <lcn>11.1</lcn>
      </channel>
      <channel id="I5.1.hdhomerun.com">
        <display-name>5.1 KSTPHD</display-name>
        <lcn>5.1</lcn>
      </channel>
      <channel id="I999.no-lcn.hdhomerun.com">
        <display-name>Not A Number</display-name>
      </channel>
      <programme start="20260618063000 +0000" stop="20260618070000 +0000" channel="I11.1.hdhomerun.com">
        <title>Later Show</title>
      </programme>
      <programme start="20260618060000 +0000" stop="20260618063000 +0000" channel="I11.1.hdhomerun.com">
        <title>Today</title>
        <sub-title>Morning News</sub-title>
        <desc>Daily news program.</desc>
        <category>News</category>
        <series-id>SID001</series-id>
        <episode-num system="onscreen">S01E01</episode-num>
        <date>19940202</date>
        <icon src="http://example.com/icon.png"/>
      </programme>
    </tv>
    """

    @Test func parsesChannelsAndProgrammes() {
        let parser = XmltvParser()
        let (channels, succeeded) = parser.parse(Data(sampleXML.utf8))
        #expect(succeeded == true)

        // The lcn-less channel (no numeric display-name either) is dropped — a guide channel
        // with no GuideNumber can't be scheduled against.
        #expect(channels.count == 2)

        // Sorted by GuideNumber ("11.1" before "5.1" — string sort of these two, not numeric).
        #expect(channels.map(\.GuideNumber) == ["11.1", "5.1"])

        let ch11 = channels.first { $0.GuideNumber == "11.1" }!
        #expect(ch11.GuideName == "KAREHD")
        #expect(ch11.Affiliate == "NBC")

        let ch5 = channels.first { $0.GuideNumber == "5.1" }!
        #expect(ch5.GuideName == "KSTPHD")
        // Affiliate is unconditionally displayNames.last (didEndElement's "channel" case) — unlike
        // GuideName's extractGuideName, it has no single-name special case, so a channel with only
        // one display-name gets that same name duplicated as its own "affiliate".
        #expect(ch5.Affiliate == "5.1 KSTPHD")

        // Programmes for channel 11.1 come back sorted by StartTime, not XML document order
        // (the sample deliberately lists "Later Show" before "Today" in the XML).
        let entries = ch11.Guide ?? []
        #expect(entries.map(\.Title) == ["Today", "Later Show"])

        let today = entries[0]
        #expect(today.EpisodeTitle == "Morning News")
        #expect(today.EpisodeNumber == "S01E01")
        #expect(today.Synopsis == "Daily news program.")
        #expect(today.SeriesID == "SID001")
        #expect(today.Filter == ["News"])
        #expect(today.ImageURL == "http://example.com/icon.png")
        #expect(today.OriginalAirdate == XmltvParser.parseDate("19940202"))
        #expect(today.StartTime == XmltvParser.parseDateTime("20260618060000 +0000"))
        #expect(today.EndTime == XmltvParser.parseDateTime("20260618063000 +0000"))
    }

    // Two distinct kinds of invalid input, merged into one parameterized test rather than two
    // near-identical ones — truncated-but-nonempty XML and zero-byte input could plausibly hit
    // different code inside XMLParser (an empty document isn't guaranteed to raise the same way
    // a mid-element truncation does), so both are worth keeping, just not as separate test bodies.
    @Test(arguments: [
        Data("<tv><channel id=\"x\">".utf8),  // truncated, unclosed
        Data(),                                // empty
    ])
    func invalidXML_reportsFailureWithoutCrashing(_ data: Data) {
        let parser = XmltvParser()
        let (channels, succeeded) = parser.parse(data)
        #expect(succeeded == false)
        #expect(channels.isEmpty)
    }
}
