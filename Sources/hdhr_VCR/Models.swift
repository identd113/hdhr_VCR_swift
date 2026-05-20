import Foundation

// MARK: - EpochDate
// Decodes from string epoch ("1234567890"), numeric epoch, or "missing value" string.
// Always encodes as string epoch for JSON compat with the AppleScript app.

struct EpochDate: Codable, Equatable {
    var date: Date?

    init(_ date: Date? = nil) { self.date = date }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let str = try? c.decode(String.self) {
            if let epoch = Double(str), epoch > 0 {
                date = Date(timeIntervalSince1970: epoch)
            } else {
                date = nil  // "missing value", "0", empty
            }
        } else if let epoch = try? c.decode(Double.self), epoch > 0 {
            date = Date(timeIntervalSince1970: epoch)
        } else {
            date = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let d = date {
            try c.encode(String(Int(d.timeIntervalSince1970)))
        } else {
            try c.encode("missing value")
        }
    }
}

// MARK: - Show

struct Show: Identifiable, Equatable {
    var id: String { show_id }
    var show_id: String
    var show_title: String
    var show_is_series: Bool
    var show_use_seriesid: Bool
    var show_use_seriesid_all: Bool
    var show_air_date: [String]
    var show_channel: String
    var show_time: Double           // UTC decimal hours (0–24), e.g. 20.5 = 8:30 PM UTC
    var show_length: Int            // minutes
    var show_next: EpochDate
    var show_end: EpochDate
    var show_active: Bool
    var hdhr_record: String         // device ID, e.g. "105404BE"
    var show_url: String            // stream URL from lineup
    var show_seriesid: String
    var show_fail_count: Int
    var show_fail_reason: String
    var show_logo_url: String
    var show_transcode: String      // "none", "heavy", "mobile", "internet720"…
    var show_tags: String
    var show_recording: Bool
    var show_last: EpochDate
    var notify_upnext_time: EpochDate
    var notify_recording_time: EpochDate
    var show_dir: String            // recording destination (Mac alias or POSIX)
    var show_temp_dir: String       // same as show_dir in most configs
    var show_recording_path: String // path of active/last recording file

    var state: ShowState {
        if !show_is_series { return .single }
        if show_use_seriesid_all { return .seriesAll }
        if show_use_seriesid { return .seriesChannel }
        return .dateTime
    }

    // Convert Mac alias path "Vol:Dir:Sub:" → "/Volumes/Vol/Dir/Sub"
    var posixRecordDir: String {
        if show_temp_dir.contains(":") && !show_temp_dir.hasPrefix("/") {
            let parts = show_temp_dir.split(separator: ":", omittingEmptySubsequences: true)
            return "/Volumes/" + parts.joined(separator: "/")
        }
        return show_temp_dir.isEmpty ? (NSHomeDirectory() + "/Movies") : show_temp_dir
    }

    func outputPath(date: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")  // fixed format, must not vary by locale
        fmt.dateFormat = "yyyyMMdd_HHmm"
        let dateStr = fmt.string(from: date)
        let safe = show_title.replacingOccurrences(of: "/", with: "-")
        let ext = (show_transcode.lowercased() == "none" || show_transcode.isEmpty) ? ".m2ts" : ".mkv"
        return (posixRecordDir as NSString).appendingPathComponent("\(safe)_\(show_channel)_\(dateStr)\(ext)")
    }

    static func blank(channel: String = "", device: String = "") -> Show {
        Show(
            show_id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            show_title: "", show_is_series: false, show_use_seriesid: false,
            show_use_seriesid_all: false, show_air_date: [], show_channel: channel,
            show_time: 20.0, show_length: 60, show_next: EpochDate(), show_end: EpochDate(),
            show_active: true, hdhr_record: device, show_url: "", show_seriesid: "",
            show_fail_count: 0, show_fail_reason: "", show_logo_url: "", show_transcode: "none",
            show_tags: "", show_recording: false, show_last: EpochDate(),
            notify_upnext_time: EpochDate(), notify_recording_time: EpochDate(),
            show_dir: "", show_temp_dir: "", show_recording_path: ""
        )
    }
}

