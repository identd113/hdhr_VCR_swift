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

    Task { _ = try? await URLSession.shared.data(for: req) }
}
