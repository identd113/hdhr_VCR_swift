import Testing
import Foundation
@testable import hdhr_guide_core

@Suite("GuidePayload decoding — decode-fallback defaults")
struct GuideDTOsTests {

    private func decode(_ json: String) throws -> GuidePayload {
        try JSONDecoder().decode(GuidePayload.self, from: Data(json.utf8))
    }

    @Test func decodesAllFieldsWhenPresent() throws {
        let payload = try decode("""
        {"deviceId":"AABBCCDD","winStart":1000,"winSec":86400,"devices":[],"channels":[],
         "sportsPaddingEnabled":false,"terminalGuideEnabled":false}
        """)
        #expect(payload.deviceId == "AABBCCDD")
        #expect(payload.winStart == 1000)
        #expect(payload.winSec == 86400)
        #expect(payload.sportsPaddingEnabled == false)
        #expect(payload.terminalGuideEnabled == false)
    }

    // Both flags were added after the field was first shipped — an old server (or one just not
    // yet redeployed after adding the field) omits them entirely. Both must default to `true`
    // (matching Sports_padding_enabled/Terminal_guide_enabled's own defaults in Models.swift), not
    // fail to decode the whole payload and not silently default to `false` (which would wrongly
    // gate Bonus Time off, or refuse to run entirely, against a perfectly normal older server).
    @Test func missingSportsPaddingEnabledDefaultsTrue() throws {
        let payload = try decode("""
        {"deviceId":"AABBCCDD","winStart":1000,"winSec":86400,"devices":[],"channels":[],
         "terminalGuideEnabled":true}
        """)
        #expect(payload.sportsPaddingEnabled == true)
    }

    @Test func missingTerminalGuideEnabledDefaultsTrue() throws {
        let payload = try decode("""
        {"deviceId":"AABBCCDD","winStart":1000,"winSec":86400,"devices":[],"channels":[],
         "sportsPaddingEnabled":true}
        """)
        #expect(payload.terminalGuideEnabled == true)
    }

    @Test func missingBothNewFieldsDefaultsBothTrue() throws {
        let payload = try decode("""
        {"deviceId":"AABBCCDD","winStart":1000,"winSec":86400,"devices":[],"channels":[]}
        """)
        #expect(payload.sportsPaddingEnabled == true)
        #expect(payload.terminalGuideEnabled == true)
    }

    @Test func decodesNestedChannelsAndEntries() throws {
        let payload = try decode("""
        {"deviceId":"AABBCCDD","winStart":1000,"winSec":86400,"devices":[{"deviceId":"AABBCCDD","active":1,"total":2}],
         "channels":[{"guideNumber":"5.1","guideName":"KVUE","hd":true,"favorite":false,
           "entries":[{"title":"Jeopardy!","startTime":2000,"endTime":3000,"isRecording":false,"isScheduled":false}]}]}
        """)
        #expect(payload.devices.first?.deviceId == "AABBCCDD")
        #expect(payload.devices.first?.active == 1)
        let channel = try #require(payload.channels.first)
        #expect(channel.guideNumber == "5.1")
        #expect(channel.hd == true)
        let entry = try #require(channel.entries.first)
        #expect(entry.title == "Jeopardy!")
        #expect(entry.episodeTitle == nil)
        #expect(entry.startDate.timeIntervalSince1970 == 2000)
        #expect(entry.endDate.timeIntervalSince1970 == 3000)
    }

    @Test func missingRequiredFieldThrows() {
        // "deviceId" is required, not decode-fallback — a payload missing it is a real server bug,
        // not a version-skew case, so this should fail to decode rather than silently default.
        #expect(throws: (any Error).self) {
            try decode("""
            {"winStart":1000,"winSec":86400,"devices":[],"channels":[]}
            """)
        }
    }
}

@Suite("Other response DTOs — plain decode, no fallback fields")
struct OtherDTOsTests {

    @Test func recordResponseDecodesOptionalFieldsAsNilWhenAbsent() throws {
        let resp = try JSONDecoder().decode(RecordResponse.self, from: Data(#"{"ok":true}"#.utf8))
        #expect(resp.ok == true)
        #expect(resp.error == nil)
        #expect(resp.title == nil)
        #expect(resp.tunerFull == nil)
        #expect(resp.recStarted == nil)
    }

    @Test func deleteResponseDecodesError() throws {
        let resp = try JSONDecoder().decode(DeleteResponse.self, from: Data(#"{"ok":false,"error":"not found"}"#.utf8))
        #expect(resp.ok == false)
        #expect(resp.error == "not found")
    }

    @Test func toggleFavoriteResponseDecodesIsFavorite() throws {
        let resp = try JSONDecoder().decode(ToggleFavoriteResponse.self, from: Data(#"{"ok":true,"isFavorite":true}"#.utf8))
        #expect(resp.isFavorite == true)
    }
}