enum ShowState: String, CaseIterable {
    case single = "Single"
    case dateTime = "DateTime"
    case seriesChannel = "SeriesID(Channel)"
    case seriesAll = "SeriesID(All)"
}

// MARK: - Codable conformance (custom to handle missing / renamed fields)

extension Show: Codable {
    enum CodingKeys: String, CodingKey {
        case show_id, show_title, show_is_series, show_use_seriesid, show_use_seriesid_all
        case show_air_date, show_channel, show_time, show_length
        case show_next, show_end, show_active, hdhr_record, show_url
        case show_seriesid, show_fail_count, show_fail_reason, show_logo_url
        case show_transcode, show_tags, show_recording, show_last
        case notify_upnext_time, notify_recording_time
        case show_dir, show_temp_dir, show_recording_path
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        show_id            = try c.decode(String.self, forKey: .show_id)
        show_title         = (try? c.decode(String.self, forKey: .show_title)) ?? ""
        show_is_series     = (try? c.decode(Bool.self,   forKey: .show_is_series)) ?? false
        show_use_seriesid  = (try? c.decode(Bool.self,   forKey: .show_use_seriesid)) ?? false
        show_use_seriesid_all = (try? c.decode(Bool.self, forKey: .show_use_seriesid_all)) ?? false
        show_air_date      = (try? c.decode([String].self, forKey: .show_air_date)) ?? []
        show_channel       = (try? c.decode(String.self, forKey: .show_channel)) ?? ""
        show_time          = (try? c.decode(Double.self, forKey: .show_time)) ?? 20.0
        // show_length may arrive as Double from JSONHelper
        if let i = try? c.decode(Int.self, forKey: .show_length) { show_length = i }
        else { show_length = Int((try? c.decode(Double.self, forKey: .show_length)) ?? 60) }
        show_next          = (try? c.decode(EpochDate.self, forKey: .show_next)) ?? EpochDate()
        show_end           = (try? c.decode(EpochDate.self, forKey: .show_end)) ?? EpochDate()
        show_active        = (try? c.decode(Bool.self,   forKey: .show_active)) ?? true
        hdhr_record        = (try? c.decode(String.self, forKey: .hdhr_record)) ?? ""
        show_url           = (try? c.decode(String.self, forKey: .show_url)) ?? ""
        show_seriesid      = (try? c.decode(String.self, forKey: .show_seriesid)) ?? ""
        if let i = try? c.decode(Int.self, forKey: .show_fail_count) { show_fail_count = i }
        else { show_fail_count = Int((try? c.decode(Double.self, forKey: .show_fail_count)) ?? 0) }
        show_fail_reason   = (try? c.decode(String.self, forKey: .show_fail_reason)) ?? ""
        show_logo_url      = (try? c.decode(String.self, forKey: .show_logo_url)) ?? ""
        show_transcode     = (try? c.decode(String.self, forKey: .show_transcode)) ?? "none"
        show_tags          = (try? c.decode(String.self, forKey: .show_tags)) ?? ""
        show_recording     = (try? c.decode(Bool.self,   forKey: .show_recording)) ?? false
        show_last          = (try? c.decode(EpochDate.self, forKey: .show_last)) ?? EpochDate()
        notify_upnext_time     = (try? c.decode(EpochDate.self, forKey: .notify_upnext_time)) ?? EpochDate()
        notify_recording_time  = (try? c.decode(EpochDate.self, forKey: .notify_recording_time)) ?? EpochDate()
        show_dir           = (try? c.decode(String.self, forKey: .show_dir)) ?? ""
        show_temp_dir      = (try? c.decode(String.self, forKey: .show_temp_dir)) ?? ""
        show_recording_path = (try? c.decode(String.self, forKey: .show_recording_path)) ?? ""
    }
}

// MARK: - AppConfig / ConfigFile

struct AppConfig: Codable {
    // Notifications
    var Notify_recording: Double = 15.5     // minutes before recording alert
    var Notify_upnext: Double    = 35.0     // minutes before show airs

