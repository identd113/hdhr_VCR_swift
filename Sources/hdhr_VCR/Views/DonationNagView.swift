import SwiftUI
import CryptoKit

// Soft, honor-system donation nag — not DRM. Shown on app launch and whenever a show is
// scheduled (native wizard or web guide), gated by AppState.pendingDonationNagTrigger /
// MenuContent's launch onAppear guard — see docs/DonationNagView.md.
//
// The payment link and the unlock-code target are both the developer's own info, identical in
// every distributed build — hardcoded constants here, same as any other app-wide setting. The
// target is stored as a SHA256 hash rather than the plain number so it isn't grep-able in a
// casual read of this (public) repo's source, but it's still baked into every install (unlike an
// earlier design that stored the raw number in per-install AppConfig — that value could never
// match for anyone except the developer's own already-configured machine, so nobody who actually
// tipped could ever unlock their own copy; fixed by going back to a single value shared by every
// build, just hashed instead of plaintext). This is still honor-system, not real cryptographic
// protection against someone willing to read the validation logic below and do the arithmetic —
// see docs/DonationNagView.md, and the developer's own private, untracked notes for the exact
// specifics of how weak and why that's an accepted tradeoff here.
struct DonationNagView: View {

    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    /// Non-nil when this is a card inside the launch splash's window: closes the card; the floating-level setup is skipped.
    @Environment(\.embeddedCardClose) private var embeddedClose

    private func closeNag() { if let embeddedClose { embeddedClose() } else { dismiss() } }

    private let paypalURL = "https://www.paypal.com/paypalme/MikeWoodfill/10"

    // Unlock validation: any hex string (0-9, A-F) of exactly `requiredCodeLength` digits whose
    // nibble values sum to a target N is accepted when SHA256(String(N)) == targetChecksumHash —
    // lets a fresh valid code be constructed by hand for each tipper (any digits summing to the
    // target work) without a generator script or server, while being far less guessable than a
    // single fixed string. The real target lives only in tools/donation_target.txt (gitignored).
    private let requiredCodeLength = 6
    private let targetChecksumHash = "31489056e0916d59fe3add79e63f095af3ffb81604691f21cad442a85c7be617"

    @State private var enteredCode = ""
    @State private var showMismatch = false
    @State private var glowOut = false   // one-shot ring pulse behind the icon on appear
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            Spacer(minLength: 0)
            // Pinned footer, the same bar as the setup wizard's Back / Next row: a divider, then the action at the right.
            Divider().opacity(0.5)
            HStack {
                Spacer()
                Button("Not yet") { closeNag() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("donation-not-now")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        // Same panel as the splash and the setup wizard (`LaunchCard`): as a launch card the splash's own persistent panel is
        // already behind it; in its own window (a later nag) it draws the panel itself.
        .frame(width: LaunchCard.width, height: embeddedClose != nil ? LaunchCard.designHeight : min(LaunchCard.designHeight, 520))
        .launchCardChrome(applied: embeddedClose == nil)
        // Keeps the nag above other windows so it can't get lost behind the guide, Settings, etc. —
        // same technique the old FloatingGuideView used (see git history) before its removal.
        .background(WindowAction(trigger: true) { if embeddedClose == nil { $0.level = .floating } })
        .onExitCommand { closeNag() }
        .onAppear {
            // macOS window-state restoration can repopulate a closed-and-reopened single-instance
            // Window scene's field contents from its last session — force a clean slate on every
            // appearance rather than showing a stale typed code + mismatch error from last time.
            enteredCode = ""
            showMismatch = false
            // As a launch card, don't let the code field grab focus on appear (a focus ring popping in mid-slide).
            if embeddedClose != nil { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
        }
    }

    // Gradient-tinted band with a glowing icon — the app's own recording-red/action-orange
    // palette (see litColor: .red in hdhr_VCRApp.swift's status icon, .tint(.orange) on
    // SettingsView's dirty Save button) rather than generic system blue, so the nag reads as
    // unmistakably *this* app's own chrome rather than a bolted-on system alert.
    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 0.95, green: 0.34, blue: 0.50).opacity(0.55), .clear],
                                          center: .center, startRadius: 2, endRadius: 40))
                    .frame(width: 80, height: 80)
                    .scaleEffect(glowOut ? 1.3 : 0.7)
                    .opacity(glowOut ? 0 : 0.9)
                Group {
                    if let icon = appIconImage {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 26))
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 44 * 0.2, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                // Flair: a small heart on the icon — this card is about saying thanks.
                Image(systemName: "heart.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Circle().fill(Color(red: 0.95, green: 0.34, blue: 0.50)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                    .offset(x: 18, y: 18)
                    .opacity(glowOut ? 1 : 0)
            }
            .frame(width: 52, height: 52)
            .accessibilityHidden(true)   // decorative: the title beside it already names the app
            VStack(alignment: .leading, spacing: 1) {
                Text("Support hdhrVCRplus").font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Free to use — tips keep it going.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.8))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .onAppear {
            // Reduce Motion: jump straight to the end state (heart visible, ring faded) with no pulse.
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.7)) { glowOut = true }
        }
    }

    private var rose: Color { Color(red: 0.95, green: 0.34, blue: 0.50) }

    // Light on purpose: no filled blocks or glows — a quiet rose-outlined tip button, then an unobtrusive code row. The card's
    // accent (the heart, the panel's glow) is the only strong colour.
    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("If hdhrVCRplus is useful to you, a tip helps pay for the next round of fixes and features.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)

            Link(destination: URL(string: paypalURL)!) {
                Label("Tip via PayPal", systemImage: "heart.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(rose.opacity(0.16)))
                    .overlay(Capsule().strokeBorder(rose.opacity(0.65), lineWidth: 1))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                Text("Already tipped? Enter your code to stop seeing this.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))

                HStack(spacing: 8) {
                    TextField("6-digit hex code", text: $enteredCode).focusEffectDisabled(false)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.16), lineWidth: 1))
                        .onSubmit { if ready { attemptUnlock() } }
                        .onChange(of: enteredCode) { _, _ in showMismatch = false }

                    Button(action: attemptUnlock) {
                        Text("Unlock")
                            .font(.subheadline).bold()
                            .foregroundStyle(ready ? .white : .white.opacity(0.35))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(ready ? AnyShapeStyle(Color.orange.opacity(0.85)) : AnyShapeStyle(Color.clear)))
                            .overlay(Capsule().strokeBorder(.white.opacity(ready ? 0 : 0.16), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(!ready)
                }

                if showMismatch {
                    Label("That code didn't match.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 20)
    }

    private var ready: Bool { !enteredCode.trimmingCharacters(in: .whitespaces).isEmpty }

    private func attemptUnlock() {
        let normalized = enteredCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let digitSum = normalized.reduce(into: 0 as Int?) { sum, ch in
            guard let current = sum, let value = ch.hexDigitValue else { sum = nil; return }
            sum = current + value
        }
        guard normalized.count == requiredCodeLength,
              let digitSum,
              sha256Hex(String(digitSum)) == targetChecksumHash
        else {
            showMismatch = true
            return
        }
        state.config.Donation_unlocked = true
        state.config.Donation_unlock_code = normalized.uppercased()
        state.saveConfig()
        closeNag()
    }

    private func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
