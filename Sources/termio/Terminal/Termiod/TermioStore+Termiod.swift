import AppKit
import Foundation
import GhosttyTerminal
import TermioShared

/// Session plumbing: sessions run inside a termiod daemon — the local one, or
/// one reached over SSH — and this app is an attach client. Kept beside the
/// protocol client so the whole backend lives in one folder.
extension TermioStore {
    /// Builds the attach channel for a session about to be surfaced. The
    /// termiod session is *named* with the app session's stable UUID, which is
    /// what makes relaunch reattachment work: `attach` with
    /// `create_if_missing` resolves the name first, so a session that survived
    /// the last app quit is rejoined — same process, same pid — and only a
    /// session with no live counterpart spawns fresh.
    func makeTermiodLink(for session: Session, argv: [String], cwd: String,
                         env: [String: String]) -> TermiodSessionLink {
        // The session is the only source of truth for where it runs. There used
        // to be a `TERMIO_TERMIOD_REMOTE` fallback here from before the picker
        // existed, but it silently turned *every* session without an explicit
        // host — including plain "New Terminal" — into a remote one. A local
        // terminal must never become remote because of an environment variable.
        let route = TermiodRoute(sshAlias: session.termiodRemoteHost)
        let remoteHost = session.termiodRemoteHost
        // A remote session runs on the VPS, so the Mac's cwd, PATH-laden env,
        // and shell path are all wrong there — hand the remote its own login
        // shell (empty argv) and let it set up its own environment. The remote
        // cwd travels when the caller chose one (a cloned repo directory): the
        // remote daemon `cd`s there before the shell. Local sessions keep the
        // full spec, unchanged.
        let specification = remoteHost == nil
            ? Termiod.CreateSpecification(
                cwd: cwd,
                argv: argv,
                env: env.map { [$0.key, $0.value] },
                rows: UInt16(clamping: lastHostGridRows),
                cols: UInt16(clamping: lastHostGridColumns))
            : Termiod.CreateSpecification(
                cwd: session.termiodRemoteCwd ?? "",
                argv: [],
                env: Self.presentationEnvironment(from: env),
                rows: UInt16(clamping: lastHostGridRows),
                cols: UInt16(clamping: lastHostGridColumns))
        return TermiodSessionLink(
            // Its uuid for a session Termio opened; the name it already had for
            // one adopted off the device's roster (see `Session.termiodSessionName`).
            sessionName: daemonSessionName(for: session),
            specification: specification,
            route: route,
            rows: lastHostGridRows,
            cols: lastHostGridColumns
        )
    }

    /// The half of the session environment that describes *how output should
    /// look*, which belongs to the client no matter which machine the process
    /// runs on. Everything else — `PATH`, `HOME`, `SHELL`, anything naming a
    /// path on this Mac — stays behind, because it describes where the process
    /// runs and the device owns that.
    ///
    /// Withholding all of it is what made a remote agent render washed out: a
    /// program that cannot see `COLORTERM` decides the terminal is 256-colour
    /// and quantises the user's theme to the nearest palette entry, and that
    /// decision is made before a single byte reaches the client, where no
    /// amount of correct rendering can undo it. Plain `ssh` cannot fix this
    /// from the client side at all — it forwards only `TERM` plus the config's
    /// `SendEnv` whitelist, so `COLORTERM` needs `sshd` changes on the far end.
    /// Spawning the process ourselves means we simply declare it.
    ///
    /// `TERMIO_SESSION` is deliberately *not* here: it is identity, not
    /// presentation, and a hook that echoes it back would be reporting to a
    /// control socket on the wrong machine.
    static func presentationEnvironment(from env: [String: String]) -> [[String]] {
        ["TERM", "COLORTERM", "TERM_PROGRAM", "FORCE_HYPERLINK"]
            .compactMap { key in env[key].map { [key, $0] } }
    }

    /// Wires the channel to the surface and registers it. Output enters the
    /// surface through `InMemoryTerminalSession.receive` — the same seam the
    /// in-process PTY read pump feeds — so there is exactly one render path.
    func attachTermiodLink(_ link: TermiodSessionLink,
                           to inMemory: InMemoryTerminalSession,
                           for session: Session) {
        let isAgentSession = session.agent != .terminal && !session.isSSH
        link.onOutput = { [weak inMemory] data in
            inMemory?.receive(data)
        }
        // The attach handshake is the cheapest device discovery there is — it was
        // going to happen anyway — so every surfaced session teaches the app which
        // machine it is on, with no extra round trip.
        link.onDevice = { [weak self] device in
            self?.adoptDevice(device, forRoute: link.route)
            // An attach that succeeded is proof the session is running now, which
            // outranks a grave dug before it. Without this, a row whose session
            // was buried and then reopened keeps reading "ended" until the next
            // roster arrives — the app disagreeing with the terminal beside it.
            self?.termiodTombstones[link.sessionName] = nil
            // The same proof outranks a close recorded before it: a name attached
            // under again must not be killed on sight by the roster sweep. On
            // this session's own route only — another machine's same-named
            // pending kill is still owed.
            self?.forgetClosedSession(named: link.sessionName, sshAlias: session.termiodRemoteHost)
        }
        // The attach reply names the daemon session it resolved to, which is
        // the earliest the row can learn its identity — a respawn under the
        // same name gets its fresh id here rather than a roster refresh later,
        // shrinking the window in which a close would journal a stale one.
        link.onDaemonSessionID = { [weak self] daemonID in
            self?.recordDaemonSessionID(daemonID, for: session.id)
        }
        // The `events` half of the negotiated capabilities. Status is the one
        // that matters: an agent running on a VPS reports to the daemon that
        // owns its PTY, and this is the only path by which that reaches the Mac
        // — the hook socket is on the wrong machine, which is exactly why
        // `presentationEnvironment` withholds `TERMIO_SESSION` from a remote.
        link.onStatus = { [weak self] status in
            self?.applyTermiodStatus(status, for: session.id)
        }
        link.onStalled = { [weak self] stall in
            self?.applyTermiodStalled(stall, for: session.id)
        }
        // Input only: the link gates its `D` frames on this. Nothing about the
        // *size* rides it any more — a pane is letterboxed at the session's grid
        // whenever the session is smaller than the pane, whoever is typing
        // (`SessionRuntime.sharedGrid`,
        // `docs/design/20260901-pty-size-is-not-the-write-token.md`).
        link.onWriter = { writer in
            Log.termiod.info("""
            session \(session.id.uuidString, privacy: .public) is now \
            \(writer ? "the writer" : "an observer", privacy: .public)
            """)
        }
        link.onSharedGrid = { [weak self] grid in
            self?.runtime(for: session.id).sharedGrid = grid
        }
        // What the device knows about the process, gated exactly where the
        // in-process PTY's own kernel poll is gated: that poll is installed only
        // on a row declared `.terminal` (a declared agent's foreground is its own
        // subprocess, and reading a `rg` it spawned as "no agent here" would
        // demote the row mid-turn), and follows the cwd only for a loose terminal,
        // whose place is wherever it wandered rather than a project root.
        let isPlainTerminal = session.agent == .terminal
        let followsWorkingDirectory = isPlainTerminal && isLooseTerminal(session.id)
        link.onInformation = { [weak self] information in
            self?.applyTermiodInformation(
                information, for: session.id,
                identifiesAgent: isPlainTerminal,
                followsWorkingDirectory: followsWorkingDirectory)
        }
        link.onStartRefused = { [weak self, weak inMemory] message in
            self?.applyTermiodStartRefused(for: session.id, message: message, surface: inMemory)
        }
        link.onConnectionLost = { [weak self, weak inMemory] in
            self?.applyTermiodConnectionLost(for: session.id, surface: inMemory)
        }
        link.onExit = { [weak self, weak inMemory] code, runtimeMilliseconds, information in
            self?.applyTermiodExit(
                for: session.id, code: code, runtimeMilliseconds: runtimeMilliseconds,
                information: information, isAgentSession: isAgentSession,
                isPlainTerminal: isPlainTerminal, surface: inMemory)
        }
        termiodLinks[session.id] = link
        link.start()
    }

    /// How much of a session this pane could show, measured from the pane
    /// itself. The daemon sizes the session to the smallest viewport currently
    /// rendering it, so this is the Mac's whole say in the matter — the write
    /// token has none.
    func reportViewport(_ grid: TerminalGrid, for id: Session.ID) {
        termiodLinks[id]?.setViewport(rows: Int(grid.rows), cols: Int(grid.cols))
    }

    /// Whether this pane is on screen. A hidden pane keeps its viewport and
    /// stops counting, so a window left open on another workspace does not hold
    /// every session it has a pane for down to its own width — zellij's rule for
    /// tabs nobody is looking at.
    func reportRendering(_ showing: Bool, for id: Session.ID) {
        termiodLinks[id]?.setRendering(showing)
    }

