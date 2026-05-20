import Foundation

/// Controls which UI is used when the user adds a show.
enum AddShowMode: String, CaseIterable {
    case menu   = "menu"    // 4-level nested menu (guide browsing in-place)
    case wizard = "wizard"  // Step-by-step window (AddShowView)

    var label: String {
        switch self {
        case .menu:   return "Menu (browse guide in-place)"
        case .wizard: return "Wizard window (step-by-step)"
        }
    }
    var detail: String {
        switch self {
        case .menu:   return "Navigate tuner → channel → guide entry entirely within the menu bar."
        case .wizard: return "Opens a dedicated window with a guided 4-step flow."
        }
    }
}
