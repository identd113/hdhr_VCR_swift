import Foundation

// MARK: - Discord-specific logging
//
// Separate from the main hdhrVCRplus.log so send/edit/retry patterns (e.g. repeated
// progress-update edits across a single recording) can be reviewed in isolation.
// Same [timestamp] [LEVEL] line format as glog(), written via its own serial queue/handle.
private let discordLogQueue = DispatchQueue(label: "com.hdhr.vcrplus.discordlog", qos: .utility)
private let discordLogDateFormatter = ISO8601DateFormatter()
let discordLogFilePath = NSHomeDirectory() + "/Library/Logs/hdhrVCRplus-discord.log"
// Discord logging runs at roughly 1% of the main log's volume (measured: ~11 KB/day vs. the main
// log's ~1.2 MB/day) — a 5 MB cap is still generous (over a year of live history) without
// carrying the main log's 20 MB default for a file this quiet.
private let discordLogFile = RotatingLogFile(path: discordLogFilePath, rotateThresholdBytes: 5 * 1024 * 1024)

func discordLog(_ msg: String, level: LogLevel = .info) {
    let tag = level == .info ? "INFO" : level == .warning ? "WARN" : "ERROR"
    let ts = Date()
    discordLogQueue.async {
        discordLogFile.write("[\(discordLogDateFormatter.string(from: ts))] [\(tag)] \(msg)\n")
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

// Sends a single Discord embed to the given webhook URL.
// Silently no-ops if the URL is blank or not a discord.com/discordapp.com host.
func sendDiscordEmbed(to webhookURL: String, embed: [String: Any]) {
    guard !webhookURL.isEmpty,
          let url = URL(string: webhookURL),
          let host = url.host,
          isDiscordHost(host) else { return }

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let body: [String: Any] = ["embeds": [embed]]
    guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
    req.httpBody = data

    let title = embedTitle(embed)
    glog("[Discord] sending embed to \(url.host ?? webhookURL)")
    discordLog("SEND title=\"\(title)\" (no id captured — fire-and-forget)")
    Task {
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
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
func sendDiscordEmbedCapturing(to webhookURL: String, embed: [String: Any]) async -> String? {
    guard !webhookURL.isEmpty,
          var components = URLComponents(string: webhookURL),
          components.host.map(isDiscordHost) == true else { return nil }
    components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "wait", value: "true")]
    guard let url = components.url else { return nil }

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: [String: Any] = ["embeds": [embed]]
    guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
    req.httpBody = data

    let title = embedTitle(embed)
    glog("[Discord] sending embed (capturing ID) to \(url.host ?? webhookURL)")
    discordLog("CREATE title=\"\(title)\"")
    do {
        let (respData, resp) = try await URLSession.shared.data(for: req)
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
func editDiscordEmbed(webhookURL: String, messageId: String, embed: [String: Any]) {
    guard !webhookURL.isEmpty, !messageId.isEmpty,
          let url = URL(string: "\(webhookURL)/messages/\(messageId)"),
          url.host.map(isDiscordHost) == true else { return }

    var req = URLRequest(url: url)
    req.httpMethod = "PATCH"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: [String: Any] = ["embeds": [embed]]
    guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
    req.httpBody = data

    let title = embedTitle(embed)
    glog("[Discord] editing message \(messageId)")
    discordLog("EDIT title=\"\(title)\" msgId=\(messageId)")
    Task {
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
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