    // MARK: - Host-reported workstream status

    /// Lands the device's one `stalled` signal on the watch plane (device
    /// architecture §4.7). The session's own status is untouched: from outside
    /// an agent a quiet long build and a wedged loop are indistinguishable,
    /// which is exactly why this plane signals and never kills — no new
    /// `SessionStatus` case, and the sidebar and menu bar do not move.
    ///
    /// The default `termio sessions watch` filter is done + needs-you, so this
    /// stays opt-in behind `--state stalled`. The evidence sentence is worded
    /// here rather than on the device, because it is prose a person reads.
    func applyTermiodStalled(_ stall: Termiod.StalledPayload, for id: Session.ID) {
        guard let session = session(id), let project = project(for: id) else { return }
        let minutes = max(1, Int(stall.workingSeconds / 60))
        let grown = Int(stall.transcriptLinesGrown)
        let growth = "transcript +\(grown) line" + (grown == 1 ? "" : "s")
        var event = SessionWatchEvent(
            projectID: project.id,
            link: sessionLink(for: session),
            status: "stalled",
            title: displayTitle(for: session),
            cwd: runtimes[id]?.workingDirectory ?? "")
        event.evidence = "working \(minutes)m, no repo change, \(growth)"
        SessionWatchHub.shared.broadcast(event)
    }

    /// Lands an `E status` event on the session's row. The vocabulary is the
    /// protocol's; the mapping to a dot, a spinner, or a notification mirrors
    /// `applyStatusReport` arm for arm, so a session behaves the same whether
    /// its status came from a local hook or from the daemon.
    func applyTermiodStatus(_ report: Termiod.StatusPayload, for id: Session.ID) {
        guard session(id) != nil else { return }

        // Everything from here to the state switch used to sit behind the app's
        // own hook socket and reach only agents on this Mac. One report path
        // means a device agent gets it too.
        if let candidate = report.promptTitle {
            recordPromptTitle(candidate, for: id)
        }
        // The workstream title is the agent's own label for what it is doing.
        // It shares `liveTitle` with the OSC 0/2 channel — same field, last
        // writer wins — because both answer the same question about the row.
        if let title = report.title, !title.isEmpty { setLiveTitle(title, for: id) }

        // Remember the session's transcript address whenever a report carries it,
        // so `sessions send` can hand it back as the place to read the response.
        let carriedTranscript = report.transcriptPath.flatMap { $0.isEmpty ? nil : $0 }
        if let path = carriedTranscript {
            transcriptPaths[id] = path
        }
        // Conversation identity moves only at a turn boundary: a working-state
        // payload embeds prompt and tool content on stdin, where a colliding
        // field name could be mined as the id by mistake, while SessionStart and
        // Stop payloads are the agent's own minimal envelope.
        //
        // Whether the report named this session exactly is no longer checked.
        // The hook path had to, because a global socket left it matching by cwd;
        // a report now arrives addressed by the daemon that owns the PTY.
        if report.status != "working" {
            if let path = carriedTranscript {
                // A carried path can name a *new* conversation id in its filename
                // (after `/clear`), so advance the resume pin to match — a no-op
                // unless it actually rotated.
                reconcileResumeID(id, transcriptPath: path)
            }
            if let conversation = conversationToken(report.conversationID) {
                // An identity-bearing report names the live conversation outright.
                // On a rotation without a carried transcript, drop the stale path
                // that described the discarded conversation; the resolve below
                // re-learns it against the new pin.
                if adoptConversationID(conversation, for: id), carriedTranscript == nil {
                    transcriptPaths[id] = nil
                }
            } else if report.status == "done" {
                // Identity-blind turn end: for a discovered-id agent, re-scan its
                // store in case the conversation rotated in-process (`/new`).
                rediscoverConversation(for: id)
            }
        }
        if transcriptPaths[id] == nil, let path = resolveTranscriptPath(for: id) {
            // No report carried a path (a pre-hook Claude session never will), so
            // learn it from the agent's own on-disk transcript instead — same
            // result, just discovered.
            transcriptPaths[id] = path
        }

        // A host that is speaking for this session is exactly the condition the
        // screen-driven promotion stands down for (`hookQuietWindow`): the
        // precise signal outranks the heuristic that exists in its absence.
        if ["working", "idle", "needs_you", "done", "failed"].contains(report.status) {
            lastHookReportAt[id] = Date()
            // Any addressed report is the agent speaking — an agent that came
            // back and finished a turn reports done/idle without ever passing
            // through working — which outranks whatever the foreground sampler
            // concluded about its exit (§D2).
            agentExitStreaks[id] = nil
            if runtimes[id]?.agentExitNotice != nil { runtimes[id]?.agentExitNotice = nil }
        }
        // `done` and `idle` are the same fact seen from two sides, and which one
        // a row shows depends on whether *this* window is looking at it — the
        // one piece of status arbitration that stays with the viewer (device
        // architecture §4.1: selection is the viewer's). A `done` the agent
        // itself reported means done everywhere and is left alone; a turn the
        // device concluded from a screen, a title or a progress marker is judged
        // here.
        if report.turnEnded, report.status == "idle" {
            clearWorking(id)
            setStatus(isViewing(id) ? .idle : .done, for: id)
            return
        }
        switch report.status {
        case "working":
            // No "is this really an agent row?" guard, deliberately: an
            // addressed report is itself the proof an agent is running there.
            // Guarding would discard every status a remote agent sends, since a
            // remote row is a plain `.terminal` — the agent runs on the far
            // machine — and would drop a local one whenever the foreground poll
            // had not caught up yet.
            setStatus(.working, for: id)
            setCurrentTool(report.tool, for: id)
            // Remember when work was last seen, so a turn that ends abnormally
            // (the agent crashed and never sent `done`) can be swept back to calm
            // instead of spinning forever.
            lastWorkingAt[id] = Date()
        case "needs_you":
            // The agent is blocked waiting on the user. This is an observable
            // blocking condition, so its dot survives a click — but only when
            // the device says the condition has a resolving transition. A bell
            // does not, and gets a dot a click clears.
            clearWorking(id)
            if report.blocking ?? true {
                flagBlockingAttention(for: id)
            } else if !isViewing(id) {
                setStatus(.needsAttention, for: id)
            }
        case "done":
            // Always leave a "ready for you" green dot, even on the session the
            // user is looking at, so a finished agent stays on the menu-bar
            // roster instead of blinking off the instant it stops.
            clearWorking(id)
            setStatus(.done, for: id)
        case "idle":
            clearWorking(id)
            setStatus(.idle, for: id)
        case "failed":
            // Not `.done`: a green "ready for you" dot on a run that failed
            // reads as success. Not `flagBlockingAttention` either — a failure
            // has no resolving transition, so its dot should clear when the user
            // looks at the row, which is what a plain `.needsAttention` does.
            clearWorking(id)
            setStatus(isViewing(id) ? .idle : .needsAttention, for: id)
        default:
            // `unknown` is the daemon's default for a session nobody has
            // reported on. Writing it would overwrite what the local signals
            // worked out, so it is left alone.
            break
        }
    }

    // MARK: - Host-reported process facts

    /// Lands a roster push on the session's row.
    ///
    /// The host reports what the process *is*; what that means is decided here, by
    /// the same consumers the in-process PTY's kernel poll feeds, so a session
    /// behaves the same whether the syscalls ran in this process or on a VPS.
    ///
    /// Every absence stands down — "the device did not say" is not evidence, so a
    /// daemon too old to sample, or a process the kernel refused, must leave the
    /// row exactly as the screen-derived signals left it.
    /// - Parameters:
    ///   - identifiesAgent: whether this row's identity follows its foreground.
    ///     False for a declared agent, whose foreground is its own subprocess.
    ///   - followsWorkingDirectory: whether this row owns its cwd. A separate flag
    ///     rather than a consequence of the first, because the local producer gates
    ///     the two separately.
    func applyTermiodInformation(_ information: Termiod.SessionInformation,
                                 for id: Session.ID,
                                 identifiesAgent: Bool,
                                 followsWorkingDirectory: Bool) {
        guard session(id) != nil else { return }
        // The daemon's own id for the process behind this row, remembered so a
        // later close can journal it — the identity the roster sweep matches a
        // pending kill by (`journalClaims`).
        recordDaemonSessionID(information.id, for: id)
        // `nil` argv is *unanswered*, so it never reaches `noteForegroundAgent` —
        // which reads its own `nil` as "a shell is in front now" and demotes.
        // An answered argv that matches nothing is that demotion, correctly.
        if identifiesAgent, let argv = information.foregroundArgv {
            noteForegroundAgent(AgentCatalog.shared.agent(forForegroundArguments: argv), for: id)
        } else if !identifiesAgent {
            // A declared row's identity never follows its foreground, but its
            // *liveness* does (§D2): an agent that ran as a child of a shell that
            // didn't exec leaves no exit event when it quits, and the foreground
            // sampler reporting that shell is the only signal the agent is gone.
            noteDeclaredAgentForeground(information.foregroundArgv, for: id)
        }
        // The daemon's equivalent of the local kernel poll, landing in the same
        // place it does. (The shell's own OSC 7 reaches `noteWorkingDirectory`
        // ungated, from the surface — that channel is the program volunteering
        // where it is, which is a different thing from termio going and looking.)
        if followsWorkingDirectory, let cwd = information.childCwd, !cwd.isEmpty {
            noteWorkingDirectory(cwd, for: id)
        }
    }

