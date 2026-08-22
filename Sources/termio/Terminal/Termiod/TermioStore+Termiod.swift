import AppKit
import Foundation
import GhosttyTerminal

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
        // The same status tap the in-process PTY installs on its output. The daemon
        // owning the PTY changes where the bytes come from, not what they say about
        // the agent — and the channels this restores (screen liveness, declared
        // screen rules, `OSC 9;4`) are what keep a spinner truthful when the host's
        // own `E status` is silent and a hook report went missing.
        let statusTap = makeStatusTap(for: session, surface: inMemory, backend: link)
        link.onOutput = { [weak inMemory] data in
            inMemory?.receive(data)
            statusTap(data)
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
        }
        // The `events` half of the negotiated capabilities. Status is the one
        // that matters: an agent running on a VPS reports to the daemon that
        // owns its PTY, and this is the only path by which that reaches the Mac
        // — the hook socket is on the wrong machine, which is exactly why
        // `presentationEnvironment` withholds `TERMIO_SESSION` from a remote.
        link.onStatus = { [weak self] status in
            self?.applyTermiodStatus(status, for: session.id)
        }
        // The link itself acts on this (it stops sending `R` frames the daemon
        // would reject, and re-asserts the grid when the token returns). Logged
        // here because a demoted pane looks identical to a live one on screen —
        // saying it out loud is what makes a silently-ignored keystroke
        // explainable. Showing it in the pane is a client-UI step, not taken here.
        link.onWriter = { writer in
            Log.termiod.info("""
            session \(session.id.uuidString, privacy: .public) is now \
            \(writer ? "the writer" : "an observer", privacy: .public)
            """)
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

    // MARK: - Host-reported workstream status

    /// Lands an `E status` event on the session's row. The vocabulary is the
    /// protocol's (`working · idle · needs_you · done · failed · unknown`, §4);
    /// the mapping to a dot, a spinner, or a notification is this client's and
    /// deliberately mirrors `applyStatusReport` arm for arm, so a session behaves
    /// the same whether its status came from a local hook or from the daemon.
    ///
    /// Unlike the hook path there is no correlation guesswork: the event arrived
    /// on this session's own attach channel, so it can only be about this
    /// session. That is also why it is not gated on `effectiveAgent` — a remote
    /// terminal is created as a plain `.terminal` row (the agent runs over
    /// there), and gating would silently discard every status a VPS agent
    /// reports, which is the entire reason this path exists.
    func applyTermiodStatus(_ report: Termiod.StatusPayload, for id: Session.ID) {
        guard session(id) != nil else { return }
        // The workstream title is the agent's own label for what it is doing.
        // It shares `liveTitle` with the OSC 0/2 channel — same field, last
        // writer wins — because both answer the same question about the row.
        if let title = report.title, !title.isEmpty { setLiveTitle(title, for: id) }
        // A host that is speaking for this session is exactly the condition the
        // screen-driven promotion stands down for (`hookQuietWindow`): the
        // precise signal outranks the heuristic that exists in its absence.
        if ["working", "idle", "needs_you", "done", "failed"].contains(report.status) {
            lastHookReportAt[id] = Date()
        }
        switch report.status {
        case "working":
            setStatus(.working, for: id)
            lastWorkingAt[id] = Date()
        case "needs_you":
            clearWorking(id)
            flagBlockingAttention(for: id)
        case "done":
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
        // `nil` argv is *unanswered*, so it never reaches `noteForegroundAgent` —
        // which reads its own `nil` as "a shell is in front now" and demotes.
        // An answered argv that matches nothing is that demotion, correctly.
        if identifiesAgent, let argv = information.foregroundArgv {
            noteForegroundAgent(AgentCatalog.shared.agent(forForegroundArguments: argv), for: id)
        }
        // The daemon's equivalent of the local kernel poll, landing in the same
        // place it does. (The shell's own OSC 7 reaches `noteWorkingDirectory`
        // ungated, from the surface — that channel is the program volunteering
        // where it is, which is a different thing from termio going and looking.)
        if followsWorkingDirectory, let cwd = information.childCwd, !cwd.isEmpty {
            noteWorkingDirectory(cwd, for: id)
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
            + localized("Select it again to reattach.")
            + "\r\n").utf8))
        // Dropped *after* the message is on it, and this is what makes the
        // message true: `surface(for:)` returns the cached surface before it
        // considers building one, and the cached surface's write closure holds
        // the link that just died. Without this the pane comes back looking
        // alive and types into nothing. `relaunchSession` clears both for the
        // same reason.
        surfaces[id] = nil
        monitors[id] = nil
    }

    func applyTermiodExit(for id: Session.ID,
                          code: Int32,
                          runtimeMilliseconds: UInt64,
                          information: Termiod.SessionInformation?,
                          isAgentSession: Bool,
                          isPlainTerminal: Bool,
                          surface: InMemoryTerminalSession?) {
        termiodLinks[id] = nil
        lastScreenActivity[id] = nil
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

    /// Takes a session the **device** reports but this app has no row for, and
    /// gives it one.
    ///
    /// This is what makes the roster more than a read-only display: a session
    /// started from `termiod` on the box, or by a phone, is a session on that
    /// device, and a viewer of that device should be able to open it. The row
    /// keeps the name the device gave it (`termiodSessionName`) instead of being
    /// renamed to a fresh uuid, because the name is how the daemon is asked for
    /// that exact PTY.
    func adoptDeviceSession(_ information: Termiod.SessionInformation) {
        let device = currentDevice
        var session = Session(title: information.displayLabel, agent: .terminal)
        session.termiodSessionName = information.name.isEmpty ? information.id : information.name
        session.termiodRemoteHost = device.alias
        session.deviceID = device.deviceID
        session.termiodRemoteCwd = information.cwd.isEmpty ? nil : information.cwd
        // Filed in the machine's fallback workspace for another device, in the
        // current workspace's Terminals for this Mac. Which workspace a session
        // really belongs to is the device's to say, and it cannot say it yet
        // (device architecture §2.2), so the viewer files it where it is reachable.
        let workspaceID = device.alias.map { deviceWorkspace(for: $0, deviceID: device.deviceID) }
            ?? currentWorkspace.id
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            Log.termiod.error("""
            adopting \(information.name, privacy: .public) found no workspace to file it under
            """)
            return
        }
        workspaces[index].terminals.append(session)
        selectedSessionID = session.id
    }

    /// Ends a session the **device** reports and this app has no row for.
    ///
    /// Adoption alone left the roster one-way: the only route to a stranger row
    /// was to take it into the sidebar first, which is backwards for the case
    /// that produces most of them — a Termio whose state file was reset or
    /// replaced, leaving its PTYs alive under names nothing here will ever
    /// claim. Closing one is a device operation, so nothing local is touched:
    /// there is no record, no surface and no link to tear down.
    ///
    /// It asks first, every time, and not on `requestCloseSession`'s terms —
    /// that one can look at the PTY to see whether the close loses anything,
    /// and this one cannot, because the process belongs to something that isn't
    /// this app. Unknown is not the same as harmless.
    func requestCloseDeviceSession(_ information: Termiod.SessionInformation) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close “\(information.displayLabel)”?"
        alert.informativeText = information.attachedClients > 0
            ? "Another client is attached to this session. Closing it stops the "
                + "process running on \(deviceDescription)."
            : "This session isn't open in Termio. Closing it stops the process "
                + "running on \(deviceDescription)."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close Session")
        alert.buttons.last?.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        closeDeviceSessions([information])
    }

    /// The whole stranger list at once. One question for the lot: a state-file
    /// reset leaves them by the dozen, and answering the same alert twenty times
    /// is not a safeguard.
    func requestCloseAllDeviceSessions() {
        let rows = deviceOnlySessions()
        guard !rows.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close \(rows.count) session\(rows.count == 1 ? "" : "s")?"
        alert.informativeText = "These sessions aren't open in Termio. Closing them "
            + "stops every one of their processes on \(deviceDescription)."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close Sessions")
        alert.buttons.last?.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        closeDeviceSessions(rows)
    }

    private func closeDeviceSessions(_ rows: [Termiod.SessionInformation]) {
        let route = currentDevice.route
        // The roster is asked once, after the last kill has been answered:
        // re-asking mid-sweep would only fetch the rows that haven't died yet.
        let kills = DispatchGroup()
        for information in rows {
            kills.enter()
            Termiod.killSession(target: information.name.isEmpty ? information.id : information.name,
                                route: route) { kills.leave() }
        }
        kills.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The kills changed the answer, so a reply that settled moments
                // ago is stale by construction — clearing the coalescing window
                // is what keeps `refreshDeviceSessions` from standing down and
                // leaving the closed rows on screen.
                self.rosterFetches[route.description]?.settledAt = nil
                self.refreshDeviceSessions()
            }
        }
    }

    /// How to name the machine in a sentence a person reads.
    private var deviceDescription: String {
        currentDevice.alias ?? "this Mac"
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
    /// in; `title` overrides the sidebar label (the host alias by default, or a
    /// repo name for a clone).
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
                var title = title
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
                    title = title ?? "\(project.name) · \(host)"
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
    /// machine's fallback workspace, same as `addSSHSession` — tagging it with the
    /// per-session remote host + cwd that `makeTermiodLink` threads through.
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
        let message: String
    }

    /// Ensures `host` has `termiod` deployed before an attach — the same
    /// idempotent check the CLI's `remote open` runs (`test -x ~/.local/bin/termiod`,
    /// deploy if absent, see termiod/src/remote.rs). Runs off the main thread with a
    /// borderless "Setting up host…" HUD; `completion` fires back on the main queue.
    /// The deploy step shells out to the *local* `termiod remote deploy <host>`
    /// (which cross-compiles + scps), so the app never re-implements the deploy.
    func ensureRemoteReady(host: String, completion: @escaping (RemoteSetupResult) -> Void) {
        let hud = RemoteSetupHUD(message: "Setting up \(host)…")
        hud.show()
        // Only the probe leaves the main actor. `completion` is the caller's
        // closure and captures main-actor state, so it must never be sent to
        // another isolation domain — it is called here, where it was formed.
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.performRemoteReadyCheck(host: host)
            }.value
            hud.dismiss()
            // Whatever the caller does next, the alias has now resolved to a
            // machine — write that down before handing back, so state keyed by
            // device is addressable by the time it is read.
            if case .success(let device) = result {
                self?.adoptDevice(device, forRoute: .ssh(host))
            }
            completion(result)
        }
    }

    /// The blocking half of `ensureRemoteReady`, run off-main. Probes for the
    /// remote binary and, when missing, invokes the local `termiod remote deploy`.
    /// `nonisolated` because it is invoked from a background queue and touches only
    /// process/filesystem primitives — never `TermioStore`'s main-actor state.
    private nonisolated static func performRemoteReadyCheck(host: String) -> RemoteSetupResult {
        // Which device is behind this alias, asked with a hello and hung up. The
        // handshake is the only thing that can answer it, and it is the same
        // handshake the attach would run anyway.
        func identify() -> Result<TermiodDevice, Error> {
            Result { try Termiod.probeDevice(route: .ssh(host)) }
        }

        // A quick reachability + presence probe. `BatchMode=yes` keeps it from
        // hanging on a password prompt (the user's key/agent must already work,
        // exactly as `ssh <host>` in a plain terminal would need). The remote path
        // mirrors `Termiod.remoteBinary()` (`$HOME/.local/bin/termiod`).
        let probe = runProcess(
            "/usr/bin/ssh",
            ["-o", "BatchMode=yes",
             "-o", "ConnectTimeout=\(Termiod.connectTimeoutSeconds)", host,
             "test -x $HOME/.local/bin/termiod && echo yes || echo no"]
        )
        guard let probe else {
            return .failure(RemoteSetupError(message: "Couldn't run ssh to reach \(host)."))
        }
        if probe.exitCode != 0 {
            // A non-zero ssh exit before our echo means the connection or auth
            // failed — surface ssh's own last line, which names the cause.
            let detail = probe.standardError
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .last(where: { !$0.isEmpty }) ?? "Connection failed"
            return .failure(RemoteSetupError(
                message: "Couldn't reach \(host) over SSH.\n\(detail)"))
        }
        if probe.standardOutput.contains("yes") {
            // Already deployed — the common case after first use.
            switch identify() {
            case .success(let device):
                return .success(device)
            case .failure(let error):
                // The binary is there but will not shake hands: a stale daemon, a
                // protocol mismatch, a half-written deploy. Say so rather than
                // opening a pane that dies on attach for an unexplained reason.
                return .failure(RemoteSetupError(
                    message: "termiod on \(host) didn't answer.\n\(error.localizedDescription)"))
            }
        }

        // Missing: deploy via the local termiod binary's `remote deploy`, which
        // cross-compiles the aarch64-musl daemon and scps it (termiod/DEPLOY.md).
        let localBinary = Termiod.daemonBinaryPath()
        guard FileManager.default.isExecutableFile(atPath: localBinary) else {
            return .failure(RemoteSetupError(
                message: "termiod isn't deployed on \(host), and the local termiod "
                    + "binary to deploy it wasn't found at \(localBinary)."))
        }
        let deploy = runProcess(localBinary, ["remote", "deploy", host])
        guard let deploy, deploy.exitCode == 0 else {
            let detail = deploy.map { output in
                (output.standardError + output.standardOutput)
                    .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    .last(where: { !$0.isEmpty }) ?? "deploy failed"
            } ?? "couldn't run termiod remote deploy"
            return .failure(RemoteSetupError(
                message: "Couldn't deploy termiod to \(host).\n\(detail)"))
        }
        switch identify() {
        case .success(let device):
            return .success(device)
        case .failure(let error):
            return .failure(RemoteSetupError(
                message: "Deployed termiod to \(host), but it didn't answer.\n"
                    + error.localizedDescription))
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
