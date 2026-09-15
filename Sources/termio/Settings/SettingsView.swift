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
                    .navigationTitle(selection.title)
                    .navigationSubtitle(selection.subtitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .toolbar {
                        // Without a toolbar item the NavigationStack collapses the
                        // title + subtitle into one inline "Title – Subtitle" line
                        // beside the traffic lights. An empty principal item forces
                        // the full-height two-line chrome on every pane (macOS 26).
                        //
                        // It carries a definite 1×1 frame: a bare `Text("")`
                        // measures zero in both axes, and AppKit answers that by
                        // re-measuring the item under ambiguous constraints and
                        // logging about it — four times per tab switch, on the
                        // main thread, which is work the switch pays for.
                        //
                        // macOS 26 backs every toolbar item with the shared glass,
                        // and at this item's 1pt width that backing is all you see:
                        // a stray hairline standing in the middle of the title bar.
                        // The item has to stay — it is what keeps the two-line
                        // chrome — so the background is what goes.
                        if #available(macOS 26.0, *) {
                            ToolbarItem(placement: .principal) {
                                Color.clear.frame(width: 1, height: 1)
                            }
                            .sharedBackgroundVisibility(.hidden)
                        } else {
                            ToolbarItem(placement: .principal) {
                                Color.clear.frame(width: 1, height: 1)
                            }
                        }
                    }
                    .toolbarBackground(.regularMaterial, for: .windowToolbar)
            }
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
    private func row(for tab: SettingsTab) -> some View {
        let isSelected = selection == tab
        return Label {
            Text(tab.title)
        } icon: {
            HugeIconView(icon: tab.icon, size: 15, color: isSelected ? .white : .primary)
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.horizontal, settingsSidebarPillPadding)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
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
        case .mobile: MobileSettingsTab(store: store)
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