    /// The wrapped-tree half of agent exit (RFC 20260830 §D2). A declared agent
    /// launched as `zsh -ilc "exec claude"` whose `exec` didn't replace the
    /// shell (a function or alias shim is enough) leaves the daemon session
    /// alive when the agent quits, so `applyTermiodExit` never fires. The
    /// foreground sampler reporting the login shell for a stable streak is that
    /// exit: the row transitions **in place** to idle with a notice saying what
    /// happened — tmux's `remain-on-exit` with a live shell. Identity is
    /// untouched: the row stays its declared agent and never re-files, and the
    /// promotion asymmetry (`identifiesAgent`) is unchanged.
    func noteDeclaredAgentForeground(_ argv: [String]?, for id: Session.ID) {
        guard let session = session(id), session.agent != .terminal, !session.isSSH else { return }
        var streak = agentExitStreaks[id] ?? AgentExitStreak()
        let verdict = streak.observe(foregroundArgv: argv)
        agentExitStreaks[id] = streak
        switch verdict {
        case .hold:
            break
        case .agentReturned:
            runtime(for: id).agentExitNotice = nil
        case .demote:
            clearWorking(id)
            setStatus(.idle, for: id)
            runtime(for: id).agentExitNotice =
                localized("\(session.agent.displayName) exited — shell")
        }
    }

    /// A daemon-hosted session's process is gone. Named rather than inlined in the
    /// link callback so the wiring from "the device said the binary moved" to "the
    /// pane relaunches" is reachable without a daemon.
    ///
    /// - Parameters:
    ///   - information: the device's final word, from the exit event. Never a
    ///     roster row — `childExecutableReplaced` is computed on the exit path,
    ///     and a poll that ran seconds earlier answers a different question.
    ///   - isAgentSession: snapshotted when the link was wired, so a row promoted
    ///     mid-life still exits as what it was launched as.
    /// The daemon answered and refused: a cwd that no longer exists, a rejected
    /// handshake, a spawn it would not perform.
    ///
    /// Not a lost connection — the daemon is right there — and not an exit,
    /// because nothing ever started. The distinction matters on screen: saying
    /// "the session is still running there" about a session that was never
    /// created would be a different lie from the one this path exists to fix.
    /// The daemon's own words are shown, since they name the cause.
    func applyTermiodStartRefused(for id: Session.ID, message: String,
                                  surface: InMemoryTerminalSession?) {
        termiodLinks[id] = nil
        Log.termiod.error("""
        \(id.uuidString, privacy: .public) was refused by the device: \
        \(message, privacy: .public)
        """)
        surface?.receive(Data((
            "\r\n\u{1B}[31m"
            + localized("This session couldn’t be started.")
            + "\u{1B}[0m\r\n" + message + "\r\n").utf8))
    }

    /// The transport died under a session that is still running.
    ///
    /// Deliberately not `applyTermiodExit`: no exit policy runs, because there
    /// was no exit — running it would park the pane over an error that does not
    /// exist, and for a plain terminal `.close` would take the row away while
    /// the shell it names is still alive on the device.
    ///
    /// The attachment is dropped, since it is dead, but nothing else about the
    /// session is: no tombstone, no status change, no row removal. Selecting
    /// the session again builds a fresh surface, and `attach` resolves the same
    /// name back to the same process.
    func applyTermiodConnectionLost(for id: Session.ID, surface: InMemoryTerminalSession?) {
        termiodLinks[id] = nil
        guard let session = session(id) else { return }
        let place = session.termiodRemoteHost ?? localized("this Mac")
        Log.termiod.error("""
        lost the connection to \(session.id.uuidString, privacy: .public) on \
        \(place, privacy: .public); the session keeps running there
        """)
        // Said on the screen the user is looking at, because a pane that simply
        // stops updating is indistinguishable from an agent that went quiet.
        surface?.receive(Data((
            "\r\n\u{1B}[33m"
            + localized("Lost the connection to \(place). The session is still running there.")
            + "\u{1B}[0m\r\n"
            + localized("Close the session and open it again to reattach.")
            + "\r\n").utf8))
    }

    func applyTermiodExit(for id: Session.ID,
                          code: Int32,
                          runtimeMilliseconds: UInt64,
                          information: Termiod.SessionInformation?,
                          isAgentSession: Bool,
                          isPlainTerminal: Bool,
                          surface: InMemoryTerminalSession?) {
        termiodLinks[id] = nil
        // The same policy the in-process PTY runs, on the same three inputs. The
        // self-update check is no longer missing here: the app cannot pin a
        // process it does not own, but the daemon that owns it can, and the exit
        // event carries its answer.
        let outcome = TermioStore.sessionExit(
            code: code,
            isAgentSession: isAgentSession,
            isPlainTerminal: isPlainTerminal,
            executableReplaced: information?.childExecutableReplaced == true)
        switch outcome {
        case .relaunch:
            relaunchSession(id)
            return
        case .revertToShell:
            revertSessionToShell(id)
            return
        case .close, .park:
            break
        }
        surface?.finish(exitCode: UInt32(bitPattern: code),
                        runtimeMilliseconds: runtimeMilliseconds)
        if outcome == .close {
            closeSession(id)
        }
    }

    // MARK: - Device identity

    /// Backfills the identity a handshake just revealed: everything reached over
    /// `route` runs on `device`, so record that on the sessions and containers
    /// that took it.
    ///
    /// This is the a-priori → a-posteriori transition. State is authored against
    /// an SSH alias because that is all the app has before it connects: a
    /// container must exist the instant a session is created, and most aliases in
    /// a `~/.ssh/config` have never been reached. The first `hello_ok` is the only
    /// moment that alias becomes a machine, and this is where the machine is
    /// written down.
    ///
    /// It does **not** merge two containers that turn out to be one device. That
    /// rule is specified in §9.5 of docs/design/20260805-termiod-device-architecture.md and
    /// left unexecuted on purpose — merging is a step to add once the identities
    /// are recorded, not a rewrite, and it must not happen before the conflict
    /// case (a cloned VM carrying a duplicate `host_id`) has an answer.
    func adoptDevice(_ device: TermiodDevice, forRoute route: TermiodRoute) {
        let alias = route.sshAlias
        for index in projects.indices {
            // A checkout recorded before checkouts were device-keyed sits under
            // the alias. Promote it the moment the alias resolves, so an old state
            // file keeps working and stops being old.
            if let alias, let legacy = projects[index].remoteCheckouts[alias],
               projects[index].remoteCheckouts[device.id] == nil {
                projects[index].remoteCheckouts[device.id] = legacy
                projects[index].remoteCheckouts[alias] = nil
            }
            // What the checkout itself is sitting on is not recorded here: a
            // project takes its machine from the workspace that owns it, and the
            // workspace loop below is where that is written down.
            for sessionIndex in projects[index].sessions.indices
            where projects[index].sessions[sessionIndex].termiodRemoteHost == alias
                && projects[index].sessions[sessionIndex].deviceID != device.id {
                projects[index].sessions[sessionIndex].deviceID = device.id
            }
        }
        for index in workspaces.indices {
            // A machine's fallback workspace keeps being matched by alias — that
            // is B's contract and it is untouched here. This only records what the
            // alias turned out to reach, which is what a later merge will read.
            if workspaces[index].deviceAlias == alias, workspaces[index].deviceID != device.id {
                workspaces[index].deviceID = device.id
            }
            for sessionIndex in workspaces[index].terminals.indices
            where workspaces[index].terminals[sessionIndex].termiodRemoteHost == alias
                && workspaces[index].terminals[sessionIndex].deviceID != device.id {
                workspaces[index].terminals[sessionIndex].deviceID = device.id
            }
        }
    }

    // MARK: - The current device's roster

    /// Asks the **current device** what is running on it, and publishes the answer.
    ///
    /// This is the only source of the session list a device's world is drawn from.
    /// It is a `list` over that device's own control channel — for this Mac a Unix
    /// socket, for anything else `ssh <alias> termiod stdio` — so the same code
    /// path serves every machine and this Mac is not a special case. What comes
    /// back includes sessions this app never opened, which is the difference
    /// between reading a device's state and filtering your own.
    ///
    /// Runs off the main thread (an SSH round trip is 216–292 ms cold) and drops
    /// its reply if the user has moved on to another device meanwhile.
    /// How long one device's answer stands in for the next ask. Long enough to
    /// absorb the several asks a single gesture makes, short enough that a user
    /// who switches deliberately gets a fresh list.
    private static let rosterCoalescingWindow = Duration.milliseconds(500)

