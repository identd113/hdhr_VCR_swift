import Foundation
@testable import hdhr_VCR

// MARK: - HDHRDevice

extension HDHRDevice {
    // JSON-decoded so the custom Codable init handles field setup correctly.
    static func test(id: String = "FFFFFFFF", ip: String = "192.168.1.100", tuners: Int = 4) -> HDHRDevice {
        let json = """
        {"DeviceID":"\(id)","LocalIP":"\(ip)","TunerCount":\(tuners),"FirmwareVersion":"20240101"}
        """
        return try! JSONDecoder().decode(HDHRDevice.self, from: Data(json.utf8))
    }
}

// MARK: - LineupEntry

extension LineupEntry {
    static func test(number: String = "5.1", name: String = "KFOO", favorite: Bool = false) -> LineupEntry {
        LineupEntry(
            GuideNumber: number,
            GuideName: name,
            URL: "http://192.168.1.100:5004/auto/v\(number)",
            HD: 1,
            Favorite: favorite ? 1 : nil
        )
    }
}

// MARK: - Show

extension Show {
    static func testRecording(title: String = "The Tonight Show", channel: String = "5.1") -> Show {
        var s = Show.blank(channel: channel, device: "FFFFFFFF")
        s.show_title = title
        s.show_recording = true
        s.show_next = Date().addingTimeInterval(-300)
        s.show_end = Date().addingTimeInterval(1800)
        return s
    }

    static func testActive(title: String = "60 Minutes", channel: String = "3.1") -> Show {
        var s = Show.blank(channel: channel, device: "FFFFFFFF")
        s.show_title = title
        s.show_active = true
        s.show_next = Date().addingTimeInterval(3600)
        return s
    }

    static func testPaused(title: String = "Dateline NBC", channel: String = "4.1") -> Show {
        var s = Show.blank(channel: channel, device: "FFFFFFFF")
        s.show_title = title
        s.show_paused = true
        return s
    }

    static func testInactive(title: String = "Evening News") -> Show {
        var s = Show.blank(channel: "7.1", device: "FFFFFFFF")
        s.show_title = title
        s.show_active = false
        return s
    }
}

// MARK: - GuideEntry / GuideChannel

extension GuideEntry {
    // Creates a guide entry relative to now. offset/duration are in seconds.
    static func test(
        title: String,
        offset: TimeInterval = 0,
        duration: TimeInterval = 3600,
        episodeTitle: String? = nil,
        seriesID: String? = nil,
        genre: String = "Drama"
    ) -> GuideEntry {
        let start = Date().addingTimeInterval(offset)
        return GuideEntry(
            StartTime: Int(start.timeIntervalSince1970),
            EndTime: Int(start.addingTimeInterval(duration).timeIntervalSince1970),
            Title: title,
            EpisodeTitle: episodeTitle,
            EpisodeNumber: nil,
            Synopsis: nil,
            SeriesID: seriesID,
            ImageURL: nil,
            OriginalAirdate: nil,
            Filter: [genre]
        )
    }
}

extension GuideChannel {
    static func test(number: String, name: String, entries: [GuideEntry] = []) -> GuideChannel {
        GuideChannel(GuideNumber: number, GuideName: name, Affiliate: name, ImageURL: nil, Guide: entries)
    }
}

// Returns guide channels sorted favorites-first (matching what loadAllGuide() produces)
// and the corresponding lineup entries.
func makeTestGuideData() -> (channels: [GuideChannel], lineup: [LineupEntry]) {
    // Favorite channels must come first in the channels array (CableGuideView splits on favCount).
    let channels: [GuideChannel] = [
        .test(number: "2.1", name: "KFOO", entries: [
            .test(title: "Morning News", offset: -3600, duration: 7200, genre: "News"),
            .test(title: "The Tonight Show", offset: 3600, duration: 3600,
                  episodeTitle: "Guest: Someone Famous", seriesID: "EP12345", genre: "Talk"),
        ]),
        .test(number: "5.1", name: "KBAR", entries: [
            .test(title: "60 Minutes", offset: -1800, duration: 5400, genre: "News"),
            .test(title: "NCIS", offset: 3600, duration: 3600,
                  episodeTitle: "Fallout", seriesID: "EP67890", genre: "Drama"),
        ]),
        .test(number: "7.1", name: "KBAZ", entries: [
            .test(title: "Local News at 6", offset: -900, duration: 1800, genre: "News"),
            .test(title: "Jeopardy!", offset: 900, duration: 1800, genre: "Game Show"),
        ]),
        .test(number: "11.1", name: "KQUX-PBS", entries: [
            .test(title: "PBS NewsHour", offset: -1800, duration: 3600, genre: "News"),
            .test(title: "Frontline", offset: 1800, duration: 5400,
                  episodeTitle: "The Choice", seriesID: "EP11111", genre: "Documentary"),
        ]),
    ]
    let lineup: [LineupEntry] = [
        .test(number: "2.1",  name: "KFOO",     favorite: true),
        .test(number: "5.1",  name: "KBAR",     favorite: true),
        .test(number: "7.1",  name: "KBAZ",     favorite: false),
        .test(number: "11.1", name: "KQUX-PBS", favorite: false),
    ]
    return (channels, lineup)
}

// MARK: - AppState

// Creates an AppState prepopulated with fake data for snapshot rendering.
// AppState.init() fires Task { await startup() } — that task is async and won't
// execute before ImageRenderer renders synchronously, so it's safe to overwrite
// properties immediately after init.
@MainActor
func makeTestAppState(
    shows: [Show] = [],
    devices: [HDHRDevice] = [],
    lineups: [String: [LineupEntry]] = [:]
) -> AppState {
    let s = AppState()
    s.shows = shows
    s.devices = devices
    s.lineups = lineups
    s.isStartingUp = false
    s.statusMessage = "Ready"
    return s
}
