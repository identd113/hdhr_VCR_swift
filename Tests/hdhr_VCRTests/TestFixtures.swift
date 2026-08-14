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

// MARK: - GuideChannel / GuideEntry

extension GuideChannel {
    // One channel with a single on-air (or arbitrary window) GuideEntry — enough to drive
    // AppState.onAirNow()/WatchNowView's ScrollView branch without a real guide.json fetch.
    static func test(number: String = "5.1", name: String = "KFOO", title: String = "Test Show",
                      start: Int, end: Int) -> GuideChannel {
        let json = """
        {"GuideNumber":"\(number)","GuideName":"\(name)","Guide":[
            {"StartTime":\(start),"EndTime":\(end),"Title":"\(title)"}
        ]}
        """
        return try! JSONDecoder().decode(GuideChannel.self, from: Data(json.utf8))
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
    // Unique per-call temp dir — any test that reaches saveConfig() (e.g. deleteShow) writes here
    // instead of the real ~/Library/Application Support/hdhrVCRplus/ config the deployed app uses.
    let tempConfigDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let s = AppState(configManager: ConfigManager(appSupportDir: tempConfigDir))
    // skipStartup must be set before any suspension point so startup()'s guard fires
    // before the Task runs on the main actor. Prevents idleLoop from spinning forever.
    s.skipStartup = true
    s.shows = shows
    s.devices = devices
    s.lineups = lineups
    s.isStartingUp = false
    s.statusMessage = "Ready"
    s.config.Web_server_enabled = false
    return s
}
