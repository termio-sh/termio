import Foundation
import TermioShared

/// Whether an agent's CLI is on a machine — with the third answer the local probe
/// never needed (RFC §D4).
///
/// `AgentAvailability` answers *available* when its own probe fails rather than
/// crying wolf, which is right for this Mac: the only way to fail is a login shell
/// that would not print its `PATH`, and that is rare. A machine reached over a
/// network fails constantly — asleep box, dead tunnel, wrong alias, key not
/// loaded — so folding "we could not ask" into either answer is a lie in one
/// direction or the other. Reported as "not installed" it sends the user to
/// reinstall a CLI that is already there; reported as "available" it promises a
/// launch that cannot happen.
enum AgentReadiness: String, Sendable {
    case available
    case missing
    /// We could not reach the machine to ask. Never a defect in the agent.
    case unknown
}

/// One agent's presence across every machine on the roster, reduced to what a
/// single line can say.
///
/// The Agents tab asks about a *subject* — an agent — so pinning its rows to one
/// machine answers the wrong question, and hides the interesting half: an agent
/// installed here and missing on `devbox` reads as fine until you happen to be
/// looking at `devbox`. A machine picker cannot say this at all, because it shows
/// one machine at a time; that is why the picker it replaced was the wrong shape
/// and not merely an ugly one.
struct AgentFleetReadiness: Equatable {
    /// Machines that answered and do not have the CLI.
    var missing: [String] = []
    /// Machines we could not ask. Never a defect in the agent (§D4), so these
    /// never earn the warning badge.
    var unknown: [String] = []
    /// How many machines were asked. A roster of one names no machine: with
    /// nothing to distinguish it from, "on This Mac" is a label carrying no
    /// information, and the line reads exactly as it did before there was ever
    /// more than one machine to mean.
    var asked = 0

    /// The word the line leads with, or `nil` when every machine that answered
    /// has the agent — the common case, where the line is the command alone.
    ///
    /// Named up to one machine and counted beyond: three names in a caption is a
    /// list nobody reads, and the count is enough to send someone to the roster.
    var summary: String? {
        if !missing.isEmpty {
            if asked <= 1 { return localized("Not installed") }
            if missing.count == 1 { return localized("Not installed on \(missing[0])") }
            return localized("Missing on \(missing.count) machines")
        }
        // "We could not ask `vps`" is a fact about **`vps`**, not about this
        // agent, so a roster that repeated it would print the same sentence on
        // every agent row — burying the command, which is what the line is for.
        // An unreached machine is reported once, where it belongs: on the
        // Machines list and on its own pane. The exception is having reached
        // nothing at all, where silence would read as "all fine".
        guard !unknown.isEmpty, unknown.count == asked else { return nil }
        if unknown.count == 1 { return localized("Can’t check on \(unknown[0])") }
        return localized("Can’t check on \(unknown.count) machines")
    }

    /// Only a machine that *answered* earns the badge. "We could not ask" says so
    /// in words instead — a warning glyph for it is the false alarm §D4 exists to
    /// prevent.
    var hasMissing: Bool { !missing.isEmpty }
}

extension AgentReadiness {
    /// `passive`, asked of every machine on the roster at once.
    ///
    /// Affordable for exactly the reason `passive` is: this Mac is one cached
    /// `PATH` probe and every other machine is a file read, so summarising N
    /// machines costs N file reads rather than N `ssh` round trips. The moment any
    /// of this reaches the network it has to go back to naming one machine.
    static func acrossFleet(
        agent: AgentPreset, on devices: [(device: KnownDevice, command: String)]
    ) async -> AgentFleetReadiness {
        var fleet = AgentFleetReadiness(asked: devices.count)
        for entry in devices {
            switch await passive(agent: agent, command: entry.command, on: entry.device) {
            case .available: continue
            case .missing: fleet.missing.append(entry.device.name)
            case .unknown: fleet.unknown.append(entry.device.name)
            }
        }
        return fleet
    }
}

