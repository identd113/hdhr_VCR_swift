import SwiftUI

/// Set when a view is shown as a card inside the launch splash's window (docs/LaunchSplash.md) instead of in its own
/// window: the call closes the card. Views use it in place of `dismiss()`, and skip their window setup (level, size,
/// centring) because the splash window is not theirs to configure. `nil` everywhere else.
private struct EmbeddedCardCloseKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }

extension EnvironmentValues {
    var embeddedCardClose: (() -> Void)? {
        get { self[EmbeddedCardCloseKey.self] }
        set { self[EmbeddedCardCloseKey.self] = newValue }
    }
}
