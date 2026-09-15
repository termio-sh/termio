import SwiftUI

/// Settings ▸ Workspaces: the whole set at once, where renaming and removing one
/// live. The switcher in the sidebar band only switches — the same line Settings ▸
/// Devices already draws between connecting to a host and configuring one. A verb
/// that reshapes the list belongs where the list is visible, not in a menu that
/// shows one row of it at a time.
///
/// Creating stays in the menus as well as here: New Workspace… is how a second
/// workspace comes to exist, and the switcher is hidden until there are two, so a
/// create verb reachable only from this pane would be reachable only by someone
/// who already knew to look for it.
struct WorkspaceSettingsTab: View {
    @ObservedObject var store: TermioStore

    var body: some View {
        Form {
            Section {
                ForEach(store.orderedWorkspaces) { workspace in
                    NavigationLink(value: WorkspaceRoute(id: workspace.id)) {
                        WorkspaceSettingsRow(
                            workspace: workspace,
                            isCurrent: workspace.id == store.currentWorkspaceID,
                            sessionCount: store.sessions(inWorkspace: workspace.id).count
                        )
                    }
                    .contextMenu {
                        Button(localized("Rename…")) {
                            store.presentRenameWorkspacePanel(workspace.id)
                        }
                        Button(localized("Remove"), role: .destructive) {
                            store.confirmRemoveWorkspace(workspace.id)
                        }
                        .disabled(!store.hasMultipleWorkspaces)
                    }
                }
                newWorkspaceControl
            } header: {
                SectionHeaderLabel(title: localized("Workspaces"))
            } footer: {
                // One sentence, saying what the thing is. What removing one costs is
                // the confirmation alert's job, and it already says it.
                Text(localized("A workspace scopes the sidebar to the projects and sessions filed under it, on the machine it belongs to."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationDestination(for: WorkspaceRoute.self) { route in
            WorkspacePane(store: store, id: route.id)
        }
    }

    /// A plain `+` on one machine, a device pull-down once there is a second box
    /// to put a workspace on — the same collapse the menus make
    /// (`refreshNewWorkspaceItem`). A workspace belongs to exactly one machine, so
    /// the choice has to be made somewhere; making it here keeps the device level
    /// invisible to someone who owns one machine.
    ///
    /// Both branches live in the list's gutter (see `SettingsListGutter`), which
    /// is what keeps them looking alike: the glyph is the same either way, and
    /// only whether it opens a menu changes.
    @ViewBuilder
    private var newWorkspaceControl: some View {
        let others = DeviceRoster.cloneTargets(in: store)
        SettingsListGutter {
            if others.isEmpty {
                Button {
                    store.presentNewWorkspacePanel(on: .thisMac)
                } label: {
                    SettingsGutterGlyph(symbol: "plus")
                }
                .buttonStyle(.plain)
                .help(localized("New Workspace"))
                .accessibilityLabel(localized("New Workspace"))
            } else {
                Menu {
                    Button(localized("This Mac")) {
                        store.presentNewWorkspacePanel(on: .thisMac)
                    }
                    ForEach(others) { device in
                        Button(device.name) {
                            store.presentNewWorkspacePanel(on: WorkspaceDevice(alias: device.alias))
                        }
                    }
                } label: {
                    SettingsGutterGlyph(symbol: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help(localized("New Workspace"))
                .accessibilityLabel(localized("New Workspace"))
            }
        }
    }
}

/// What a row pushes. A named type so the settings window's shared navigation
/// stack can't confuse a workspace with another pane's string destination.
private struct WorkspaceRoute: Hashable {
    let id: Workspace.ID
}

/// One workspace: its name, the machine and session count under it, and a mark
/// when it is the one on screen. No controls — the row opens onto them.
///
/// The mark sits at the trailing edge. Leading, it needed a reserved column on
/// every row to keep the names on one edge, which is a column of blank space
/// paid for by every workspace so that one of them can be ticked — and the names
/// still read as indented from the card. Trailing, it lands beside the chevron,
/// where a list puts its state.
private struct WorkspaceSettingsRow: View {
    let workspace: Workspace
    let isCurrent: Bool
    let sessionCount: Int

    /// The machine the workspace is on, and what removing it would cost. Zero
    /// sessions say so by omission rather than reading "0 sessions".
    private var subtitle: String {
        let device = workspace.device.displayName
        guard sessionCount > 0 else { return device }
        return localized("\(device) · \(sessionCount) session(s)")
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(localized("Current workspace"))
            }
        }
    }
}

/// One workspace's pane: what it is called, where it lives, and how to get rid of
/// it — the two verbs that used to hide behind a `⋯` on every row.
///
/// Renaming happens in the field rather than in the modal panel the menus open:
/// a panel is the right shape when the verb is invoked from a menu with no pane
/// to put a field in, and the wrong one when you are already looking at the
/// thing's own page.
private struct WorkspacePane: View {
    @ObservedObject var store: TermioStore
    let id: Workspace.ID

    /// The name being typed, committed on return or on leaving. Bound straight to
    /// the store, an emptied field would read back as the old name on the very
    /// next keystroke and make the name impossible to retype.
    @State private var draftName = ""
    @Environment(\.dismiss) private var dismiss

    private var workspace: Workspace? {
        store.orderedWorkspaces.first { $0.id == id }
    }

    var body: some View {
        if let workspace {
            Form {
                Section {
                    LabeledContent {
                        TextField("", text: $draftName, prompt: Text(workspace.name))
                            .multilineTextAlignment(.trailing)
                            .labelsHidden()
                            .frame(minWidth: 180)
                            .onSubmit { commit() }
                    } label: {
                        SettingsLabel(
                            title: localized("Name"),
                            subtext: localized("What this workspace is called in the sidebar."),
                            titleFont: .headline
                        )
                    }
                    LabeledContent {
                        Text(workspace.device.displayName).foregroundStyle(.secondary)
                    } label: {
                        SettingsLabel(
                            title: localized("Machine"),
                            subtext: localized("Where everything filed under this workspace lives."),
                            titleFont: .headline
                        )
                    }
                }

                Section {
                    LabeledContent {
                        Button(localized("Remove…"), role: .destructive) {
                            store.confirmRemoveWorkspace(id)
                            // The alert runs modally, so by here the answer is in:
                            // gone means leave, cancelled means stay.
                            if workspaceIsGone { dismiss() }
                        }
                        // The store refuses to remove the last workspace — the
                        // sidebar has to have a scope to show — so the button dims
                        // rather than answering a click with nothing.
                        .disabled(!store.hasMultipleWorkspaces)
                    } label: {
                        SettingsLabel(
                            title: localized("Remove Workspace"),
                            subtext: localized("Closes every session in it. The folders on disk are left alone.")
                        )
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(workspace.name)
            .task(id: id) { draftName = workspace.name }
            .onDisappear { commit() }
        } else {
            // The workspace went away under us — removed from the switcher while
            // its pane was open.
            ContentUnavailableView {
                Text(localized("Workspace Unavailable"))
            } description: {
                Text(localized("This workspace is no longer on your list."))
            }
        }
    }

    private var workspaceIsGone: Bool {
        !store.orderedWorkspaces.contains { $0.id == id }
    }

    /// Writes the draft back. The store drops an empty or whitespace-only name, so
    /// the field is resynced from what actually landed rather than from what was
    /// typed.
    private func commit() {
        store.renameWorkspace(id, to: draftName)
        draftName = workspace?.name ?? draftName
    }
}