    func refreshDeviceSessions() {
        let span = Trace.device.begin("roster request")
        defer { Trace.device.end(span) }
        let device = currentDevice
        let route = device.route
        let key = route.description

        // One workspace switch asks this device the same question twice: moving
        // the selection follows the session onto its machine, and then the switch
        // enters the machine's own fallback workspace. Both are right, and
        // neither can see the other, so the second ask is dropped here — the one
        // already in flight is for this same route and its reply is still
        // wanted, which is why the generation is deliberately not bumped.
        //
        // A reply that landed a moment ago counts too, but only while the
        // published answer is still that route's: after switching away and back
        // the screen holds another machine's sessions, and reusing the timestamp
        // would leave them there under this machine's name.
        let fetch = rosterFetches[key] ?? RosterFetch()
        let settledRecently = fetch.settledAt.map {
            $0.duration(to: .now) < Self.rosterCoalescingWindow
        } ?? false
        if fetch.inFlight
            || (settledRecently && deviceSessionsRoute == key && deviceSessions.sessions != nil) {
            Trace.device.report("roster coalesced", "route=\(key)", since: span.started)
            return
        }

        let persistedNames = Set(projects.flatMap { project in
            project.sessions.map(daemonSessionName(for:))
        })
        deviceSessionsGeneration += 1
        let generation = deviceSessionsGeneration
        rosterFetches[key, default: RosterFetch()].inFlight = true
        // Only when there is nothing of this machine's to show. A switch back to
        // a device whose roster is already on screen keeps it there for the
        // length of the round trip rather than blanking the column to a spinner
        // and filling it back in with the same rows.
        if deviceSessionsRoute != key || deviceSessions.sessions == nil {
            deviceSessions = .loading
        }
        let requested = ContinuousClock.now
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<Termiod.SessionsPayload, Error> = Trace.device.measure(
                "roster fetch", "route=\(route.description)"
            ) {
                do {
                    return .success(try Termiod.roster(route: route))
                } catch {
                    return .failure(error)
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Field by field: replacing the whole record here would drop
                    // the cached answer this route is about to be compared with.
                    self.rosterFetches[key, default: RosterFetch()].inFlight = false
                    self.rosterFetches[key, default: RosterFetch()].settledAt = .now
                    // The counter drops a reply from a device the user has left.
                    // The route is the second half of that question and the one
                    // that survives coalescing: an ask that stood down behind
                    // this request bumped no counter, so the counter can name a
                    // later request while this reply is still the right answer
                    // for the machine on screen. Only one request per route is
                    // ever out, so there is no older reply to overtake a newer.
                    guard self.deviceSessionsGeneration == generation
                        || self.currentDevice.route.description == key else {
                        Trace.device.report("roster dropped", "route=\(key)", since: requested)
                        return
                    }
                    Trace.device.report("roster round trip", "route=\(key)", since: requested)
                    self.applyRoster(outcome, from: device, route: route,
                                     persisted: persistedNames)
                }
            }
        }
    }

    private func applyRoster(
        _ outcome: Result<Termiod.SessionsPayload, Error>,
        from device: KnownDevice,
        route: TermiodRoute,
        persisted: Set<String>
    ) {
        let span = Trace.device.begin("roster apply")
        defer { Trace.device.end(span) }
        let key = route.description
        switch outcome {
        case .failure(let error):
            let message = error.localizedDescription
            // A daemon this app asked to stop is between builds, not gone. The
            // column keeps its spinner; the loop refreshes it when it is done.
            if upgradingRoutes.contains(key) {
                deviceSessions = .loading
                deviceSessionsRoute = key
                return
            }
            // The last good answer is no longer this device's answer, so it
            // cannot stand in for the next reply: a machine that comes back must
            // repaint even if it comes back holding exactly what it held before.
            rosterFetches[key]?.answer = nil
            // An unreachable machine fails the same way every time it is asked.
            // Saying so once is the report; saying so on every switch is noise
            // in the log and a sidebar rebuild for news that hasn't changed.
            if case .failed(message) = deviceSessions, deviceSessionsRoute == key {
                Trace.device.report("roster unchanged", "route=\(key)", since: span.started)
                return
            }
            deviceSessions = .failed(message)
            deviceSessionsRoute = key
            Log.termiod.error("""
            roster of \(key, privacy: .public) failed: \
            \(message, privacy: .public)
            """)
        case .success(let payload):
            let live = payload.sessions.filter(\.alive)
            let answer = DeviceSessions(live: live, tombstones: payload.tombstones)
            let unchanged = rosterFetches[key]?.answer == answer
            rosterFetches[key, default: RosterFetch()].answer = answer
            // The graveyard is the other half of the answer, and the half that
            // explains an empty list. Recorded before anything reads the rows so
            // `termiodEndReason` is populated by the time the sidebar asks why a
            // row it restored has no session behind it.
            recordTombstones(payload.tombstones, live: live, persisted: persisted)
            // Settled on every successful refresh, before the unchanged guard: a
            // pending kill whose first attempt failed leaves the roster looking
            // exactly as it did, and that is precisely when it must be retried.
            reconcileExternalSessions(live, from: device, route: route)
            // Published only when it would say something different. The sidebar
            // rebuilds on every publish, and a device that answers what it
            // answered last time — a switch back into a machine nothing has
            // happened on — should cost nothing.
            if deviceSessionsRoute != key || deviceSessions.sessions != answer {
                deviceSessions = .ready(answer)
                deviceSessionsRoute = key
            }
            // Everything below writes to the tree or to the log, and an identical
            // answer has nothing to write: the alias already resolved to this
            // machine, and repeating the roster line by line buries the changes
            // that matter under the ones that don't.
            guard !unchanged else {
                Trace.device.report("roster unchanged", "route=\(key)", since: span.started)
                return
            }
            // The handshake `roster` just performed recorded this route's device;
            // naming it here is the visible proof that the app knows *which
            // machine* it is talking to, not just a socket.
            if let identified = TermiodDeviceRegistry.shared.device(for: route) {
                adoptDevice(identified, forRoute: route)
                Log.termiod.info("""
                device \(identified.id, privacy: .public) \
                running \(identified.daemonVersion, privacy: .public) \
                reachable via \(route.description, privacy: .public); \
                known routes: \
                \(identified.routes.map(\.description).joined(separator: ", "), privacy: .public)
                """)
            }
            for information in live {
                let verdict = persisted.contains(information.name)
                    ? "has a row here" : "opened elsewhere"
                Log.termiod.info("""
                live session on \(device.name, privacy: .public): \
                name=\(information.name, privacy: .public) \
                pid=\(information.pid, privacy: .public) \
                status=\(information.status, privacy: .public) — \
                \(verdict, privacy: .public)
                """)
            }
            if live.isEmpty {
                Log.termiod.info("no live sessions on \(device.name, privacy: .public)")
            }
        }
    }

    // MARK: - Tombstones

    /// Files the daemon's graveyard, and says out loud what happened to any row
    /// this app restored whose session did not survive.
    ///
    /// Merged rather than replaced, because each device buries its own dead and a
    /// switch must not erase what the machine you just left told you. A name that
    /// came back **live** in this reply loses its tombstone: the session was
    /// restarted under the same name, so the grave is stale.
    ///
    /// Only names that map to a session this app knows are kept — another
    /// client's sessions are not this app's story to tell, and the host caps the
    /// list at 100 anyway.
    func recordTombstones(
        _ tombstones: [Termiod.SessionTombstone],
        live: [Termiod.SessionInformation],
        persisted: Set<String>
    ) {
        for information in live { termiodTombstones[information.name] = nil }
        let liveNames = Set(live.map(\.name))
        // Newest first, so the first tombstone for a name is the one to keep.
        for tombstone in tombstones.reversed()
        where persisted.contains(tombstone.name) && !liveNames.contains(tombstone.name) {
            // A grave that is already filed is not news. Without this, every
            // roster reply repeats the whole graveyard into the log.
            guard termiodTombstones[tombstone.name] != tombstone else { continue }
            termiodTombstones[tombstone.name] = tombstone
            Log.termiod.info("""
            termiod session name=\(tombstone.name, privacy: .public) ended: \
            \(tombstone.reason, privacy: .public) \
            (status \(tombstone.status, privacy: .public), \
            exit \(tombstone.exitStatus.map(String.init) ?? "unknown", privacy: .public))
            """)
        }
    }

    // MARK: - Adopting a session the device already had

    /// The daemon handle a roster row is addressed by — its name, or its id for
    /// the rare row without one.
    nonisolated static func daemonKey(_ information: Termiod.SessionInformation) -> String {
        information.name.isEmpty ? information.id : information.name
    }

    /// Takes a session the **device** reports but this app has no row for, and
    /// gives it one — unprompted, from the roster sweep (§D3). A session started
    /// from `termiod` on the box, or left behind by another install that quit,
    /// is a session on that device, and a viewer of that device should reach it
    /// as an ordinary row. The row keeps the name the device gave it
    /// (`termiodSessionName`) instead of being renamed to a fresh uuid, because
    /// the name is how the daemon is asked for that exact PTY.
    ///
    /// Filed in the project whose checkout on this device contains its cwd, else
    /// as a loose terminal — the machine's fallback workspace for another
    /// device, the current workspace's Terminals for this Mac. The selection is
    /// deliberately not moved: nobody clicked anything.
    func adoptDeviceSession(_ information: Termiod.SessionInformation, on device: KnownDevice) {
        var session = Session(title: information.displayLabel, agent: .terminal)
        session.givenTitle = information.givenName
        session.termiodSessionName = Self.daemonKey(information)
        session.termiodDaemonID = information.id.isEmpty ? nil : information.id
        session.termiodRemoteHost = device.alias
        session.deviceID = device.deviceID
        session.termiodRemoteCwd = information.cwd.isEmpty ? nil : information.cwd
        if let projectIndex = adoptionProjectIndex(forCwd: information.cwd, on: device) {
            projects[projectIndex].sessions.append(session)
            return
        }
        let workspaceID = device.alias.map { deviceWorkspace(for: $0, deviceID: device.deviceID) }
            ?? currentWorkspace.id
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            Log.termiod.error("""
            adopting \(information.name, privacy: .public) found no workspace to file it under
            """)
            return
        }
        workspaces[index].terminals.append(session)
    }

    /// The project an adopted session files under: the one whose root **on the
    /// adopting device** contains the session's cwd, deepest root winning when
    /// checkouts nest. Roots are read per device — a local project answers with
    /// its path and worktrees, a project cloned to the device with its recorded
    /// checkout — because matching a device's cwd against another machine's
    /// paths is how a row lands in the wrong repo.
    private func adoptionProjectIndex(forCwd cwd: String, on device: KnownDevice) -> Int? {
        guard !cwd.isEmpty else { return nil }
        var best: (index: Int, rootLength: Int)?
        for (index, project) in projects.enumerated() {
            let projectWorkspace = workspaces.first { $0.id == project.workspaceID }
            var roots: [String] = []
            if device.isLocal {
                // A project filed under a machine's workspace names a path over
                // there, not here.
                guard projectWorkspace?.deviceAlias == nil else { continue }
                roots.append(project.path)
                roots.append(contentsOf: project.worktrees.map(\.path))
            } else if let alias = device.alias {
                if let checkout = project.remoteCheckout(device: device.deviceID, alias: alias) {
                    roots.append(checkout)
                }
                if projectWorkspace?.deviceAlias == alias {
                    roots.append(project.path)
                }
            }
            for root in roots where Self.path(cwd, isInside: root) {
                if root.count > (best?.rootLength ?? -1) {
                    best = (index, root.count)
                }
            }
        }
        return best?.index
    }

    /// Whether `path` is `root` itself or lives under it, by whole path
    /// components — `/code/termio-worktrees` is not inside `/code/termio`.
    nonisolated static func path(_ path: String, isInside root: String) -> Bool {
        guard !root.isEmpty, !path.isEmpty else { return false }
        let standardizedPath = (path as NSString).standardizingPath
        let standardizedRoot = (root as NSString).standardizingPath
        if standardizedPath == standardizedRoot { return true }
        let prefix = standardizedRoot.hasSuffix("/") ? standardizedRoot : standardizedRoot + "/"
        return standardizedPath.hasPrefix(prefix)
    }

    // MARK: - Name-addressed destroy (RFC 20260830 §D1)

    /// Destroys a session's daemon side. The `(daemon name, route)` pair is the
    /// destroy capability; the link is a live attachment — an optimization,
    /// never a prerequisite — so a row restored after relaunch, closed from the
    /// CLI or the phone without ever rendering, or torn down after the exit /
    /// connection-lost paths nil'd its link, still kills the process it names.
    ///
    /// `rememberClosed` writes the name into the closed-session journal first,
    /// which is what makes the kill durable: an unreachable route or a crash
    /// between the journal write and the kill is settled by the next roster
    /// sweep for that route (`reconcileExternalSessions`). A respawn-in-place
    /// passes `false` — it reuses the same daemon name, and a journaled name
    /// would have the sweep kill the replacement.
    func destroyDaemonSession(for session: Session, rememberClosed: Bool) {
        let name = daemonSessionName(for: session)
        if rememberClosed {
            journalClosedSession(
                named: name, sshAlias: session.termiodRemoteHost, deviceID: session.deviceID,
                daemonID: session.termiodDaemonID)
        }
        if let link = termiodLinks[session.id] {
            link.killAndClose()
        } else {
            Termiod.killSession(
                target: name, route: TermiodRoute(sshAlias: session.termiodRemoteHost))
        }
        termiodLinks[session.id] = nil
    }

    /// How many closed-session records are kept. Far above what a session tree
    /// can hold; the bound only stops a pathological state file from growing
    /// without limit.
    private static let closedSessionJournalCapacity = 200

    /// Records a destroyed daemon session, newest last, evicting the oldest
    /// past capacity. One record per `(name, sshAlias)` — re-closing on the
    /// same route replaces rather than duplicates, and a same-named session on
    /// another machine keeps its own record.
    func journalClosedSession(
        named name: String, sshAlias: String?, deviceID: String? = nil, daemonID: String? = nil
    ) {
        closedSessionJournal.removeAll { $0.name == name && $0.sshAlias == sshAlias }
        closedSessionJournal.append(ClosedDaemonSession(
            name: name, sshAlias: sshAlias, deviceID: deviceID, daemonID: daemonID))
        if closedSessionJournal.count > Self.closedSessionJournalCapacity {
            closedSessionJournal.removeFirst(
                closedSessionJournal.count - Self.closedSessionJournalCapacity)
        }
        persistSoon()
    }

    /// Clears a name from the closed-session journal, on its own route only —
    /// a session attached (or respawned) under a name is proof the name is
    /// live again on that machine, which outranks a close recorded before it.
    /// Another machine's same-named record still describes *its* close.
    func forgetClosedSession(named name: String, sshAlias: String?) {
        let before = closedSessionJournal.count
        closedSessionJournal.removeAll { $0.name == name && $0.sshAlias == sshAlias }
        if closedSessionJournal.count != before { persistSoon() }
    }

    // MARK: - External sessions (RFC 20260830 §D3)

    /// What becomes of one live daemon session this app has no row for.
    enum ExternalSessionResolution: Equatable {
        /// The name is in the closed-session journal: this app's own orphan —
        /// D1 should have killed it, so kill it now.
        case killOnSight
        /// Attached, unknown, **on this Mac**: a second install's live session,
        /// not ours to claim.
        case leaveAlone
        /// Unknown and adoptable: give it a row.
        case adopt
    }

    /// The §D3 verdict for a roster row no current row accounts for. Pure so the
    /// resolution is testable without a daemon or a roster.
    ///
    /// `journaled` is this route's record for the row's name, if one exists —
    /// and it claims the row only when the daemon ids agree (`journalClaims`).
    /// A same-named row with a different id is legitimate name reuse, resolved
    /// like any other stranger.
    ///
    /// The attached-client guard is local-only, deliberately: the local socket
    /// is per-uid, so an attached unknown here is another install's session.
    /// Attachment itself is read-many by design (single writer, many readers),
    /// so on a remote device it is no evidence of foreign ownership — the
    /// roster is that box's whole sidebar, and a session the phone has open is
    /// still one of the box's own sessions; skipping it would hide its work.
    nonisolated static func resolveExternalSession(
        name: String, rowID: String, attachedClients: Int, isLocal: Bool,
        journaled: ClosedDaemonSession?
    ) -> ExternalSessionResolution {
        if let journaled, journalClaims(journaled, rowID: rowID) {
            return .killOnSight
        }
        if isLocal, attachedClients > 0 { return .leaveAlone }
        return .adopt
    }

    /// Whether a journal record describes this roster row, or the row merely
    /// reuses the name. The daemon mints a fresh id per creation and never
    /// reuses one, so identity — not any clock — is the gate: a matching id is
    /// the very session the close named; a different id under the same name is
    /// a new session the close never promised to end.
    ///
    /// A record without an id (the app closed the row before any attach or
    /// roster revealed one) may match by name **only when the name is
    /// app-authored — a UUID**. Nothing else mints those, and the app's own
    /// respawn-in-place path doesn't journal, so a UUID name-match cannot hit
    /// anyone else's session. An id-less record with a device-given name
    /// ("build") proves nothing about which same-named session it meant, so it
    /// never claims: safety over kill when identity is unproven. The sweep then
    /// drops the record, and if a true orphan resurfaces it is re-adopted —
    /// whose close journals *with* the id, so the miss converges.
    nonisolated static func journalClaims(
        _ record: ClosedDaemonSession, rowID: String
    ) -> Bool {
        guard let daemonID = record.daemonID else {
            return UUID(uuidString: record.name) != nil
        }
        return daemonID == rowID
    }

    /// Settles every live daemon session against this app's rows, once per
    /// successful roster refresh: journaled names are killed on sight (the
    /// belt-and-braces that makes D1's close hold across crashes and offline
    /// routes), unknown sessions are adopted into ordinary rows, and — on this
    /// Mac only — an attached unknown is left alone as a second install's live
    /// session.
    ///
    /// A journal record belongs to this sweep when its alias matches the route
    /// **or** its device matches the machine the route resolved to — the alias
    /// half is how records written before a handshake settle, the device half
    /// is how a close made via `prod-old` still lands when the box is reached
    /// as `prod-new`. A record is dropped once it stops claiming anything on
    /// its machine: its name left the roster (the kill held, or the session
    /// died), or the name lives on under a different daemon id (name reuse —
    /// not ours, and killing it would murder someone else's session; the
    /// record's own id is gone for good, so it can never claim again).
    /// Records for other machines are untouched.
    func reconcileExternalSessions(
        _ live: [Termiod.SessionInformation], from device: KnownDevice, route: TermiodRoute
    ) {
        // The identity is re-read, not taken from the captured device: on the
        // first refresh through a new alias the capture predates the handshake
        // this very roster performed, and matching rows by the stale identity
        // would read every session authored under the machine's other aliases
        // as strangers — and adopt duplicates of them.
        let device = KnownDevice(
            alias: device.alias,
            deviceID: device.deviceID ?? TermiodDeviceRegistry.shared.deviceID(for: route))
        let sweepRecords = closedSessionJournal.filter { record in
            record.sshAlias == route.sshAlias
                || (record.deviceID != nil && record.deviceID == device.deviceID)
        }
        recordDaemonIDs(from: live, for: device)
        var claimingRecords = Set<ClosedDaemonSession>()
        for information in deviceOnlySessions(in: live, for: device) {
            let name = Self.daemonKey(information)
            let record = sweepRecords.first { $0.name == name }
            switch Self.resolveExternalSession(
                name: name, rowID: information.id,
                attachedClients: information.attachedClients,
                isLocal: device.isLocal, journaled: record) {
            case .killOnSight:
                if let record { claimingRecords.insert(record) }
                Log.termiod.info("""
                killing journaled session \(name, privacy: .public) still live on \
                \(route.description, privacy: .public)
                """)
                Termiod.killSession(target: name, route: route)
            case .leaveAlone:
                break
            case .adopt:
                adoptDeviceSession(information, on: device)
            }
        }
        // A record is kept only while it still claims a live row — the kill
        // above may fail and must be retried. Everything else this sweep could
        // see has done its job: the name is gone, or it names a session the
        // close never promised to end.
        let spent = Set(sweepRecords).subtracting(claimingRecords)
        if !spent.isEmpty {
            closedSessionJournal.removeAll { spent.contains($0) }
            persistSoon()
        }
    }

    /// Records the daemon's own id for a row — the identity the closed-session
    /// journal matches a pending kill by (`journalClaims`). The one seam every
    /// channel that reveals the id lands on: the attach reply, the information
    /// events, and the roster pass below.
    func recordDaemonSessionID(_ daemonID: String, for id: Session.ID) {
        guard !daemonID.isEmpty, let session = session(id),
              session.termiodDaemonID != daemonID else { return }
        updateSession(id) { $0.termiodDaemonID = daemonID }
    }

    /// Writes the daemon's own id onto every row the roster answers for, so a
    /// later close can journal it. This is what arms the sweep's identity gate
    /// for rows that are never surfaced this run — a restored row closed
    /// without ever being selected has no link to learn the id from, and the
    /// roster is the one channel that still names it.
    private func recordDaemonIDs(from live: [Termiod.SessionInformation], for device: KnownDevice) {
        let mine = sessions(authoredFor: device)
        guard !mine.isEmpty else { return }
        var idsByName: [String: String] = [:]
        for information in live where !information.id.isEmpty {
            idsByName[Self.daemonKey(information)] = information.id
        }
        for session in mine {
            guard let daemonID = idsByName[daemonSessionName(for: session)] else { continue }
            recordDaemonSessionID(daemonID, for: session.id)
        }
    }

    // MARK: - Remote terminals (per-session SSH host)

    /// Opens a **remote terminal** on `host`: a `.terminal` session whose termiod
    /// link runs on that SSH box (`session.termiodRemoteHost`), so the shell lives
    /// on the remote and the Mac attaches over `ssh <host> termiod stdio`. Unlike
    /// `addSSHSession` (a plain `ssh <host>` in a *local* PTY), this is the durable
    /// termiod path — detach-not-kill and snapshot repaint carry across the network.
    ///
    /// The whole feature depends on the opt-in daemon backend, so with the flag off
    /// it surfaces a clear message rather than silently opening a broken pane. The
    /// remote must have `termiod` installed; `ensureRemoteReady` deploys it if
    /// missing (off the main thread, with progress) before the session is created —
    /// otherwise the first `termiod stdio` over SSH would fail and the pane would
    /// sit dead.
    ///
    /// `cwd` (used by "Clone to <device>…") is the remote directory the shell spawns
    /// in; `title` overrides the sidebar label (the host alias by default, or a repo
    /// name for a clone) for a session that lands in a machine's own workspace. A
    /// session that lands under a project takes that project's own naming instead —
    /// see `createRemoteTerminalSession`.
    func addRemoteTerminal(
        host: String,
        cwd: String? = nil,
        title: String? = nil,
        project projectID: UUID? = nil
    ) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }

        // The checkout is resolved *after* readiness, not before, because it is
        // keyed by device and only the handshake knows which device this alias
        // reaches. Deciding from the alias is the bug the device model exists to
        // remove: the same clone, reached over `vps-wan` instead of `vps-lan`,
        // would read as "not cloned yet".
        ensureRemoteReady(host: host) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.presentRemoteSetupFailure(host: host, message: error.message)
            case .success(let device):
                var cwd = cwd
                // Opened from a project row: the user means "this repo, on that
                // machine". The local path doesn't exist over there, so the only
                // honest answer is the checkout `Clone to <device>…` recorded.
                // Without one, say so rather than silently dropping a `$HOME`
                // shell into the Terminals bucket — that mismatch between where
                // you clicked and what you got is exactly the confusion this
                // replaces.
                if let projectID, let project = self.projects.first(where: { $0.id == projectID }) {
                    guard let checkout = project.remoteCheckout(device: device.id, alias: host)
                    else {
                        self.presentRemoteCheckoutMissing(host: host, project: project.name)
                        return
                    }
                    cwd = checkout
                }
                self.createRemoteTerminalSession(
                    host: host, device: device.id, cwd: cwd, title: title, project: projectID
                )
            }
        }
    }

    /// The project has never been cloned to this device, so there is nothing to
    /// `cd` into. Name the action that would fix it.
    private func presentRemoteCheckoutMissing(host: String, project: String) {
        let alert = NSAlert()
        alert.messageText = "\(project) isn't on \(host) yet"
        alert.informativeText =
            "Use \"Clone to \(host)…\" first. Termio then remembers where the "
            + "clone lives and opens future terminals on \(host) inside it."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Creates the remote `.terminal` session under the machine it runs on — that
    /// machine's fallback workspace — tagging it with the per-session remote host +
    /// cwd that `makeTermiodLink` threads through.
    ///
    /// Filed by machine, unlike the plain `ssh` shell `addSSHSession` opens: this
    /// process really does live on the box and outlive the connection to it, so the
    /// workspace holding it is telling the truth about where its work is.
    private func createRemoteTerminalSession(
        host: String,
        device deviceID: String,
        cwd: String?,
        title: String?,
        project projectID: UUID? = nil
    ) {
        var session = Session(title: title ?? host, agent: .terminal)
        session.termiodRemoteHost = host
        // Known up front here, unusually: the session is only created once
        // readiness has already shaken hands with the machine. Every other session
        // learns its device on first attach.
        session.deviceID = deviceID
        session.termiodRemoteCwd = cwd
        // Selecting it below is what enters the machine (see the selection's
        // `didSet`), so a terminal opened on another device never lands in a world
        // the window is not showing.

        // A remote terminal opened from a project belongs to that project — the
        // row you clicked is the row it appears under, wherever it runs, and the
        // row's device mark is what says it is elsewhere. Everything else belongs
        // to the machine's own fallback workspace, so a remote session is never
        // filed among the loose local shells.
        if let projectID, let index = projects.firstIndex(where: { $0.id == projectID }) {
            // Named exactly like a local project's terminals (`addSession`), because
            // the header above the row already names the repo and the row's device
            // mark already names the machine — repeating both back as the label
            // (`boxlit · ukvps`) said nothing the row wasn't saying, and it pinned
            // the label: a composed name that isn't the auto convention reads as one
            // the user chose, so the row could never become `Claude Code` and then
            // follow the agent's own title the way its local twin does.
            let count = projects[index].sessions.filter { $0.agent == .terminal }.count
            session.title = "Terminal \(count + 1)"
            projects[index].sessions.append(session)
            selectedSessionID = session.id
            return
        }

        let workspaceID = deviceWorkspace(for: host, deviceID: deviceID)
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        // The workspace is already named for the machine, so an unnamed session
        // numbers itself like any other terminal instead of repeating the machine
        // name down the column (`ukvps ▸ ukvps`).
        if title == nil {
            let count = workspaces[index].terminals.filter { $0.agent == .terminal }.count
            session.title = "Terminal \(count + 1)"
        }
        workspaces[index].terminals.append(session)
        selectedSessionID = session.id
    }

    /// A remote-setup outcome carrying a human message on failure (host
    /// unreachable, deploy failed) so the caller can show exactly what went wrong.
    /// Success carries the **device** that answered: readiness and identity are
    /// learned by the same handshake, so a caller never has to ask twice.
    enum RemoteSetupResult {
        case success(TermiodDevice)
        case failure(RemoteSetupError)
    }

    struct RemoteSetupError {
        /// The states the lifecycle loop can leave a machine in short of ready
        /// (RFC §8). `staged` is the one that is not a fault: the binary is in
        /// place and takes over once the sessions named in `message` close.
        enum State {
            case unreachable, staged, unhealthy, failed
        }
        let state: State
        let message: String
    }

    /// Ensures `host` runs the `termiod` this app ships before an attach, by
    /// running the daemon's own lifecycle loop against it (`termiod deploy
    /// --host`): observe, stage the binary if older, stop the old daemon if it
    /// is idle, verify the new one answers, roll back if it does not. Runs off
    /// the main thread with a borderless "Setting up host…" HUD; `completion`
    /// fires back on the main queue.
    func ensureRemoteReady(host: String, completion: @escaping (RemoteSetupResult) -> Void) {
        let hud = RemoteSetupHUD(message: "Setting up \(host)…")
        hud.show()
        // While the loop may have the daemon down, a failed roster is the restart
        // in progress, not an unreachable machine (RFC §5.5).
        let route = TermiodRoute.ssh(host)
        upgradingRoutes.insert(route.description)
        // Only the probe leaves the main actor. `completion` is the caller's
        // closure and captures main-actor state, so it must never be sent to
        // another isolation domain — it is called here, where it was formed.
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.performRemoteReadyCheck(host: host)
            }.value
            hud.dismiss()
            guard let self else { return }
            self.upgradingRoutes.remove(route.description)
            // Whatever the caller does next, the alias has now resolved to a
            // machine — write that down before handing back, so state keyed by
            // device is addressable by the time it is read.
            if case .success(let device) = result {
                self.adoptDevice(device, forRoute: route)
            }
            if self.currentDevice.route == route {
                self.refreshDeviceSessions()
            }
            completion(result)
        }
    }

    /// The same check without the HUD, for a caller that already shows its own
    /// progress — Settings ▸ Machines runs it as the first rung of "Set up this
    /// device", where a borderless panel over the preferences window would be
    /// chrome fighting chrome.
    ///
    /// `static` because it touches nothing on the store: the device a successful
    /// check reveals is handed back rather than adopted here, so a caller that is
    /// only *inspecting* a machine does not silently rewrite the registry.
    ///
    /// `force` stops the old daemon even while its sessions have work in
    /// progress — the pane's "Update Anyway", offered with those sessions named.
    static func remoteReadyCheck(host: String, force: Bool = false) async -> RemoteSetupResult {
        await Task.detached(priority: .userInitiated) {
            performRemoteReadyCheck(host: host, force: force)
        }.value
    }

    /// The blocking half of `ensureRemoteReady`, run off-main: one process, one
    /// JSON document. The loop itself lives in the daemon (`lifecycle.rs`) so
    /// that every state a machine can be in is decided by the binary that also
    /// runs on the machine; this side only turns the report into a sentence.
    /// `nonisolated` because it is invoked from a background queue and touches
    /// only process primitives — never `TermioStore`'s main-actor state.
    private nonisolated static func performRemoteReadyCheck(
        host: String, force: Bool = false
    ) -> RemoteSetupResult {
        let localBinary = Termiod.daemonBinaryPath()
        guard FileManager.default.isExecutableFile(atPath: localBinary) else {
            return .failure(RemoteSetupError(
                state: .failed,
                message: "The termiod binary to deploy wasn't found at \(localBinary)."))
        }
        // The `remote` spelling, not `deploy --host`: the top-level twin is
        // deprecated and warns on stderr, which this side reads as a diagnosis.
        var arguments = ["remote", "deploy", host, "--json"]
        if force { arguments.append("--force") }
        guard let run = runProcess(localBinary, arguments) else {
            return .failure(RemoteSetupError(
                state: .failed, message: "Couldn't run termiod deploy."))
        }
        let report: Termiod.LifecycleReport
        do {
            report = try Termiod.LifecycleReport.decode(Data(run.standardOutput.utf8))
        } catch {
            // No report means the loop never ran to a state: the binary could
            // not start, or died. Its last words are the diagnosis.
            let detail = run.standardError
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .last(where: { !$0.isEmpty }) ?? "termiod deploy exited \(run.exitCode)"
            return .failure(RemoteSetupError(
                state: .failed, message: "Couldn't set up termiod on \(host).\n\(detail)"))
        }
        switch report.state {
        case .current:
            guard let hostID = report.hostId, let version = report.version else {
                return .failure(RemoteSetupError(
                    state: .failed,
                    message: "termiod on \(host) answered without saying which machine it is."))
            }
            return .success(TermiodDevice(
                id: hostID, daemonVersion: version, routes: [.ssh(host)], lastSeen: Date()))
        case .staged:
            // Named, not counted. "1 session" is a number the user cannot act
            // on: whether to interrupt it depends entirely on what it is doing,
            // and only the name and the command answer that.
            let names = (report.busy ?? [])
                .map { "• \($0.label)" }
                .joined(separator: "\n")
            return .failure(RemoteSetupError(
                state: .staged,
                message: "termiod \(report.desired) is ready on \(host) and takes over once "
                    + "this finishes:\n\(names)\n"
                    + "Update Anyway stops it now."))
        case .unhealthy:
            let rolledBack = report.rolledBack == true
                ? "\nThe previous termiod is back in place." : ""
            return .failure(RemoteSetupError(
                state: .unhealthy,
                message: "Updated termiod on \(host), but the new one didn't answer.\n"
                    + "\(report.message ?? "")\(rolledBack)"))
        case .unreachable:
            return .failure(RemoteSetupError(
                state: .unreachable,
                message: "Couldn't reach \(host) over SSH.\n\(report.message ?? "")"))
        case .failed:
            return .failure(RemoteSetupError(
                state: .failed,
                message: "Couldn't set up termiod on \(host).\n\(report.message ?? "")"))
        }
    }

    /// A captured subprocess result — exit code plus drained stdout/stderr.
    private struct ProcessOutput {
        let exitCode: Int32
        let standardOutput: String
        let standardError: String
    }

    /// Runs `executable args`, draining both pipes before waiting so neither can
    /// deadlock on a full buffer. `nil` only when the process couldn't launch.
    /// `nonisolated` so the off-main `performRemoteReadyCheck` can call it.
    private nonisolated static func runProcess(_ executable: String, _ args: [String]) -> ProcessOutput? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return nil }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessOutput(
            exitCode: process.terminationStatus,
            standardOutput: String(data: outData, encoding: .utf8) ?? "",
            standardError: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// A remote setup/clone failure, shown verbatim so the cause (unreachable,
    /// auth, deploy) is visible rather than a silently dead pane.
    func presentRemoteSetupFailure(host: String, message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't set up \(host)"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Clone to a device

    /// Where a finished remote clone is filed.
    ///
    /// The two cases differ in *when* the project exists. `Clone to <device>…`
    /// starts from a row that is already in the sidebar and only records the
    /// correspondence; `Open Project ▸ <device> ▸ Clone…` has no row yet, and can't
    /// make one up front — the clone's absolute path on the far machine is only
    /// known once `git clone` has run and reported it, and a project row pointing
    /// at a directory nobody has confirmed is the guess this avoids.
    enum RemoteCloneDestination {
        /// A project already in the tree: the clone is recorded as its checkout on
        /// that machine.
        case existing(Project.ID)
        /// A project made from the clone itself. It is filed by `addRemoteProject`,
        /// in a workspace on the machine the clone landed on — a checkout takes its
        /// machine from its workspace, so the destination is not the caller's to
        /// name.
        case new(name: String)
    }

    /// Clones a project's `origin` **onto** `host` (git clone runs on the remote,
    /// not an rsync from the Mac — decided with the user), then opens a remote
    /// terminal inside the freshly cloned directory. The clone is `ssh <host> 'git
    /// clone <url> <name>'`, so the remote needs git and credentials for that
    /// origin; a non-zero exit surfaces the remote's stderr verbatim (auth failure,
    /// "already exists", …). If the local branch is ahead of its upstream those
    /// commits won't be on the remote clone, so the user is warned first.
    ///
    /// `info` comes from `GitService.cloneInfo` (origin URL, derived repo name,
    /// unpushed count). The whole feature is the termiod backend, so the flag-off
    /// case explains instead of opening a dead pane.
    func cloneOnRemote(
        host: String,
        info: GitService.CloneInfo,
        into destination: RemoteCloneDestination? = nil
    ) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }

        // Unpushed commits live only on this Mac and won't be in a fresh clone —
        // warn before we clone what the remote can actually see, so the divergence
        // isn't a silent surprise. `nil` (no upstream) skips the warning.
        if let ahead = info.unpushedCommits, ahead > 0 {
            let warn = NSAlert()
            warn.messageText = "\(ahead) unpushed commit\(ahead == 1 ? "" : "s") won't be cloned"
            warn.informativeText = "The remote clones from \(info.originURL). "
                + "Commits you haven't pushed stay on this Mac. Clone anyway?"
            warn.alertStyle = .warning
            warn.addButton(withTitle: "Clone Anyway")
            warn.addButton(withTitle: "Cancel")
            guard warn.runModal() == .alertFirstButtonReturn else { return }
        }

        // The remote must have termiod for the terminal we open afterwards, so run
        // the same deploy-if-missing gate first; it doubles as a reachability check
        // before we attempt the (slower) clone.
        ensureRemoteReady(host: host) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.presentRemoteSetupFailure(host: host, message: error.message)
            case .success(let device):
                self.performRemoteClone(
                    host: host, device: device.id, info: info, into: destination)
            }
        }
    }

    /// The clone half: `ssh <host> git clone <url> <name>` off the main thread with
    /// a "Cloning…" HUD, then opens a remote terminal in `~/<name>` on success.
    private func performRemoteClone(
        host: String,
        device deviceID: String,
        info: GitService.CloneInfo,
        into destination: RemoteCloneDestination? = nil
    ) {
        let hud = RemoteSetupHUD(message: "Cloning \(info.repositoryName) on \(host)…")
        hud.show()
        let name = info.repositoryName
        // Clone into `$HOME` (an explicit `cd ~` first, so the destination is
        // stable regardless of the ssh command's default directory), then print
        // the clone's absolute path on its own trailing line. termiod spawns the
        // shell with a raw `chdir` (no `~`/relative resolution — see
        // termiod/src/session.rs `Pty::spawn`), so the terminal needs an absolute
        // cwd; we capture it here rather than guess `$HOME`. Both the URL and name
        // are single-quoted for the remote shell (built on-main before dispatch;
        // `shellQuoted` is main-actor). `BatchMode=yes` stops a stuck credential
        // prompt from hanging the clone. The trailing `cd <name> && pwd` prints
        // the clone's absolute path WITHOUT re-embedding `name` unquoted — every
        // use of the URL and name is single-quoted, so a hostile origin URL whose
        // last path component carries shell metacharacters (`$(…)`, backticks)
        // cannot break out and execute code on the remote host.
        let quotedName = Self.shellQuoted(name)
        let remoteCommand = "cd ~ && git clone \(Self.shellQuoted(info.originURL)) "
            + "\(quotedName) && cd \(quotedName) && pwd"
        DispatchQueue.global(qos: .userInitiated).async {
            let clone = Self.runProcess(
                "/usr/bin/ssh",
                ["-o", "BatchMode=yes", host, remoteCommand]
            )
            DispatchQueue.main.async {
                hud.dismiss()
                guard let clone, clone.exitCode == 0 else {
                    let detail = clone.map { output in
                        (output.standardError + output.standardOutput)
                            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                            .last(where: { !$0.isEmpty }) ?? "clone failed"
                    } ?? "couldn't run ssh"
                    self.presentRemoteSetupFailure(
                        host: host, message: "git clone failed on \(host).\n\(detail)")
                    return
                }
                // The last non-empty stdout line is the absolute clone path we
                // printed. termiod is already deployed (ensureRemoteReady ran), so
                // create the session directly rather than re-probing.
                let clonedPath = clone.standardOutput
                    .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    .last(where: { !$0.isEmpty })
                let projectID = self.fileClone(
                    at: clonedPath, on: host, device: deviceID, into: destination)
                self.createRemoteTerminalSession(
                    host: host, device: deviceID, cwd: clonedPath, title: name, project: projectID
                )
            }
        }
    }

    /// Files a finished clone and returns the project its first terminal belongs
    /// under, or `nil` when there is none — the session then lands in the
    /// machine's own workspace, which is where a terminal with no project goes.
    ///
    /// Recording the checkout is what makes the clone a lasting link rather than a
    /// one-shot action: later remote terminals for this project land there without
    /// cloning again. Keyed by the *machine*, so reaching it by a different alias
    /// tomorrow still finds the clone.
    private func fileClone(
        at clonedPath: String?,
        on alias: String,
        device deviceID: String,
        into destination: RemoteCloneDestination?
    ) -> Project.ID? {
        guard let destination else { return nil }
        switch destination {
        case .existing(let id):
            guard let path = clonedPath,
                  let index = projects.firstIndex(where: { $0.id == id })
            else { return id }
            projects[index].remoteCheckouts[deviceID] = path
            return id
        case .new(let name):
            // No path means the clone landed somewhere we couldn't read back, and
            // a project row whose directory is a guess is worse than no row: the
            // terminal still opens on the machine, just without one.
            guard let path = clonedPath else { return nil }
            return addRemoteProject(name: name, at: path, on: alias, device: deviceID)
        }
    }
}

