import AppKit
import SwiftUI

/// One machine's pane: the outcome line, how it is reached, and what it runs.
///
/// The section order is the D2 decision made visible. *Reached by* is the route —
/// the `~/.ssh/config` half the old Devices tab was entirely made of. *Runs* is
/// the identity — what is installed on that box, which had nowhere to live
/// before. A machine is both, and reading them in that order is how someone
/// works out why a box is not ready: you cannot install anything on a machine you
/// cannot reach.
///
/// Above both sits D6's single line. Deploy `termiod` → probe agent CLIs →
/// install hooks and skill is a real dependency chain, and a wrong primary UI:
/// four rungs with independent states turn choosing a machine into infrastructure
/// triage. So the pane promises one outcome — "Ready", or "Set up this device" —
/// and the rungs are the disclosure underneath it.
struct DevicePane: View {
    let machine: KnownDevice
    let host: SSHConfigHost?
    @ObservedObject var settings: AppSettings
    /// The key an install would put on this host, or `nil` when there is none to
    /// send — which decides whether the password advice can offer a fix.
    let keyToInstall: SSHPublicKey?
    let onConnect: (String) -> Void
    let onSetUpKey: (String, String) -> Void
    let onEditConfig: () -> Void
    /// Whether a session has run here, which is when a phone has something to
    /// attach to. An alias from `~/.ssh/config` alone may have no `termiod`, and
    /// publishing one would start a tunnel to nothing.
    let pairsPhones: Bool

    @StateObject private var model: DevicePaneModel
    private enum ProbeState { case idle, running, result(SSHProbeResult) }
    @State private var probe: ProbeState = .idle
    @State private var confirmUnpair = false
    @State private var unpairFailed = false

    init(
        machine: KnownDevice,
        host: SSHConfigHost?,
        settings: AppSettings,
        keyToInstall: SSHPublicKey?,
        onConnect: @escaping (String) -> Void,
        onSetUpKey: @escaping (String, String) -> Void,
        onEditConfig: @escaping () -> Void,
        pairsPhones: Bool
    ) {
        self.machine = machine
        self.host = host
        self.settings = settings
        self.keyToInstall = keyToInstall
        self.onConnect = onConnect
        self.onSetUpKey = onSetUpKey
        self.onEditConfig = onEditConfig
        self.pairsPhones = pairsPhones
        _model = StateObject(wrappedValue: DevicePaneModel(device: machine, settings: settings))
    }

    @ObservedObject private var pairing = PairingModel.shared

    var body: some View {
        Form {
            Section { hero }
            reachedBySection
            serverSection
            // Only for a box. This Mac's answer to "which agent CLIs are here,
            // where do they launch from, what did Termio write into them" is
            // already on Settings ▸ Agents — every row's subtext is
            // `<readiness> · <command>`, each agent's Launch section carries the
            // path, and the Integration switches install the hooks and the skill
            // here without leaving the page. A link to a transposed copy of that
            // is a second editor for one matrix (`setCommandPath(_:for:on:)`),
            // which is how the two panes drift.
            //
            // A box is the opposite case: nothing there is known until it is
            // probed, the probe answers for the whole machine at once, and
            // installing on it can fail in ways only its own pane can report —
            // so "what does *this box* have" stays a page of its own.
            if !machine.isLocal { agentsSection }
            commandLineSection
            // A phone attaches to a port the machine serves, so pairing is a fact
            // about the machine and sits in its pane. This Mac's card drives the
            // companion port here; a box's card mints its invite over SSH.
            if machine.isLocal {
                DeviceServingSection()
            } else if pairsPhones {
                RemotePairingSection(machine: machine)
            }
        }
        .formStyle(.grouped)
        .navigationDestination(for: MachineAgentsRoute.self) { _ in
            MachineAgentsPane(machine: machine, settings: settings, model: model)
        }
        // On the Form, not the Pairing section: the section is the last row of a
        // lazy list, and the menu bar's Pair iPhone… must open the sheet before
        // anyone has scrolled to it. Only this Mac's pane presents it.
        .sheet(isPresented: machine.isLocal ? $pairing.showsSheet : .constant(false)) {
            PairingSheet()
        }
    }

    // MARK: D6 — one outcome

