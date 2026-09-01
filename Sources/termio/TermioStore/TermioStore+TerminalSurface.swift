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
        let resolved = realpath(cwd, &buffer) != nil
            ? String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            : cwd
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
    /// What a session's process exiting means for its pane.
    enum SessionExit: Equatable {
        /// The agent replaced its own binary and quit asking to be restarted
        /// (codex's in-pane upgrade ends with "Please restart Codex."). Respawn it
        /// in place with its resume arguments — the restart, done for the user.
        case relaunch
        /// A clean `/quit`: hand the pane back to a shell in the same directory,
        /// exactly where a hand-started agent leaves you.
        case revertToShell
        /// A plain terminal that exited cleanly. The pane goes away with no extra
        /// keypress, like a native terminal tab.
        case close
        /// Leave the exit on screen, on ghostty's "Press any key to close"
        /// prompt, so a failure's output stays readable.
        case park
    }

    /// The exit policy, as a decision with no side effects, so the in-process PTY
    /// and the daemon link run the *same* one rather than two that drift.
    ///
    /// Both backends know the same three things at exit: the code, what the row
    /// is, and whether the launch binary was replaced underneath the running
    /// process. Only the last differs in how it is *learned* — the local PTY pins
    /// the executable itself, the daemon owns the process and reports it — which
    /// is a producer difference, not a policy one.
    ///
    /// - Parameters:
    ///   - isAgentSession: a declared agent, not a plain terminal and not `ssh`.
    ///   - isPlainTerminal: the row's declared agent is `.terminal` (an SSH
    ///     terminal is one of these, which is why the two flags are separate
    ///     rather than one being the negation of the other).
    ///   - executableReplaced: `false` when nothing knows — an absent answer must
    ///     never respawn a process the user quit.
    static func sessionExit(code: Int32, isAgentSession: Bool, isPlainTerminal: Bool,
                            executableReplaced: Bool) -> SessionExit {
        // A non-zero exit always parks: its error output is the only record of
        // what went wrong, and closing or respawning over it loses that.
        guard code == 0 else { return .park }
        if isAgentSession { return executableReplaced ? .relaunch : .revertToShell }
        return isPlainTerminal ? .close : .park
    }

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
    /// shell) in the session's working directory via the real PTY (`.exec`).
    func surface(for session: Session) -> TerminalViewState {
        if let existing = surfaces[session.id] {
            return existing
        }

        // An isolated worktree (if one was created for this session) wins over the
        // project's own directory, so the agent edits the branch in place.
        // A loose terminal instead respawns at the cwd it last reported over OSC 7
        // (its path is the session's own mutable property, not a container's) —
        // so a relaunch drops the user back where they `cd`'d, not at `$HOME`.
        // Ahead of the worktree/project anchor sits the directory the session was
        // opened in (⌘T): where the user asked *this* shell to start, even when the
        // session belongs to a project rooted elsewhere. Each rung must still exist —
        // a stale path falls through rather than dropping the shell at `/`.
        let slot = locate(session.id)
        let isLooseTerminal: Bool
        if case .terminals? = slot { isLooseTerminal = true } else { isLooseTerminal = false }
        let restoredCwd = isLooseTerminal
            ? Self.existingDirectory(session.lastWorkingDirectory)
            : nil
        // A session that runs on another machine works in a directory on *that*
        // box — handing it to the local PTY would `chdir` somewhere that doesn't
        // exist here, or worse, somewhere that does. The remote cwd travels
        // separately: `session.termiodRemoteCwd` for a termiod session, the remote
        // login shell's own default for a plain `ssh`. Locally these spawn at `$HOME`.
        let localRoot: String
        if session.sshHost != nil || session.termiodRemoteHost != nil {
            localRoot = Self.looseTerminalRoot
        } else if case .project(let index, _)? = slot {
            localRoot = projects[index].path
        } else if case .chats? = slot {
            localRoot = ensureLooseChatRoot()
        } else {
            localRoot = Self.looseTerminalRoot
        }
        let spawnPath = restoredCwd
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
        let launch = session.sshHost.map {
            (command: Self.sshLaunchCommand(host: $0, keyToInstall: session.sshKeyToInstall),
             resumeID: String?.none)
        } ?? resolveLaunch(for: session, spawnPath: spawnPath)
        let agentCommand = launch.command

        // Pi checks the pinned `--session-id` against its session store at startup
        // and warns when no file exists yet; pre-creating it keeps the launch silent.
        // The manifest opts in via `resume.seed`, so no agent is named here.
        if session.agent.resumeSpec.seed == "session-file", let pinnedID = launch.resumeID {
            PiSession.ensureExists(id: pinnedID, cwd: spawnPath)
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
        // letting `termio agent report` name this exact session.
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

        // An SSH session to a host with a saved password answers the prompt from
        // the Keychain instead of asking. Empty for every other host and for every
        // host with nothing saved, so ssh behaves exactly as it always has. The
        // key install is deliberately excluded: `ssh-copy-id` is how a password
        // host stops being one, and feeding it the password it is trying to
        // replace would install the key while teaching the user nothing.
        if let host = session.sshHost, session.sshKeyToInstall == nil {
            env.merge(SSHPasswordStore.askpassEnvironment(for: host)) { _, new in new }
        }

        // The session runs inside the daemon and this app instance attaches to
        // it, so quitting detaches instead of killing.
        //
        // Attached at the last real host grid rather than a fixed 80x24, so the
        // shell's first prompt is drawn at (usually) the window's actual width
        // and the first layout pass doesn't reflow it — the reflow that mangles
        // zsh's `PROMPT_SP` line into a stray `%` (see `lastHostGridColumns`).
        let termiodLink = makeTermiodLink(
            for: session, argv: argv, cwd: spawnPath, env: env)
        let inMemory = InMemoryTerminalSession(
            write: { data in
                // libghostty answers the host's terminal queries through this
                // same closure. Those are not the user, so they must not claim
                // the token — and only the writer's surface may answer at all
                // (`TerminalDeviceReport`).
                guard !TerminalDeviceReport.isReport(data) else {
                    termiodLink.sendDeviceReport(data)
                    return
                }
                // Typing on the Mac reclaims the write token, and with it the
                // winsize, from an attached phone — the size follows the device
                // being used. `send` does the claiming.
                // The daemon stamps the keystroke itself, on the write path
                // every client crosses, so the screen-streak promotion stands
                // down for a phone's typing as well as this window's.
                termiodLink.send(data)
            },
            resize: { [weak self] viewport in
                let columns = Int(viewport.columns)
                let rows = Int(viewport.rows)
                termiodLink.resize(rows: rows, cols: columns)
                // Remember the host grid for the next session's initial size.
                DispatchQueue.main.async { self?.rememberHostGrid(columns: columns, rows: rows) }
            }
        )
        attachTermiodLink(termiodLink, to: inMemory, for: session)

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
    /// No `ControlMaster` options are injected. The session used to double as a
    /// master so the inspector's SFTP tree could ride it; the tree now reads the
    /// device's own daemon, which brings its own multiplexing
    /// (`Termiod.sshArguments`) and, unlike this, only after checking
    /// that the user's `~/.ssh/config` left the decision to us.
    static func sshCommand(host: String) -> String {
        "ssh -- \(shellQuoted(host))"
    }

    /// What an SSH session actually launches: normally the shell above, but the
    /// one-shot `ssh-copy-id` when the session carries a key to install.
    ///
    /// `ssh-copy-id` is the only place termio takes part in a password at all, and
    /// it takes part by getting out of the way — the prompt is the remote server's,
    /// answered on this PTY by the person sitting here. What it leaves behind is a
    /// key, which is the one credential the paths that can never prompt
    /// (`BatchMode=yes` on every termiod connection) are able to use.
    static func sshLaunchCommand(host: String, keyToInstall: String?) -> String {
        guard let keyToInstall else { return sshCommand(host: host) }
        return "ssh-copy-id -i \(shellQuoted(keyToInstall)) -- \(shellQuoted(host))"
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
    private func resolveLaunch(for session: Session, spawnPath: String)
        -> (command: String?, resumeID: String?) {
        // Resolved against the machine the session runs on: a command path typed
        // for this Mac's Homebrew install names nothing on a VPS, so handing it to
        // one is the "settings silently mean this Mac" bug at its most expensive —
        // the agent dies at 0 ms with "not found".
        let device = KnownDevice.running(session) ?? .thisMac
        guard let base = settings.command(for: session.agent, on: device) else {
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
                ?? AgentSessionStore.discover(agent: agent, directory: spawnPath,
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
        guard var session = session(id) else { return }
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
        updateSession(id) { $0 = session }
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
        guard let slot = locate(id) else { return false }
        var session = self[slot]
        // Only a session whose declared agent participates in conversation identity
        // (a pinned, discovered, or resumable id) has a pin to keep honest. A plain
        // terminal that merely *runs* an agent relaunches as a shell, so adopting an
        // id there is pure noise.
        let spec = session.agent.resumeSpec
        guard spec.pinsID || spec.discoversID || spec.resume != nil else { return false }
        guard conversationID != session.resumeID else { return false }
        // A genuine rotation (the pin already named a conversation and it changed —
        // not the first-report adoption of an unpinned session) also orphans the
        // sidebar topic titles: they describe the discarded conversation. Drop the
        // in-memory native title plus both persisted candidates so `displayTitle`
        // falls back to the agent name until the new conversation earns a topic.
        // Status and `lastTitleActivity` are separate channels — leave them alone.
        if session.resumeID != nil {
            setLiveTitle(nil, for: id)
            session.liveTitle = nil
            session.promptTitle = nil
        }
        session.resumeID = conversationID
        self[slot] = session
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

    /// The surface's top/bottom margin in points. Named because the pane needs
    /// the same number to size a letterboxed surface to an exact grid.
    static let terminalWindowPaddingY = 2

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
        builder.withWindowPaddingY(Self.terminalWindowPaddingY)
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
    /// resolves). The light default is `lightDefaultTheme` — a pure-white canvas
    /// rather than libghostty's Alabaster (#F7F7F7), because the agent UIs paint
    /// their own grey panels over it and an off-white background just reads as
    /// unstyled. The dark default is Afterglow.
    private func makeTheme() -> TerminalTheme {
        TerminalTheme(
            light: Self.themeConfiguration(named: settings.lightThemeName) ?? Self.lightDefaultTheme,
            dark: Self.themeConfiguration(named: settings.darkThemeName) ?? .afterglow
        )
    }

    /// termio's light default: Alabaster on a pure-white canvas, with ANSI white and
    /// bright white moved from paper to ink.
    ///
    /// Alabaster names slots 7 and 15 by literal color (#F7F7F7 — its own original
    /// background) rather than by role, so anything an agent prints as "white" lands
    /// at 1.07:1 against the canvas and disappears. That is issue #426: Claude Code
    /// draws its version, cwd and shortcut hints in ANSI white, which is legible on
    /// the dark terminal it assumes and invisible here. Light themes that read well
    /// (Xcode Light, Monokai Pro Light) map both slots to the foreground instead; 7
    /// stays the softer of the two so a secondary line still reads as secondary.
    static let lightDefaultTheme = TerminalConfiguration.alabaster
        .background("FFFFFF")
        .palette(7, color: "#4D4D4D")
        .palette(15, color: "#262626")
        .minimumContrast(lightContrastFloor)

    /// The WCAG floor libghostty enforces per glyph, against that glyph's own
    /// background, for light themes only.
    ///
    /// It is a floor rather than a remap because a theme's palette is not the only
    /// way text arrives — an agent can set a color directly, or rewrite the palette
    /// at runtime through OSC 4. 1.5 is the knee measured across the bundled
    /// catalog: it rescues every entry that is invisible against its own background
    /// while flattening none that a reader could already make out. Higher is worse,
    /// not better — libghostty snaps a failing foreground to pure black or white
    /// rather than nudging it, so a 3.0 floor turns legible yellows and greens
    /// black. Dark themes get no floor: their one sub-floor slot is ANSI black on a
    /// dark canvas, which every dark theme does on purpose.
    static let lightContrastFloor = 1.5

    /// Resolves a chosen theme name to its terminal configuration, or `nil` when the
    /// slot is left on the default or the name no longer resolves. The contrast floor
    /// follows the theme's own brightness rather than the slot it was chosen into, so
    /// a light theme parked in the Dark slot keeps its protection and a dark one
    /// parked in the Light slot keeps its intentional black-on-black.
    static func themeConfiguration(named name: String) -> TerminalConfiguration? {
        guard !name.isEmpty, let definition = ThemeLibrary.theme(named: name) else { return nil }
        let configuration = definition.toTerminalConfiguration()
        guard !definition.isDark else { return configuration }
        return configuration.minimumContrast(Self.lightContrastFloor)
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
    /// The title channel keeps its right to override `done` (the device's
    /// `StatusEngine::note_title`): a title is a *level* signal of the agent's
    /// current state, so "Action Required" after a turn ends is a real question.
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
            // the agent session's display label. The status half of this channel
            // is the device's now — it reads the same `OSC 0/2` out of the byte
            // stream, against the same manifest rules, for every client at once
            // (`termiod/src/session/status.rs`). What is left here is the label.
            state.$title.removeDuplicates().sink { [weak self] title in
                guard let self, let session = self.session(id) else { return }
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
                if session.agent != .terminal {
                    self.updateSession(id) { $0.liveTitle = cleaned }
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
        guard let slot = locate(id), case .terminals = slot,
              self[slot].lastWorkingDirectory != cwd else { return }
        self[slot].lastWorkingDirectory = cwd
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
