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
// protection — anyone determined enough could brute-force the ~91 possible sums against the hash
// in under a second. See docs/DonationNagView.md.
struct DonationNagView: View {

    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss

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
        }
        .frame(width: 400)
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 28, y: 14)
        .background(FloatingWindowLevelSetter())
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
        ZStack {
            LinearGradient(
                colors: [Color.orange.opacity(0.35), Color.red.opacity(0.18), .clear],
                startPoint: .top, endPoint: .bottom
            )
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [.orange.opacity(0.55), .clear],
                                              center: .center, startRadius: 2, endRadius: 46))
                        .frame(width: 92, height: 92)
                        .scaleEffect(glowOut ? 1.25 : 0.7)
                        .opacity(glowOut ? 0 : 0.9)

                    Group {
                        if let icon = appIconImage {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 30))
                        }
                    }
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                }
                .frame(height: 68)
                .accessibilityLabel("hdhrVCRplus app icon")

                Text("Support hdhrVCRplus")
                    .font(.system(.title3, design: .monospaced)).bold()
            }
            .padding(.top, 30)
            .padding(.bottom, 20)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.1)) { glowOut = true }
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
                Button("Not now") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
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
        dismiss()
    }

    private func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// Keeps the nag above other windows so it can't get lost behind the guide, Settings, etc. —
// same technique the old FloatingGuideView used (see git history) before its removal.
private struct FloatingWindowLevelSetter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            v.window?.level = .floating
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
