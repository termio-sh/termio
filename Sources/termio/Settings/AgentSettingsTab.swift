import AppKit
import SwiftUI

/// The Agents tab as a master–detail split: a left column listing the user's
/// agents (drag to reorder, switch to enable) plus a pinned General row, and a
/// right pane carrying the selected agent's configuration — replacing the old
/// single-column list whose per-agent config hid behind disclosure drawers.
struct AgentSettingsTab: View {
    @ObservedObject var settings: AppSettings

    /// What the detail pane shows. `general` carries the tab's non-per-agent
    /// settings (the default chat agent) so they keep a home in the split
    /// without a second tab.
    private enum Pane: Hashable {
        case general
        case agent(String)
    }

    @State private var selection: Pane = .general

    /// Bumped after every catalog reload. `AgentDefinition` equality is by id, so
    /// without this a rename would leave stale rows on screen; referencing the
    /// version in `body` forces a recompute from the fresh catalog.
    @State private var catalogVersion = 0

    /// The agents the user actually manages, in the user's arrangement. The plain
    /// Terminal is not here — it's the login shell, configured on the Terminal tab and
    /// always available, so it's never an enable/reorder row (see `AgentDefinition.isShell`).
    private var listedAgents: [AgentPreset] {
        settings.orderedAgents(AgentPreset.codingAgents.filter(settings.isAgentListed))
    }
    private var addableAgents: [AgentPreset] {
        settings.orderedAgents(AgentPreset.codingAgents.filter { !settings.isAgentListed($0) })
    }

    var body: some View {
        let _ = catalogVersion
        HStack(spacing: 0) {
            sidebar
                .frame(width: 230)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // Custom agents are edited in their manifest, in another app. Re-reading
        // the catalog when termio comes back to the front is what makes that land.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            AgentCatalog.reload()
            catalogVersion += 1
        }
    }

    // MARK: Left column

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Label {
                    Text(localized("General"))
                } icon: {
                    IconBadge(.symbol("gearshape"))
                }
                .tag(Pane.general)

