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

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .interface: return "sidebar.left"
        case .terminal: return "terminal"
        case .ssh: return "server.rack"
        case .keyboard: return "keyboard"
        case .agents: return "sparkles"
        case .usage: return "gauge.medium"
        case .mobile: return "iphone"
        }
    }

    /// The one-line description shown under the pane title in the detail header,
    /// matching macOS System Settings' navigation subtitle.
    var subtitle: String {
        switch self {
        case .general: return "The termio command-line tool"
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
