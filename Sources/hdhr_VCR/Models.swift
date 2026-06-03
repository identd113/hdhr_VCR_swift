import Foundation
import OSLog

// MARK: - LogLevel

enum LogLevel {
    case info, warning, error
}

private let appLog = Logger(subsystem: "com.hdhr.vcrplus", category: "app")

/// Universal log function. Safe to call from any actor or thread.
func glog(_ msg: String, level: LogLevel = .info) {
    switch level {
    case .info:    appLog.info("\(msg, privacy: .public)")
    case .warning: appLog.warning("\(msg, privacy: .public)")
    case .error:   appLog.error("\(msg, privacy: .public)")
    }
}

// MARK: - Show

struct Show: Identifiable, Equatable {
    var id: String { show_id }
    var isSeries: Bool { state.isSeries }
    var show_id: String
    var show_title: String
    var show_is_series: Bool
    var show_use_seriesid: Bool
    var show_use_seriesid_all: Bool
    var show_air_date: [String]
    var show_channel: String
    var show_time: Double           // local decimal hours (0–24), e.g. 20.5 = 8:30 PM local time
    var show_length: Int            // minutes
    var show_next: Date?
    var show_end: Date?
    var show_active: Bool
    var show_paused: Bool           // auto-paused (failures, manual stop, skip); recovers automatically
    var hdhr_record: String         // device ID, e.g. "105404BE"
    var show_url: String            // stream URL from lineup
    var show_seriesid: String
    var show_fail_count: Int
    var show_fail_reason: String
    var show_logo_url: String
    var show_transcode: String      // "none", "heavy", "mobile", "internet720"…
    var show_tags: String
    var show_recording: Bool
    var show_last: Date?
    var notify_upnext_time: Date?
    var notify_recording_time: Date?
    var show_dir: String            // recording destination (POSIX path)
    var show_temp_dir: String       // same as show_dir in most configs
    var show_recording_path: String // path of active/last recording file
    var show_genre: String          // first genre tag from guide (e.g. "Sports")
    var show_bonus_time: Bool       // true = extend recording past guide end
    var discord_start_msg_id: String = ""   // message ID of the "Recording Started" embed; "" = none
    var show_tuner_resource: String  = ""   // e.g. "tuner0" — from X-HDHomeRun-Resource response header

    var state: ShowState {
        if !show_is_series { return .single }
        if show_use_seriesid_all { return .seriesAll }
        if show_use_seriesid { return .seriesChannel }
        return .dateTime
    }

    var posixRecordDir: String {
        let primary  = show_dir.isEmpty      ? (NSHomeDirectory() + "/Movies/hdhr_videos") : show_dir
        let fallback = show_temp_dir.isEmpty ? (NSHomeDirectory() + "/Movies/hdhr_videos") : show_temp_dir
        guard primary != fallback else { return primary }
        // Use primary only when its parent directory exists (i.e. the volume is mounted)
        let parent = URL(fileURLWithPath: primary).deletingLastPathComponent().path
        return FileManager.default.fileExists(atPath: parent) ? primary : fallback
    }

    private static let outputDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")  // fixed format, must not vary by locale
        f.dateFormat = "yyyyMMdd_HHmm"
        return f
    }()

    func outputPath(date: Date = Date()) -> String {
        let dateStr = Self.outputDateFormatter.string(from: date)
        let safe = show_title.replacingOccurrences(of: "/", with: "-")
        let ext = (show_transcode.lowercased() == "none" || show_transcode.isEmpty) ? ".m2ts" : ".mkv"
        return (posixRecordDir as NSString).appendingPathComponent("\(safe)_\(show_channel)_\(dateStr)\(ext)")
    }

    static func blank(channel: String = "", device: String = "") -> Show {
        Show(
            show_id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            show_title: "", show_is_series: false, show_use_seriesid: false,
            show_use_seriesid_all: false, show_air_date: [], show_channel: channel,
            show_time: 20.0, show_length: 60, show_next: nil, show_end: nil,
            show_active: true, show_paused: false, hdhr_record: device, show_url: "", show_seriesid: "",
            show_fail_count: 0, show_fail_reason: "", show_logo_url: "", show_transcode: "none",
            show_tags: "", show_recording: false, show_last: nil,
            notify_upnext_time: nil, notify_recording_time: nil,
            show_dir: "", show_temp_dir: "", show_recording_path: "", show_genre: "",
            show_bonus_time: false
        )
    }

    mutating func recordFailure(reason: String) {
        show_fail_count += 1
        show_fail_reason = reason
        // show_paused is NOT set here — startRecording's threshold check pauses the show
        // after Fail_count_setting consecutive failures, allowing 1 retry per idle loop tick.
    }

    mutating func clearFailures() {
        show_fail_count = 0
        show_fail_reason = ""
    }
}

