import SwiftUI

/// The preferences window, opened from the app menu (⌘,). The groups mirror the
/// settings model: terminal appearance, the app's own interface chrome, terminal
/// behaviour, the agent presets, usage, and mobile pairing. Controls bind straight
/// to `AppSettings`, which persists on change, so there is no separate save step.
///
/// The layout follows macOS System Settings: a left sidebar of groups and a detail
/// pane that carries the group's title + subtitle in the toolbar with a grouped
/// `Form` below. Window chrome (resizable, unified toolbar, saved size) is set up
/// in `AppDelegate.openSettings`.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var usage: UsageMonitor
    /// Opens an SSH terminal to a `~/.ssh/config` alias in the main window — the
    /// SSH tab's Connect action, injected by the app delegate so the settings
    /// window doesn't hold the store.
    let onSSHConnect: (String) -> Void
    @State private var selection: SettingsTab

    init(
        settings: AppSettings,
        usage: UsageMonitor,
        initialTab: SettingsTab = .appearance,
        onSSHConnect: @escaping (String) -> Void
    ) {
        self.settings = settings
        self.usage = usage
        self.onSSHConnect = onSSHConnect
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selection) { tab in
                Label {
                    Text(tab.title)
                } icon: {
                    HugeIconView(icon: tab.icon, size: 15, color: .primary)
                }
                .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 184, ideal: 204, max: 240)
        } detail: {
            NavigationStack {
                detail
                    .navigationTitle(selection.title)
                    .navigationSubtitle(selection.subtitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .toolbar {
                        // Without a toolbar item the NavigationStack collapses the
                        // title + subtitle into one inline "Title – Subtitle" line
                        // beside the traffic lights. An empty principal item forces
                        // the full-height two-line chrome on every pane (macOS 26).
                        ToolbarItem(placement: .principal) { Text("") }
                    }
                    .toolbarBackground(.regularMaterial, for: .windowToolbar)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .labeledContentStyle(.settingsCentered)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general: GeneralSettingsTab(settings: settings)
        case .appearance: AppearanceSettingsTab(settings: settings)
        case .interface: InterfaceSettingsTab(settings: settings)
        case .terminal: TerminalSettingsTab(settings: settings)
        case .ssh: SSHSettingsTab(settings: settings, onConnect: onSSHConnect)
        case .keyboard: KeybindingsSettingsTab()
        case .agents: AgentSettingsTab(settings: settings)
        case .usage: UsageSettingsTab(settings: settings, usage: usage)
        case .mobile: MobileSettingsTab()
        }
    }
}
