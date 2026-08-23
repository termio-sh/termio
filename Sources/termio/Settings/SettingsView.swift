import SwiftUI

/// The preferences window, opened from the app menu (⌘,). The groups mirror the
/// settings model: appearance, terminal behaviour, the agent presets, usage, and
/// mobile pairing. Controls bind straight
/// to `AppSettings`, which persists on change, so there is no separate save step.
///
/// The layout follows macOS System Settings: a left sidebar of groups and a detail
/// pane that carries the group's title + subtitle in the toolbar with a grouped
/// `Form` below. Window chrome (resizable, unified toolbar, saved size) is set up
/// in `AppDelegate.openSettings`.
///
/// Both columns paint the terminal theme's colors rather than the stock window
/// material, the way every other chrome surface does (see `ChromeTheme`) — the
/// theme is the app's one source of color truth, and a preferences window in
/// system grey was the last surface that ignored it.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var usage: UsageMonitor
    /// The Workspaces tab's subject. Actions elsewhere are injected as closures so
    /// a pane can't reach past its own concern, but that tab *is* a live view of
    /// the workspace list — a closure would have to hand over a copy that stops
    /// tracking the moment one is added.
    @ObservedObject var store: TermioStore
    /// Opens an SSH terminal to a `~/.ssh/config` alias in the main window — the
    /// Devices tab's Connect action, injected by the app delegate because
    /// connecting is a main-window launch, not something this window does.
    let onSSHConnect: (String) -> Void
    @State private var selection: SettingsTab

    init(
        settings: AppSettings,
        usage: UsageMonitor,
        store: TermioStore,
        initialTab: SettingsTab = .general,
        onSSHConnect: @escaping (String) -> Void
    ) {
        self.settings = settings
        self.usage = usage
        self.store = store
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
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: settings.panelBackgroundColor))
            .navigationSplitViewColumnWidth(min: 184, ideal: 204, max: 240)
        } detail: {
            NavigationStack {
                detail
                    .navigationTitle(selection.title)
                    .navigationSubtitle(selection.subtitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: settings.terminalBackgroundColor))
                    .toolbar {
                        // Without a toolbar item the NavigationStack collapses the
                        // title + subtitle into one inline "Title – Subtitle" line
                        // beside the traffic lights. An empty principal item forces
                        // the full-height two-line chrome on every pane (macOS 26).
                        ToolbarItem(placement: .principal) { Text("") }
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .labeledContentStyle(.settingsCentered)
        // Remember where the user is, so the next ⌘, reopens the same tab
        // (see `AppDelegate.showSettings`). Written on every switch — cheap,
        // and it must also capture the initial deep-linked tab a user stays on.
        .onChange(of: selection, initial: true) { _, tab in
            UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.lastOpenKey)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general: GeneralSettingsTab(settings: settings)
        case .appearance: AppearanceSettingsTab(settings: settings)
        case .terminal: TerminalSettingsTab(settings: settings)
        case .workspaces: WorkspaceSettingsTab(store: store)
        case .devices: DevicesSettingsTab(settings: settings, onConnect: onSSHConnect)
        case .keyboard: KeybindingsSettingsTab()
        case .agents: AgentSettingsTab(settings: settings)
        case .usage: UsageSettingsTab(settings: settings, usage: usage)
        case .mobile: MobileSettingsTab()
        case .community: CommunitySettingsTab()
        }
    }
}