enum ShowState: String, CaseIterable {
    case single = "Single"
    case dateTime = "DateTime"
    case seriesChannel = "SeriesID(Channel)"
    case seriesAll = "SeriesID(All)"

    var isSeries: Bool { self == .seriesChannel || self == .seriesAll }
}

// MARK: - Codable conformance (custom to handle missing / renamed fields)

extension Show: Codable {
    enum CodingKeys: String, CodingKey {
        case show_id, show_title, show_is_series, show_use_seriesid, show_use_seriesid_all
        case show_air_date, show_channel, show_time, show_length
        case show_next, show_end, show_active, show_paused, hdhr_record, show_url
        case show_seriesid, show_fail_count, show_fail_reason, show_logo_url
        case show_transcode, show_tags, show_recording, show_last
        case notify_upnext_time, notify_recording_time
        case show_dir, show_temp_dir, show_recording_path, show_genre, show_bonus_time
        case discord_start_msg_id, show_tuner_resource
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
        show_length        = (try? c.decode(Int.self, forKey: .show_length)) ?? 60
        show_next          = try? c.decode(Date.self, forKey: .show_next)
        show_end           = try? c.decode(Date.self, forKey: .show_end)
        show_active        = (try? c.decode(Bool.self,   forKey: .show_active)) ?? true
        show_paused        = (try? c.decode(Bool.self,   forKey: .show_paused)) ?? false
        hdhr_record        = (try? c.decode(String.self, forKey: .hdhr_record)) ?? ""
        show_url           = (try? c.decode(String.self, forKey: .show_url)) ?? ""
        show_seriesid      = (try? c.decode(String.self, forKey: .show_seriesid)) ?? ""
        show_fail_count    = (try? c.decode(Int.self, forKey: .show_fail_count)) ?? 0
        show_fail_reason   = (try? c.decode(String.self, forKey: .show_fail_reason)) ?? ""
        show_logo_url      = (try? c.decode(String.self, forKey: .show_logo_url)) ?? ""
        show_transcode     = (try? c.decode(String.self, forKey: .show_transcode)) ?? "none"
        show_tags          = (try? c.decode(String.self, forKey: .show_tags)) ?? ""
        show_recording     = (try? c.decode(Bool.self,   forKey: .show_recording)) ?? false
        show_last          = try? c.decode(Date.self, forKey: .show_last)
        notify_upnext_time     = try? c.decode(Date.self, forKey: .notify_upnext_time)
        notify_recording_time  = try? c.decode(Date.self, forKey: .notify_recording_time)
        show_dir           = (try? c.decode(String.self, forKey: .show_dir)) ?? ""
        show_temp_dir      = (try? c.decode(String.self, forKey: .show_temp_dir)) ?? ""
        show_recording_path = (try? c.decode(String.self, forKey: .show_recording_path)) ?? ""
        show_genre          = (try? c.decode(String.self, forKey: .show_genre)) ?? ""
        show_bonus_time     = (try? c.decode(Bool.self,   forKey: .show_bonus_time))
            ?? show_genre.lowercased().contains("sports")
        discord_start_msg_id = (try? c.decode(String.self, forKey: .discord_start_msg_id)) ?? ""
        show_tuner_resource  = (try? c.decode(String.self, forKey: .show_tuner_resource))  ?? ""
    }
}

// MARK: - AppConfig / ConfigFile

struct AppConfig: Equatable {
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

    // Default recording folder (POSIX path; empty = ~/Movies/hdhr_videos)
    var Hdhr_setup_folder: String = ""

    var Network_interface: String = ""  // empty = Auto (OS chooses interface)
    var Verbose_curl: Bool = false
    var Watch_in_VLC: Bool = false
    var Watch_in_VLC_initialized: Bool = false  // set true after first auto-detect so user toggles are preserved
    var Player_buffer_min_rate: Int = 93        // adaptive buffer fill-phase floor (90–100); 100 = disabled
    // Bonus Time: extends recording past the guide end for sports shows
    var Sports_padding_enabled: Bool = true
    var Sports_padding_minutes: Int  = 30   // user-settable 10–60 min, default 30
    var Config_version: String = "2"

