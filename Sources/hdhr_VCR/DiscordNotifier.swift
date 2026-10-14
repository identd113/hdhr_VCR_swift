import Foundation

// MARK: - Discord-specific logging
//
// Separate from the main hdhrVCRplus.log so send/edit/retry patterns (e.g. repeated
// progress-update edits across a single recording) can be reviewed in isolation.
// Same [timestamp] [LEVEL] line format as glog(), written via its own serial queue/handle.
private let discordLogQueue = DispatchQueue(label: "com.hdhr.vcrplus.discordlog", qos: .utility)
private let discordLogDateFormatter = ISO8601DateFormatter()
let discordLogFilePath = appLogsDirectory + "/hdhrVCRplus-discord.log"
// Discord logging runs at roughly 1% of the main log's volume (measured: ~11 KB/day vs. the main
// log's ~1.2 MB/day) — a 5 MB cap is still generous (over a year of live history) without
// carrying the main log's 20 MB default for a file this quiet.
private let discordLogFile = RotatingLogFile(path: discordLogFilePath, rotateThresholdBytes: 5 * 1024 * 1024)

func discordLog(_ msg: String, level: LogLevel = .info) {
    let tag = level == .info ? "INFO" : level == .warning ? "WARN" : "ERROR"
    let ts = Date()
    discordLogQueue.async {
        discordLogFile.write("[\(discordLogDateFormatter.string(from: ts))] [\(tag)] \(redactingSecrets(msg))\n")
    }
}

private func embedTitle(_ embed: [String: Any]) -> String {
    embed["title"] as? String ?? "?"
}

// Exact host or a proper subdomain of discord.com/discordapp.com — a bare `hasSuffix` check
// would also accept "notdiscord.com" or "harddiscordapp.com" since it has no "." boundary.
private func isDiscordHost(_ host: String) -> Bool {
    // URL.host preserves case, so a user pasting DISCORD.COM would otherwise be rejected —
    // hostnames are case-insensitive, and real Discord hosts are ASCII-lowercase.
    let host = host.lowercased()
    for domain in ["discord.com", "discordapp.com"] {
        if host == domain || host.hasSuffix("." + domain) { return true }
    }
    return false
}

// Builds the JSON POST/PATCH every sender shares. `op` ("SEND"/"CREATE"/"EDIT") and `detail` (e.g. " msgId=…")
// only label the log line when the embed can't be encoded — a caller bug, not a network failure, so it is
// logged to both files rather than returning silently.
private func discordJSONRequest(url: URL, method: String, embed: [String: Any], op: String, detail: String = "") -> (request: URLRequest, title: String)? {
    let title = embedTitle(embed)
    guard let data = try? JSONSerialization.data(withJSONObject: ["embeds": [embed]]) else {
        glog("[Discord] embed JSON-encode failed — title=\"\(title)\"\(detail), not sent", level: .error)
        discordLog("\(op) title=\"\(title)\"\(detail) FAILED — embed JSON-encode failed", level: .error)
        return nil
    }
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = data
    return (req, title)
}

/// The webhook URL as components, or nil unless it is `https` on a Discord host. Plain `http://` is refused
/// outright — the token is part of the URL path and would cross the network in the clear.
private func discordWebhookComponents(_ webhookURL: String) -> URLComponents? {
    guard !webhookURL.isEmpty,
          let c = URLComponents(string: webhookURL),
          c.scheme?.lowercased() == "https",
          c.host.map(isDiscordHost) == true else { return nil }
    return c
}

/// `<webhook>/messages/<id>` with any query (`?thread_id=…`) kept after the path, not glued onto the message id.
func discordEditURL(webhookURL: String, messageId: String) -> URL? {
    guard !messageId.isEmpty, var c = discordWebhookComponents(webhookURL),
          let id = messageId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
    while c.path.hasSuffix("/") { c.path.removeLast() }
    c.percentEncodedPath += "/messages/" + id
    return c.url
}

/// How long to wait after a 429: the `Retry-After` header (seconds), else the body's `retry_after`, else 1 s —
/// kept within 0.1–15 s so one bad value can't stall the per-show card chain.
func discordRetryDelay(retryAfterHeader: String?, body: Data) -> TimeInterval {
    var seconds = retryAfterHeader.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    if seconds == nil, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
        seconds = (json["retry_after"] as? Double) ?? (json["retry_after"] as? Int).map(Double.init)
    }
    return min(max(seconds ?? 1, 0.1), 15)
}