/// One machine's whole answer, as one line (RFC §D6).
///
/// Deploy `termiod` → probe the agent CLIs → install hooks and skill is a real
/// dependency chain, and four rungs with independent states turn choosing a
/// machine into infrastructure triage. So the pane shows one outcome and the
/// ladder becomes the disclosure behind it.
enum DeviceReadinessState: Equatable {
    /// Nothing asked yet, and no cache to draw on.
    case unasked
    case checking
    case ready
    /// The **first** blocking step, in words. Only the first: a machine with no
    /// `termiod` also has no hooks, and listing both invites the user to fix the
    /// consequence instead of the cause.
    case blocked(String)
    /// The new `termiod` is on the machine and the old daemon is still running
    /// because it has work in progress — a command running, or an agent
    /// mid-task — named in the text. Not a fault: it takes over once that
    /// finishes, or when the user says to stop it now.
    case staged(String)

    var isBusy: Bool { self == .checking }
}

/// The steps behind the one line, in dependency order. Named so the pane can say
/// what it is doing while it runs, and so a failure can name the rung it stopped
/// on rather than reporting "setup failed".
enum DeviceSetupStep: Equatable {
    /// This Mac: link the `termio` CLI onto `PATH`. A device: deploy `termiod`.
    /// Both are "the binary this machine needs before anything else works", which
    /// is why they are one rung rather than a local branch bolted onto a remote
    /// flow (RFC §D8: installing a CLI on a machine is a machine operation).
    case foundation
    case probeAgents
    case installIntegration

    var label: String {
        switch self {
        case .foundation: return localized("Checking the machine…")
        case .probeAgents: return localized("Looking for agent CLIs…")
        case .installIntegration: return localized("Installing hooks and skill…")
        }
    }
}

extension AgentReadiness {
    /// The answer a **passive** line may give: this Mac is probed live, and any
    /// other machine is read from its device file or left `unknown`.
    ///
    /// Passive is the constraint, not a shortcut. The Agents tab draws one of
    /// these per row, and a live remote probe there would fire an `ssh` per agent
    /// every time the tab is opened or a workspace is switched — several seconds
    /// of Settings hanging on a sleeping box, to decorate a line the user did not
    /// ask about. So the tab reports what is known and says "can't check" when
    /// nothing is; the machine's pane is where asking happens, and it writes the
    /// file this reads.
    ///
    /// Keyed by agent rather than by command, so a path edited since the last
    /// probe reads as whatever the old path resolved to until the machine's pane
    /// is opened again. That is the cache being a cache; it is never the thing
    /// that decides whether a launch happens.
    static func passive(
        agent: AgentPreset, command: String, on device: KnownDevice
    ) async -> AgentReadiness {
        guard device.alias != nil else {
            return await AgentAvailability.isCommandAvailable(command) ? .available : .missing
        }
        let key = device.settingsKey
        guard let cached = await Task.detached(priority: .utility, operation: {
            DeviceStateCache.load(key)
        }).value else { return .unknown }
        return cached.readiness(for: agent)
    }
}

// MARK: - Probing

