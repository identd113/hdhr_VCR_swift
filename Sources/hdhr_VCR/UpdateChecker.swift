import Foundation

// MARK: - GitHub release update check
//
// Sparkle has been tried twice (commit 1376dc6, then re-parked in 39f1419) and is currently
// a dead end: swift build/package resolve hangs indefinitely fetching Sparkle's binary SPM
// artifact on this toolchain (matches the unresolved upstream swiftlang/swift-subprocess#192).
// This is a much smaller substitute: read-only, no appcast, no signing, no auto-download —
// it just asks GitHub's public Releases API for the latest tag and compares it to our own
// CFBundleShortVersionString, surfacing a link to the Releases page when a newer one exists.

private let githubReleasesAPIURL = URL(string: "https://api.github.com/repos/identd113/hdhr_VCR_swift/releases/latest")!

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

struct UpdateCheckResult: Equatable {
    let latestVersion: String   // e.g. "2.0.5" (tag's leading "v" stripped)
    let releaseURL: URL
}

// Component-wise integer compare ("2.0.10" > "2.0.9" — a plain string compare would get this
// wrong). Missing trailing components are treated as 0, so "2.1" > "2.0.9".
func isVersion(_ a: String, newerThan b: String) -> Bool {
    let aParts = a.split(separator: ".").map { Int($0) ?? 0 }
    let bParts = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(aParts.count, bParts.count) {
        let x = i < aParts.count ? aParts[i] : 0
        let y = i < bParts.count ? bParts[i] : 0
        if x != y { return x > y }
    }
    return false
}

// Returns non-nil only when a newer release exists. Silent no-op on any failure (offline,
// rate-limited, malformed response, dev build with no CFBundleShortVersionString) — this is
// a courtesy check and must never surface an error or block anything.
func checkForUpdate(currentVersion: String, session: URLSession = .shared) async -> UpdateCheckResult? {
    guard !currentVersion.isEmpty else { return nil }
    var request = URLRequest(url: githubReleasesAPIURL)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("hdhrVCRplus/\(currentVersion)", forHTTPHeaderField: "User-Agent")
    do {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            glog("[UpdateCheck] non-200 response fetching latest release", level: .warning)
            return nil
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let latest = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        guard isVersion(latest, newerThan: currentVersion), let url = URL(string: release.htmlURL) else {
            return nil
        }
        glog("[UpdateCheck] newer release available: \(latest) (current: \(currentVersion))")
        return UpdateCheckResult(latestVersion: latest, releaseURL: url)
    } catch {
        glog("[UpdateCheck] fetch failed: \(error.localizedDescription)", level: .warning)
        return nil
    }
}