/// Evidence that a declared agent's wrapped shell has outlived it (RFC 20260830
/// §D2): consecutive foreground samples showing a login shell where the agent
/// should be. The same evidence bar as the device's status-promotion streak
/// (`StatusEngine::note_output`) — two consecutive samples, ~4s at the 2s
/// cadence — and the same stand-down rule as every other host-reported fact: an
/// unanswered sample (`nil` argv) is not evidence and leaves the streak alone.
/// A plain value type so the verdict logic is testable without the store.
struct AgentExitStreak: Equatable {
    private(set) var shellSamples = 0
    /// Latches after one demotion so a shell that stays in front doesn't re-fire
    /// every sample; reset by anything that isn't the shell taking the
    /// foreground back.
    private(set) var fired = false

    static let demotionThreshold = 2

    /// The login shells a session wrapper can leave behind. Matched by leaf name
    /// with the login `-` stripped, the same normalization the agent catalog
    /// applies to its own commands.
    private static let shellNames: Set<String> = [
        "zsh", "bash", "sh", "fish", "dash", "csh", "tcsh", "ksh", "nu",
    ]

    static func isShell(_ argv: [String]) -> Bool {
        guard let first = argv.first(where: { !$0.isEmpty }) else { return false }
        var name = (first as NSString).lastPathComponent.lowercased()
        if name.hasPrefix("-") { name.removeFirst() }
        return shellNames.contains(name)
    }

    enum Verdict: Equatable {
        /// Nothing to act on — evidence still gathering, unanswered, or already acted on.
        case hold
        /// Something other than the shell took the foreground back after a
        /// demotion: the notice is stale.
        case agentReturned
        /// The shell has held the foreground long enough — demote the row now.
        case demote
    }

    mutating func observe(foregroundArgv: [String]?) -> Verdict {
        guard let argv = foregroundArgv else { return .hold }
        guard Self.isShell(argv) else {
            let hadFired = fired
            shellSamples = 0
            fired = false
            return hadFired ? .agentReturned : .hold
        }
        shellSamples += 1
        guard shellSamples >= Self.demotionThreshold, !fired else { return .hold }
        fired = true
        return .demote
    }
}

/// A small borderless "Setting up host…" panel shown while a remote deploy/clone
/// runs off the main thread — a spinner plus one line, centered on the key window.
/// Not an `NSAlert` (which is modal and would block the runloop the work reports
/// back on); a floating panel that the completion handler dismisses.
@MainActor
final class RemoteSetupHUD {
    private let panel: NSPanel
    private let message: String

    init(message: String) {
        self.message = message
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 84),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
    }

    func show() {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: message)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView ?? NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        panel.center()
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel.orderOut(nil)
    }
}