/// Asks a machine what it is. Every method here runs off the main actor and
/// returns a value; nothing renders, and nothing is cached as authority.
enum DeviceProbe {
    /// A read-only check: what is true on this machine right now.
    ///
    /// The one probe that matters is reachability, and it is asked **first and
    /// once**: a machine that does not answer makes every agent `.unknown` in one
    /// step, instead of paying an ssh timeout per agent to reach the same
    /// conclusion eight times.
    static func inspect(
        device: KnownDevice, commands: [(id: String, command: String)]
    ) async -> DeviceDiscoveredState {
        let now = Date()
        guard let alias = device.alias else {
            // This Mac always answers. Its readiness is `AgentAvailability`'s
            // login-shell PATH — the exact PATH a session launches with.
            var agents: [String: String] = [:]
            for entry in commands {
                agents[entry.id] = await AgentAvailability.isCommandAvailable(entry.command)
                    ? AgentReadiness.available.rawValue
                    : AgentReadiness.missing.rawValue
            }
            // Asked off-main: it is a socket handshake, and the pane calling
            // this is on the main actor. `nil` means no daemon is running yet,
            // which the row renders as "Not running" rather than as a failure.
            let version = await Task.detached(priority: .userInitiated) {
                try? Termiod.probeExistingLocalDevice().daemonVersion
            }.value
            return DeviceDiscoveredState(
                checkedAt: now, reachable: true, termiodVersion: version, agents: agents)
        }

        let probe = await SSHConfigFile.testConnection(alias: alias)
        guard case .reachable = probe else {
            return DeviceDiscoveredState(checkedAt: now, reachable: false)
        }
        // One question for the whole roster. This was one blocking `ssh` per
        // agent — a dozen round trips to learn something the box knows about
        // itself in microseconds.
        do {
            let presence = try await AgentIntegrationInstaller.probe(
                host: alias, agents: commands.map(\.id))
            var agents: [String: String] = [:]
            for entry in presence {
                agents[entry.id] = entry.present
                    ? AgentReadiness.available.rawValue
                    : AgentReadiness.missing.rawValue
            }
            // Every handshake records the daemon's build in the registry, and
            // the probe just made one.
            return DeviceDiscoveredState(
                checkedAt: now, reachable: true,
                termiodVersion: TermiodDeviceRegistry.shared.device(for: .ssh(alias))?.daemonVersion,
                agents: agents)
        } catch {
            // Reached over ssh, but the daemon could not answer — an old
            // termiod, or one that will not start. Reported as reachable with
            // nothing known rather than as a machine with no agents, because
            // "No agent CLIs found" sends the user looking in the wrong place.
            Log.termiod.error("""
                agent probe on \(alias, privacy: .public) failed: \
                \(error.localizedDescription, privacy: .public)
                """)
            return DeviceDiscoveredState(checkedAt: now, reachable: true)
        }
    }
}

// MARK: - The device file's integration stamp

extension DeviceDiscoveredState {
    /// Whether the hooks and skill installed on this machine were installed by
    /// *this* build.
    ///
    /// Stamped rather than re-derived: a hook is a line inside each agent's own
    /// config in four different dialects, and re-parsing all of them on every pane
    /// open would fork the installers' knowledge into a second reader that can
    /// drift from them. The stamp costs one honest failure mode — a config
    /// hand-edited after we wrote it still reads as installed — and the ladder's
    /// "Reinstall hooks" is exactly the disclosure that answers it.
    ///
    /// Compared against the build, not merely checked for presence, because a
    /// local hook embeds the CLI's path and a device hook embeds `termiod`'s: an
    /// upgrade that moves either leaves a hook that cannot exec.
    var carriesCurrentIntegration: Bool {
        integrationVersion != nil && integrationVersion == AppInfo.buildStamp
    }
}

// MARK: - What a machine's pane runs on

/// The state behind one machine's pane: what we last learned, what we are asking
/// now, and the single outcome line.
///
/// Owned by the pane rather than the app because a machine is only asked about
/// while someone is looking at it. Nothing here probes on launch: a Settings
/// window that fires ssh at every configured host on open is how a sleeping VPS
/// makes opening preferences take twenty seconds.
@MainActor
final class DevicePaneModel: ObservableObject {
    let device: KnownDevice
    private let settings: AppSettings

    /// The last probe's answer, seeded from `~/.termio/devices/<key>.json` so the
    /// pane draws something the moment it opens. Replaced by the first live probe
    /// — it is a cache, never the authority.
    @Published private(set) var discovered: DeviceDiscoveredState?
    @Published private(set) var readiness: DeviceReadinessState = .unasked
    /// The rung in progress, so a chain that takes ten seconds says which part is
    /// slow instead of spinning anonymously.
    @Published private(set) var step: DeviceSetupStep?
    /// What the last completed setup left behind, shown once and dismissed.
    @Published var feedback: InstallFeedback?