    /// The machine, its state and the one thing to do about it, in the card the
    /// page opens on. They were two cards — a name with a line that said nothing
    /// ("The machine Termio is running on") and a Status section below it — so
    /// the first thing on the page was the least informative and the state sat a
    /// header further down.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // One glyph for both entrances, and no branch: what this pane is
                // about is the machine's termiod, which this Mac runs as much as
                // a VPS does. On the sidebar's glass tile, at hero size.
                HugeIconView(icon: .serverStack, size: 18, color: .primary)
                    .frame(width: 34, height: 34)
                    .background(GlassTile(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(machine.name)
                        .font(.body.weight(.semibold))
                    Text(statusLine)
                        .font(.settingsDetail)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                action
                if let alias = machine.alias {
                    Button(localized("Connect")) { onConnect(alias) }
                }
            }
            // The sentence under the state is only worth a line when it says
            // something the state does not: why a machine is blocked, what an
            // update waits on, or that Ready has no agent to run.
            if model.readiness != .ready || !model.hasAgentAvailable {
                Text(outcomeSubtext)
                    .font(.settingsDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let feedback = model.feedback {
                InstallFeedbackLabel(feedback: feedback)
            }
        }
        .padding(.vertical, 2)
        .task {
            // Asked when the pane opens, not when the roster draws: one machine,
            // because someone is looking at it.
            //
            // Asked *every* time it opens, cache or no cache. The file seeds the
            // first frame so the pane is never blank, but it cannot report a
            // machine whose daemon has stopped answering since it was written —
            // it would read Ready beside a box that cannot run anything, and the
            // only button offered would be Check Again. The cache draws; the
            // probe decides.
            await model.check()
        }
    }

    /// The state, and for a box the address it is reached at, which used to be
    /// the header's whole second line.
    private var statusLine: String {
        guard !machine.isLocal else { return outcomeTitle }
        return "\(outcomeTitle) · \(host?.destinationLabel ?? localized("Reached over SSH"))"
    }

    @ViewBuilder
    private var action: some View {
        if model.readiness.isBusy {
            ProgressView().controlSize(.small)
        } else if case .ready = model.readiness {
            Button(localized("Check Again")) { Task { await model.check() } }
        } else if case .staged = model.readiness {
            // The work holding the old daemon up is named right beside this, so
            // the choice is informed; the daemon otherwise takes the update the
            // next time it stops on its own.
            Button(localized("Update Anyway")) { Task { await model.setUp(force: true) } }
        } else {
            Button(localized("Set Up \(machine.name)")) { Task { await model.setUp() } }
        }
    }

    private var outcomeTitle: String {
        switch model.readiness {
        case .ready: return localized("Ready")
        case .checking: return model.step?.label ?? localized("Checking…")
        case .staged: return localized("Update ready")
        // Named, because the pane is reached two ways now and "this device"
        // reads as a stray when the tab above it says Server.
        case .blocked, .unasked:
            return machine.isLocal
                ? localized("Set up this Mac")
                : localized("Set up this host")
        }
    }

    private var outcomeSubtext: String {
        switch model.readiness {
        case .ready:
            // Ready is about Termio's own setup, which is why a machine with no
            // agent on it still earns the word — `termiod` is there and its hooks
            // are current. What it must not do is promise agents that are not
            // there, so the sentence says what is true and where the next step is.
            // Connect, at the top of this pane, is that step: installing an agent
            // is done on the machine, each with its own installer.
            guard model.hasAgentAvailable else {
                return localized("No agent CLIs on \(machine.name) yet. Install one there and it shows up here.")
            }
            // Only promise the reporting when it was actually asked for: with both
            // integration switches off, setup deliberately installs nothing, and
            // "reports their status back here" would be a claim about hooks that
            // are not there.
            return reportsStatus
                ? localized("Agents on \(machine.name) can run, and report their status back here.")
                : localized("Agents on \(machine.name) can run.")
        case .checking:
            return localized("Asking \(machine.name) what it has.")
        case .blocked(let reason), .staged(let reason):
            // Only the first blocking rung, by design: a machine with no `termiod`
            // also has no hooks, and naming both invites fixing the consequence.
            return reason
        case .unasked:
            // An agent that arrived after the last setup is a different sentence
            // from a machine nobody has set up yet: the work is the same button,
            // but "deploys termiod" describes none of what is actually left, and
            // the agent that has no hooks is the whole reason to press it.
            let waiting = model.agentsAwaitingIntegration
            if !waiting.isEmpty {
                return localized("\(InstallOutcome.list(waiting, unit: localized("agents"))) arrived on \(machine.name) since the last setup. Set up again to install Termio’s hooks there.")
            }
            return machine.isLocal
                ? localized("Installs the `\(CommandLineTool.toolName)` command-line tool, then Termio’s hooks and skill for each agent.")
                : localized("Deploys `termiod`, looks for your agent CLIs, then installs Termio’s hooks and skill.")
        }
    }

    /// Whether anything on this machine is meant to report status — the two
    /// switches live on the Agents tab, because wanting the feature is a
    /// preference and installing it is a machine operation (RFC §D1).
    private var reportsStatus: Bool {
        settings.agentHooksEnabled || settings.sessionControlEnabled
    }

    // MARK: Reached by — the route half

    /// Absent on this Mac rather than filled with a placeholder. The old pane
    /// stood one machine list in front of both, so every section had to render
    /// for both and the local branch printed "nothing to reach" — a card whose
    /// only content was that it did not apply. Server and Remote Hosts are
    /// separate entrances now, so a section that cannot apply simply is not
    /// there.
    @ViewBuilder
    private var reachedBySection: some View {
        if case .paired(let hostID) = machine.route {
            pairedSection(hostID: hostID)
        } else if !machine.isLocal {
            Section {
                LabeledContent {
                    probeControl
                } label: {
                    SettingsLabel(
                        title: host?.destinationLabel ?? machine.name,
                        subtext: host?.identityFile.map { localized("Signs in with \($0)") }
                            ?? localized("Signs in with the keys ssh offers by default.")
                    )
                }
                if case .result(.wantsPassword) = probe { passwordAdvice }
                LabeledContent {
                    Button(localized("Edit"), action: onEditConfig)
                } label: {
                    SettingsLabel(
                        title: localized("Host block"),
                        subtext: localized("Opens the ~/.ssh/config entry this machine is defined in.")
                    )
                }
            } header: {
                SectionHeaderLabel(title: localized("Reached by"))
            }
        }
    }

    /// A paired Mac is reached by its address and a token, not by a host block,
    /// so its road is that address and the one thing to do about it is unpair.
    private func pairedSection(hostID: String) -> some View {
        Section {
            LabeledContent {
                Button(localized("Unpair…")) { confirmUnpair = true }
                    .confirmationDialog(
                        localized("Unpair \(machine.name)?"),
                        isPresented: $confirmUnpair,
                        titleVisibility: .visible
                    ) {
                        Button(localized("Unpair"), role: .destructive) {
                            // Announced only once the keychain has let go: links
                            // would otherwise redial with the record still there.
                            unpairFailed = !PairedDeviceStore.remove(hostID: hostID)
                            guard !unpairFailed else { return }
                            NotificationCenter.default.post(
                                name: PairedDeviceStore.didChange, object: nil,
                                userInfo: [PairedDeviceStore.unpairedHostIDKey: hostID])
                        }
                        Button(localized("Cancel"), role: .cancel) {}
                    } message: {
                        Text(localized("Its sessions keep running there. To reach it again, copy a new link from its Pairing sheet."))
                    }
            } label: {
                SettingsLabel(
                    title: PairedDeviceStore.device(hostID: hostID)?.url ?? machine.name,
                    subtext: localized("Paired over the network. Its Termio must be open with Allow Paired Devices and Direct Attach on.")
                )
            }
            if unpairFailed {
                Text(localized("Couldn’t remove the pairing from the keychain. Open Keychain Access, unlock the login keychain, and try again."))
                    .font(.settingsDetail)
                    .foregroundStyle(.red)
            }
        } header: {
            SectionHeaderLabel(title: localized("Reached by"))
        }
    }

    // MARK: Termio server — the daemon that holds the sessions

    /// Read-only, on both entrances. Putting the daemon there and moving it
    /// forward is what *Set Up* does, and a second button for the same loop was
    /// the same action under two verbs.
    ///
    /// This Mac used to have no such row at all: the integration card spent the
    /// local branch on the CLI, so the one daemon the user could actually see
    /// running was the only one whose version the app never showed.
    private var serverSection: some View {
        Section {
            SettingsLabel(title: "termiod", subtext: serverSubtext)
        } header: {
            SectionHeaderLabel(title: localized("Termio server"))
        }
    }

    private var serverSubtext: String {
        if let version = model.discovered?.termiodVersion {
            return localized(
                "Version \(version) on \(machine.name). Sessions keep running there after you disconnect.")
        }
        return machine.isLocal
            ? localized("Not running yet. Sessions start it, and keep running after you quit Termio.")
            : localized("The session host on \(machine.name). Sessions keep running there after you disconnect.")
    }

    /// The one probe outcome with a fix worth offering in place. A password is a
    /// dead end for everything but the plain shell — the daemon connections that
    /// carry sessions and the file tree set `BatchMode=yes` and can never answer a
    /// prompt — so the row says that plainly and offers the install that ends it.
    @ViewBuilder
    private var passwordAdvice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(keyToInstall == nil
                 ? localized("This host takes a password. Termio signs in with keys, and ~/.ssh has none that ssh offers on its own — run ssh-keygen to make one, then set it up here.")
                 : localized("This host takes a password. Termio signs in with keys, so set yours up once and every session, file tree and remote terminal can reach it."))
                .font(.settingsDetail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let keyToInstall, let alias = machine.alias {
                Button(localized("Set Up Key…")) { onSetUpKey(alias, keyToInstall.url.path) }
                    .buttonStyle(.bordered)
                    .help(localized("Runs ssh-copy-id with \(keyToInstall.name) in a terminal — the host asks for your password once, there."))
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var probeControl: some View {
        switch probe {
        case .idle:
            Button(localized("Test"), action: runProbe)
        case .running:
            ProgressView()
                .controlSize(.small)
                .frame(minWidth: 44)
        case .result(let outcome):
            Button(action: runProbe) {
                Text(outcome.label)
                    .foregroundStyle(outcome.tint)
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .help(localized("\(outcome.detail) — click to re-test"))
        }
    }

    private func runProbe() {
        guard let alias = machine.alias else { return }
        probe = .running
        Task { @MainActor in
            probe = .result(await SSHConfigFile.testConnection(alias: alias))
        }
    }

    // MARK: The ladder, as disclosure

    // MARK: Agents — this machine's half of the agent question

    /// A link, not a list: the roster on Settings ▸ Agents answers "which agents
    /// do I use", and this answers "what does *this box* have" — the same
    /// question from the other axis, which is a page of its own rather than four
    /// more rows on a pane that is already five sections deep.
    ///
    /// This used to be a sentence in the section below telling the user to go to
    /// another tab and re-find this machine there. Naming the destination is not
    /// the same as going there.
    private var agentsSection: some View {
        Section {
            NavigationLink(value: MachineAgentsRoute(key: machine.settingsKey)) {
                SettingsLabel(
                    title: agentsSummary,
                    subtext: localized("Which agent CLIs are on \(machine.name), where each launches from, and what Termio installed into their configs.")
                )
            }
        } header: {
            SectionHeaderLabel(title: localized("Agents"))
        }
    }

    /// The headline the link carries: the bad news if there is any, the count
    /// otherwise. A machine nobody has asked about yet says so rather than
    /// reporting zero of anything.
    private var agentsSummary: String {
        guard model.discovered != nil else { return localized("Not checked yet") }
        let states = model.listedAgents.map { model.readiness(for: $0) }
        let missing = states.filter { $0 == .missing }.count
        if missing > 0 { return localized("\(missing) not installed") }
        let available = states.filter { $0 == .available }.count
        guard available > 0 else { return localized("None found") }
        return localized("\(available) installed")
    }

    // MARK: Command line — this Mac's own foundation rung

    /// The `termio` CLI, on this Mac only: there is no CLI to link onto a box the
    /// user never types into directly.
    ///
    /// Its own section now that the hooks and the skill have left. Those three
    /// shared a card called "Installed by Termio", which was true of all of them
    /// and useful about none: the CLI is a binary on *your* PATH that you run,
    /// and the other two are files written into each agent's config. Only the
    /// second pair is about agents, so only the second pair moved.
    @ViewBuilder
    private var commandLineSection: some View {
        if machine.isLocal {
            Section {
                CommandLineToolRow()
            } header: {
                SectionHeaderLabel(title: localized("Command line"))
            }
        }
    }
}

/// Installs and reports the `termio` command-line tool on **this Mac**.
///
/// It moved off the General tab because installing a CLI on a machine is a
/// machine operation (RFC §D8) — here it sits beside "deploy `termiod`", which is
/// the same rung on every other machine's pane.
///
/// Installs and reports the `termio` command-line tool, as a switch like the other
/// feature rows: on means the PATH symlink exists, off removes it. The switch is
/// bound to the audit, not a stored preference, so it always reflects reality (a
/// declined admin prompt snaps it back). It audits on appear (a moved app shows
/// "Update") and re-audits after every action so the caption updates in place.
struct CommandLineToolRow: View {
    @State private var status: CommandLineTool.Status = .notInstalled
    @State private var state = InstallFeedbackState()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { isOn }, set: { setEnabled($0) })) {
                SettingsLabel(
                    title: localized("Command-line tool"), subtext: description)
            }
            .toggleStyle(.switch)
            .disabled(!isSwitchable)
            if let feedback = state.feedback {
                InstallFeedbackLabel(feedback: feedback)
            }
        }
        .onAppear { status = CommandLineTool.audit() }
        .autoDismissing($state)
        if isOn {
            // For re-linking after something else has touched /usr/local/bin;
            // install is idempotent. Reports through its own feedback line.
            InstallButtonRow(title: buttonTitle) { runInstall() }
        }
    }

