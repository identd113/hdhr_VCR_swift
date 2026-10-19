import Foundation

/// The one place the app's own loopback relay endpoints (`WebServer`'s `/api/watch-recording` and
/// `/api/feed-local-relay`) are spelled — as URLs the in-app player is handed, and as the path
/// checks that classify a playing URL as "a relay, not a real tuner stream". One source keeps the URL shapes and the
/// tuner-occupancy classification (`AppState.vlcOccupiesTuner`) from drifting apart.
enum LocalRelay {
    static let watchRecordingPath = "/api/watch-recording"
    static let feedLocalRelayPath = "/api/feed-local-relay"

    /// Pass `webServer.activePort` — the port actually bound (`WebServer.start` clamps the configured one).
    static func watchRecordingURL(port: Int, showId: String, start: Int = 0) -> String {
        "http://127.0.0.1:\(port)\(watchRecordingPath)?show=\(showId)&start=\(start)"
    }

    static func feedLocalRelayURL(port: Int, sessionId: String) -> String {
        "http://127.0.0.1:\(port)\(feedLocalRelayPath)?session=\(sessionId)"
    }

    static func isWatchRecording(_ url: String) -> Bool { url.contains(watchRecordingPath) }
    static func isFeedLocalRelay(_ url: String) -> Bool { url.contains(feedLocalRelayPath) }
    /// Either relay shape — i.e. playing it occupies no tuner.
    static func isRelay(_ url: String) -> Bool { isWatchRecording(url) || isFeedLocalRelay(url) }
}
