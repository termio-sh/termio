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
    @Environment(\.colorScheme) private var colorScheme

    /// The palette a workspace's mark is an index into. Resolved once here rather
    /// than per row: every row draws from the same theme.
    private var chrome: ChromeTheme? { store.settings.chromeTheme(for: colorScheme) }

    var body: some View {
        Form {
            Section {
                ForEach(store.orderedWorkspaces) { workspace in
                    WorkspaceSettingsRow(
                        workspace: workspace,
                        isCurrent: workspace.id == store.currentWorkspaceID,
                        sessionCount: store.sessions(inWorkspace: workspace.id).count,
                        canRemove: store.hasMultipleWorkspaces,
                        tints: chrome?.workspaceTints ?? [],
                        rename: { store.presentRenameWorkspacePanel(workspace.id) },
                        recolor: { store.setWorkspaceColor(workspace.id, to: $0) },
                        remove: { store.confirmRemoveWorkspace(workspace.id) }
                    )
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
    }

    /// A plain verb on one machine, a device pull-down once there is a second box
    /// to put a workspace on — the same collapse the menus make
    /// (`refreshNewWorkspaceItem`). A workspace belongs to exactly one machine, so
    /// the choice has to be made somewhere; making it here keeps the device level
    /// invisible to someone who owns one machine.
    @ViewBuilder
    private var newWorkspaceControl: some View {
        let others = DeviceRoster.cloneTargets(in: store)
        if others.isEmpty {
            Button {
                store.presentNewWorkspacePanel(on: .thisMac)
            } label: {
                Label(localized("New Workspace"), systemImage: "plus")
            }
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
                Label(localized("New Workspace"), systemImage: "plus")
            }
            // Borderless so the two branches of this control look alike: with one
            // machine it is a plain row (the `Button` above, matching Devices' "Add
            // Host"), and the bordered pull-down default would turn the same verb
            // into the only filled slab on the pane the moment a second machine
            // exists. The bezel comes back on hover, the way every row-level
            // control in System Settings behaves.
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

/// One workspace: its name, the machine and session count under it, and the two
/// verbs that reshape it behind a trailing menu.
///
/// The row carries exactly one control, at the trailing edge, and says everything
/// else in type — the shape every list row in System Settings has. An earlier
/// version put the name in a bordered text field and Remove in a bordered button
/// on every row, which stacked two control chromes inside a grouped row that
/// already draws its own background: three rows of boxes inside boxes, with the
/// name's baseline pushed off the caption's leading edge by the field's insets.
private struct WorkspaceSettingsRow: View {
    let workspace: Workspace
    let isCurrent: Bool
    let sessionCount: Int
    let canRemove: Bool
    let tints: [Color]
    let rename: () -> Void
    let recolor: (Int) -> Void
    let remove: () -> Void

    /// The mark this workspace wears in the switcher, wrapped the way the switcher
    /// wraps it so both surfaces agree under a theme with fewer tints.
    private var color: Color? {
        guard !tints.isEmpty else { return nil }
        return tints[(workspace.color ?? 0) % tints.count]
    }

    /// The machine the workspace is on, and what removing it would cost. Zero
    /// sessions say so by omission rather than reading "0 sessions".
    private var subtitle: String {
        let device = workspace.device.displayName
        guard sessionCount > 0 else { return device }
        return localized("\(device) · \(sessionCount) session(s)")
    }

    var body: some View {
        HStack(spacing: 10) {
            // The same mark the switcher menu puts beside the workspace on screen,
            // holding its width on every row so the names share one leading edge.
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isCurrent ? Color.secondary : Color.clear)
                .frame(width: 12)
                .accessibilityHidden(!isCurrent)
                .accessibilityLabel(localized("Current workspace"))
            // The switcher's own mark, shown here because this is the other place
            // every workspace is visible at once — and the place it can be
            // changed. Not a control: the row carries one, and it is the menu.
            if let color {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }
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
            actions
        }
        .contentShape(Rectangle())
        .contextMenu { actionButtons }
    }

    /// The trailing overflow menu. Borderless and unindicated so the row reads as
    /// type with one affordance in it, rather than as a row of buttons.
    private var actions: some View {
        Menu {
            actionButtons
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(localized("Workspace actions"))
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button(localized("Rename…"), action: rename)
        if !tints.isEmpty {
            // A submenu rather than a row of wells: the row's one control is this
            // menu, and a second chrome beside the name is what the row's shape
            // exists to avoid. The tick marks the current one, so the colour is
            // readable without relying on colour alone.
            Menu(localized("Colour")) {
                ForEach(tints.indices, id: \.self) { index in
                    Button {
                        recolor(index)
                    } label: {
                        Label {
                            Text(localized("Colour \(index + 1)"))
                        } icon: {
                            Image(systemName: (workspace.color ?? 0) % tints.count == index
                                ? "checkmark.circle.fill" : "circle.fill")
                        }
                    }
                }
            }
        }
        // The store refuses to remove the last workspace — the sidebar has to have
        // a scope to show — so the row dims rather than answering a click with
        // nothing.
        Button(localized("Remove"), role: .destructive, action: remove)
            .disabled(!canRemove)
    }
}
