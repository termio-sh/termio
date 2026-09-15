import AppKit
import SwiftUI
import UserNotifications

/// The Agents tab as a drill-down, the shape System Settings ▸ Notifications has:
/// one pane holding a grouped roster of agents, each row carrying its mark, its
/// name and a status line, and each row pushing that agent's configuration onto the
/// settings window's own navigation stack. The earlier master–detail split gave the
/// window a third column no other tab had.
///
/// This tab is *what you use*: the enabled set, the order, the default agent and
/// the integration switches are preferences, and they have no machine dimension.
/// The values that do — where a CLI lives, whether it is there — are shown here
/// **once per machine**, never behind a machine picker.
///
/// A picker was tried and is the thing this shape exists to replace. It is a
/// mode: a control that changes what the rest of the page means, so the machine
/// has to be remembered rather than read, a mis-remembered one quietly configures
/// the wrong box, and the machines you are *not* looking at — the ones missing a
/// CLI — are exactly the ones it hides. It also does not generalise: every other
/// page touching a machine would need its own copy, and the phone would need one
/// too.
///
/// So machines are rows. A machine is chosen by navigation — Settings ▸ Server,
/// or a row in Settings ▸ Remote Hosts — and never by a control on a page about
/// something else. The property that makes this affordable everywhere: **a roster
/// of one renders exactly as this page did before there was more than one
/// machine** — no list, no labels, no bar. A picker with one option cannot do
/// that; it still costs a row.
struct AgentSettingsTab: View {
    @ObservedObject var settings: AppSettings
    /// The store the device roster and the readiness lines read from.
    @ObservedObject var store: TermioStore
    /// Opens the machine that can fix an integration gap — Server for this Mac,
    /// the host's pane under Remote Hosts otherwise. Injected because switching
    /// tabs is the settings window's own business, not this pane's.
    let onOpenMachine: (KnownDevice) -> Void

    /// Every machine Termio has worked on. The same roster Remote Hosts lists
    /// (plus this Mac), so a machine appears here the moment it is real and never
    /// before.
    private var devices: [KnownDevice] { DeviceRoster.known(in: store) }