    /// Returns `baseURL` with a `?transcode=<profile>` query appended when the effective
    /// profile is not empty or "none". `override` takes precedence over `Default_transcode`.
    func applyTranscode(_ baseURL: String, override: String? = nil) -> String {
        let profile = (override ?? Default_transcode).lowercased().trimmingCharacters(in: .whitespaces)
        return (profile.isEmpty || profile == "none") ? baseURL : "\(baseURL)?transcode=\(profile)"
    }

    // Discord webhook
    var Discord_webhook_url: String  = ""
    var Discord_on_start:    Bool    = true    // Recording Started
    var Discord_on_complete: Bool    = true    // Recording Complete
    var Discord_on_failed:   Bool    = true    // Recording Failed
    var Discord_on_paused:   Bool    = true    // Show Paused (max fails / no air days)
    var Discord_on_skipped:  Bool    = true    // Skipped — disk full
    var Discord_on_conflict: Bool    = true    // Tuner Conflict
    var Discord_on_guide_error: Bool = true    // Guide Load Failed
    var Discord_on_upnext:    Bool   = false   // Up Next reminder
    var Discord_on_soon:      Bool   = false   // Recording Soon reminder
    var Discord_on_show_added: Bool  = false   // Show Added
    var Discord_on_progress:  Bool   = false   // Edit start embed every 5 min with elapsed/remaining
    var Discord_enabled:      Bool   = false   // Master enable/disable toggle

    // Web server
    var Web_server_enabled: Bool = false
    var Web_server_port:    Int  = 1980
}

extension AppConfig: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Notify_recording      = (try? c.decode(Double.self,  forKey: .Notify_recording))      ?? 15.5
        Notify_upnext         = (try? c.decode(Double.self,  forKey: .Notify_upnext))         ?? 35.0
        GuideHours            = (try? c.decode(Int.self,     forKey: .GuideHours))            ?? 24
        Default_transcode     = (try? c.decode(String.self,  forKey: .Default_transcode))     ?? "none"
        Fail_count_setting    = (try? c.decode(Int.self,     forKey: .Fail_count_setting))    ?? 3
        Min_disk_free_gb      = (try? c.decode(Double.self,  forKey: .Min_disk_free_gb))      ?? 10.0
        Idle_timer_interval   = (try? c.decode(Int.self,     forKey: .Idle_timer_interval))   ?? 10
        Series_scan_retry_hours = (try? c.decode(Int.self,   forKey: .Series_scan_retry_hours)) ?? 4
        Hdhr_setup_folder     = (try? c.decode(String.self,  forKey: .Hdhr_setup_folder))     ?? ""
        Network_interface     = (try? c.decode(String.self,  forKey: .Network_interface))     ?? ""
        Verbose_curl          = (try? c.decode(Bool.self,    forKey: .Verbose_curl))          ?? false
        Watch_in_VLC          = (try? c.decode(Bool.self,    forKey: .Watch_in_VLC))          ?? false
        Watch_in_VLC_initialized = (try? c.decode(Bool.self, forKey: .Watch_in_VLC_initialized)) ?? false
        Player_buffer_min_rate   = (try? c.decode(Int.self,  forKey: .Player_buffer_min_rate))   ?? 93
        Sports_padding_enabled  = (try? c.decode(Bool.self,   forKey: .Sports_padding_enabled))  ?? true
        Sports_padding_minutes  = (try? c.decode(Int.self,    forKey: .Sports_padding_minutes))  ?? 30
        Config_version          = (try? c.decode(String.self,  forKey: .Config_version))         ?? "1"
        Discord_webhook_url     = (try? c.decode(String.self, forKey: .Discord_webhook_url))     ?? ""
        Discord_on_start        = (try? c.decode(Bool.self,   forKey: .Discord_on_start))        ?? true
        Discord_on_complete     = (try? c.decode(Bool.self,   forKey: .Discord_on_complete))     ?? true
        Discord_on_failed       = (try? c.decode(Bool.self,   forKey: .Discord_on_failed))       ?? true
        Discord_on_paused       = (try? c.decode(Bool.self,   forKey: .Discord_on_paused))       ?? true
        Discord_on_skipped      = (try? c.decode(Bool.self,   forKey: .Discord_on_skipped))      ?? true
        Discord_on_conflict     = (try? c.decode(Bool.self,   forKey: .Discord_on_conflict))     ?? true
        Discord_on_guide_error  = (try? c.decode(Bool.self,   forKey: .Discord_on_guide_error))  ?? true
        Discord_on_upnext       = (try? c.decode(Bool.self,   forKey: .Discord_on_upnext))       ?? false
        Discord_on_soon         = (try? c.decode(Bool.self,   forKey: .Discord_on_soon))         ?? false
        Discord_on_show_added   = (try? c.decode(Bool.self,   forKey: .Discord_on_show_added))   ?? false
        Discord_on_progress     = (try? c.decode(Bool.self,   forKey: .Discord_on_progress))     ?? false
        // Migration: existing configs with a URL had Discord working, so default to enabled for them.
        Discord_enabled         = (try? c.decode(Bool.self,   forKey: .Discord_enabled))         ?? !Discord_webhook_url.isEmpty
        Web_server_enabled      = (try? c.decode(Bool.self,   forKey: .Web_server_enabled))      ?? false
        Web_server_port         = (try? c.decode(Int.self,    forKey: .Web_server_port))         ?? 1980
    }
}

