import Foundation

// Sends a single Discord embed to the given webhook URL.
// Silently no-ops if the URL is blank or not a discord.com/discordapp.com host.
func sendDiscordEmbed(to webhookURL: String, embed: [String: Any]) {
    guard !webhookURL.isEmpty,
          let url = URL(string: webhookURL),
          let host = url.host,
          host.contains("discord") else { return }

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let body: [String: Any] = ["embeds": [embed]]
    guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
    req.httpBody = data

    glog("[Discord] sending embed to \(url.host ?? webhookURL)")
    Task {
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                glog("[Discord] unexpected response type", level: .warning); return
            }
            if http.statusCode < 200 || http.statusCode >= 300 {
                glog("[Discord] HTTP \(http.statusCode) — check webhook URL or rate limit", level: .error)
            } else {
                glog("[Discord] sent OK (\(http.statusCode))")
            }
        } catch {
            glog("[Discord] send failed: \(error)", level: .error)
        }
    }
}

// POSTs with ?wait=true so Discord echoes the created message. Returns the message ID on success.
func sendDiscordEmbedCapturing(to webhookURL: String, embed: [String: Any]) async -> String? {
    guard !webhookURL.isEmpty,
          var components = URLComponents(string: webhookURL),
          components.host?.contains("discord") == true else { return nil }
    components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "wait", value: "true")]
    guard let url = components.url else { return nil }

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: [String: Any] = ["embeds": [embed]]
    guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
    req.httpBody = data

    glog("[Discord] sending embed (capturing ID) to \(url.host ?? webhookURL)")
    do {
        let (respData, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            glog("[Discord] unexpected response type", level: .warning); return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            glog("[Discord] HTTP \(http.statusCode) on capture send", level: .error); return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let msgId = json["id"] as? String else {
            glog("[Discord] could not parse message ID from response", level: .warning); return nil
        }
        glog("[Discord] sent OK — message ID \(msgId)")
        return msgId
    } catch {
        glog("[Discord] capture send failed: \(error)", level: .error)
        return nil
    }
}

// PATCHes an existing webhook message in-place. Fire-and-forget.
func editDiscordEmbed(webhookURL: String, messageId: String, embed: [String: Any]) {
    guard !webhookURL.isEmpty, !messageId.isEmpty,
          let url = URL(string: "\(webhookURL)/messages/\(messageId)"),
          url.host?.contains("discord") == true else { return }

    var req = URLRequest(url: url)
    req.httpMethod = "PATCH"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: [String: Any] = ["embeds": [embed]]
    guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
    req.httpBody = data

    glog("[Discord] editing message \(messageId)")
    Task {
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                glog("[Discord] edit: unexpected response type", level: .warning); return
            }
            if http.statusCode < 200 || http.statusCode >= 300 {
                glog("[Discord] edit HTTP \(http.statusCode)", level: .error)
            } else {
                glog("[Discord] edit OK (\(http.statusCode))")
            }
        } catch {
            glog("[Discord] edit failed: \(error)", level: .error)
        }
    }
}