    init(device: KnownDevice, settings: AppSettings) {
        self.device = device
        self.settings = settings
        discovered = DeviceStateCache.load(device.settingsKey)
        // Seeded from the cache, but never *blocked* by it: a box that was asleep
        // when we last looked must not greet the user with a failure we have not
        // re-confirmed. It reads as "not set up yet" until a live probe says more.
        if let discovered, discovered.carriesCurrentIntegration, discovered.reachable {
            readiness = .ready
        }
    }

    /// The agents whose presence this machine is judged on: the ones the user
    /// actually keeps on their list. Judging on the whole catalog would report a
    /// machine unready for an agent its owner has never used.
    var listedAgents: [AgentPreset] {
        settings.orderedAgents(AgentPreset.codingAgents.filter(settings.isAgentListed))
    }

    private var commandPairs: [(id: String, command: String)] {
        listedAgents.map { ($0.rawValue, settings.command(for: $0, on: device) ?? "") }
    }

    func readiness(for agent: AgentPreset) -> AgentReadiness {
        guard let discovered else { return .unknown }
        return discovered.readiness(for: agent)
    }

    /// Asks the machine, without changing anything on it. The pane's own refresh,
    /// and what the roster row calls when it first appears.
    func check() async {
        guard !readiness.isBusy else { return }
        readiness = .checking
        step = .foundation
        let state = await DeviceProbe.inspect(device: device, commands: commandPairs)
        // Carry the integration stamp forward: a probe asks what is on the
        // machine, and does not un-install what a previous setup put there.
        var merged = state
        merged.integrationVersion = discovered?.integrationVersion
        apply(merged)
        step = nil
    }

    /// The whole safe chain, in one click (RFC §D6). Stops at the first rung that
    /// blocks and says what it was — the later rungs cannot succeed anyway, and
    /// reporting all three invites fixing a consequence instead of a cause.
    ///
    /// `force` stops the machine's old daemon even while it has work in
    /// progress — "Update Anyway", offered only once that work has been named.
    func setUp(force: Bool = false) async {
        guard !readiness.isBusy else { return }
        readiness = .checking
        feedback = nil
        defer { step = nil }

        step = .foundation
        if let failure = await installFoundation(force: force) {
            readiness = failure
            return
        }

        step = .probeAgents
        var state = await DeviceProbe.inspect(device: device, commands: commandPairs)
        state.integrationVersion = discovered?.integrationVersion
        apply(state)
        // `resolve` already names the first thing in the way — unreachable, or
        // nothing to run — and those are exactly the two that stop the chain.
        if case .blocked = readiness { return }

        step = .installIntegration
        // One message for the whole roster. There is no `Task.detached` wrapper
        // any more because there is no blocking work left to detach from — the
        // daemon on that machine does the writing, and this awaits one reply.
        let outcome = await AgentIntegrationInstaller.sync(
            hooks: settings.agentHooksEnabled ? .install : .remove,
            skills: settings.sessionControlEnabled ? .install : .remove,
            target: device.integrationTarget)
        // A request the machine never acted on is reported in its own words —
        // it is a sentence, not an agent that refused.
        if let failure = outcome.failure {
            apply(state)
            readiness = .blocked(localized("Couldn’t install hooks on \(device.name).\n\(failure)"))
            return
        }
        // A rung that reached the machine but could not write every agent's config
        // is still a failure of *this* rung, and the one worth naming.
        let refused = outcome.failed
        guard refused.isEmpty else {
            apply(state)
            readiness = .blocked(localized(
                "Couldn’t write the config for \(InstallOutcome.list(refused, unit: localized("agents"))) on \(device.name)."))
            return
        }
        state.integrationVersion = AppInfo.buildStamp
        apply(state)
        // The outcome line already says "Ready"; what this adds is *what was
        // put there*, and with both switches off there is nothing to add.
        let headline: String? = switch (settings.agentHooksEnabled, settings.sessionControlEnabled) {
        case (true, true): localized("Hooks and skill installed")
        case (true, false): localized("Hooks installed")
        case (false, true): localized("Skill installed")
        case (false, false): nil
        }
        feedback = headline.map { .summarizing(outcome, headline: $0, unit: localized("agents")) }
    }