struct ConfigFile: Codable {
    var config: AppConfig
    var shows: [Show]
}

extension ConfigFile {
    // Custom decoder: accepts both "shows" (v2) and "the_shows" (v1 legacy key)
    init(from decoder: Decoder) throws {
        enum K: String, CodingKey { case config, shows, the_shows }
        let c = try decoder.container(keyedBy: K.self)
        config = try c.decode(AppConfig.self, forKey: .config)
        shows = (try? c.decode([Show].self, forKey: .shows))
             ?? (try? c.decode([Show].self, forKey: .the_shows))
             ?? []
    }
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
    var LineupURL: String?    // from discover.json; stored but not used — lineupURL always uses LocalIP

    var streamBase: String { "http://\(LocalIP):5004" }
    var guideURL:   String { "http://\(LocalIP)/guide.json" }
    var lineupURL:  String { "http://\(LocalIP)/lineup.json" }  // always IP — LineupURL from discover.json may contain mDNS hostname
    var statusURL:  String { "http://\(LocalIP)/status.json" }
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
    var isFavorite: Bool { Favorite == 1 }
}

extension String {
    // Natural channel-number sort: "5.1" → (5, 1), "10.2" → (10, 2)
    var channelSortKey: (Int, Int) {
        let parts = split(separator: ".").compactMap { Int($0) }
        return (parts.first ?? 0, parts.dropFirst().first ?? 0)
    }

    // Stream URL without a transcode query: "http://host/auto?transcode=ts" → "http://host/auto"
    var urlBase: String { components(separatedBy: "?").first ?? self }
}

struct GuideChannel: Codable {
    var GuideNumber: String
    var GuideName: String
    var Affiliate: String?
    var ImageURL: String?
    var Guide: [GuideEntry]?
}

// MARK: - TunerStatus

/// One entry from /status.json — only present when that tuner is actively streaming.
struct DeviceTunerInfo: Decodable {
    let Resource: String      // "tuner0", "tuner1", …
    let VctNumber: String?    // channel number if locked
    let TargetIP:  String?    // client IP receiving the stream
}

struct TunerStatus {
    let signalStrength: Int   // ss field (0–100)
    let signalQuality: Int    // snq field (0–100)
    let lockType: String      // e.g. "qam256", "8vsb", "none"
    let bitrateMbps: Double   // bps / 1_000_000

    var displayString: String {
        guard lockType != "none" else { return "Signal: no lock" }
        return "Signal: \(signalStrength)% · \(lockType.uppercased()) · \(String(format: "%.1f", bitrateMbps)) Mbps"
    }
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
    var Filter: [String]?   // genre tags from SiliconDust guide API (e.g. ["Drama","Series"])

    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(StartTime)) }
    var endDate:   Date { Date(timeIntervalSince1970: TimeInterval(EndTime)) }
    var durationMinutes: Int { (EndTime - StartTime) / 60 }
    var firstGenre: String? { Filter?.first }
}

extension GuideEntry {
    var episodeInfoLabel: String? {
        let parts = [EpisodeNumber, EpisodeTitle].compactMap { s -> String? in
            guard let s, !s.isEmpty else { return nil }
            return s
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
