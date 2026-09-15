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

    @StateObject private var model: DevicePaneModel
    private enum ProbeState { case idle, running, result(SSHProbeResult) }
    @State private var probe: ProbeState = .idle

    init(
        machine: KnownDevice,
        host: SSHConfigHost?,
        settings: AppSettings,
        keyToInstall: SSHPublicKey?,
        onConnect: @escaping (String) -> Void,
        onSetUpKey: @escaping (String, String) -> Void,
        onEditConfig: @escaping () -> Void
    ) {
        self.machine = machine
        self.host = host
        self.settings = settings
        self.keyToInstall = keyToInstall
        self.onConnect = onConnect
        self.onSetUpKey = onSetUpKey
        self.onEditConfig = onEditConfig
        _model = StateObject(wrappedValue: DevicePaneModel(device: machine, settings: settings))
    }

    var body: some View {
        Form {
            Section { header }
            Section { outcome } header: {
                SectionHeaderLabel(title: localized("Status"))
            }
            reachedBySection
            serverSection
            agentsSection
            integrationSection
            // What a machine serves to phones is Settings ▸ Mobile, not a second
            // copy here: one set of controls, one place they live.
        }
        .formStyle(.grouped)
        .navigationDestination(for: MachineAgentsRoute.self) { _ in
            MachineAgentsPane(machine: machine, settings: settings, model: model)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            // One glyph for both entrances, and no branch: what this pane is
            // about is the machine's termiod, which this Mac runs as much as a
            // VPS does. Line ink rather than a filled accent square — the
            // accent colour is reserved for controls, and a hero mark is not one.
            HugeIconView(icon: .serverStack, size: 22, color: .secondary)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name)
                    .font(.title3.weight(.semibold))
                Text(machine.isLocal
                     ? localized("The machine Termio is running on")
                     : host?.destinationLabel ?? localized("Reached over SSH"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let alias = machine.alias {
                Spacer(minLength: 8)
                Button(localized("Connect")) { onConnect(alias) }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: D6 — one outcome

    @ViewBuilder
    private var outcome: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SettingsLabel(title: outcomeTitle, subtext: outcomeSubtext, titleFont: .headline)
                Spacer(minLength: 8)
                if model.readiness.isBusy {
                    ProgressView().controlSize(.small)
                } else if case .ready = model.readiness {
                    Button(localized("Check Again")) { Task { await model.check() } }
                } else if case .staged = model.readiness {
                    // The work holding the old daemon up is named right beside
                    // this, so the choice is informed; the daemon otherwise
                    // takes the update the next time it stops on its own.
                    Button(localized("Update Anyway")) { Task { await model.setUp(force: true) } }
                } else {
                    Button(localized("Set Up \(machine.name)")) { Task { await model.setUp() } }
                }
            }
            if let feedback = model.feedback {
                InstallFeedbackLabel(feedback: feedback)
            }
        }
        .task {
            // Asked when the pane opens, not when the roster draws: one machine,
            // because someone is looking at it.
            guard case .unasked = model.readiness, model.discovered == nil else { return }
            await model.check()
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
        if !machine.isLocal {
            Section {
                LabeledContent {
                    probeControl
                } label: {
                    SettingsLabel(
                        title: host?.destinationLabel ?? machine.name,
                        subtext: host?.identityFile.map { localized("Signs in with \($0)") }
                            ?? localized("Signs in with the keys ssh offers by default."),
                        titleFont: .headline
                    )
                }
                if case .result(.wantsPassword) = probe { passwordAdvice }
                LabeledContent {
                    Button(localized("Edit"), action: onEditConfig)
                } label: {
                    SettingsLabel(
                        title: localized("Host block"),
                        subtext: localized("Opens the ~/.ssh/config entry this machine is defined in."),
                        titleFont: .headline
                    )
                }
            } header: {
                SectionHeaderLabel(title: localized("Reached by"))
            }
        }
    }

    // MARK: Termio server — the daemon that holds the sessions

    /// Read-only, on both entrances. Putting the daemon there and moving it
    /// forward is what *Set Up* does, and a second button for the same loop was
    /// the same action under two verbs.
    ///
    /// This Mac used to have no such row at all: `integrationSection` spent the
    /// local branch on the CLI, so the one daemon the user could actually see
    /// running was the only one whose version the app never showed.
    private var serverSection: some View {
        Section {
            SettingsLabel(title: "termiod", subtext: serverSubtext, titleFont: .headline)
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
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let keyToInstall, let alias = machine.alias {
                Button(localized("Set Up Key…")) { onSetUpKey(alias, keyToInstall.url.path) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
                    subtext: localized("Which agent CLIs are on \(machine.name), and where each one launches from."),
                    titleFont: .headline
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

    /// The facts behind the one line: what the two Agents switches asked for, and
    /// whether this machine is carrying it.
    ///
    /// **One Reinstall, not one per half.** Each half used to carry its own
    /// button passing `.leave` for the other, and neither touched the machine's
    /// integration stamp — so a config repaired here still read as "not
    /// installed" everywhere the stamp is consulted. The daemon writes both
    /// halves in one pass anyway (`AgentIntegrationInstaller.sync` takes the
    /// pair), so two buttons were two names for one write, and only the one that
    /// does what the switches say can honestly claim the machine is current.
    ///
    /// The `termio` CLI rides here on this Mac only: it is the local twin of the
    /// daemon rung, and there is no CLI to link onto a box the user never types
    /// into directly.
    private var integrationSection: some View {
        Section {
            if machine.isLocal {
                CommandLineToolRow()
            }
            SettingsLabel(
                title: localized("Hooks"),
                subtext: settings.agentHooksEnabled
                    ? localized("Report each agent’s status back to Termio.")
                    : localized("Turned off in Settings ▸ Agents, so Termio removes them from \(machine.name)."),
                titleFont: .headline
            )
            SettingsLabel(
                title: localized("Skill"),
                subtext: settings.sessionControlEnabled
                    ? localized("Teaches agents the termio session commands.")
                    : localized("Turned off in Settings ▸ Agents, so Termio removes it from \(machine.name)."),
                titleFont: .headline
            )
            InstallButtonRow(title: localized("Reinstall")) { await reinstallIntegration() }
        } header: {
            SectionHeaderLabel(title: localized("Installed by Termio"))
        } footer: {
            Text(localized("What Termio puts on \(machine.name) so its agents can report. Reinstall after hand-editing an agent’s config."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Writes both halves as the switches ask, then stamps the machine when the
    /// write was clean — the stamp is what "Not installed on \(machine.name)"
    /// reads, so a repair that does not clear it leaves the user chasing a
    /// warning they have already answered.
    private func reinstallIntegration() async -> InstallFeedback {
        let outcome = await AgentIntegrationInstaller.sync(
            hooks: settings.agentHooksEnabled ? .install : .remove,
            skills: settings.sessionControlEnabled ? .install : .remove,
            target: machine.integrationTarget)
        if outcome.failure == nil && outcome.failed.isEmpty {
            model.stampIntegration()
        }
        return .summarizing(
            outcome, headline: localized("Reinstalled"), unit: localized("agents"))
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
                    title: localized("Command-line tool"), subtext: description, titleFont: .headline)
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
                            subtext: detail(for: preset),
                            titleFont: .headline
                        )
                    }
                }
            } footer: {
                Text(localized("Leave a path empty to launch the agent the way \(machine.name)’s login shell would. Which agents appear at all is Settings ▸ Agents."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(localized("Agents on \(machine.name)"))
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