    private var isOn: Bool {
        switch status {
        case .installed, .stale: return true
        case .notInstalled, .conflict, .unavailable: return false
        }
    }

    /// A conflicting file isn't ours to remove and a bare binary has nothing to
    /// link, so in both states the switch is disabled and the caption explains.
    private var isSwitchable: Bool {
        switch status {
        case .installed, .stale, .notInstalled: return true
        case .conflict, .unavailable: return false
        }
    }

    private func setEnabled(_ enabled: Bool) {
        withAnimation {
            if enabled {
                state.show(runInstall())
            } else {
                status = CommandLineTool.uninstall()
                state.show(isOn
                    ? .failure(localized("Couldn’t remove \(CommandLineTool.installURL.path)."))
                    : .success(localized("Removed from PATH.")))
            }
        }
    }

    /// Installs, then reports the fresh audit. The caption alone can't carry this:
    /// a declined admin prompt leaves the row reading exactly as it did before the
    /// click, so success and cancellation would be indistinguishable. The
    /// confirmation stays short — the caption above it already names the path — and
    /// echoes the verb that was offered: an "Update" that lands says "Updated."
    private func runInstall() -> InstallFeedback {
        let wasStale: Bool
        if case .stale = status { wasStale = true } else { wasStale = false }
        let result = CommandLineTool.install()
        status = result
        switch result {
        case .installed:
            return .success(wasStale ? localized("Updated.") : localized("Installed."))
        case .conflict:
            return .failure(localized("Something else already owns \(CommandLineTool.installURL.path)."))
        case .unavailable:
            return .failure(localized("No bundled tool to install from."))
        case .notInstalled, .stale:
            let directory = CommandLineTool.installURL.deletingLastPathComponent().path
            return .failure(localized("Couldn’t link `\(CommandLineTool.toolName)` into \(directory)."))
        }
    }

