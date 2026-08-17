import Combine
import Foundation
import GhosttyTerminal
import GhosttyTheme
import TermioShared

/// Resolves an agent's on-disk conversation entries from the declarative store
/// descriptor its manifest supplies (`ResumeSpec.Store`) — one probe for every agent,
/// replacing the per-agent lookups. Agents bucket sessions per working directory under
/// `root`; termio globs the immediate buckets for the entry whose name matches the
/// pattern (`{id}` the session id, `*` a wildcard) rather than reconstruct each agent's
/// private cwd encoding. Used to decide create-vs-resume (a create flag errors on a
/// duplicate id), to back the Info-pane transcript fallback, and to follow a `/clear`
/// that rotates the id mid-session.
enum SessionStore {
    static func exists(_ store: AgentDefinition.ResumeSpec.Store, id: String) -> Bool {
        locate(store, id: id) != nil
    }

    /// The path of the on-disk entry for `id`, or `nil` if the agent hasn't saved it yet.
    static func locate(_ store: AgentDefinition.ResumeSpec.Store, id: String) -> String? {
        let root = URL(fileURLWithPath: (store.root as NSString).expandingTildeInPath)
        guard let buckets = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return nil }
        let target = store.name.replacingOccurrences(of: "{id}", with: id)
        let fileManager = FileManager.default
        for bucket in buckets {
            if !target.contains("*") {
                // Exact name (the common case) — a direct existence check, kind-matched
                // so a file store never matches a stray directory and vice versa.
                let candidate = bucket.appendingPathComponent(target)
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                   isDirectory.boolValue == store.isDirectory { return candidate.path }
            } else if let entries = try? fileManager.contentsOfDirectory(atPath: bucket.path),
                      let hit = entries.first(where: { glob(target, matches: $0) }) {
                return bucket.appendingPathComponent(hit).path
            }
        }
        return nil
    }

    /// Recovers `{id}` from a concrete entry name given the store's `{id}`/`*` pattern —
    /// e.g. `<uuid>.jsonl` against `{id}.jsonl`, or `170_<uuid>.jsonl` against `*_{id}.jsonl`.
    static func id(fromEntryName name: String, pattern: String) -> String? {
        guard let idRange = pattern.range(of: "{id}") else { return nil }
        let prefix = pattern[..<idRange.lowerBound].replacingOccurrences(of: "*", with: "")
        let suffix = pattern[idRange.upperBound...].replacingOccurrences(of: "*", with: "")
        var core = Substring(name)
        if !suffix.isEmpty {
            guard core.hasSuffix(suffix) else { return nil }
            core = core.dropLast(suffix.count)
        }
        if !prefix.isEmpty, let r = core.range(of: prefix) { core = core[r.upperBound...] }
        return core.isEmpty ? nil : String(core)
    }

    /// A minimal `*`-only glob: the non-empty fragments must appear in order, anchored at
    /// both ends. (Enough for the session-file patterns; not a full shell glob.)
    private static func glob(_ pattern: String, matches name: String) -> Bool {
        let fragments = pattern.components(separatedBy: "*")
        var cursor = name.startIndex
        for (index, fragment) in fragments.enumerated() where !fragment.isEmpty {
            guard let range = name.range(of: fragment, range: cursor..<name.endIndex) else { return false }
            if index == 0, range.lowerBound != name.startIndex { return false }
            cursor = range.upperBound
        }
        if let last = fragments.last, !last.isEmpty { return name.hasSuffix(last) }
        return true
    }
}

/// Pre-creates Pi's on-disk session file for a pinned id, so `--session-id` always
/// resolves to an existing session. Pi looks the id up in its session store at
/// startup and prints a yellow "No project session found … creating a new session"
/// warning when no file exists yet — which, with termio minting the id up front,
/// would be every first launch. Writing the same header-only JSONL file pi itself
/// would create keeps that launch silent; pi appends the conversation to it. The
/// layout mirrors pi's session-manager (verified against pi v0.80.6):
/// `~/.pi/agent/sessions/--<encoded cwd>--/<timestamp>_<id>.jsonl`, where the first
/// line is `{"type":"session","version":3,"id":…,"timestamp":…,"cwd":…}`. If pi ever
/// changes the layout the lookup just misses and pi warns-and-creates as before.
enum PiSession {
    static func ensureExists(id: String, cwd: String) {
        // Pi derives the folder from its *process* cwd, whose symlinks the kernel
        // resolved at chdir — canonicalize the same way (`/tmp` → `/private/tmp`).
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = realpath(cwd, &buffer) != nil ? String(cString: buffer) : cwd
        var encoded = resolved
        if encoded.hasPrefix("/") { encoded.removeFirst() }
        encoded = "--\(String(encoded.map { "/\\:".contains($0) ? "-" : $0 }))--"
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
        // Pi names session files `<timestamp>_<id>.jsonl`; one already carrying this
        // id (created by pi or by us) means there is nothing to do — never overwrite.
        if let existing = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
           existing.contains(where: { $0.hasSuffix("_\(id).jsonl") }) { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        let header: [String: Any] = [
            "type": "session", "version": 3, "id": id, "timestamp": timestamp, "cwd": resolved,
        ]
        guard var line = try? JSONSerialization.data(
            withJSONObject: header, options: [.withoutEscapingSlashes]) else { return }
        line.append(0x0A)
        let name = "\(String(timestamp.map { ":.".contains($0) ? "-" : $0 }))_\(id).jsonl"
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? line.write(to: dir.appendingPathComponent(name), options: .atomic)
    }
}

extension TermioStore {
    /// `path` when it still names a real directory, else `nil`. A recorded cwd outlives
    /// the folder it points at, and a shell spawned in a deleted directory lands at `/`.
    static func existingDirectory(_ path: String?) -> String? {
        guard let path else { return nil }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue ? path : nil
    }