/// Sends the request, waiting out Discord's rate limit (HTTP 429) and retrying up to twice — several shows
/// starting or stopping in one idle tick easily hit it, and a lost "Recording Started" card is never re-sent.
private func discordPerform(_ req: URLRequest, session: URLSession, label: String) async throws -> (Data, URLResponse) {
    var retries = 0
    while true {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 429, retries < 2 else { return (data, resp) }
        let wait = discordRetryDelay(retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"), body: data)
        retries += 1
        glog("[Discord] \(label) rate limited (429) — retry \(retries)/2 in \(wait)s", level: .warning)
        discordLog("\(label) rate limited (429) — retry \(retries)/2 in \(wait)s", level: .warning)
        try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
    }
}

// Sends a single Discord embed to the given webhook URL.
// Silently no-ops if the URL is blank or not a discord.com/discordapp.com host.
func sendDiscordEmbed(to webhookURL: String, embed: [String: Any], session: URLSession = .shared) {
    guard let url = discordWebhookComponents(webhookURL)?.url else { return }

    guard let (req, title) = discordJSONRequest(url: url, method: "POST", embed: embed, op: "SEND") else { return }

    glog("[Discord] sending embed to \(url.host ?? webhookURL)")
    discordLog("SEND title=\"\(title)\" (no id captured — fire-and-forget)")
    Task {
        do {
            let (_, resp) = try await discordPerform(req, session: session, label: "SEND")
            guard let http = resp as? HTTPURLResponse else {
                glog("[Discord] unexpected response type", level: .warning)
                discordLog("SEND title=\"\(title)\" — unexpected response type", level: .warning)
                return
            }
            if http.statusCode < 200 || http.statusCode >= 300 {
                glog("[Discord] HTTP \(http.statusCode) — check webhook URL or rate limit", level: .error)
                discordLog("SEND title=\"\(title)\" FAILED http=\(http.statusCode)", level: .error)
            } else {
                glog("[Discord] sent OK (\(http.statusCode))")
                discordLog("SEND title=\"\(title)\" OK http=\(http.statusCode)")
            }
        } catch {
            glog("[Discord] send failed: \(error)", level: .error)
            discordLog("SEND title=\"\(title)\" FAILED error=\(error)", level: .error)
        }
    }
}

// POSTs with ?wait=true so Discord echoes the created message. Returns the message ID on success.
func sendDiscordEmbedCapturing(to webhookURL: String, embed: [String: Any], session: URLSession = .shared) async -> String? {
    guard var components = discordWebhookComponents(webhookURL) else { return nil }
    components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "wait", value: "true")]
    guard let url = components.url else { return nil }

    guard let (req, title) = discordJSONRequest(url: url, method: "POST", embed: embed, op: "CREATE") else { return nil }

    glog("[Discord] sending embed (capturing ID) to \(url.host ?? webhookURL)")
    discordLog("CREATE title=\"\(title)\"")
    do {
        let (respData, resp) = try await discordPerform(req, session: session, label: "CREATE")
        guard let http = resp as? HTTPURLResponse else {
            glog("[Discord] unexpected response type", level: .warning)
            discordLog("CREATE title=\"\(title)\" — unexpected response type", level: .warning)
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            glog("[Discord] HTTP \(http.statusCode) on capture send", level: .error)
            discordLog("CREATE title=\"\(title)\" FAILED http=\(http.statusCode)", level: .error)
            return nil
        }
        if let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
           let msgId = json["id"] as? String {
            glog("[Discord] sent OK — message ID \(msgId)")
            discordLog("CREATE title=\"\(title)\" OK msgId=\(msgId) — future edits to this card will use this ID")
            return msgId
        } else {
            glog("[Discord] message-ID parse failed — HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1), body prefix: \(String(data: respData.prefix(120), encoding: .utf8) ?? "<binary>")", level: .warning)
            discordLog("CREATE title=\"\(title)\" — message-ID parse failed, http=\(http.statusCode)", level: .warning)
            return nil
        }
    } catch {
        glog("[Discord] capture send failed: \(error)", level: .error)
        discordLog("CREATE title=\"\(title)\" FAILED error=\(error)", level: .error)
        return nil
    }
}

// PATCHes an existing webhook message in-place. Fire-and-forget.
func editDiscordEmbed(webhookURL: String, messageId: String, embed: [String: Any], session: URLSession = .shared) {
    guard let url = discordEditURL(webhookURL: webhookURL, messageId: messageId) else { return }

    guard let (req, title) = discordJSONRequest(url: url, method: "PATCH", embed: embed, op: "EDIT", detail: " msgId=\(messageId)") else { return }

    glog("[Discord] editing message \(messageId)")
    discordLog("EDIT title=\"\(title)\" msgId=\(messageId)")
    Task {
        do {
            let (_, resp) = try await discordPerform(req, session: session, label: "EDIT")
            guard let http = resp as? HTTPURLResponse else {
                glog("[Discord] edit: unexpected response type", level: .warning)
                discordLog("EDIT title=\"\(title)\" msgId=\(messageId) — unexpected response type", level: .warning)
                return
            }
            if http.statusCode < 200 || http.statusCode >= 300 {
                glog("[Discord] edit HTTP \(http.statusCode)", level: .error)
                discordLog("EDIT title=\"\(title)\" msgId=\(messageId) FAILED http=\(http.statusCode)", level: .error)
            } else {
                glog("[Discord] edit OK (\(http.statusCode))")
                discordLog("EDIT title=\"\(title)\" msgId=\(messageId) OK http=\(http.statusCode)")
            }
        } catch {
            glog("[Discord] edit failed: \(error)", level: .error)
            discordLog("EDIT title=\"\(title)\" msgId=\(messageId) FAILED error=\(error)", level: .error)
        }
    }
}
