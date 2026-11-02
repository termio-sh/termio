import SwiftUI

/// The preferences window, opened from the app menu (⌘,). The three sidebar
/// groups are the scope model itself: how this app behaves, what you use wherever
/// it runs, and the machines that run it. Controls bind straight to
/// `AppSettings`, which persists on change, so there is no separate save step.
///
/// The layout follows macOS System Settings: a left sidebar of groups and a detail
/// pane that carries the group's title + subtitle in the toolbar with a grouped
/// `Form` below. Window chrome (resizable, unified toolbar, saved size) is set up
/// in `AppDelegate.openSettings`.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var usage: UsageMonitor
    /// The Workspaces tab's subject. Actions elsewhere are injected as closures so
    /// a pane can't reach past its own concern, but that tab *is* a live view of
    /// the workspace list — a closure would have to hand over a copy that stops
    /// tracking the moment one is added.
    @ObservedObject var store: TermioStore
    /// Opens an SSH terminal to a `~/.ssh/config` alias in the main window — a
    /// host pane's Connect action, injected by the app delegate because
    /// connecting is a main-window launch, not something this window does.
    let onSSHConnect: (String) -> Void
    /// Runs `ssh-copy-id` for an alias with the given public key, in the main
    /// window — injected for the same reason as `onSSHConnect`, since it is also a
    /// terminal launch rather than something this window can do.
    let onSetUpKey: (String, String) -> Void
    @State private var selection: SettingsTab
    /// The detail column's push stack, which a tab drills into (Agents pushes one
    /// agent's pane). Owned here so switching tabs can empty it: a pushed pane
    /// whose `navigationDestination` left with its tab would otherwise sit on the
    /// stack unresolvable.
    @State private var path = NavigationPath()
    /// A machine to open once the tab switch that `open(_:)` asked for has
    /// landed. Held rather than pushed inline because the switch clears the
    /// stack; see the `onChange` below.
    @State private var pendingMachine: String?

    init(
        settings: AppSettings,
        usage: UsageMonitor,
        store: TermioStore,
        initialTab: SettingsTab = .general,
        onSSHConnect: @escaping (String) -> Void,
        onSetUpKey: @escaping (String, String) -> Void
    ) {
        self.settings = settings
        self.usage = usage
        self.store = store
        self.onSSHConnect = onSSHConnect
        self.onSetUpKey = onSetUpKey
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Array(SettingsTab.groups.enumerated()), id: \.offset) { index, group in
                    ForEach(Array(group.enumerated()), id: \.element) { position, tab in
                        row(for: tab)
                            // The gap System Settings leaves between groups, kept
                            // inside the row: a sidebar list floors every row at
                            // 32pt, so a blank row can only ever be that tall, and
                            // `Section` — which does leave the right gap — squares
                            // off the top corners of its first row's pill.
                            .padding(.top, index > 0 && position == 0 ? 13 : 0)
                            // Leading is left at zero and paid back in `row(for:)`
                            // instead — see `settingsSidebarBaseIndent`. Trailing
                            // behaves, so it is set here and only has to make up
                            // the ~4pt the list already leaves on that side.
                            .listRowInsets(EdgeInsets(
                                top: 1, leading: 0,
                                bottom: 1, trailing: settingsSidebarPillInset - 4))
                            .tag(tab)
                            // Strips the source list's own selection fill, which
                            // would otherwise draw the full row height behind the
                            // pill, and takes its leading indent with it. Mounted
                            // in a row: that is where the walk-up reaches the
                            // table (see `OutlineViewFixups`).
                            .background(OutlineViewFixups(style: .fullWidth))
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 184, ideal: 204, max: 240)
        } detail: {
            NavigationStack(path: $path) {
                detail
                    // One line, no subtitle: the page's name is the only thing the
                    // title bar has to say, and the second line truncated on half
                    // the tabs at the default width. What a page is for is said by
                    // its own section headers.
                    .navigationTitle(selection.title)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            // The page sits on a ground a shade off the window white, so the
            // sidebar reads as the lighter panel floating above it and each grouped
            // card as a well sunk into it. On white all three were one sheet, told
            // apart only by the sidebar's shadow. Set on the stack, not the root
            // page, so a pushed pane (an agent, a remote host) stands on it too.
            .scrollContentBackground(.hidden)
            .background(Color.primary.opacity(settingsCanvasInk).ignoresSafeArea())
        }
        .navigationSplitViewStyle(.balanced)
        .labeledContentStyle(.settingsCentered)
        // Remember where the user is, so the next ⌘, reopens the same tab
        // (see `AppDelegate.showSettings`). Written on every switch — cheap,
        // and it must also capture the initial deep-linked tab a user stays on.
        .onChange(of: selection, initial: true) { previous, tab in
            UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.lastOpenKey)
            // Only a real switch empties the stack: the `initial: true` fire is
            // what writes a deep-linked tab to `lastOpenKey`, and it has no stack
            // to clear.
            guard previous != tab else { return }
            path = NavigationPath()
            // …and the same clear is why a jump to a machine has to re-push
            // afterwards rather than set both at once: the switch it just made
            // would empty the stack under it.
            if let pending = pendingMachine {
                path = NavigationPath([DeviceRoute(key: pending)])
                pendingMachine = nil
            }
        }
    }

    /// Jumps to the machine that owns a fact shown elsewhere — the Agents tab's
    /// integration rows. This Mac is a tab of its own, so it needs no push; a
    /// remote host is a row under Remote Hosts, so it needs one.
    ///
    /// The hop exists because the alternative is worse in both directions: a
    /// machine pane rendered inside the Agents tab would leave the sidebar
    /// pointing at Agents while showing a machine, and a row that only *names*
    /// the machine (what the sentence here used to do) tells the user where to go
    /// and then makes them walk.
    private func open(_ machine: KnownDevice) {
        if machine.isLocal {
            pendingMachine = nil
            selection = .server
        } else {
            pendingMachine = machine.settingsKey
            selection = .remoteHosts
        }
    }

    /// One sidebar row, painting its own selection pill because the source list's
    /// fill covers the whole row — including the group gap the first row of a
    /// group carries.
    ///
    /// The pill is the main sidebar's selection glass, not the accent: Termio marks
    /// state with ink, and the same "this one" in both sidebars reads as one app.
    /// The selected row keeps the full-strength label and takes a medium weight.
    private func row(for tab: SettingsTab) -> some View {
        let isSelected = selection == tab
        let isServer = tab == .server
        // An HStack rather than a Label: a Label centres its icon in a fixed
        // column, so Server's larger tile grew out to the left past the others.
        // Here every tile starts on one edge and the larger one pushes its text.
        return HStack(spacing: 7) {
            // On the same glass tile the main sidebar puts behind each session's
            // mark, so the two sidebars read as one app. The tile is the shape that
            // makes a column of icons scannable; the glyph inside stays ink.
            //
            // Server's tile is larger, the way the row that reports state leads a
            // System Settings sidebar: it is the machine, and it sits above the
            // preferences rather than among them.
            HugeIconView(icon: tab.icon, size: isServer ? 16 : 12, color: .primary)
                .frame(width: isServer ? 28 : 20, height: isServer ? 28 : 20)
                .background(GlassTile(cornerRadius: isServer ? 8 : 6))
            Text(tab.title)
                .fontWeight(isSelected ? .medium : .regular)
        }
        .padding(.vertical, isServer ? 4 : 0)
        .foregroundStyle(Color.primary)
        .padding(.horizontal, settingsSidebarPillPadding)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .background {
            if isSelected {
                SelectionGlass(shape: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        // Applied *after* the pill so the pill widens with the row rather than
        // sliding out from under it, and last so nothing downstream re-insets it.
        .padding(.leading, settingsSidebarPillInset - settingsSidebarBaseIndent)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general: GeneralSettingsTab(settings: settings)
        case .appearance: AppearanceSettingsTab(settings: settings)
        case .terminal: TerminalSettingsTab(settings: settings)
        case .workspaces: WorkspaceSettingsTab(store: store)
        case .server: ServerSettingsTab(settings: settings)
        case .remoteHosts:
            RemoteHostsSettingsTab(
                settings: settings, store: store,
                onConnect: onSSHConnect, onSetUpKey: onSetUpKey
            )
        case .keyboard: KeybindingsSettingsTab()
        case .agents:
            AgentSettingsTab(settings: settings, store: store, onOpenMachine: open)
        case .usage: UsageSettingsTab(settings: settings, usage: usage)
        case .community: CommunitySettingsTab()
        }
    }
}

/// Where a sidebar row lands. `pillInset + pillPadding` is the icon's leading
/// edge, aimed at the close button's — a sidebar whose items hang to the right of
/// the traffic lights reads as a column that was nudged and never lined back up,
/// and it is the first thing the eye checks, since the two are the only things on
/// that edge.
///
/// `baseIndent` is what the sidebar list indents every row by before any inset of
/// ours, and it is the reason the first three attempts at this moved nothing:
/// it is not reachable from `listRowInsets`, from `contentMargins` at either
/// placement, or from the table's style — each was tried and measured, and the
/// pill stayed at 26.7pt. So it is paid back rather than removed, with a negative
/// leading padding on the row.
///
/// The number is measured off a screenshot, not guessed: the window's left edge
/// comes from fitting its rounded corner, the scale from the sidebar's own 184pt
/// minimum width, and the indent is then pill-left minus the inset that produced
/// it. Re-measure the same way if a macOS release moves it; a wrong value shows
/// up immediately as rows that overhang the window or sit short of the lights.
private let settingsSidebarBaseIndent: CGFloat = 18.7
private let settingsSidebarPillInset: CGFloat = 10
private let settingsSidebarPillPadding: CGFloat = 6

/// How much ink the detail page's ground carries over the window background:
/// #F4F4F4 on light, and the matching lift on dark.
private let settingsCanvasInk: Double = 0.045
