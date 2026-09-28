import Testing
import Foundation
@testable import hdhr_VCR

// Covers GuideChannel.init(from:)'s lossy decode of its Guide array — a plain [GuideEntry] would
// discard the whole channel's guide (and, before GuideStore.load's own catch, the entire device's
// fetch) if even one entry has a malformed field, since Swift's array Decodable conformance is
// all-or-nothing per element. Found in code review 2026-09-28.
struct GuideChannelDecodingTests {

    private func decodeChannel(guideJSON: String) throws -> GuideChannel {
        let json = """
        {"GuideNumber":"5.1","GuideName":"Test Channel","Guide":\(guideJSON)}
        """
        return try JSONDecoder().decode(GuideChannel.self, from: Data(json.utf8))
    }

    @Test func allValidEntries_decodesEveryOne() throws {
        let ch = try decodeChannel(guideJSON: """
        [
            {"StartTime":1000,"EndTime":2000,"Title":"Show A"},
            {"StartTime":2000,"EndTime":3000,"Title":"Show B"}
        ]
        """)
        #expect(ch.Guide?.map { $0.Title } == ["Show A", "Show B"])
    }

    // The actual malformed-entry shape this guards against: StartTime arriving as a JSON string
    // instead of a number (a known class of upstream glitch this app defends against elsewhere).
    @Test func oneMalformedEntry_isSkipped_othersSurvive() throws {
        let ch = try decodeChannel(guideJSON: """
        [
            {"StartTime":1000,"EndTime":2000,"Title":"Show A"},
            {"StartTime":"not-a-number","EndTime":3000,"Title":"Bad Entry"},
            {"StartTime":3000,"EndTime":4000,"Title":"Show C"}
        ]
        """)
        #expect(ch.Guide?.map { $0.Title } == ["Show A", "Show C"])
    }

    @Test func missingRequiredField_isSkipped() throws {
        let ch = try decodeChannel(guideJSON: """
        [
            {"StartTime":1000,"EndTime":2000,"Title":"Show A"},
            {"StartTime":2000,"Title":"Missing EndTime"}
        ]
        """)
        #expect(ch.Guide?.map { $0.Title } == ["Show A"])
    }

    @Test func allEntriesMalformed_yieldsEmptyArray_notNil() throws {
        let ch = try decodeChannel(guideJSON: """
        [{"StartTime":"nope","EndTime":"nope","Title":"Bad"}]
        """)
        #expect(ch.Guide == [])
    }

    @Test func missingGuideKey_yieldsNil() throws {
        let ch = try JSONDecoder().decode(GuideChannel.self, from: Data("""
        {"GuideNumber":"5.1","GuideName":"Test Channel"}
        """.utf8))
        #expect(ch.Guide == nil)
    }

    // Round-trips through the explicit memberwise init added alongside init(from:) — confirms
    // XmltvParser.swift's construction syntax (labeled GuideNumber:/GuideName:/etc.) still works.
    @Test func memberwiseInit_stillConstructible() {
        let ch = GuideChannel(GuideNumber: "5.1", GuideName: "Test", Affiliate: nil, ImageURL: nil, Guide: [])
        #expect(ch.GuideNumber == "5.1")
        #expect(ch.Guide == [])
    }
}
