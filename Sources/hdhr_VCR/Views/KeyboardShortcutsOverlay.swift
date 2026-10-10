import SwiftUI

// A "?" help card: a semi-translucent panel floating over a window's content that lists the keyboard
// shortcuts that work there — keycap on the left, what it does on the right — and goes away on the next
// key press. The pattern YouTube, Tella and the Mac cheat-sheet apps (CheatSheet, KeyClu) all use.
// Styled from the player's info banner (VLCPlayerView.infoBannerBackdrop): the same charcoal gradient,
// pale accent bar and serif type, so it reads as part of the same overlay family.
//
// The view is generic — a title and a list of rows — so another window can reuse it by supplying its own
// rows. `PlayerShortcuts` below is the player window's list.

/// One shortcut: the key(s) to show as keycaps, what it does, and whether it can do anything right now
/// (an unavailable row is dimmed and carries a short note saying when it works).
struct ShortcutRow: Identifiable, Equatable {
    var id: String { title }
    let keys: [String]
    let title: String
    var note: String? = nil
    var isAvailable: Bool = true
}

struct KeyboardShortcutsOverlay: View {
    let title: String
    let rows: [ShortcutRow]
    var onDismiss: () -> Void = {}

    var body: some View {
        ZStack {
            // Soft scrim so the panel stands off any picture; a click anywhere closes, like a key press.
            Color.black.opacity(0.28)
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Capsule().fill(Color(white: 0.85).opacity(0.9)).frame(width: 3, height: 26)
                    Text(title)
                        .font(.system(size: 24, weight: .bold, design: .serif))
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 22, verticalSpacing: 12) {
                    ForEach(rows) { row in
                        GridRow {
                            HStack(spacing: 6) { ForEach(row.keys, id: \.self) { KeyCap(text: $0) } }
                                .gridColumnAlignment(.trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).font(.system(size: 16, weight: .medium, design: .serif))
                                if !row.isAvailable, let note = row.note {
                                    Text(note).font(.system(size: 13, design: .serif)).italic()
                                        .foregroundStyle(Color(white: 0.7))
                                }
                            }
                        }
                        .opacity(row.isAvailable ? 1 : 0.45)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(row.keys.joined(separator: " or ")): \(row.title)\(row.isAvailable ? "" : ", \(row.note ?? "not available right now")")")
                    }
                }
                Text("Press any key to close")
                    .font(.system(size: 13, design: .serif)).italic()
                    .foregroundStyle(Color(white: 0.7))
            }
            .foregroundStyle(Color(white: 0.94))
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.08).opacity(0.80), Color(white: 0.18).opacity(0.70)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color(white: 0.85).opacity(0.22), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
            .padding(24)
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(title)
    }
}

/// A keyboard key drawn as a small raised cap.
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color(white: 0.96))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(minWidth: 30)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(white: 0.30).opacity(0.92)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color(white: 0.8).opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.55), radius: 0, y: 2)   // the cap's depth
    }
}

/// The player window's shortcuts — every key `VLCPlayerWindowManager.installKeyMonitor` handles — with
/// whether each can do anything right now. Pure, so it's unit-tested.
enum PlayerShortcuts {
    static func rows(canSeek: Bool, canPause: Bool, hasPiP: Bool, isFullScreen: Bool) -> [ShortcutRow] {
        [
            ShortcutRow(keys: ["←", "→"], title: "Skip back 15 s / forward 30 s",
                        note: "Recordings and FEEDs only", isAvailable: canSeek),
            ShortcutRow(keys: ["Space"], title: "Pause / resume",
                        note: "Recordings and FEEDs only", isAvailable: canPause),
            ShortcutRow(keys: ["Tab"], title: "Swap the picture-in-picture with the main video",
                        note: "Needs a picture-in-picture open", isAvailable: hasPiP),
            ShortcutRow(keys: ["Esc"], title: "Leave full screen",
                        note: "Only while in full screen", isAvailable: isFullScreen),
            ShortcutRow(keys: ["i"], title: "Show what's playing"),
            ShortcutRow(keys: ["?"], title: "Show this help"),
        ]
    }
}
