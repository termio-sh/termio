import SwiftUI

/// The top-level settings groups. Each is one row in the Settings sidebar. Not
/// private so the launch reminder can open settings straight to a given tab (see
/// `AppDelegate.openSettings`).
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case interface
    case terminal
    case ssh
    case keyboard
    case agents
    case usage
    case mobile

    var id: String { rawValue }

    /// UserDefaults key remembering the last tab the user had open, so ⌘,
    /// reopens where they left off (see `AppDelegate.showSettings`).
    static let lastOpenKey = "settings.lastTab"

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .interface: return "Interface"
        case .terminal: return "Terminal"
        case .ssh: return "SSH"
        case .keyboard: return "Keyboard"
        case .agents: return "Agents"
        case .usage: return "Usage"
        case .mobile: return "Mobile"
        }
    }

    /// The sidebar glyph, drawn from the app's Hugeicons set so the settings
    /// window matches the main sidebar's line-icon style instead of SF Symbols.
    var icon: HugeIcon {
        switch self {
        case .general: return .settings
        case .appearance: return .paintBrush
        case .interface: return .sidebarLeft
        case .terminal: return .terminal
        case .ssh: return .serverStack
        case .keyboard: return .keyboard
        case .agents: return .bot
        case .usage: return .dashboardSpeed
        case .mobile: return .smartPhone
        }
    }

    /// The one-line description shown under the pane title in the detail header,
    /// matching macOS System Settings' navigation subtitle.
    var subtitle: String {
        switch self {
        case .general: return "Notifications and the termio command-line tool"
        case .appearance: return "Terminal font, theme, cursor, and window"
        case .interface: return "The app's own sidebar font and density"
        case .terminal: return "Scrollback history and text selection"
        case .ssh: return "Your ~/.ssh/config hosts, one click away"
        case .keyboard: return "Keyboard shortcuts for every command"
        case .agents: return "Agent presets, live status, and control"
        case .usage: return "Token usage for your connected agents"
        case .mobile: return "Pair your iPhone and remote access"
        }
    }
}