    /// The machines this build's hooks and skill have not reached, one row each.
    /// Read from their device files off the main actor rather than in `body`,
    /// which would put N file reads in every redraw.
    @State private var behind: [IntegrationGap] = []

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
        // A grouped `Form`, like every other pane. It was a `List` because
        // `onMove` is only honoured by an editable list — in a `Form` the same
        // rows render and silently stop reordering, and agent order is what
        // the New Chat menu reads. That is a real constraint, so reordering
        // was rebuilt rather than dropped: rows are draggable onto each other,
        // and the context menu carries Move Up / Move Down, which works
        // whatever a drag does.
        Form {
            Section {
                DefaultChatAgentRow(settings: settings)
            } header: {
                SectionHeaderLabel(title: localized("New chat"))
            }

            Section {
                Toggle(isOn: $settings.agentHooksEnabled) {
                    SettingsLabel(
                        title: localized("Live agent status"),
                        subtext: localized("Shows when an agent is working or waiting on you — the sidebar spinner and menu-bar pulse."),
                        titleFont: .headline
                    )
                }
                .toggleStyle(.switch)
                Toggle(isOn: $settings.sessionControlEnabled) {
                    SettingsLabel(
                        title: localized("Session control"),
                        subtext: localized("Lets an agent see and drive its sibling sessions in this project via the `termio sessions` command."),
                        titleFont: .headline
                    )
                }
                .toggleStyle(.switch)
                // The machines that are not carrying what the switches ask for,
                // one row each, each opening the machine that can fix it.
                //
                // There was a button here that installed on every machine at
                // once, and it was the same operation's fourth caller: this Mac
                // reconciles itself whenever a switch moves
                // (`TermioStore.syncAgentIntegration`), and a remote box is
                // brought current by its own "Set Up" — so on a single Mac the
                // button re-did what flipping the switch had just done, and its
                // failure path sent the user to the machine's pane regardless. It
                // was also the only control that fired ssh at every configured
                // host on one click, which one sleeping VPS was enough to stall.
                //
                // What is left is the half a preference tab may honestly own: the
                // intent, and a report naming who is behind. Installing is a
                // machine operation and happens on the machine (RFC §D1).
                ForEach(behind) { machine in
                    Button { onOpenMachine(machine.device) } label: {
                        IntegrationGapRow(machine: machine)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                SectionHeaderLabel(title: localized("Integration"))
            } footer: {
                Text(behind.isEmpty
                    ? localized("Whether you want these at all. Termio puts them on each machine as you set it up.")
                    : localized("Open a machine to put them there."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $settings.notifyOnTaskCompletion) {
                    SettingsLabel(
                        title: localized("Task completion"),
                        subtext: localized("Posts a notification when an agent finishes or needs you while Termio is in the background."),
                        titleFont: .headline
                    )
                }
                .toggleStyle(.switch)
                if settings.notifyOnTaskCompletion {
                    Toggle(localized("Play sound"), isOn: $settings.notificationSoundEnabled)
                    NotificationPermissionRow()
                }
            } header: {
                SectionHeaderLabel(title: localized("Notifications"))
            } footer: {
                // The dependency, said once. A banner with the hooks off is a
                // switch that does nothing, and General — where this lived —
                // had no way to say so from another tab.
                Text(settings.notifyOnTaskCompletion && !settings.agentHooksEnabled
                    ? localized("Needs Live agent status above: without it, nothing tells Termio an agent finished.")
                    : localized("Termio notifies you about the agents above, wherever they run."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(listedAgents) { preset in
                    NavigationLink(value: AgentRoute(id: preset.id)) {
                        AgentListRow(settings: settings, preset: preset, devices: devices)
                    }
                    .draggable(preset.id)
                    .dropDestination(for: String.self) { ids, _ in
                        guard let dragged = ids.first else { return false }
                        return move(dragged, onto: preset)
                    }
                    .contextMenu {
                        Button(localized("Move Up")) { move(preset, by: -1) }
                            .disabled(listedAgents.first?.id == preset.id)
                        Button(localized("Move Down")) { move(preset, by: 1) }
                            .disabled(listedAgents.last?.id == preset.id)
                        Divider()
                        Button(localized("Remove from List")) { remove(preset) }
                    }
                }
                AddAgentGutter(
                    addable: addableAgents,
                    onAdd: add,
                    onCustom: createCustomAgent
                )
            } header: {
                SectionHeaderLabel(title: localized("Agents"))
            } footer: {
                // Only worth saying once there is more than one machine to cover.
                // On a roster of one the sentence would be true and pointless, and
                // this page's whole claim is that a single machine costs nothing.
                Text(devices.count > 1
                    ? localized("Drag an agent onto another to reorder. Readiness covers every machine you work on.")
                    : localized("Drag an agent onto another to reorder."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationDestination(for: AgentRoute.self) { route in
            detail(for: route.id)
        }
        .task(id: integrationKey) { await refreshIntegrationGap() }
        // Custom agents are edited in their manifest, in another app. Re-reading
        // the catalog when termio comes back to the front is what makes that land.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            AgentCatalog.reload()
            catalogVersion += 1
        }
    }

    // MARK: Integration

    /// Re-read whenever the roster or either switch changes: turning a switch on
    /// is exactly when "and it is not on `devbox` yet" becomes worth saying.
    private var integrationKey: String {
        "\(devices.map(\.settingsKey).joined(separator: "|"))"
            + "#\(settings.agentHooksEnabled)#\(settings.sessionControlEnabled)"
    }

    /// Which machines are not carrying what the switches ask for.
    ///
    /// This replaced a one-line sentence naming them ("Not installed on vps and
    /// devbox.") — the right information in a shape nobody could act on. The
    /// computation is unchanged and still off the main actor: this Mac's answer
    /// is a cached probe and every other machine is a file read, never the
    /// network, which is the only reason a preference tab may ask about N
    /// machines at all.
    ///
    /// Empty is the common case and renders nothing. With one Mac and a switch
    /// on, the files are already there — `syncAgentIntegration` put them there
    /// the instant the switch moved — so there is no row, no button, and no
    /// question with one answer.
    private func refreshIntegrationGap() async {
        guard settings.agentHooksEnabled || settings.sessionControlEnabled else {
            behind = []
            return
        }
        let roster = devices
        behind = await Task.detached(priority: .utility) {
            roster.compactMap { device -> IntegrationGap? in
                let state = DeviceStateCache.load(device.settingsKey)
                guard state?.carriesCurrentIntegration != true else { return nil }
                return IntegrationGap(device: device, state: state)
            }
        }.value
    }

    // MARK: Pushed pane


    @ViewBuilder
    private func detail(for id: String) -> some View {
        if let preset = listedAgents.first(where: { $0.id == id }) {
            AgentDetailPane(
                settings: settings,
                preset: preset,
                devices: devices,
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
            // The agent went away under us (a manifest deleted outside the app).
            MissingAgentPane()
        }
    }

    /// Adds the agent's row, then lets the availability probe decide the switch: an
    /// installed CLI turns it on; a missing one leaves it off, with the row saying
    /// so and its pane carrying the install link.
    private func add(_ preset: AgentPreset) {
        settings.addAgent(preset)
        Task { @MainActor in
            if await AgentAvailability.isCommandAvailable(settings.command(for: preset) ?? "") {
                settings.setAgent(preset, enabled: true)
            }
        }
    }

    private func remove(_ preset: AgentPreset) {
        settings.removeAgent(preset)
    }

    /// Seeds a starter manifest, puts it on the list, and opens the file — the
    /// manifest is the editor for a custom agent, so Settings' job ends at handing
    /// over a valid one. The row lands switched off (the placeholder command
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
        NSWorkspace.shared.open(created.file)
    }

    /// Deletes a user agent's manifest file (its sessions survive via the id-only
    /// fallback definition). Confirmation lives on the button in the pushed pane.
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
    /// other id ranked behind it so the ordering stays total. Returns false for a
    /// drag that changes nothing, so a row dropped on itself is not an edit.
    ///
    /// The arithmetic lives in `AgentOrdering`, where it can be tested.
    private func move(_ draggedID: String, onto target: AgentPreset) -> Bool {
        guard let moved = AgentOrdering.moving(
            draggedID, onto: target.id, in: listedAgents.map(\.id))
        else { return false }
        settings.setEnabledOrder(moved)
        return true
    }

    /// The keyboard- and menu-reachable half of reordering. Drag is the nice way;
    /// this is the way that cannot quietly stop working, which matters because
    /// the last container change is exactly what broke `onMove`.
    private func move(_ preset: AgentPreset, by offset: Int) {
        guard let moved = AgentOrdering.moving(
            preset.id, by: offset, in: listedAgents.map(\.id))
        else { return }
        settings.setEnabledOrder(moved)
    }
}

/// What a row pushes. A named type rather than the bare id string so the settings
/// window's shared navigation stack can't confuse an agent with some other pane's
/// string destination.
private struct AgentRoute: Hashable {
    let id: String
}

/// One machine that is not carrying this build's hooks and skill, and why —
/// which is the difference between "go install it" and "that box is asleep".
///
/// Distinguishing the two is why this is a type rather than a name: §D4's rule is
/// that a machine we could not reach must never be reported as missing something,
/// because that sends the user to reinstall what is already there.
struct IntegrationGap: Identifiable {
    let device: KnownDevice
    /// The machine's device file, or `nil` when it has never been asked.
    let state: DeviceDiscoveredState?

    var id: String { device.settingsKey }

    /// What the row says on its second line.
    var detail: String {
        guard let state else { return localized("Not set up yet") }
        return state.reachable ? localized("Not installed") : localized("Can’t check")
    }

    /// Only a machine that answered earns the warning tint. "We could not ask" is
    /// a fact about the machine, not a defect to flag.
    var isFault: Bool { state?.reachable ?? false }
}

/// A gap row: the machine, what is missing, and a chevron saying the fix is one
/// click away on the machine itself.
private struct IntegrationGapRow: View {
    let machine: IntegrationGap

    var body: some View {
        // No leading mark: there are at most a handful of these, the machine's
        // name is the whole point of the row, and a glyph that only says "this is
        // a machine" repeats what the name already said.
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.device.name)
                Text(machine.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// The roster's add and remove actions, in the list's own gutter (see
/// `SettingsListGutter`).
///
/// The roster's add action, in the list's own gutter (see `SettingsListGutter`).
///
/// A pull-down rather than a plain button: the agents worth adding are a known
/// list, and a sheet to pick one from it would be a window for a menu's worth of
/// choice.
private struct AddAgentGutter: View {
    let addable: [AgentPreset]
    let onAdd: (AgentPreset) -> Void
    let onCustom: () -> Void

    var body: some View {
        SettingsListGutter {
            Menu {
                // Plain text rows: AppKit menus rasterize custom SwiftUI icon
                // views at their natural image size, not the badge frame.
                ForEach(addable) { preset in
                    Button(preset.displayName) { onAdd(preset) }
                }
                if !addable.isEmpty { Divider() }
                Button(localized("Custom Agent…")) { onCustom() }
            } label: {
                SettingsGutterGlyph(symbol: "plus")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help(localized("Add Agent"))
            .accessibilityLabel(localized("Add Agent"))
        }
    }
}

/// One agent on the roster: brand mark, name, a second line, and the switch that
/// decides whether the agent is offered at all — the shape a Sharing row has, where
/// the on/off state is the thing you came to read and the row still opens onto the
/// details behind it.
///
/// The switch lived in the pushed pane, which made the roster's whole point — which
/// agents are on — a click deep per row, and cost the line a leading "Off ·" to say
/// what a switch says by being off. The second line is now only ever the command
/// the agent launches with, bypass flag and all, led by anything that blocks that
/// launch.
private struct AgentListRow: View {
    @ObservedObject var settings: AppSettings
    let preset: AgentPreset
    /// Every machine on the roster. The line answers for all of them at once:
    /// this row's subject is the agent, and *which machines it is missing on* is
    /// the part a line pinned to one machine could never say.
    let devices: [KnownDevice]

    /// `nil` while the probe is still running: show nothing rather than a
    /// premature warning.
    @State private var fleet: AgentFleetReadiness?

    /// Whether *this Mac* can launch it, which is what the switch is allowed to
    /// gate. The fleet answer is the wrong one for that: an agent installed here
    /// and missing on a sleeping VPS is still perfectly launchable, and a switch
    /// dimmed by a box you are not sitting at cannot be argued with.
    @State private var availableHere: Bool?

    /// Nothing to say about an agent present everywhere — the common case, where
    /// the line is the command alone.
    private var status: String? { fleet?.summary }

    /// This Mac's command. A machine with its own path shows it on its own row in
    /// the pushed pane; repeating four of them here would make the roster a table.
    private var detail: String {
        let command = settings.command(for: preset) ?? localized("Login shell")
        guard let status else { return command }
        return localized("\(status) · \(command)")
    }

    private var probeTargets: [(device: KnownDevice, command: String)] {
        devices.map { ($0, settings.command(for: preset, on: $0) ?? "") }
    }

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(preset.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.displayName)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            // Only a machine that answered earns the badge. `unknown` says so in
            // words instead: a warning glyph for "we could not ask" is the false
            // alarm.
            if fleet?.hasMissing == true {
                Image(systemName: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help(missingHelp)
            }
            Toggle(isOn: Binding(
                get: { settings.isAgentEnabled(preset) },
                set: { settings.setAgent(preset, enabled: $0) }
            )) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .labelsHidden()
            // A missing CLI can't be launched, so it can't be switched on — only
            // off (an already-on agent stays revocable while the badge shows).
            .disabled(availableHere == false && !settings.isAgentEnabled(preset))
            .help(localized("Offers \(preset.displayName) in the new-session menus."))
            .accessibilityLabel(localized("Enable \(preset.displayName)"))
        }
        // Re-probed when any machine's command changes, or when the roster does.
        .task(id: probeTargets.map { "\($0.device.settingsKey)=\($0.command)" }
            .joined(separator: "|")) {
            fleet = await AgentReadiness.acrossFleet(agent: preset, on: probeTargets)
        }
        .task(id: settings.command(for: preset) ?? "") {
            availableHere = await AgentAvailability.isCommandAvailable(
                settings.command(for: preset) ?? "")
        }
    }

    /// The tooltip names the machines even when the caption had to count them —
    /// a hover is where "which two?" gets answered without leaving the roster.
    private var missingHelp: String {
        let names = InstallOutcome.list(fleet?.missing ?? [], unit: localized("machines"))
        return localized("\(preset.displayName) isn’t installed on \(names)")
    }
}

/// The pushed pane for one agent: an identity header above a grouped form — the
/// enable switch, command override, install link when the CLI is missing, the
/// permission-bypass switch, and removal.
private struct AgentDetailPane: View {
    @ObservedObject var settings: AppSettings
    let preset: AgentPreset
    /// Every machine on the roster, one row apiece in the Launch section. Where a
    /// CLI lives is a fact about a machine — so the pane names all of them rather
    /// than making you choose one and then remember which you chose.
    let devices: [KnownDevice]
    let onRemove: () -> Void
    /// True for agents backed by a manifest in the user's config folder — the only
    /// ones whose file can be opened or deleted from here.
    var isUserDefined = false
    /// Set only for user-manifest agents: deletes the manifest file.
    var onDelete: (() -> Void)?

    @State private var confirmingDelete = false
    /// Removing or deleting takes the row away, so the pane it opened has to go
    /// back with it.
    @Environment(\.dismiss) private var dismiss

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
                ForEach(devices) { device in
                    CommandPathRow(
                        settings: settings, preset: preset, device: device,
                        namesItsMachine: devices.count > 1)
                }
                LabeledContent {
                    TextField(
                        "",
                        text: Binding(
                            get: { settings.arguments(for: preset) ?? "" },
                            set: { settings.setArguments($0, for: preset) }
                        ),
                        prompt: Text(localized("None"))
                    )
                    .multilineTextAlignment(.trailing)
                    .labelsHidden()
                    .frame(minWidth: 180)
                } label: {
                    SettingsLabel(
                        title: localized("Arguments"),
                        subtext: localized("Passed to \(preset.displayName) every time a session starts."),
                        titleFont: .headline
                    )
                }
                LabeledContent {
                    if let url = preset.installURL {
                        Link(localized("Install Page"), destination: url)
                    } else {
                        Text(localized("None")).foregroundStyle(.secondary)
                    }
                } label: {
                    SettingsLabel(
                        title: localized("Get \(preset.displayName)"),
                        subtext: localized("The install page — the same one whichever machine you are installing on."),
                        titleFont: .headline
                    )
                }
            } header: {
                SectionHeaderLabel(title: localized("Launch"))
            } footer: {
                // Said once under the rows rather than repeated in every row's
                // subtext, which is where the readiness word goes once there is
                // more than one machine to report on.
                if devices.count > 1 {
                    Text(localized("Where each machine launches \(preset.displayName) from. Leave empty to use its default."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                    Button(localized("Remove")) {
                        onRemove()
                        dismiss()
                    }
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
                                Button(localized("Delete"), role: .destructive) {
                                    onDelete()
                                    dismiss()
                                }
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
        .navigationTitle(preset.displayName)
    }
}

/// One machine's command path for this agent.
///
/// A row per machine rather than one field behind a machine picker. The picker
/// changed what the field below it meant, so the machine had to be remembered
/// rather than read — and the machines you were not looking at, the ones missing
/// the CLI, were exactly the ones worth seeing. Rows have neither problem, and
/// they cost a single-machine user nothing, which is what lets them be the
/// default rather than a mode you switch into.
private struct CommandPathRow: View {
    @ObservedObject var settings: AppSettings
    let preset: AgentPreset
    let device: KnownDevice
    /// False on a roster of one, where naming the only machine there is carries
    /// no information: the row reverts to the plain `Path` field this pane has
    /// always had, with its original subtext.
    let namesItsMachine: Bool

    /// `nil` until the passive answer lands — a file read for a device, a cached
    /// `PATH` lookup for this Mac, so it is a frame, not a wait.
    @State private var readiness: AgentReadiness?

    var body: some View {
        LabeledContent {
            TextField(
                "",
                text: Binding(
                    get: { settings.commandPath(for: preset, on: device) ?? "" },
                    set: { settings.setCommandPath($0, for: preset, on: device) }
                ),
                prompt: Text(preset.command ?? localized("Login shell"))
            )
            .multilineTextAlignment(.trailing)
            .labelsHidden()
            .frame(minWidth: 180)
        } label: {
            SettingsLabel(title: title, subtext: subtext, titleFont: .headline)
        }
        // Keyed on the path so a corrected one re-reads without leaving the pane.
        // Passive by construction: probing live here would fire an `ssh` per
        // keystroke at every machine on the roster.
        .task(id: "\(device.settingsKey)#\(settings.command(for: preset, on: device) ?? "")") {
            readiness = await AgentReadiness.passive(
                agent: preset,
                command: settings.command(for: preset, on: device) ?? "",
                on: device)
        }
    }

    private var title: String {
        namesItsMachine ? device.name : localized("Path")
    }

    /// The machine's answer, always present rather than shown only when something
    /// is wrong: a caption that appears and disappears makes every row jump as the
    /// probes land.
    private var subtext: String {
        guard namesItsMachine else {
            return localized("Where \(preset.displayName) launches from on \(device.name). Leave empty to use its default.")
        }
        switch readiness {
        case .available: return localized("Installed")
        case .missing: return localized("Not installed")
        case .unknown: return localized("Can’t check")
        case nil: return localized("Checking…")
        }
    }
}

/// Shown when the pushed agent stops existing while its pane is open — a custom
/// agent's manifest deleted in Finder, say. Says so and leaves the back chevron to
/// carry the user out; popping from here would fight the pop the deleting button
/// already asked for.
private struct MissingAgentPane: View {
    var body: some View {
        ContentUnavailableView {
            Text(localized("Agent Unavailable"))
        } description: {
            Text(localized("This agent is no longer on your list."))
        }
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
            Text(localized("Last used")).tag(lastUsedTag)
            ForEach(chatAgents) { Text($0.displayName).tag($0.id) }
        } label: {
            SettingsLabel(
                title: localized("Default agent"),
                subtext: localized("The agent New Chat (⌘N) starts. “Last used” follows whichever agent you most recently chatted with."),
                titleFont: .headline
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

/// Surfaces the macOS-side notification authorization under the toggle. An app
/// cannot grant itself notification permission — only the system prompt or
/// System Settings can — so this row offers whichever of the two applies:
/// "Request Permission" while macOS has never been asked, a System Settings
/// deep link once the user has denied. Silent when already authorized (or when
/// running unbundled, where the framework is untouchable). Re-audits whenever
/// the app comes back to front, so returning from System Settings updates it.
private struct NotificationPermissionRow: View {
    @State private var status: UNAuthorizationStatus?

    var body: some View {
        Group {
            switch status {
            case .notDetermined:
                HStack(spacing: 10) {
                    Text(localized("macOS hasn’t been asked to allow Termio’s notifications yet."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(localized("Request Permission")) {
                        Task {
                            _ = await TaskNotificationCenter.requestPermission()
                            status = await TaskNotificationCenter.authorizationStatus()
                        }
                    }
                }
            case .denied:
                HStack(spacing: 10) {
                    Text(localized("Notifications for Termio are turned off in System Settings."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(localized("Open System Settings")) {
                        let id = Bundle.main.bundleIdentifier ?? ""
                        if let url = URL(string:
                            "x-apple.systempreferences:com.apple.preference.notifications?id=\(id)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            default:
                EmptyView()
            }
        }
        .task { status = await TaskNotificationCenter.authorizationStatus() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { status = await TaskNotificationCenter.authorizationStatus() }
        }
    }
}