    /// The first rung. This Mac needs the `termio` CLI on `PATH` — a hook it
    /// installs invokes it by name. A device needs the `termiod` this build
    /// ships, which is also the reachability check, since deploying requires
    /// reaching it. `nil` when the rung passed; otherwise the state to show.
    private func installFoundation(force: Bool) async -> DeviceReadinessState? {
        guard let alias = device.alias else {
            switch CommandLineTool.install() {
            case .installed:
                break
            case .conflict:
                return .blocked(localized("Something else already owns \(CommandLineTool.installURL.path)."))
            case .unavailable:
                return .blocked(localized("Run Termio from the built app to install its command-line tool."))
            case .notInstalled, .stale:
                let directory = CommandLineTool.installURL.deletingLastPathComponent().path
                return .blocked(localized("Couldn’t link `\(CommandLineTool.toolName)` into \(directory)."))
            }
            // The daemon rung, which this Mac used to skip: a machine is set up
            // when it runs this build's termiod, and that was true of every box
            // except the one the app runs on (`localReadyCheck`).
            switch await TermioStore.localReadyCheck(force: force) {
            case .success:
                return nil
            case .failure(let error):
                return error.state == .staged ? .staged(error.message) : .blocked(error.message)
            }
        }
        switch await TermioStore.remoteReadyCheck(host: alias, force: force) {
        case .success:
            return nil
        case .failure(let error):
            return error.state == .staged ? .staged(error.message) : .blocked(error.message)
        }
    }

    /// Records that this build's hooks and skill are on the machine, after a
    /// write that reported no failure. The end of `setUp`'s integration rung
    /// does the same thing inline; Reinstall is the other way the same fact
    /// becomes true, and until it said so a repaired machine kept reading as
    /// behind.
    func stampIntegration() {
        var state = discovered ?? DeviceDiscoveredState(checkedAt: Date(), reachable: true)
        state.checkedAt = Date()
        state.integrationVersion = AppInfo.buildStamp
        apply(state)
    }

    private func apply(_ state: DeviceDiscoveredState) {
        discovered = state
        readiness = resolve(state)
        let key = device.settingsKey
        Task.detached(priority: .utility) { DeviceStateCache.save(state, for: key) }
    }

    /// What a completed probe means, in one line: ready when the machine
    /// answered, something on it can run, and this build put its hooks there —
    /// and otherwise the **first** thing standing in the way, in that order.
    ///
    /// Order matters more than completeness. A box that does not answer also has
    /// no agent CLIs and no hooks, and saying all three would invite the user to
    /// go install an agent on a machine that is switched off.
    private func resolve(_ state: DeviceDiscoveredState) -> DeviceReadinessState {
        guard state.reachable else { return .blocked(localized("Can’t reach \(device.name).")) }
        guard state.agents.values.contains(AgentReadiness.available.rawValue) else {
            return .blocked(localized("No agent CLIs found on \(device.name)."))
        }
        // Not blocked, just not done — the setup button is the whole next step, so
        // it reads as "set up this device" rather than as a fault.
        return state.carriesCurrentIntegration ? .ready : .unasked
    }
}

extension KnownDevice {
    /// Which machine's daemon is asked to install, and what a hook there runs
    /// to report status.
    var integrationTarget: AgentIntegrationInstaller.Target {
        alias.map { AgentIntegrationInstaller.Target.device(host: $0) } ?? .thisMac
    }
}

/// The build a device file's integration stamp is compared against.
enum AppInfo {
    /// Version plus build number: a version alone would not notice a dev rebuild
    /// that moved the CLI copy the hooks point at.
    static let buildStamp: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version)+\(build)"
    }()

    /// The same stamp, `nil` when the running binary is not a bundle. A bare
    /// `swift build` executable carries no version at all, and the daemon it
    /// finds in the checkout is stamped from the commit count — comparing the
    /// two would report a mismatch on every launch that no update could settle.
    static let bundledStamp: String? = {
        Bundle.main.infoDictionary?["CFBundleVersion"] == nil ? nil : buildStamp
    }()
}
