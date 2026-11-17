import Foundation
import TermioShared

/// Asks a machine to install termio's agent integration on itself.
///
/// This replaces `AgentConfigStore` and both installers. The machine that owns
/// the agent config files decides what goes in them: this side states
/// *preferences* — which agents are on the user's list, whether each switch is
/// on, what a hook should invoke — and `termiod` works out where every agent
/// keeps its config, whether its CLI is even there, which of six dialects to
/// merge into, and what to write. See
/// `docs/design/20260825-agent-integration-moves-to-termiod.md`.
///
/// What that buys, measured: a twelve-agent install on a device was forty to
/// sixty sequential `ssh` invocations, each a `Process` with `waitUntilExit()`.
/// It is now one round trip.
///
/// **Installing on this Mac is now an IPC call too.** That is
/// `one-path-local-through-termiod`'s thesis and not a new cost — but it is a
/// new failure mode, so it is handled rather than assumed: `Transport.open`
/// already auto-starts `termiod serve` when nothing answers, which is the same
/// spawn every local session depends on, so "the daemon was not running" is a
/// state this recovers from rather than one it reports. What it cannot recover
/// from — no daemon binary at all — is reported, never swallowed, because a Mac
/// that could always install its own hooks must not start failing quietly.
enum AgentIntegrationInstaller {
    /// Where the integration is written, and which machine's skill it gets.
    ///
    /// The two travel together because they are one decision. Every hook
    /// reports to the daemon that owns its PTY — the daemon builds that command
    /// itself — but this Mac's skill teaches the `termio` CLI and a device's
    /// does not.
    struct Target {
        let route: TermiodRoute
        let reporter: Termiod.AgentHookReporter

        /// This Mac. The daemon is local, and the app is what listens.
        static var thisMac: Target {
            Target(route: .local, reporter: .thisMac)
        }

        static func device(host: String) -> Target {
            Target(route: .ssh(host), reporter: .device)
        }

        var isLocal: Bool { reporter == .thisMac }
    }

    /// Act on one or both halves in a single message.
    ///
    /// Each half is stated independently — install it, remove it, or leave it —
    /// because the two Integration switches are independent and the device
    /// pane's "Reinstall hooks" must not touch the skill. The roster is the
    /// whole catalog: that is what the app has always installed, and this stage
    /// changes no Settings surface.
    /// `commands` is what each agent launches with **on that machine**, by id:
    /// the path the user authored in Settings where they authored one. The
    /// daemon judges presence against the binary a session would really run, so
    /// an agent the app reports available is never one the daemon silently
    /// refuses to write a config for.
    static func sync(
        hooks: Termiod.AgentHalfAction,
        skills: Termiod.AgentHalfAction,
        target: Target = .thisMac,
        commands: [String: String] = [:]
    ) async -> InstallOutcome {
        // Every local hook invokes the channel-stable CLI copy, so make sure it
        // carries this build's content before the daemon stamps its path
        // anywhere. A device's hooks invoke its own `termiod`, which the
        // foundation rung keeps current; there is nothing here to refresh for it.
        if target.isLocal { CommandLineTool.refreshSupportCopy() }
        // Whether a switch is on decides install-or-remove; whether the caller
        // named that half decides whether it is touched at all.
        do {
            let reply = try await Task.detached(priority: .userInitiated) {
                try Termiod.installAgents(
                    route: target.route,
                    agents: nil,
                    hooks: hooks,
                    skills: skills,
                    reporter: target.reporter,
                    commands: commands)
            }.value
            return InstallOutcome(reply)
        } catch {
            Log.termiod.error("""
                agent integration install failed: \
                \(error.localizedDescription, privacy: .public)
                """)
            return InstallOutcome(failure: error.localizedDescription)
        }
    }

    /// Which of these agents' CLIs are on that machine.
    ///
    /// Only for a device. This Mac keeps answering through `AgentAvailability`,
    /// which reads the login-shell `PATH` in-process: it is the exact `PATH` a
    /// session launches with, it costs no IPC, and routing a read-only question
    /// through the daemon would change an answer the Agents tab already renders
    /// correctly.
    static func probe(host: String, agents: [String], commands: [String: String]) async throws
        -> [Termiod.AgentPresence]
    {
        try await Task.detached(priority: .userInitiated) {
            try Termiod.probeAgents(route: .ssh(host), agents: agents, commands: commands)
        }.value
    }
}

extension InstallOutcome {
    /// Built from the daemon's reply rather than accumulated locally.
    ///
    /// One agent contributes up to two rows — its hooks and its skill — and a
    /// name is recorded as failed if either refused, because a row that says
    /// "Claude Code" and means "its skill landed but its hooks did not" is worse
    /// than no row.
    init(_ reply: Termiod.AgentsInstalledPayload) {
        self.init()
        let results = reply.results
        coveredIDs = reply.present.isEmpty ? nil : reply.present.sorted()
        var seen: [String: Bool] = [:]
        var order: [String] = []
        for result in results {
            // A dialect the daemon does not write yet reports `skipped`. It is
            // neither a success to claim nor a failure to blame someone for, so
            // it stays out of the sentence.
            guard result.status != "skipped" else { continue }
            if seen[result.name] == nil { order.append(result.name) }
            seen[result.name] = (seen[result.name] ?? true) && result.isInstalled
        }
        for name in order {
            record(name, installed: seen[name] ?? false)
        }
    }

    /// The install never reached the machine at all. Named so a Settings row
    /// says what happened instead of showing an empty success, and kept apart
    /// from the per-agent list so a pane can print it as the sentence it is
    /// rather than as the name of an agent.
    init(failure: String) {
        self.init()
        self.failure = failure
        record(failure, installed: false)
    }
}