    /// Returns the cached terminal surface for a session, creating and starting
    /// it on first access. The surface launches `session.command` (or the login
    /// shell) in the project's working directory via the real PTY (`.exec`).
    func surface(for session: Session, in project: Project) -> TerminalViewState {
        if let existing = surfaces[session.id] {
            return existing
        }

        // An isolated worktree (if one was created for this session) wins over the
        // project's own directory, so the agent edits the branch in place.
        // A loose terminal instead respawns at the cwd it last reported over OSC 7
        // (its path is the session's own mutable property, not the container's) —
        // so a relaunch drops the user back where they `cd`'d, not at `$HOME`.
        // Ahead of the worktree/project anchor sits the directory the session was
        // opened in (⌘T): where the user asked *this* shell to start, even when the
        // session belongs to a project rooted elsewhere. Each rung must still exist —
        // a stale path falls through rather than dropping the shell at `/`.
        let restoredCwd = project.kind == .terminals
            ? Self.existingDirectory(session.lastWorkingDirectory)
            : nil
        // A `.host` container's `path` is a path on *that box* (`~`, or a clone's
        // directory) — handing it to the local PTY would `chdir` somewhere that
        // doesn't exist here, or worse, somewhere that does. The remote cwd travels
        // separately: `session.termiodRemoteCwd` for a termiod session, the remote
        // login shell's own default for a plain `ssh`. Locally these spawn at `$HOME`.
        let localRoot = project.kind == .host
            ? FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
            : project.path
        let workspacePath = restoredCwd
            ?? Self.existingDirectory(session.spawnDirectory)
            ?? session.worktreePath
            ?? localRoot

        // Resolve the launch command *with* any resume arguments, so a session that was
        // running when the app last quit picks its conversation back up instead of
        // starting over. `resumeID` is the id we persist for it (nil for the plain shell
        // and the directory-resume agents); it's written back below.
        // An SSH terminal launches `ssh <host>` instead of a local shell or agent —
        // the remote host allocates its own pty over the connection. It never
        // resumes (a local-agent concept), so it short-circuits the agent launch
        // resolution below.
        let launch = session.sshHost.map { (command: Self.sshCommand(host: $0), resumeID: String?.none) }
            ?? resolveLaunch(for: session, workspacePath: workspacePath)
        let agentCommand = launch.command

        // Pi checks the pinned `--session-id` against its session store at startup
        // and warns when no file exists yet; pre-creating it keeps the launch silent.
        // The manifest opts in via `resume.seed`, so no agent is named here.
        if session.agent.resumeSpec.seed == "session-file", let pinnedID = launch.resumeID {
            PiSession.ensureExists(id: pinnedID, cwd: workspacePath)
        }

        let controller = TerminalController { [self] builder in
            applyAppearance(to: &builder)
        }
        let state = TerminalViewState(controller: controller)
        state.controller.setTheme(makeTheme())
        // Honor ghostty's close request (fired when the child has exited and the
        // user presses a key, fulfilling the "Press any key to close" prompt) by
        // removing the session — the same thing the sidebar's Close does. Without
        // this the prompt is a dead end: the keypress reaches ghostty, which calls
        // `close()`, but nothing on the termio side acts on it, so the pane never
        // goes away. Paired with `wait-after-command` below (which keeps the pane
        // alive to *show* that prompt) and the clean-exit auto-close in `onExit`.
        state.onClose = { [weak self] _ in self?.closeSession(session.id) }

        // Host-managed backend: termio owns the PTY (rather than libghostty's
        // `.exec`), so the byte stream can be teed to a phone and read for
        // session control. The surface's keystrokes/resizes flow to the PTY via
        // the callbacks; the PTY's output fans back into the surface (and any
        // attached companion sink) through `receive`.
        let argv = Self.launchArgv(command: agentCommand)
        var env = Self.sanitizedEnvironment()
        // Stamp the session id so any agent hook running inside can echo it back,
        // letting `HookListener` correlate events to this exact session.
        env["TERMIO_SESSION"] = session.id.uuidString
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "termio"
        // termio embeds libghostty, which renders OSC 8 hyperlinks. Agent CLIs
        // that gate hyperlink emission on a `TERM_PROGRAM` allowlist (the npm
        // `supports-hyperlinks` package — Claude Code, Gemini, Qwen, …) don't
        // recognize `termio`, so they fall back to plain text. FORCE_HYPERLINK
        // is that library's highest-precedence override; setting it here makes
        // file-path/URL links clickable without impersonating another terminal
        // (we must keep TERM_PROGRAM=termio for session identity — see
        // `PTYProcess` self-detection). Tools that emit OSC 8 unconditionally
        // (Codex, Aider/Rich) are unaffected.
        env["FORCE_HYPERLINK"] = "1"

        // Opt-in termiod backend (`TERMIO_TERMIOD=1`): the session runs inside
        // the local daemon and this app instance merely attaches, so quitting
        // detaches instead of killing. Flag off, the in-process PTY below is
        // created exactly as before.
        let termiodLink: TermiodSessionLink? = Termiod.isEnabled
            ? makeTermiodLink(for: session, argv: argv, cwd: workspacePath, env: env)
            : nil
        // The PTY is created first so the surface's `@Sendable` write/resize
        // callbacks can capture it directly (it is thread-safe: fd writes and
        // ioctl are atomic, sinks are lock-guarded).
        // Spawn at the last real host grid rather than a fixed 80×24, so the
        // shell's first prompt is drawn at (usually) the window's actual width
        // and the first layout pass doesn't reflow it — the reflow that mangles
        // zsh's `PROMPT_SP` line into a stray `%` (see `lastHostGridColumns`).
        let pty: PTYProcess? = termiodLink != nil
            ? nil
            : PTYProcess(argv: argv, cwd: workspacePath, env: env,
                         cols: lastHostGridColumns, rows: lastHostGridRows)
        let inMemory = InMemoryTerminalSession(
            write: { data in
                if let termiodLink {
                    termiodLink.send(data)
                    return
                }
                // Typing on the Mac reclaims the winsize from an attached
                // phone — the size follows the device being used.
                pty?.claimHostOwnership()
                pty?.write(data)
            },
            resize: { [weak self] viewport in
                let columns = Int(viewport.columns)
                let rows = Int(viewport.rows)
                if let termiodLink {
                    termiodLink.resize(rows: rows, cols: columns)
                } else {
                    pty?.resizeFromHost(cols: columns, rows: rows)
                }
                // Remember the host grid for the next session's initial size.
                DispatchQueue.main.async { self?.rememberHostGrid(columns: columns, rows: rows) }
            }
        )
        if let termiodLink {
            attachTermiodLink(termiodLink, to: inMemory, for: session)
        }
        if let pty {
            pty.addSink { [weak inMemory] data in inMemory?.receive(data) }
            // Tap the same stream as a working-status signal (see
            // `noteOutputActivity` for the full model): a *changing* rendered
            // screen keeps a working session's `lastWorkingAt` fresh — and, when
            // hooks have gone quiet, can promote an idle session back to working —
            // while a static screen lets the stale sweep clear the spinner. The
            // screen, not raw bytes, is the primary key: an agent parked at an
            // idle prompt still dribbles output (a redraw, a blinking cursor) that
            // the byte stream alone reads as activity, which is what pins a
            // finished agent's spinner on forever. The per-tick byte count rides
            // along as a secondary liveness signal for a viewport the user
            // scrolled away from the live tail. `readViewportText` is thread-safe
            // (its own lock), so the compare runs on the read pump; only the
            // changed-flag and byte count hop to the main actor. Throttled to once
            // a second. The read pump calls sinks serially, so the captured
            // `lastPoke` / `lastScreenSignature` / `pendingBytes` need no lock.
            // A user agent may declare `status` regex rules in its `agent.json`; the
            // same viewport read that feeds the liveness sweep is classified against
            // them to drive working / needs-attention / done for agents that ship no
            // hook system (see `AgentStatusRules`). Built-ins carry no rules (they use
            // hooks), so this is `nil` for them and the classify step is skipped.
            //
            // Caveat: `readViewportText` returns the *displayed* viewport, which follows
            // the user's scrollback — so scrolling an inline agent's pane up feeds stale
            // rows to the classifier until it snaps back to the bottom (self-healing;
            // the byte-count signal covers working-liveness meanwhile). herdr avoids
            // this by reading the live bottom (active) buffer; the clean fix
            // here needs a `readActiveText()` on the libghostty wrapper (its blessed read
            // serializes against the PTY write under a private lock we can't hold, and a
            // raw unsynchronized `GHOSTTY_POINT_ACTIVE` read from this pump thread would
            // race `inMemory.receive` — the exact libghostty threading hazard termio has
            // been bitten by). Tracked as an upstream ask, not worked around unsafely.
            let statusRules = session.agent.statusRules
            let agentID = session.agent.id
            let isAgentSession = session.agent != .terminal && !session.isSSH
            let statusTrace = ProcessInfo.processInfo.environment["TERMIO_STATUS_TRACE"] != nil
            // Reads this session's ConEmu `OSC 9;4` progress out of the raw stream as
            // a busy/idle signal (Grok emits it natively). Scanned on every chunk
            // *before* the 1 s status throttle below — an agent's turn boundary is an
            // edge, not something to sample once a second. The scan runs for every
            // session (a plain terminal can be promoted to a hand-started Grok, whose
            // sink was built while the row was still a shell); whether a transition is
            // *acted on* is gated in `applyProgressActivity` by the session's live
            // agent, so an unrelated shell's `wget`/`npm` progress bar can't move a dot.
            var progressScanner = OSCProgressScanner()
            var lastPoke = Date.distantPast
            var lastScreenSignature: Int?
            // Bytes seen since the last poke, so the throttled tick can report the
            // stream's volume alongside the screen compare — the scroll-frozen-
            // viewport liveness signal (see `noteOutputActivity`).
            var pendingBytes = 0
            pty.addSink { [weak self, weak inMemory, weak pty] data in
                pendingBytes += data.count
                for progress in progressScanner.scan(data) {
                    if statusTrace {
                        AgentStatusRules.trace(
                            agent: "\(agentID).progress", session: session.id,
                            activity: progress, matched: "OSC 9;4")
                    }
                    // Tie the event to the PTY that produced it. Unlike the title
                    // channel — whose Combine subscription is torn down with the view
                    // state on relaunch — this sink is only session-id-keyed, so a
                    // same-agent relaunch could otherwise let a dead PTY's queued
                    // `working` mark the replacement process. Applying only while this
                    // PTY is still the session's live one drops that stale event.
                    DispatchQueue.main.async { [weak pty] in
                        guard let self, let pty, self.ptyProcesses[session.id] === pty else { return }
                        self.applyProgressActivity(progress, for: session.id)
                    }
                }
                let now = Date()
                guard now.timeIntervalSince(lastPoke) >= 1 else { return }
                lastPoke = now
                let bytes = pendingBytes
                pendingBytes = 0
                // Pin the agent's launch binary (once, post-exec) as the baseline
                // for the self-update relaunch check in `onExit` below. Agent
                // sessions only — a terminal's exit policy never consults it.
                if isAgentSession { pty?.recordChildExecutable() }
                // The PTY timestamps every stdin write (Mac keystrokes, phone
                // input over the companion bridge, synthetic `sessions send`
                // text), so sampling it here — instead of tapping only the Mac
                // surface's write callback — keeps promotion quiet after input
                // from any device. Input echo repaints the screen just like
                // agent output does.
                let inputAt = pty?.lastInputAt
                let text = inMemory?.readViewportText()
                let screenChanged: Bool
                if let text {
                    let signature = text.hashValue
                    screenChanged = signature != lastScreenSignature
                    lastScreenSignature = signature
                } else {
                    // No surface to read (e.g. detached) — fall back to treating
                    // output as activity rather than risk clearing a live turn.
                    screenChanged = true
                }
                let detected: AgentStatusRules.Activity?
                if let statusRules {
                    let (activity, matched) = statusRules.explain(text ?? "")
                    detected = activity
                    if statusTrace {
                        AgentStatusRules.trace(
                            agent: agentID, session: session.id, activity: activity, matched: matched)
                    }
                } else {
                    detected = nil
                }
                DispatchQueue.main.async {
                    if let inputAt { self?.noteUserInput(session.id, at: inputAt) }
                    self?.noteOutputActivity(session.id, screenChanged: screenChanged, bytes: bytes)
                    if let detected {
                        self?.applyScreenDetectedActivity(detected, for: session.id)
                    }
                }
            }
            // A plain terminal's kernel-sampled introspection, after output settles:
            // which agent (if any) is running in its foreground, and — for a loose
            // terminal — the shell's cwd. Both are read from the child's own process
            // because plain shells on macOS never emit OSC 7 (the stock /etc/zshrc
            // reports cwd only under `TERM_PROGRAM=Apple_Terminal`) and the
            // host-managed PTY injects no shell integration, so the OSC 7/foreground
            // signals in `monitor(_:for:)` stay silent — the same integration-less
            // fallback iTerm2 uses. A *trailing* debounce, not a leading-edge throttle:
            // a `cd`'s new prompt (and an agent's first banner) land a few ms after the
            // command echo, so a leading throttle samples the echo then skips the
            // settled state and the now-idle shell emits nothing more to re-poll.
            // Debouncing polls once ~350ms after output stops, catching both the launch
            // and the exit of a hand-started agent. Detection runs for every terminal;
            // cwd-following is for loose terminals only — a project session's place is
            // its project, not where it wandered.
            if session.agent == .terminal {
                let sessionID = session.id
                let followCwd = project.kind == .terminals
                var pendingPoll: DispatchWorkItem?
                pty.addSink { [weak self, weak pty] _ in
                    pendingPoll?.cancel()
                    // Resolve off the main thread: both reads are syscalls that walk
                    // kernel structures (`KERN_PROCARGS2`, `PROC_PIDVNODEPATHINFO`) —
                    // usually microseconds, but they take locks and can stall under
                    // memory pressure or on a slow mount, and a main-thread stall is a
                    // beachball. Only the @MainActor-published tree writes hop to main.
                    //
                    // `@Sendable` is what says "off the main thread" to the compiler,
                    // and it is load-bearing: a closure written in this main-actor
                    // scope otherwise inherits main-actor isolation, and the block
                    // `DispatchWorkItem` wraps it in re-checks that isolation when the
                    // utility queue runs it — a trap on the first poll rather than a
                    // hop. Marking it also makes the captures checked for real.
                    let work = DispatchWorkItem { @Sendable [weak self, weak pty] in
                        guard let pty else { return }
                        // A hand-started agent (a `claude` typed at the prompt) becomes
                        // the foreground process; when it exits the shell returns and
                        // this resolves to `nil`, reverting the row to a plain terminal.
                        let detected = pty.foregroundProcessArguments()
                            .flatMap { AgentCatalog.shared.agent(forForegroundArguments: $0) }
                        let cwd = followCwd ? pty.currentWorkingDirectory() : nil
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                self?.noteForegroundAgent(detected, for: sessionID)
                                if let cwd { self?.noteWorkingDirectory(cwd, for: sessionID) }
                            }
                        }
                    }
                    pendingPoll = work
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35, execute: work)
                }
            }
            pty.onExit = { [weak self, weak inMemory, weak pty] code, runtimeMs in
                self?.ptyProcesses[session.id] = nil
                self?.lastScreenActivity[session.id] = nil
                // A clean agent exit never parks the pane on the dead-end
                // "Press any key to close" prompt (whose keypress deleted the
                // session outright). Two flavors, told apart by the launch
                // binary on disk:
                //  - replaced (codex's in-pane upgrade ends with "Please restart
                //    Codex." and quits — Homebrew purged the old version): do the
                //    restart for the user, respawning the agent in place with its
                //    resume arguments. Can't loop — the respawn pins the new
                //    binary as its own baseline.
                //  - untouched (a plain `/quit`): hand the pane back to a shell
                //    in the same directory — exactly where a hand-started agent
                //    leaves you — demoting the session to a plain terminal (the
                //    identity mirror of `noteForegroundAgent`'s promotion).
                // A non-zero exit still parks on the prompt: its error output
                // must stay readable.
                if isAgentSession, code == 0 {
                    if pty?.childExecutableWasReplaced() == true {
                        self?.relaunchSession(session.id)
                    } else {
                        self?.revertSessionToShell(session.id)
                    }
                    return
                }
                // Report the *real* runtime, not 0. On macOS ghostty ignores the
                // exit code and shows its "failed to launch the requested command"
                // overlay whenever runtime ≤ `abnormal-command-exit-runtime` (250 ms) —
                // so a hardcoded 0 mislabeled every ordinary exit (a codex self-update
                // that quits, an agent you `exit` out of) as a launch failure. A true
                // runtime lets a long-lived session fall through to the neutral
                // "process exited" message, reserving the scary banner for genuine
                // sub-threshold launch failures (binary not found, bad argv).
                inMemory?.finish(exitCode: UInt32(bitPattern: code), runtimeMilliseconds: runtimeMs)
                // A plain terminal that exits *cleanly* closes its tab like a
                // native terminal (Terminal.app / iTerm2 / Ghostty all do this) —
                // you typed `exit`, so the pane goes away with no extra keypress.
                // A non-zero exit (terminal or agent — clean agent exits were
                // handled above) is left on screen so its error output stays
                // readable rather than silently vanishing. ghostty can't read
                // the exit code reliably on macOS, but our `waitpid` here can.
                if session.agent == .terminal, code == 0 {
                    self?.closeSession(session.id)
                }
            }
            ptyProcesses[session.id] = pty
        }

        state.configuration = TerminalSurfaceOptions(backend: .inMemory(inMemory))
        surfaces[session.id] = state
        processSpawnedAt[session.id] = Date()
        monitor(state, for: session.id)
        warmUpRendering(state)
        // Record that this session has now launched (and its pinned resume id) so the
        // next app run resumes it — but on the *next* runloop turn, not inline. This
        // method is called from `TerminalPane`'s `body`, and `recordLaunch` writes the
        // `@Published projects` tree; mutating published state mid-render re-enters
        // SwiftUI's view-graph transaction and aborts the app (an AttributeGraph
        // `precondition_failure` during `NSHostingView.layout`). The surface is already
        // cached above, so the re-render this schedules just looks it up and returns
        // (no second shell), and `recordLaunch` is idempotent — running it a turn later
        // is harmless. (`surfaces`/`monitors` are plain, non-`@Published` caches, so
        // writing them here is fine; only the `projects` write must be deferred.)
        DispatchQueue.main.async { [self] in recordLaunch(session.id, resumeID: launch.resumeID) }
        return state
    }

    /// The app's environment minus identity claims that belong to whatever launched
    /// it, not to the sessions it hosts. When termio is relaunched from a terminal
    /// (a dev rebuild out of VS Code, or an agent session), the child agent would
    /// otherwise detect the *host's* terminal (`TERM_PROGRAM=vscode`) or believe it
    /// is a nested Claude Code run (`CLAUDECODE`, `CLAUDE_CODE_SSE_PORT`, …). termio
    /// is the terminal here, so none of those claims may reach the session. Color
    /// policy flags are launcher policy too: Codex, CI, or a build shell commonly
    /// sets `NO_COLOR=1`, which must not silently turn off color in every hosted
    /// agent. A user's shell startup files can still opt back into those flags.
    /// A Finder launch carries none of them — this only matters for dev relaunches.
    private static func sanitizedEnvironment() -> [String: String] {
        let dropped: Set<String> = [
            "CLAUDECODE", "CLAUDE_EFFORT", "TERM_SESSION_ID", "TERMINAL_EMULATOR",
            "TMUX", "TMUX_PANE", "STY", "INSIDE_EMACS", "LC_TERMINAL",
            "LC_TERMINAL_VERSION", "KONSOLE_VERSION", "GNOME_TERMINAL_SERVICE",
            "WT_SESSION", "NO_COLOR", "FORCE_COLOR", "CLICOLOR", "CLICOLOR_FORCE",
        ]
        let droppedPrefixes = [
            "TERM_PROGRAM", "VSCODE_", "CLAUDE_CODE_", "ITERM_", "GHOSTTY_",
            "KITTY_", "WEZTERM_", "ALACRITTY_",
        ]
        return ProcessInfo.processInfo.environment.filter { key, _ in
            !dropped.contains(key) && !droppedPrefixes.contains { key.hasPrefix($0) }
        }
    }

    /// The argv to spawn in the session's PTY. An agent command string runs through
    /// the shell so its quoting/args parse exactly as under libghostty's `.exec`;
    /// `exec` keeps the shell from lingering as an extra process. A `nil` command is
    /// the plain interactive login shell.
    private static func launchArgv(command: String?) -> [String] {
        let shell = loginShell
        if let command, !command.isEmpty {
            // Run through an interactive *login* shell (`-i -l`) so the user's real PATH is
            // sourced from BOTH `~/.zprofile` (login — e.g. Homebrew's `brew shellenv`) and
            // `~/.zshrc` (interactive — where nvm/fnm/pyenv and npm-global bins usually land).
            // A Finder/Dock-launched app inherits only the minimal
            // `/usr/bin:/bin:/usr/sbin:/sbin` LaunchServices PATH, so a bare `sh -c` can't
            // find agent CLIs under /opt/homebrew/bin, ~/.local/bin, … — they die at 0 ms
            // with "Ghostty failed to launch the requested command". `exec` keeps the login
            // shell from lingering (so quoting/args still parse as under `.exec`).
            return [shell, "-ilc", "exec \(command)"]
        }
        return [shell, "-il"]
    }

    /// The command that opens an interactive SSH session to `host`. The host is a
    /// `~/.ssh/config` alias or a bare `user@host`; it's single-quoted so an alias
    /// with spaces or shell metacharacters can't break out of the `exec ssh …` line
    /// that `launchArgv` wraps it in. `ssh` with a tty on stdin (the PTY) and no
    /// remote command allocates a remote pty on its own, so the user lands at the
    /// remote shell — no `-t` needed.
    ///
    /// The session doubles as an OpenSSH ControlMaster (see `SSHMux`): the user
    /// authenticates once here, and the inspector's remote file tree rides the
    /// same connection through the control socket — no second handshake.
    static func sshCommand(host: String) -> String {
        if let options = SSHMux.masterShellOptions {
            return "ssh \(options) -- \(shellQuoted(host))"
        }
        // A failure to create the optional mux directory must not break the
        // terminal itself. The remote browser will show its unavailable state.
        return "ssh -- \(shellQuoted(host))"
    }

    /// POSIX single-quote escaping: wraps `value` in `'…'`, splicing any embedded
    /// quote as `'\''`, so the result is one literal argument no matter what it
    /// contains. Used to make a user-supplied SSH host safe inside `exec ssh …`.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The user's real login shell, read from the password database rather than the
    /// ambient `SHELL` env var. A GUI app inherits whatever `SHELL` launchd or `open`
    /// happened to pass — often unset, and sometimes `/bin/sh`, whose `-lc` sources NONE
    /// of the user's zsh PATH config, so `codex`/`claude` die at 0 ms with "not found".
    /// `getpwuid` returns the shell the user actually logs in with (`/bin/zsh` by default
    /// on modern macOS), matching how native terminals (Ghostty, kitty, iTerm2) resolve it.
    private static var loginShell: String {
        if let entry = getpwuid(getuid()), let cString = entry.pointee.pw_shell {
            let path = String(cString: cString)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// The launch command for a session, with resume arguments folded in, plus the
    /// resume id that should be persisted for it (nil when the agent doesn't pin one).
    /// Pure — it reads session state but mutates nothing; `recordLaunch` does the write.
    private func resolveLaunch(for session: Session, workspacePath: String)
        -> (command: String?, resumeID: String?) {
        guard let base = settings.command(for: session.agent) else {
            return (nil, nil) // plain login shell — nothing to resume
        }
        let agent = session.agent
        let resumeID: String?
        if agent.usesPinnedResumeID {
            // We mint and pin the id up front; reuse the persisted one across launches.
            resumeID = session.resumeID ?? UUID().uuidString
        } else if agent.usesDiscoveredResumeID, session.launched {
            // The id couldn't be set up front, so once the agent has run we learn it from
            // the agent's own session store — cached after the first successful discovery
            // so the scan happens at most once per session.
            resumeID = session.resumeID
                ?? AgentSessionStore.discover(agent: agent, directory: workspacePath,
                                              after: session.launchedAt)
        } else {
            resumeID = nil
        }
        // Does the agent already have a saved conversation under this id? Probe its
        // declared store — the create flag errors on a duplicate id, so we switch to the
        // resume flag once the agent has persisted it. Fully manifest-driven: no agent is
        // named here.
        let pinnedConversationExists: Bool
        if let store = agent.resumeSpec.store, let id = resumeID {
            pinnedConversationExists = SessionStore.exists(store, id: id)
        } else {
            pinnedConversationExists = false
        }
        let context = AgentPreset.ResumeContext(
            resumeID: resumeID ?? "",
            pinnedConversationExists: pinnedConversationExists
        )
        guard let arguments = agent.resumeArguments(context) else {
            return (base, resumeID)
        }
        return ("\(base) \(arguments)", resumeID)
    }

    /// Persists that a session has launched and, for the id-pinning agents, the id it
    /// was pinned to. Writes only when something actually changed, so re-opening an
    /// already-launched session doesn't churn the state file or re-sync watched folders.
    private func recordLaunch(_ id: Session.ID, resumeID: String?) {
        guard let location = locate(id) else { return }
        var session = projects[location.project].sessions[location.session]
        let firstLaunch = !session.launched
        let needsResumeID = resumeID != nil && session.resumeID == nil
        guard firstLaunch || needsResumeID else { return }
        if needsResumeID { session.resumeID = resumeID }
        if firstLaunch {
            session.launched = true
            // Stamp the launch moment so a later run can correlate Codex/OpenCode's own
            // session record back to this session by creation time (see `resolveLaunch`).
            session.launchedAt = Date()
        }
        projects[location.project].sessions[location.session] = session
    }

    /// Advances a session's pinned `resumeID` to the conversation it is *currently*
    /// writing, so a reopened tab resumes that one rather than a conversation the
    /// agent has since rotated away from. Claude Code's `/clear` mints a new id and
    /// transcript and orphans the old file; the once-pinned id (`recordLaunch` writes
    /// it only while nil) would otherwise resume the cleared conversation. A no-op
    /// unless the live transcript names a different id than the pin, and only for
    /// styles whose filename *is* the id — other agents advance through an
    /// identity-bearing report or turn-boundary re-discovery, which land in the same
    /// `adoptConversationID`. Fed by the hook-carried transcript path in
    /// `applyStatusReport`. See docs/design/20260716-agent-resume-identity.md.
    func reconcileResumeID(_ id: Session.ID, transcriptPath: String) {
        guard let session = session(id),
              let liveID = session.agent.resumeSpec.conversationID(fromTranscriptPath: transcriptPath)
        else { return }
        adoptConversationID(liveID, for: id)
    }

    /// The one point where a session's conversation identity changes, shared by every
    /// rotation signal (transcript-filename reconcile, identity-bearing reports,
    /// turn-boundary re-discovery). Returns whether the pin actually advanced.
    @discardableResult
    func adoptConversationID(_ conversationID: String, for id: Session.ID) -> Bool {
        guard let location = locate(id) else { return false }
        var session = projects[location.project].sessions[location.session]
        // Only a session whose declared agent participates in conversation identity
        // (a pinned, discovered, or resumable id) has a pin to keep honest. A plain
        // terminal that merely *runs* an agent relaunches as a shell, so adopting an
        // id there is pure noise.
        let spec = session.agent.resumeSpec
        guard spec.pinsID || spec.discoversID || spec.resume != nil else { return false }
        guard conversationID != session.resumeID else { return false }
        // A genuine rotation (the pin already named a conversation and it changed —
        // not the first-report adoption of an unpinned session) also orphans the
        // sidebar topic title: it describes the discarded conversation. Drop both
        // the in-memory and the persisted copy so `displayTitle` falls back to the
        // agent name until the new conversation earns a topic. Status and
        // `lastTitleActivity` are separate channels — leave them alone.
        if session.resumeID != nil {
            setLiveTitle(nil, for: id)
            session.liveTitle = nil
        }
        session.resumeID = conversationID
        projects[location.project].sessions[location.session] = session
        return true
    }

    /// Turn-boundary re-discovery for a discovered-id agent whose reports carry no
    /// conversation identity: at each turn end, re-scan the agent's own session store
    /// for a record born in this session's directory since launch. The newest such
    /// record is the conversation the agent is writing *now*, so a changed id means
    /// an in-process rotation (`/new`) — advance the pin and transcript through the
    /// shared adoption path. Guarded by the no-guessing rule: when two same-agent
    /// sessions share the directory, a newer record can't be attributed and nothing
    /// moves. The scan runs only on `done` reports, so its cost lands at turn end,
    /// not on a timer.
    func rediscoverConversation(for id: Session.ID) {
        guard let session = session(id),
              session.agent.resumeSpec.discover != nil,
              session.launched,
              let directory = session.worktreePath ?? project(for: id)?.path
        else { return }
        // An agent whose manifest declares an identity locator reports the id
        // whenever it is attributable; a report *without* one is deliberate (an
        // OpenCode subagent's turn end, say), and its store record — same agent,
        // same directory, newer — is exactly the false match this scan must not
        // adopt. Re-discovery is only for manifests with no identity channel.
        guard session.agent.hookSpec?.conversation == nil else { return }
        // Bound the scan to this app run's process, not the persisted first-ever
        // `launchedAt` — a resumed tab's window would otherwise span days and swallow
        // records the agent minted in runs (or outside termio) in between.
        guard let spawnedAt = processSpawnedAt[id] else { return }
        guard soleAgentSession(session.agent, in: directory, is: id) else { return }
        guard let found = AgentSessionStore.rediscover(
            agent: session.agent, directory: directory, after: spawnedAt)
        else { return }
        if adoptConversationID(found.id, for: id) {
            transcriptPaths[id] = found.transcriptPath
        }
    }

    /// Whether `id` is the only session of this agent working in `directory` — the
    /// precondition for attributing a store record to it without guessing. Paths are
    /// compared symlink-resolved, matching how the store scan canonicalizes the
    /// agent's recorded cwd (`/tmp` vs `/private/tmp` must count as the same place).
    private func soleAgentSession(_ agent: AgentDefinition, in directory: String,
                                  is id: Session.ID) -> Bool {
        func canonical(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let target = canonical(directory)
        for project in projects {
            for peer in project.sessions where peer.agent == agent && peer.id != id {
                if canonical(peer.worktreePath ?? project.path) == target { return false }
            }
        }
        return true
    }

    /// The position of a session in the project tree, for an in-place edit.
    func locate(_ id: Session.ID) -> (project: Int, session: Int)? {
        for (p, project) in projects.enumerated() {
            if let s = project.sessions.firstIndex(where: { $0.id == id }) {
                return (p, s)
            }
        }
        return nil
    }

    /// Pushes the current font and theme onto every live surface without tearing
    /// down its shell — libghostty reconfigures the running terminal in place.
    ///
    /// Reconfiguring updates the core's config but does not itself repaint: this
    /// embedding has no continuous tick (see `warmUpRendering`), so a surface only
    /// redraws on its next PTY-output wakeup. Without a nudge a theme or font change
    /// would not show until the user typed or the agent printed. So when a setter
    /// reports an actual change, pump the core briefly to flush the redraw now.
    func applyAppearanceToOpenSurfaces() {
        let appearance = appearanceConfiguration()
        let theme = makeTheme()
        for state in surfaces.values {
            let configChanged = state.controller.setTerminalConfiguration(appearance)
            let themeChanged = state.controller.setTheme(theme)
            if configChanged || themeChanged {
                pumpRendering(state, duration: 0.5)
            }
        }
    }

    /// Drives the terminal through its startup render handshake.
    ///
    /// Unlike Ghostty.app — which ticks `ghostty_app_tick` every vsync via a
    /// display link — this libghostty embedding has no continuous tick on macOS:
    /// it advances the core only reactively, one hop per PTY-output wakeup, and
    /// those wakeups are edge-triggered (a missed edge is not re-queued). Most
    /// agents paint their grid unconditionally, so a later layout/focus tick
    /// flushes them. OpenCode's renderer instead performs a multi-round-trip,
    /// reply-gated terminal-capability handshake (cursor-position, device
    /// attributes, colour and mode queries) and paints nothing until it is
    /// answered; a single dropped wakeup in that window leaves it blank forever.
    ///
    /// Pumping the core at display rate across the spawn-and-handshake window
    /// lets the round-trips complete. Once the surface has produced content its
    /// own render callbacks sustain later frames, so the pump stops a short grace
    /// after the surface reports a size, with a hard backstop in case it never
    /// attaches (the session was created but never shown).
    private func warmUpRendering(_ state: TerminalViewState) {
        let started = Date()
        let ref = WeakMainActorRef(state)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { timer in
            let keepPumping = MainActor.assumeIsolated { () -> Bool in
                guard let state = ref.value else { return false }
                state.controller.tick()
                let elapsed = Date().timeIntervalSince(started)
                return !((state.surfaceSize != nil && elapsed > 2.0) || elapsed > 6.0)
            }
            if !keepPumping { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Builds the live appearance config shared by surface creation and the
    /// re-style path.
    private func appearanceConfiguration() -> TerminalConfiguration {
        TerminalConfiguration { builder in
            applyAppearance(to: &builder)
        }
    }

    /// Translates `AppSettings` (plain values) into Ghostty config commands. This
    /// is the single place terminal-core keys are named, so surface creation and
    /// the live re-style path can never drift apart. Everything here is accepted
    /// by `setTerminalConfiguration`, which reconfigures a running surface in
    /// place — no shell restart.
    private func applyAppearance(to builder: inout TerminalConfiguration.Builder) {
        if !settings.fontFamily.isEmpty {
            builder.withFontFamily(settings.fontFamily)
            // Fallback faces from the user's Ghostty config ride along even over a
            // termio-chosen primary — repeated font-family keys form Ghostty's fallback
            // chain, and they only engage for glyphs the primary lacks (CJK above all).
            for fallback in settings.ghosttyFontFallbacks where fallback != settings.fontFamily {
                builder.withFontFamily(fallback)
            }
            // When the chain still can't draw hanzi, close with a purpose-built dual-width
            // CJK face if one is installed — otherwise the system falls back to proportional
            // PingFang per glyph, whose weight and metrics visibly fight the Latin face.
            // (The grid's cell width still follows the primary; only a dual-width *primary*
            // removes the spacing gaps entirely.)
            let chain = [settings.fontFamily] + settings.ghosttyFontFallbacks
            if let cjkFallback = InstalledFonts.cjkMonospaceFallback(existingChain: chain) {
                builder.withFontFamily(cjkFallback)
            }
        }
        builder.withFontSize(Float(settings.fontSize))
        builder.withFontThicken(settings.fontThicken)

        // `CursorStyle`'s raw values are the Ghostty cursor tokens, so this bridge
        // is a straight rawValue hand-off (the guard is just belt-and-braces).
        if let style = TerminalCursorStyle(rawValue: settings.cursorStyle.rawValue) {
            builder.withCursorStyle(style)
        }
        builder.withCursorStyleBlink(settings.cursorBlink)

        // Horizontal padding is the terminal's left/right margin (the tunable
        // Padding setting). Vertical is kept tight on purpose: the title bar sits
        // directly above the surface, so matching the setting there would open a
        // visible gap between the title and the first prompt line.
        builder.withWindowPaddingX(settings.windowPadding)
        builder.withWindowPaddingY(2)
        builder.withBackgroundOpacity(settings.backgroundOpacity)
        builder.withBackgroundBlur(settings.backgroundBlur)

        // Ghostty measures scrollback in bytes; the UI speaks megabytes.
        builder.withCustom("scrollback-limit", String(settings.scrollbackMegabytes * 1_000_000))
        // `clipboard` routes a selection to the system pasteboard; `false` leaves
        // selection copy-free (Ghostty's own default uses the X11 selection, which
        // is meaningless on macOS).
        builder.withCustom("copy-on-select", settings.copyOnSelect ? "clipboard" : "false")

        // Hold the pane open after the child process exits rather than letting
        // ghostty tear it down instantly, so a non-zero exit (or an agent that
        // quit / self-updated) stays on screen and readable, with a working
        // "Press any key to close the terminal." prompt (the keypress routes
        // through `state.onClose` → `closeSession`). A clean plain-terminal exit
        // is closed proactively in `onExit`, so it never lingers on this prompt —
        // it just vanishes like a native terminal tab.
        builder.withCustom("wait-after-command", "true")

        // The keyboard is split in two: keys that act on the terminal's text
        // (copy, paste, clear, scrollback, selection, word motion, search) stay
        // ghostty's, and keys that act on the app (sessions, panes, palettes,
        // settings, full screen) are the host's. Ghostty ships defaults on both
        // sides — ⌘D is `new_split`, ⌘T `new_tab`, ⌘, `open_config` — and a
        // surface-handled keybind is consumed before the menu bar sees the
        // event, so every host-claimed trigger has to be unbound here or the
        // menu action never fires. `surfaceUnbindTriggers` derives that set from
        // the effective binding table, so a rebind in Settings is covered too.
        for trigger in KeybindingStore.shared.surfaceUnbindTriggers {
            builder.withCustom("keybind", "\(trigger)=unbind")
        }
    }

    /// The light/dark theme pair libghostty switches between as the system
    /// appearance changes. Each slot resolves its own chosen Ghostty theme, falling
    /// back to termio's default when none is chosen (or the name no longer
    /// resolves). The light default is a pure-white canvas rather than libghostty's
    /// Alabaster (#F7F7F7): the agent UIs paint their own grey panels over it, so an
    /// off-white background just reads as unstyled. The dark default is Afterglow.
    private func makeTheme() -> TerminalTheme {
        TerminalTheme(
            light: themeConfiguration(named: settings.lightThemeName) ?? .alabaster.background("FFFFFF"),
            dark: themeConfiguration(named: settings.darkThemeName) ?? .afterglow
        )
    }

    /// Resolves a chosen theme name to its terminal configuration, or `nil` when the
    /// slot is left on the default or the name no longer resolves.
    private func themeConfiguration(named name: String) -> TerminalConfiguration? {
        guard !name.isEmpty, let definition = ThemeLibrary.theme(named: name) else { return nil }
        return definition.toTerminalConfiguration()
    }

    /// Drives `ghostty_app_tick` at display rate for a short window so a config
    /// change (theme, font, padding) repaints the live surface immediately, rather
    /// than waiting for the next PTY-output wakeup. A fixed short pump is enough: a
    /// color/font reconfigure needs no reply-gated handshake the way a cold spawn
    /// does, so a handful of frames flush the new look.
    /// Repaints the selected session's surface for a brief window. Used when a full-window
    /// overlay — the maximized inspector detail — is torn down and re-exposes the terminal:
    /// this embedding has no continuous tick (see `warmUpRendering`), so an uncovered surface
    /// would otherwise sit on its stale last frame (a blank on a fresh session) until the next
    /// PTY-output or focus event. This is issue #160's fullscreen blank-on-tab-switch.
    func repaintSelectedSurface() {
        guard let id = selectedSessionID, let state = surfaces[id] else { return }
        pumpRendering(state, duration: 0.25)
    }

    /// Keeps every visible surface painting for the length of a pane drag.
    ///
    /// The drag overlay washes translucently over the *live* surfaces, so the
    /// layer underneath is re-blended every frame of the gesture. Ghostty.app
    /// affords that by ticking the core every vsync from a display link; this
    /// embedding advances only on a PTY-output wakeup (see `warmUpRendering`),
    /// so a quiet terminal hands the compositor its last frame for the whole
    /// drag and the wash smears stale pixels. Same failure as the uncovered
    /// surface above, same fix: pump while it matters, stop when it doesn't.
    func beginPaneDragRepaint() {
        paneDragRepaintTimer?.invalidate()
        let ref = WeakMainActorRef(self)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { timer in
            let keepPumping = MainActor.assumeIsolated { () -> Bool in
                guard let self = ref.value else { return false }
                for id in self.visiblePaneIDs {
                    self.surfaces[id]?.controller.tick()
                }
                return true
            }
            if !keepPumping { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        paneDragRepaintTimer = timer
    }

    /// Ends the drag pump, with one last pass so the panes settle on a fresh
    /// frame after the tree has been rebuilt under them.
    func endPaneDragRepaint() {
        paneDragRepaintTimer?.invalidate()
        paneDragRepaintTimer = nil
        for id in visiblePaneIDs {
            guard let state = surfaces[id] else { continue }
            pumpRendering(state, duration: 0.25)
        }
    }

    private func pumpRendering(_ state: TerminalViewState, duration: TimeInterval) {
        let started = Date()
        let ref = WeakMainActorRef(state)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { timer in
            let keepPumping = MainActor.assumeIsolated { () -> Bool in
                guard let state = ref.value else { return false }
                state.controller.tick()
                return Date().timeIntervalSince(started) <= duration
            }
            if !keepPumping { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Watches the surface's already-published activity signals and flags the
    /// session as needing attention when it rings the bell or posts a desktop
    /// notification while the user is looking elsewhere. (Claude Code emits
    /// OSC 9/99 notifications natively inside Ghostty, so this works with no
    /// per-agent configuration.) Selecting the session clears the flag.
    ///
    /// A `.done` session is never downgraded here. Bell and notification are
    /// *edge* events — "something happened", not "this is my state" — and agents
    /// fire them for turn completion as much as for being blocked: Grok posts an
    /// OSC 777 turn-complete notification a few seconds *after* its Stop hook
    /// (its unfocused-delay default), which would repaint the green "finished"
    /// as the orange "waiting for you" on every tool-using turn. Once a turn has
    /// ended, nothing can be blocked on the user, so the flag is meaningless.
    /// The title channel keeps its right to override `done` (see
    /// `applyTitleActivity`): a title is a *level* signal of the agent's current
    /// state, so "Action Required" after a turn ends is a real question to you.
    private func monitor(_ state: TerminalViewState, for id: Session.ID) {
        let flag: () -> Void = { [weak self] in
            guard let self, !self.isViewing(id), self.status(for: id) != .done
            else { return }
            self.setStatus(.needsAttention, for: id)
        }
        monitors[id] = [
            state.$lastBellAt.dropFirst().compactMap { $0 }.sink { _ in flag() },
            state.$lastDesktopNotificationAt.dropFirst().compactMap { $0 }.sink { _ in flag() },
            // The surface already publishes the program's live `OSC 0/2` title;
            // classify it as a status signal, then adopt the meaningful values as
            // the agent session's display label. Classification sees the RAW
            // title — the working/idle marks (Claude's braille spinner prefix,
            // Codex's "Action Required") are exactly what the label sanitizer
            // strips as noise. Every frame of a ticking title spinner republishes
            // here; `applyTitleActivity` collapses them on its own transition
            // guard, so per-frame work is one regex over a short string.
            state.$title.removeDuplicates().sink { [weak self] title in
                guard let self, let session = self.session(id) else { return }
                let agent = self.effectiveAgent(for: session)
                if let rules = agent.titleRules {
                    let (activity, matched) = rules.explain(title)
                    if ProcessInfo.processInfo.environment["TERMIO_STATUS_TRACE"] != nil {
                        AgentStatusRules.trace(
                            agent: "\(agent.id).title", session: id,
                            activity: activity, matched: matched)
                    }
                    self.applyTitleActivity(activity, for: id)
                }
                let cleaned = LiveTerminalTitle.sanitized(title)
                guard self.isMeaningfulLiveTitle(cleaned, for: session),
                      self.runtimes[id]?.liveTitle != cleaned else { return }
                self.setLiveTitle(cleaned, for: id)
                // Also record it on the session itself, so the label survives an
                // app restart (the agent won't re-emit a title until it next works).
                // Declared agent sessions only: a plain terminal's adopted title
                // belongs to the transient hand-started agent, so it lives in
                // `liveTitles` and is cleared when that agent exits — persisting it
                // would strand a stale topic on a bare shell across restarts.
                if session.agent != .terminal, let location = self.locate(id) {
                    self.projects[location.project].sessions[location.session]
                        .liveTitle = cleaned
                }
            },
            // The shell's OSC 7 cwd reports — the precise signal, when a shell
            // with integration actually emits it (the kernel poll in
            // `surface(for:in:)` covers the common integration-less shell).
            state.$workingDirectory.compactMap { $0 }.removeDuplicates()
                .sink { [weak self] cwd in self?.noteWorkingDirectory(cwd, for: id) },
        ]
    }

    /// Records a session's reported working directory, from either source (the
    /// shell's OSC 7 or the kernel poll): publishes it for the sidebar row label
    /// and the cwd-following inspector, and — for a loose terminal only — persists
    /// it on the session itself, since the cwd is that entity's own path (the
    /// shell respawns there next launch; see docs/design/20260713-loose-terminal-entity.md).
    func noteWorkingDirectory(_ cwd: String, for id: Session.ID) {
        setWorkingDirectory(cwd, for: id)
        guard let location = locate(id),
              projects[location.project].kind == .terminals,
              projects[location.project].sessions[location.session]
                  .lastWorkingDirectory != cwd else { return }
        projects[location.project].sessions[location.session].lastWorkingDirectory = cwd
    }

    /// Whether a live terminal title is worth showing as the session's label, as
    /// opposed to the startup noise we'd rather not flash. Only agent sessions adopt
    /// one — a declared agent, or a plain terminal running a *detected* hand-started
    /// agent (see `effectiveAgent`); a bare shell keeps its `Terminal N` numbering. And
    /// even for an agent we reject what it reports before it has anything to say: an
    /// empty string, a bare path or `user@host`, or just the program's own name.
    private func isMeaningfulLiveTitle(_ title: String, for session: Session) -> Bool {
        let agent = effectiveAgent(for: session)
        guard agent != .terminal else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~"),
              !trimmed.contains("@") else { return false }
        let lowered = trimmed.lowercased()
        if lowered == agent.displayName.lowercased() { return false }
        if let command = agent.command {
            let firstToken = command.split(separator: " ").first.map(String.init) ?? command
            if lowered == (firstToken as NSString).lastPathComponent.lowercased() { return false }
        }
        // Shells set the OSC title to the working-directory basename (e.g. "termio"),
        // and some agents prefix it with a brand glyph that survives sanitizing
        // because the glyph is a Unicode letter (Pi reports "π - termio"); either way
        // it names the folder, not the agent's activity, so it is not meaningful. Test
        // both the whole title and the segment after a " - " separator.
        let workingDirectory = session.worktreePath ?? project(for: session.id)?.path
        if let workingDirectory {
            let folder = (workingDirectory as NSString).lastPathComponent.lowercased()
            let tail = lowered.components(separatedBy: " - ").last ?? lowered
            if lowered == folder || tail == folder { return false }
        }
        return true
    }
}

/// Carries a weak main-actor reference into a pump timer's @Sendable closure.
/// @unchecked: the timers are added to RunLoop.main only, and their closures
/// re-enter the main actor (`assumeIsolated`) before touching the referent.
private struct WeakMainActorRef<Value: AnyObject>: @unchecked Sendable {
    private weak var referent: Value?
    init(_ value: Value) { referent = value }
    @MainActor var value: Value? { referent }
}