    private var description: String {
        let tool = CommandLineTool.toolName
        switch status {
        case .installed:
            return localized("`\(tool)` is on your PATH. Run `\(tool) sessions …` to drive sibling sessions, or `\(tool) .` to open a folder.")
        case .stale(let path):
            return localized("An older install points at \(path). Update it to this version of Termio.")
        case .notInstalled:
            return localized("Links `\(tool)` into /usr/local/bin so you (and agents) can run `\(tool) sessions …` from any shell.")
        case .conflict:
            return localized("A different `\(tool)` already exists at \(CommandLineTool.installURL.path). Remove it first — Termio won’t overwrite a file it didn’t create.")
        case .unavailable:
            return localized("Available when Termio runs from the built app bundle.")
        }
    }

    private var buttonTitle: String {
        if case .stale = status { return localized("Update") }
        return localized("Reinstall")
    }
}

/// What the machine pane's Agents row pushes. A named type so the settings
/// window's shared stack cannot confuse it with a machine or an agent.
struct MachineAgentsRoute: Hashable {
    let key: String
}

/// One machine's agents: which CLIs are on it, and where each one launches from.
///
/// The same two facts Settings ▸ Agents shows, turned ninety degrees. That tab
/// holds the agent fixed and walks the machines, because the task it serves is
/// "get Claude running everywhere". This page holds the *machine* fixed and walks
/// the agents, because the task it serves is "I just added this box — what can it
/// run?". Neither is the other's duplicate, and both read the same stored value
/// (`AppSettings.commandPath(for:on:)`), so an edit here shows up there.
///
/// Readiness comes from the pane's own probe rather than a fresh one: this page
/// is reached *from* the machine's pane, which has already asked.
private struct MachineAgentsPane: View {
    let machine: KnownDevice
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: DevicePaneModel

