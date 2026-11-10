import Foundation

/// Build stamp (`YYMMDD-HHMM`): deploy.sh and deploy_release.sh write it into the app bundle's Info.plist (`HDHRBuildStamp`) when they deploy, so this
/// file never changes and a deploy leaves the working tree clean. "dev" for a build that was not deployed (`swift build`, `swift test`).
let appVersion: String = (Bundle.main.object(forInfoDictionaryKey: "HDHRBuildStamp") as? String) ?? "dev"