                Section(localized("Agents")) {
                    ForEach(listedAgents) { preset in
                        AgentListRow(settings: settings, preset: preset)
                            .tag(Pane.agent(preset.id))
                            .contextMenu {
                                Button(localized("Remove from List")) { remove(preset) }
                            }
                    }
                    .onMove(perform: moveListed)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()
            AddAgentBar(
                addable: addableAgents,
                onAdd: add,
                onCustom: createCustomAgent
            )
        }
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general:
            generalPane
        case .agent(let id):
            if let preset = listedAgents.first(where: { $0.id == id }) {
                AgentDetailPane(
                    settings: settings,
                    preset: preset,
                    onRemove: { remove(preset) },
                    // Editing and deletion exist only for agents backed by a user
                    // manifest; bundled agents just leave the list.
                    isUserDefined: AgentCatalog.shared.isUserDefined(preset.id),
                    onDelete: AgentCatalog.shared.isUserDefined(preset.id)
                        ? { deleteCustom(preset) } : nil
                )
                // Distinct identity per agent — and per catalog generation, so a
                // rename rebuilds the pane (definitions compare equal by id).
                .id("\(preset.id)#\(catalogVersion)")
            } else {
                // The selected agent was removed out from under us; fall back.
                generalPane.onAppear { selection = .general }
            }
        }
    }

    /// The tab's non-per-agent settings — just the default chat agent now that
    /// agent integrations live on the General tab.
    private var generalPane: some View {
        Form {
            Section {
                DefaultChatAgentRow(settings: settings)
            } header: {
                SectionHeaderLabel(title: localized("New chat"))
            } footer: {
                Text(localized("Drag the list to change the order agents appear in."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Adds the agent's row immediately and selects it, then lets the availability
    /// probe decide the switch: an installed CLI turns it on; a missing one leaves
    /// it off with the detail pane already showing the install link.
    private func add(_ preset: AgentPreset) {
        settings.addAgent(preset)
        selection = .agent(preset.id)
        Task { @MainActor in
            if await AgentAvailability.isCommandAvailable(settings.command(for: preset) ?? "") {
                settings.setAgent(preset, enabled: true)
            }
        }
    }

    private func remove(_ preset: AgentPreset) {
        if selection == .agent(preset.id) { selection = .general }
        settings.removeAgent(preset)
    }

    /// Seeds a starter manifest, puts it on the list, and opens the file — the
    /// manifest is the editor for a custom agent, so Settings' job ends at handing
    /// over a valid one. The row lands with its switch off (the placeholder command
    /// resolves to nothing) and turns on once the file names a real CLI.
    private func createCustomAgent() {
        let created: (id: String, file: URL)
        do {
            created = try UserAgentStore.createTemplate()
        } catch {
            AgentCatalog.log("could not create a custom agent manifest: \(error)")
            NSSound.beep()
            return
        }
        AgentCatalog.reload()
        catalogVersion += 1
        settings.addAgent(AgentCatalog.shared.definition(for: created.id))
        selection = .agent(created.id)
        NSWorkspace.shared.open(created.file)
    }

    /// Deletes a user agent's manifest file (its sessions survive via the id-only
    /// fallback definition). Confirmation lives on the button in the detail pane.
    private func deleteCustom(_ preset: AgentPreset) {
        do {
            try UserAgentStore.delete(id: preset.id)
        } catch {
            AgentCatalog.log("could not delete \(preset.id): \(error)")
            return
        }
        remove(preset)
        AgentCatalog.reload()
        catalogVersion += 1
    }

    /// Persists a drag as the new arrangement; `setEnabledOrder` keeps every
    /// other id ranked behind it so the ordering stays total.
    private func moveListed(from source: IndexSet, to destination: Int) {
        var ids = listedAgents.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        settings.setEnabledOrder(ids)
    }
}

/// The list's footer action, shaped like the sidebar bottom bars in Mail and
/// Reminders: the whole bar is the pull-down's hit target, so the control reads as
/// part of the column rather than a small floating button, and its hover highlight
/// lines up with the list rows above it.
private struct AddAgentBar: View {
    let addable: [AgentPreset]
    let onAdd: (AgentPreset) -> Void
    let onCustom: () -> Void

    @State private var hovering = false

    var body: some View {
        Menu {
            // Plain text rows: AppKit menus rasterize custom SwiftUI icon views
            // at their natural image size, not the badge frame.
            ForEach(addable) { preset in
                Button(preset.displayName) { onAdd(preset) }
            }
            if !addable.isEmpty { Divider() }
            Button(localized("Custom Agent…")) { onCustom() }
        } label: {
            HStack(spacing: 8) {
                // Same 22pt frame IconBadge uses, so the plus sits in the rows'
                // icon column instead of starting its own margin.
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(localized("Add Agent"))
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0))
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovering = $0 }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }
}

/// A left-column agent row: brand mark, name, and the enable switch — kept to one
/// line so the column stays a scannable roster. The heavier config lives in the
/// detail pane.
private struct AgentListRow: View {
    @ObservedObject var settings: AppSettings
    let preset: AgentPreset

    /// `nil` while the PATH probe is still running (show nothing rather than a
    /// premature warning); `false` once we've confirmed the command isn't resolvable.
    @State private var available: Bool?

    var body: some View {
        HStack(spacing: 8) {
            IconBadge(preset.icon)
            Text(preset.displayName)
            Spacer(minLength: 4)
            if available == false {
                Image(systemName: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help(localized("\(preset.displayName) isn’t on your PATH"))
            }
            Toggle("", isOn: Binding(
                get: { settings.isAgentEnabled(preset) },
                set: { settings.setAgent(preset, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            // A missing CLI can't be launched, so it can't be switched on — only
            // off (an already-on agent stays revocable while the hint shows).
            .disabled(available == false && !settings.isAgentEnabled(preset))
        }
        .task(id: settings.command(for: preset) ?? "") {
            available = await AgentAvailability.isCommandAvailable(
                settings.command(for: preset) ?? "")
        }
    }
}

/// The selected agent's configuration: an identity header above a grouped form —
/// command override, install link when the CLI is missing, the permission-bypass
/// switch, and removal.
private struct AgentDetailPane: View {
    @ObservedObject var settings: AppSettings
    let preset: AgentPreset
    let onRemove: () -> Void
    /// True for agents backed by a manifest in the user's config folder — the only
    /// ones whose file can be opened or deleted from here.
    var isUserDefined = false
    /// Set only for user-manifest agents: deletes the manifest file.
    var onDelete: (() -> Void)?

    /// Same probe semantics as the list row (see `AgentListRow.available`).
    @State private var available: Bool?
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    IconBadge(preset.icon)
                        .scaleEffect(1.4)
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.displayName)
                            .font(.title3.weight(.semibold))
                        Text(settings.command(for: preset) ?? localized("Login shell"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if isUserDefined {
                        Spacer(minLength: 8)
                        Button(localized("Reveal in Finder")) {
                            UserAgentStore.reveal(id: preset.id)
                        }
                        Button(localized("Edit Manifest")) {
                            UserAgentStore.open(id: preset.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            Section {
                LabeledContent(localized("Command")) {
                    TextField(
                        "",
                        text: Binding(
                            get: { settings.agentCommandOverrides[preset.rawValue] ?? "" },
                            set: { settings.agentCommandOverrides[preset.rawValue] = $0 }
                        ),
                        prompt: Text(preset.command ?? "")
                    )
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .labelsHidden()
                }
                if available == false, let url = preset.installURL {
                    Link(destination: url) {
                        Label(localized("Install \(preset.displayName)"), systemImage: "arrow.down.circle")
                    }
                }
            } header: {
                SectionHeaderLabel(title: localized("Launch"))
            }

            if let flag = preset.permissionBypassFlag {
                Section {
                    Toggle(isOn: Binding(
                        get: { settings.bypassesPermissions(preset) },
                        set: { settings.setBypassPermissions(preset, enabled: $0) }
                    )) {
                        SettingsLabel(
                            title: localized("Skip permission prompts"),
                            subtext: localized("Runs with `\(flag)`. The agent won’t ask before editing files or running commands.")
                        )
                    }
                    .toggleStyle(.switch)
                } header: {
                    SectionHeaderLabel(title: localized("Permissions"))
                }
            }

            Section {
                // Deliberately not red: nothing is destroyed — the agent folds back
                // into the "Add Agent" menu with its overrides intact, so no
                // confirmation either.
                LabeledContent {
                    Button(localized("Remove")) { onRemove() }
                } label: {
                    SettingsLabel(
                        title: localized("Remove from List"),
                        subtext: localized("Takes \(preset.displayName) out of the new-session menu. Its settings are kept.")
                    )
                }
                if let onDelete {
                    // Red and confirmed, unlike Remove: this one erases the
                    // manifest file the agent is made of.
                    LabeledContent {
                        Button(localized("Delete…"), role: .destructive) { confirmingDelete = true }
                            .confirmationDialog(
                                localized("Delete \(preset.displayName)?"),
                                isPresented: $confirmingDelete
                            ) {
                                Button(localized("Delete"), role: .destructive) { onDelete() }
                            } message: {
                                Text(localized("Removes this custom agent and its configuration file. Existing sessions keep running."))
                            }
                    } label: {
                        SettingsLabel(
                            title: localized("Delete Agent"),
                            subtext: localized("Deletes the custom agent’s manifest from this Mac.")
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Re-checks whenever the effective command changes, so typing a valid path
        // clears the install link. The PATH probe runs once (cached); each check is
        // an in-memory lookup. The leading sleep debounces per-keystroke edits into
        // one probe once the user pauses.
        .task(id: effectiveCommand) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            available = await AgentAvailability.isCommandAvailable(effectiveCommand)
        }
    }

    private var effectiveCommand: String { settings.command(for: preset) ?? "" }
}

/// The "New chat" default-agent picker: which agent the single New Chat action
/// (⌘N, the `+` menu, the Chats header) launches. "Last used" keeps it adaptive
/// (the last agent you started a chat with); picking a specific agent pins it.
/// Only enabled agents are offered — a disabled one can't run a chat — and a
/// previously-pinned agent that is now disabled reads back as "Last used".
private struct DefaultChatAgentRow: View {
    @ObservedObject var settings: AppSettings

    /// Empty-string tag stands for "Last used" (agent ids are always non-empty),
    /// so the picker can carry the `nil` choice as a plain `String` selection.
    private let lastUsedTag = ""

    private var chatAgents: [AgentPreset] {
        enabledAgentPresets(settings).filter { !$0.isShell }
    }

    var body: some View {
        Picker(selection: selection) {
            Text(localized("Last used")).tag(lastUsedTag)
            ForEach(chatAgents) { Text($0.displayName).tag($0.id) }
        } label: {
            SettingsLabel(
                .huge(.bubbleChatAdd),
                title: localized("Default agent"),
                subtext: localized("The agent New Chat (⌘N) starts. “Last used” follows whichever agent you most recently chatted with.")
            )
        }
    }

    /// Reads back the pinned id only while that agent is still enabled; otherwise
    /// falls to "Last used" so the control never shows a stale, unlaunchable choice.
    private var selection: Binding<String> {
        Binding(
            get: {
                if let id = settings.defaultChatAgentID,
                   chatAgents.contains(where: { $0.id == id }) { return id }
                return lastUsedTag
            },
            set: { settings.defaultChatAgentID = $0 == lastUsedTag ? nil : $0 }
        )
    }
}