    var body: some View {
        Form {
            Section {
                ForEach(model.listedAgents) { preset in
                    LabeledContent {
                        TextField(
                            "",
                            text: Binding(
                                get: { settings.commandPath(for: preset, on: machine) ?? "" },
                                set: { settings.setCommandPath($0, for: preset, on: machine) }
                            ),
                            prompt: Text(preset.command ?? localized("Login shell"))
                        )
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                        .frame(minWidth: 180)
                    } label: {
                        SettingsLabel(
                            title: preset.displayName,
                            subtext: detail(for: preset)
                        )
                    }
                }
            } header: {
                SectionHeaderLabel(title: localized("Command paths"))
            } footer: {
                Text(localized("Leave a path empty to launch the agent the way \(machine.name)’s login shell would. Which agents appear at all is Settings ▸ Agents."))
                    .font(.settingsDetail)
                    .foregroundStyle(.secondary)
            }

            // Hooks and the skill are files written **into each agent's own
            // config directory**, so this is the page they belong on: the one
            // about agents on this machine. They sat on the machine's pane in a
            // card called "Installed by Termio", a section header that named the
            // author rather than the subject, one level above the agents they are
            // written for.
            //
            // They stay machine-level rows rather than a column on the list
            // above, because that is the truth of what is stored: one stamp per
            // machine (`DeviceDiscoveredState.integrationVersion`), written when
            // the daemon writes both halves for every agent in one pass. A tick
            // per agent row would be a claim the data cannot support.
            Section {
                SettingsLabel(
                    title: localized("Hooks"),
                    subtext: settings.agentHooksEnabled
                        ? localized("Report each agent’s status back to Termio.")
                        : localized("Turned off in Settings ▸ Agents, so Termio removes them from \(machine.name).")
                )
                SettingsLabel(
                    title: localized("Skill"),
                    subtext: settings.sessionControlEnabled
                        ? localized("Teaches agents the termio session commands.")
                        : localized("Turned off in Settings ▸ Agents, so Termio removes it from \(machine.name).")
                )
                // Named, not a bare "Reinstall": one button serves both rows above
                // it, but sitting last it reads as the Skill row's own — leaving
                // Hooks looking like the one thing here with no way to repair it.
                InstallButtonRow(title: localized("Reinstall Hooks and Skill")) {
                    await reinstallIntegration()
                }
            } header: {
                SectionHeaderLabel(title: localized("Installed by Termio"))
            } footer: {
                Text(localized("What Termio writes into each agent’s config on \(machine.name) so it can report. Reinstall after hand-editing one."))
                    .font(.settingsDetail)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(localized("Agents on \(machine.name)"))
    }

    /// Writes both halves as the switches ask, then stamps the machine when the
    /// write was clean — the stamp is what "Not installed on \(machine.name)"
    /// reads on the Agents tab, so a repair that does not clear it leaves the
    /// user chasing a warning they have already answered.
    ///
    /// **One Reinstall, not one per half.** Each half used to carry its own
    /// button passing `.leave` for the other, and neither touched the stamp. The
    /// daemon writes both halves in one pass anyway
    /// (`AgentIntegrationInstaller.sync` takes the pair), so two buttons were two
    /// names for one write, and only the one that does what both switches say can
    /// honestly claim the machine is current.
    private func reinstallIntegration() async -> InstallFeedback {
        // Captured once: Settings stays editable while the install is in flight,
        // and the stamp has to probe what the install was actually given.
        let commands = model.commandPairs
        let outcome = await AgentIntegrationInstaller.sync(
            hooks: settings.agentHooksEnabled ? .install : .remove,
            skills: settings.sessionControlEnabled ? .install : .remove,
            target: machine.integrationTarget,
            commands: Dictionary(commands.map { ($0.id, $0.command) }) { first, _ in first })
        if outcome.failure == nil && outcome.failed.isEmpty {
            model.stampIntegration(outcome)
        }
        return .summarizing(
            outcome, headline: localized("Reinstalled"), unit: localized("agents"))
    }

    /// The machine's answer under each name. Always present rather than shown
    /// only when something is wrong: a caption that appears and disappears makes
    /// every row jump as answers land.
    private func detail(for preset: AgentPreset) -> String {
        switch model.readiness(for: preset) {
        case .available: return localized("Installed")
        case .missing: return localized("Not installed")
        case .unknown: return localized("Can’t check")
        }
    }
}
