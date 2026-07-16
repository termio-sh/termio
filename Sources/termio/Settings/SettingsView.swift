import SwiftUI

/// The preferences window, opened from the app menu (⌘,). The tabs mirror the
/// settings groups: terminal appearance, the app's own interface chrome, terminal
/// behaviour, the agent presets, and worktree isolation. Controls bind straight to
/// `AppSettings`, which persists on change, so there is no separate save step.
///
/// The visual language follows Dia's settings: a top icon-tab toolbar for the
/// top-level groups, grouped rounded cards in the body, and Dia's signature
/// leading colored icon badges (`IconBadge`) to give each section and feature
/// row a distinct identity.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var usage: UsageMonitor
    @State private var selection: SettingsTab

    init(
        settings: AppSettings,
        usage: UsageMonitor,
        initialTab: SettingsTab = .appearance
    ) {
        self.settings = settings
        self.usage = usage
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $selection)
            Divider()
            Group {
                switch selection {
                case .appearance: AppearanceSettingsTab(settings: settings)
                case .interface: InterfaceSettingsTab(settings: settings)
                case .terminal: TerminalSettingsTab(settings: settings)
                case .keyboard: KeybindingsSettingsTab()
                case .agents: AgentSettingsTab(settings: settings)
                case .usage: UsageSettingsTab(settings: settings, usage: usage)
                case .mobile: MobileSettingsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Wide enough for the seven-tab bar (7 × 84 + spacing/padding) and the
        // Keyboard pane's shortcut column.
        .frame(width: 660, height: 540)
    }
}
