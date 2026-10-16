import SwiftUI
import AppKit

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

/// The one size and look every launch card shares — the splash card, the setup wizard and the donation card
/// (docs/LaunchSplash.md): a 520pt-wide dark panel, as tall as the wizard needs but never taller than the screen.
enum LaunchCard {
    static let width: CGFloat = 520
    static var height: CGFloat { min(600, (NSScreen.main?.visibleFrame.height ?? 800) - 80) }
    static let corner: CGFloat = 20
}

/// The card panel's background — the launch splash's look: near-black, a soft warm glow from the top-left corner (the logo
/// is orange) and a vignette at the foot, no material.
struct CardBackdrop: View {
    var body: some View {
        ZStack {
            Color(white: 0.075)
            RadialGradient(colors: [Color.orange.opacity(0.20), .clear], center: UnitPoint(x: 0.10, y: 0.0),
                           startRadius: 8, endRadius: 360)
            LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .center, endPoint: .bottom)
        }
    }
}

extension View {
    /// The launch panel as part of the poster wall: no hard box, border or shadow — a translucent dark pool with a warm glow
    /// whose edges are feathered into the posters around it. The cards inside are clipped to a rounded rectangle (their
    /// slide stays within it) and drawn in the dark scheme.
    func blendedLaunchPanel() -> some View {
        self.clipShape(RoundedRectangle(cornerRadius: LaunchCard.corner + 8, style: .continuous))
            .background(
                ZStack {
                    Color.black.opacity(0.68)
                    RadialGradient(colors: [Color.orange.opacity(0.16), .clear], center: UnitPoint(x: 0.12, y: 0.0),
                                   startRadius: 8, endRadius: 380)
                }
                .mask(RoundedRectangle(cornerRadius: LaunchCard.corner + 12, style: .continuous).padding(10).blur(radius: 18))
            )
            .environment(\.colorScheme, .dark)
    }

    /// Rounded dark panel with the faint border and drop shadow shared by every launch card (always dark). With
    /// `applied: false` only the dark colour scheme is set — the card sits inside a panel that already draws the chrome.
    @ViewBuilder func launchCardChrome(applied: Bool = true) -> some View {
        if applied {
            self.background(CardBackdrop())
                .clipShape(RoundedRectangle(cornerRadius: LaunchCard.corner, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: LaunchCard.corner, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 28, y: 14)
                .environment(\.colorScheme, .dark)
        } else {
            self.environment(\.colorScheme, .dark)
        }
    }
}