    // Guide
    var GuideHours: Int          = 24       // hours ahead to fetch

    // Recording
    var Default_transcode: String   = "none"  // none | heavy | mobile | internet720
    var Fail_count_setting: Int     = 3       // deactivate show after N failures
    var Min_disk_free_gb: Double    = 10.0    // refuse to record below this free space
    var Idle_timer_interval: Int    = 10      // seconds between idle checks

    // Series
    var Series_scan_retry_hours: Int = 4     // hours to wait before retrying guide scan

    // Default recording folder (POSIX path; empty = ~/Movies)
    // Stored here for compat with the AppleScript config (Hdhr_setup_folder field).
    var Hdhr_setup_folder: String = ""

    var Verbose_curl: Bool = false
    var Config_version: String = "1"
}

struct ConfigFile: Codable {
    var config: AppConfig
    var the_shows: [Show]
}

// MARK: - HDHomeRun Device

struct HDHRDevice: Identifiable, Equatable {
    var id: String { DeviceID }
    var DeviceID: String
    var LocalIP: String     // present in cloud response; extracted from BaseURL for local/mDNS responses
    var BaseURL: String?
    var TunerCount: Int?
    var FirmwareVersion: String?
    var DeviceAuth: String?   // used to call SiliconDust cloud guide API (EXTEND and similar)
    var LineupURL: String?    // raw lineup URL from discover.json (uses mDNS host if available)

    var streamBase: String { "http://\(LocalIP):5004" }
    var guideURL:   String { "http://\(LocalIP)/guide.json" }
    var lineupURL:  String { LineupURL ?? "http://\(LocalIP)/lineup.json" }
}

extension HDHRDevice: Codable {
    enum CodingKeys: String, CodingKey {
        case DeviceID, LocalIP, BaseURL, TunerCount, FirmwareVersion, DeviceAuth, LineupURL
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        DeviceID        = try  c.decode(String.self, forKey: .DeviceID)
        BaseURL         = try? c.decode(String.self, forKey: .BaseURL)
        TunerCount      = try? c.decode(Int.self,    forKey: .TunerCount)
        FirmwareVersion = try? c.decode(String.self, forKey: .FirmwareVersion)
        DeviceAuth      = try? c.decode(String.self, forKey: .DeviceAuth)
        LineupURL       = try? c.decode(String.self, forKey: .LineupURL)
        // Cloud response includes LocalIP directly; mDNS/device response omits it — extract host from BaseURL
        if let ip = try? c.decode(String.self, forKey: .LocalIP) {
            LocalIP = ip
        } else if let host = BaseURL.flatMap({ URL(string: $0)?.host }) {
            LocalIP = host
        } else {
            throw DecodingError.keyNotFound(CodingKeys.LocalIP,
                .init(codingPath: decoder.codingPath, debugDescription: "LocalIP missing and BaseURL not usable"))
        }
    }
}

// MARK: - Guide / Lineup

struct LineupEntry: Codable, Identifiable {
    var id: String { GuideNumber }
    var GuideNumber: String
    var GuideName: String
    var URL: String?
    var HD: Int?
    var Favorite: Int?
}

struct GuideChannel: Codable {
    var GuideNumber: String
    var GuideName: String
    var Guide: [GuideEntry]?
}

struct GuideEntry: Codable, Identifiable, Hashable {
    static func == (lhs: GuideEntry, rhs: GuideEntry) -> Bool { lhs.StartTime == rhs.StartTime }
    func hash(into hasher: inout Hasher) { hasher.combine(StartTime) }
    var id: Int { StartTime }
    var StartTime: Int
    var EndTime: Int
    var Title: String
    var EpisodeTitle: String?
    var EpisodeNumber: String?
    var Synopsis: String?
    var SeriesID: String?
    var ImageURL: String?
    var OriginalAirdate: Int?

    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(StartTime)) }
    var endDate:   Date { Date(timeIntervalSince1970: TimeInterval(EndTime)) }
    var durationMinutes: Int { (EndTime - StartTime) / 60 }
}
