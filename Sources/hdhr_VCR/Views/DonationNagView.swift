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

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            Spacer(minLength: 0)
        }
        // Same panel as the splash and the setup wizard (`LaunchCard`): as a launch card the splash's own persistent panel is
        // already behind it; in its own window (a later nag) it draws the panel itself.
        .frame(width: LaunchCard.width, height: embeddedClose != nil ? LaunchCard.designHeight : min(LaunchCard.designHeight, 520))
        .launchCardChrome(applied: embeddedClose == nil)
        // Keeps the nag above other windows so it can't get lost behind the guide, Settings, etc. —
        // same technique the old FloatingGuideView used (see git history) before its removal.
        .background(WindowAction(trigger: true) { if embeddedClose == nil { $0.level = .floating } })
        .onAppear {
            // macOS window-state restoration can repopulate a closed-and-reopened single-instance
            // Window scene's field contents from its last session — force a clean slate on every
            // appearance rather than showing a stale typed code + mismatch error from last time.
            enteredCode = ""
            showMismatch = false
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
                    .scaleEffect(glowOut ? 1 : 0.4)
            }
            .frame(width: 52, height: 52)
            .accessibilityLabel("hdhrVCRplus app icon")
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
            withAnimation(.spring(response: 0.6, dampingFraction: 0.55)) { glowOut = true }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("This app is free to use. If it's useful to you, consider leaving a tip — it helps support ongoing development.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link(destination: URL(string: paypalURL)!) {
                Label("Tip via PayPal", systemImage: "heart.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(LinearGradient(colors: [Color.blue, Color.blue.opacity(0.85)],
                                        startPoint: .top, endPoint: .bottom))
            .clipShape(Capsule())
            .shadow(color: .blue.opacity(0.35), radius: 10, y: 4)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Already tipped?")
                    .font(.subheadline).bold()
                Text("Enter the code you were sent to stop seeing this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    TextField("6-digit hex code", text: $enteredCode)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.quaternary.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .onSubmit(attemptUnlock)

                    Button(action: attemptUnlock) {
                        Text("Unlock")
                            .font(.subheadline).bold()
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(enteredCode.trimmingCharacters(in: .whitespaces).isEmpty
                                ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.orange.gradient))
                    .clipShape(Capsule())
                    .disabled(enteredCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if showMismatch {
                    Label("That code didn't match.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button("Not now") { closeNag() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(20)
    }

    private func attemptUnlock() {
        let normalized = enteredCode.trimmingCharacters(in: .whitespacesAndNewlines)
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
