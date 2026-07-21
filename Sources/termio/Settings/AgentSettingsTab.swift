import SwiftUI

struct AgentSettingsTab: View {
    @ObservedObject var settings: AppSettings

    /// Which listed agents have their configuration drawer open. Keyed by id so the
    /// set survives reordering and enable/disable without stale indices.
    @State private var expanded: Set<String> = []

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
        Form {
            Section {
                Toggle(isOn: $settings.agentHooksEnabled) {
                    SettingsLabel(
                        symbol: "dot.radiowaves.left.and.right",
                        title: "Live agent status",
                        subtext: "Installs hooks for Claude Code, Codex, OpenCode, and Pi so termio can tell when an agent is working or waiting on you — shown as the spinning sidebar icon and the menu-bar pulse. Adds termio's own entries to each agent's config; turning this off removes them. (Codex needs a one-time /hooks trust.)"
                    )
                }
                .toggleStyle(.switch)
                if settings.agentHooksEnabled {
                    // For re-applying after the user (or another tool) has edited
                    // ~/.claude/settings.json; install is idempotent.
                    Button("Reinstall hooks") { AgentStatusHooks.sync(enabled: true) }
                }
            } header: {
                SectionHeaderLabel(title: "Status")
            }
            Section {
                Toggle(isOn: $settings.sessionControlEnabled) {
                    SettingsLabel(
                        symbol: "arrow.triangle.branch",
                        title: "Session control",
                        subtext: "Lets an agent see and drive its sibling sessions in the same project with the `termio sessions` command (list, send a prompt, answer a menu, start, stop). Scoped to the current project. Adds a short awareness note to the agents' instruction files; turning this off removes it."
                    )
                }
                .toggleStyle(.switch)
                if settings.sessionControlEnabled {
                    Button("Reinstall note") { SessionSkillInstaller.sync(enabled: true) }
                }
            } header: {
                SectionHeaderLabel(title: "Orchestration")
            }
            Section {
                DefaultChatAgentRow(settings: settings)
            } header: {
                SectionHeaderLabel(title: "New chat")
            }
            agentsSection
        }
        .formStyle(.grouped)
    }

    /// The one section that replaced a full-height card per agent: the user's agents
    /// as a compact, reorderable list whose per-agent config hides behind a disclosure,
    /// and the rest of the catalog behind an "Add Agent" pull-down at the bottom —
    /// the System Settings shape for "curated list + pool to add from".
    private var agentsSection: some View {
        Section {
            ForEach(listedAgents) { preset in
                AgentManagerRow(
                    settings: settings,
                    preset: preset,
                    isExpanded: expanded.contains(preset.id),
                    toggleExpanded: { toggleExpanded(preset) }
                )
            }
            .onMove(perform: moveListed)

            if !addableAgents.isEmpty {
                Menu {
                    ForEach(addableAgents) { preset in
                        Button { add(preset) } label: {
                            Label { Text(preset.displayName) } icon: { IconBadge(preset.icon) }
                        }
                    }
                } label: {
                    Label("Add Agent", systemImage: "plus")
                }
            }
        } header: {
            SectionHeaderLabel(title: "Agents")
        } footer: {
            Text("The agents offered in the new-session menu and the sidebar's quick-add row, in this order — drag to reorder, right-click to remove. Open a row to set a custom command or skip its permission prompts. An agent whose CLI isn't installed stays off until it is.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Adds the agent's row immediately, then lets the availability probe decide the
    /// switch: an installed CLI turns it on; a missing one leaves it off with its
    /// drawer opened onto the install link. The row never blocks on the probe.
    private func add(_ preset: AgentPreset) {
        settings.addAgent(preset)
        Task { @MainActor in
            if await AgentAvailability.isCommandAvailable(settings.command(for: preset) ?? "") {
                settings.setAgent(preset, enabled: true)
            } else {
                expanded.insert(preset.id)
            }
        }
    }

    private func toggleExpanded(_ preset: AgentPreset) {
        if expanded.contains(preset.id) { expanded.remove(preset.id) } else { expanded.insert(preset.id) }
    }

    /// Persists a drag as the new arrangement; `setEnabledOrder` keeps every
    /// other id ranked behind it so the ordering stays total.
    private func moveListed(from source: IndexSet, to destination: Int) {
        var ids = listedAgents.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        settings.setEnabledOrder(ids)
    }
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
            Text("Last used").tag(lastUsedTag)
            ForEach(chatAgents) { Text($0.displayName).tag($0.id) }
        } label: {
            SettingsLabel(
                symbol: "plus.bubble",
                title: "Default agent",
                subtext: "The agent New Chat (⌘N) starts. “Last used” follows whichever agent you most recently chatted with."
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

/// An enabled agent's management row: a compact header (icon, name, effective
/// command, an unavailable hint, the enable switch) with the heavier config —
/// command override, install link, permission bypass — tucked behind a disclosure so
/// the list stays scannable. Draggable to reorder (the enclosing `ForEach.onMove`).
private struct AgentManagerRow: View {
    @ObservedObject var settings: AppSettings
    let preset: AgentPreset
    let isExpanded: Bool
    let toggleExpanded: () -> Void

    /// `nil` while the PATH probe is still running (show nothing rather than a
    /// premature warning); `false` once we've confirmed the command isn't resolvable.
    @State private var available: Bool?

    var body: some View {
        // One VStack = one Form row, so the header and its disclosed controls share a
        // single cell — separators fall only between agents, and the drawer can't be
        // mistaken for top-level rows (as `Group`'s sibling rows were).
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                IconBadge(preset.icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.displayName).font(.headline)
                    Text(settings.command(for: preset) ?? "Login shell")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                // A quiet, uncolored hint — matching the tab's calm tone — rather than
                // an alarm; the install link lives inside the drawer.
                if available == false {
                    Image(systemName: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("\(preset.displayName) isn’t on your PATH")
                }
                Button(action: toggleExpanded) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .contentShape(Rectangle())
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                Toggle("", isOn: Binding(
                    get: { settings.isAgentEnabled(preset) },
                    set: { settings.setAgent(preset, enabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                // A missing CLI can't be launched, so it can't be switched on — only
                // off (an already-on agent stays revocable while the hint shows).
                .disabled(available == false && !settings.isAgentEnabled(preset))
            }
            // Without an explicit shape only the row's glyphs are right-clickable —
            // the padding and the Spacer are holes in the Form row's hit test.
            .contentShape(Rectangle())
            .contextMenu {
                Button("Remove from List") { settings.removeAgent(preset) }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Command") {
                        TextField(
                            "",
                            text: Binding(
                                get: { settings.agentCommandOverrides[preset.rawValue] ?? "" },
                                set: { settings.agentCommandOverrides[preset.rawValue] = $0 }
                            ),
                            prompt: Text(preset.command ?? "")
                        )
                        .textFieldStyle(.plain)
                        .labelsHidden()
                    }

                    if available == false, let url = preset.installURL {
                        Link(destination: url) {
                            Label("Install \(preset.displayName)", systemImage: "arrow.down.circle")
                        }
                    }

                    if let flag = preset.permissionBypassFlag {
                        Toggle(isOn: Binding(
                            get: { settings.bypassesPermissions(preset) },
                            set: { settings.setBypassPermissions(preset, enabled: $0) }
                        )) {
                            SettingsLabel(
                                title: "Skip permission prompts",
                                subtext: "Runs with `\(flag)`. The agent won't ask before editing files or running commands."
                            )
                        }
                        .toggleStyle(.switch)
                    }

                    // The visible twin of the row's right-click item — a drawer-only
                    // action so the scannable list stays clean. Deliberately not
                    // red: nothing is destroyed — the row folds back into the "Add
                    // Agent" menu with its overrides intact, so no confirmation
                    // either.
                    Button("Remove from List") {
                        settings.removeAgent(preset)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                // Indent to the title's column (icon 22 + spacing 10) so the drawer
                // reads as the row's children, not more agents.
                .padding(.leading, 32)
                .padding(.top, 12)
            }
        }
        // Re-checks whenever the effective command changes, so typing a valid path
        // clears the hint. The PATH probe runs once (cached); each row does an
        // in-memory lookup. The leading sleep debounces per-keystroke edits into one
        // probe once the user pauses.
        .task(id: effectiveCommand) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            available = await AgentAvailability.isCommandAvailable(effectiveCommand)
        }
    }

    private var effectiveCommand: String { settings.command(for: preset) ?? "" }
}
