import AppKit
import Foundation

extension TermioStore {
    /// Adds a session to a project, optionally running in one of its linked
    /// worktree folders while remaining in the project's flat session roster.
    @discardableResult
    func addSession(
        to projectID: Project.ID,
        agent: AgentPreset = .terminal,
        worktreePath: String? = nil,
        spawnDirectory: String? = nil,
        takeFocus: Bool = true
    ) -> Session.ID? {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        let project = projects[index]
        let terminalCount = project.sessions.filter { $0.agent == .terminal }.count
        let title = agent == .terminal
            ? "Terminal \(terminalCount + 1)"
            : agent.displayName
        var session = Session(title: title, agent: agent)
        session.worktreePath = worktreePath
        session.spawnDirectory = spawnDirectory
        projects[index].sessions.append(session)
        if takeFocus {
            selectedSessionID = session.id
        } else {
            activateInBackground(session.id)
        }
        return session.id
    }

    /// Which gap a dragged row lands in, relative to the row it was released over.
    enum RowInsertion {
        case above, below
    }

    /// Whether `moved` may be drag-reordered next to `target`: both must sit in the
    /// same roster — one project, or one workspace's Terminals or Chats — and the
    /// same worktree bucket. Drives which rows light their background as a legal
    /// drop target while a session is in flight, so a cross-section hover stays inert.
    func canReorder(_ moved: Session.ID, relativeTo target: Session.ID) -> Bool {
        guard moved != target,
              let movedSlot = locate(moved), let targetSlot = locate(target),
              movedSlot.sharesRoster(with: targetSlot)
        else { return false }
        return sessionBucketKey(self[movedSlot], at: movedSlot)
            == sessionBucketKey(self[targetSlot], at: targetSlot)
    }

    /// Moves `moved` to the `side` of `target` within their shared roster, committed
    /// on drop (a cross-roster move is a no-op via `canReorder`). Persistence rides
    /// the tree's `didSet` like every roster edit.
    ///
    /// The side is the caller's, not inferred from which row started higher: the
    /// sidebar draws an insertion line at the edge the pointer is nearest, and a
    /// line that showed one gap while the row landed in another would be a lie.
    func reorderSession(_ moved: Session.ID, relativeTo target: Session.ID,
                        insert side: RowInsertion) {
        guard canReorder(moved, relativeTo: target),
              let movedSlot = locate(moved)
        else { return }

        var sessions = roster(at: movedSlot)
        let row = sessions.remove(at: movedSlot.sessionIndex)
        // Re-find the target after the removal so its index stays valid regardless of
        // which row came first.
        let newTarget = sessions.firstIndex(where: { $0.id == target }) ?? sessions.count - 1
        sessions.insert(row, at: side == .above ? newTarget : newTarget + 1)
        setRoster(sessions, at: movedSlot)
        // A drop that lands between a group's rows would split its bracket in two;
        // rows only join or leave a group through "Group with" / "Ungroup", so the
        // run closes back up around the dropped row (see `gatherSplitRuns`).
        gatherSplitRuns()
    }

    /// The sidebar bucket a session sits in: `nil` for the primary checkout (a `nil`
    /// or project-root `worktreePath`) and for every loose session, else the worktree
    /// path. Reorder works only within one bucket, matching how the sidebar nests.
    private func sessionBucketKey(_ session: Session, at slot: SessionSlot) -> String? {
        guard case .project(let index, _) = slot else { return nil }
        if session.worktreePath == nil || session.worktreePath == projects[index].path { return nil }
        return session.worktreePath
    }

    /// Creates a fresh detached checkout and records its folder under the parent
    /// project. No session is forced into it: the nested header remains available so
    /// the user can add terminals or agents when ready.
    func addWorktree(from projectID: Project.ID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let project = projects[index]

        let repoName = (project.path as NSString).lastPathComponent
        let worktreeRoot = AppChannel.homeConfigDirectory
            .appendingPathComponent("worktrees", isDirectory: true)

        // Let the user name the worktree, defaulting to the next free `<repo>-worktree-N`.
        // Bailing out of the prompt leaves the tree untouched.
        let suggestion = uniqueWorktreeDirName(from: "\(repoName)-worktree", root: worktreeRoot)
        guard let entered = promptForWorktreeName(defaultName: suggestion) else { return }

        // A hand-typed name can be non-filesystem-safe or collide with an existing
        // worktree; sanitize it and bump a counter so the path is always fresh.
        let dirName = uniqueWorktreeDirName(from: entered, root: worktreeRoot)
        let worktreePath = worktreeRoot.appendingPathComponent(dirName, isDirectory: true).path

        do {
            try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        } catch {
            presentWorktreeFailure(message: localized("Couldn’t create the worktrees folder: \(error.localizedDescription)"))
            return
        }
        // Create the worktree on a fresh branch named after it, not detached. A
        // detached HEAD has no name, so every git-aware surface improvises a different
        // label for the same checkout — the sidebar node shows the folder name while
        // the inspector chip and the shell's own prompt show the commit SHA. A named
        // branch makes all three agree (and the shell prompt is only reachable this
        // way — zsh reads HEAD itself). The dir name is already collision-free on disk;
        // the branch needs its own guard, since a branch can exist with no worktree.
        let branchName = uniqueBranchName(base: dirName, in: project.path)
        guard runGit(["worktree", "add", "-b", branchName, worktreePath, "HEAD"], in: project.path) != nil else {
            presentWorktreeFailure(message: localized("git couldn’t create a worktree for “\(project.name)”. Is it a git repository with at least one commit?"))
            return
        }

        copyWorktreeIncludes(from: project.path, to: worktreePath)
        projects[index].worktrees.append(Worktree(path: worktreePath))
    }

    /// A branch name free in `repo`, starting from `base` and bumping a `-2`, `-3`, …
    /// suffix until `git` reports no such ref. `base` is already filesystem-safe
    /// (hyphenated by `uniqueWorktreeDirName`), which is also valid for a branch name.
    /// `show-ref --verify --quiet` exits 0 when the ref exists, so a non-nil result
    /// means "taken".
    private func uniqueBranchName(base: String, in repo: String) -> String {
        var candidate = base
        var counter = 2
        while runGit(["show-ref", "--verify", "--quiet", "refs/heads/\(candidate)"], in: repo) != nil {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }

    /// Removes a clean linked checkout, then drops its container and matching flat
    /// sessions from the parent project. Dirty work always stays on disk and in the
    /// sidebar so an accidental cleanup cannot discard agent changes.
    func removeWorktree(_ worktreeID: Worktree.ID, from projectID: Project.ID) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let worktree = projects[projectIndex].worktrees.first(where: { $0.id == worktreeID })
        else { return }

        guard let status = runGit(["status", "--porcelain"], in: worktree.path) else {
            presentWorktreeFailure(
                title: localized("Couldn’t inspect worktree"),
                message: localized("git couldn’t check “\((worktree.path as NSString).lastPathComponent)” for changes, so it was not removed.")
            )
            return
        }
        guard status.isEmpty else {
            presentWorktreeFailure(
                title: localized("Worktree has changes"),
                message: localized("Commit or discard the changes in “\((worktree.path as NSString).lastPathComponent)” before removing it.")
            )
            return
        }
        // The branch termio created for this worktree, captured before removal so it can
        // be tidied afterward. A user who switched branches inside the worktree leaves a
        // different name here — that is theirs to keep, and the safe delete below won't
        // touch it if it carries unmerged commits.
        let branch = runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: worktree.path)
        guard runGit(["worktree", "remove", worktree.path], in: projects[projectIndex].path) != nil else {
            presentWorktreeFailure(
                title: localized("Couldn’t remove worktree"),
                message: localized("git couldn’t remove “\((worktree.path as NSString).lastPathComponent)”.")
            )
            return
        }

        let pruneSucceeded = runGit(["worktree", "prune"], in: projects[projectIndex].path) != nil
        // Best-effort tidy of the auto-created branch. `-d` (not `-D`) refuses to drop a
        // branch with unmerged commits, so real work is never lost — the branch simply
        // stays. Skips a detached HEAD ("HEAD") and any failure is silent.
        if let branch, branch != "HEAD" {
            runGit(["branch", "-d", branch], in: projects[projectIndex].path)
        }
        let sessionIDs = projects[projectIndex].sessions
            .filter { $0.worktreePath == worktree.path }
            .map(\.id)
        for sessionID in sessionIDs { closeSession(sessionID) }
        if let updatedProjectIndex = projects.firstIndex(where: { $0.id == projectID }) {
            projects[updatedProjectIndex].worktrees.removeAll { $0.id == worktreeID }
        }
        if !pruneSucceeded {
            presentWorktreeFailure(
                title: localized("Worktree removed"),
                message: localized("The folder was removed, but git couldn’t prune its stale worktree metadata.")
            )
        }
    }

    /// Copies the git-ignored files a repo lists in `.worktreeinclude` into a freshly
    /// created worktree — the same manifest (gitignore-style globs) Codex and Claude
    /// Code read, so a repo already set up for them works here unchanged. A fresh
    /// worktree only has tracked files, so without this its `.env`/secrets are missing
    /// and the agent's dev server won't boot. Only files that are *both* ignored and
    /// match a pattern are copied (git resolves that for us); a missing manifest is a
    /// no-op. Copy failures are logged, not fatal — a partial env beats no worktree.
    private func copyWorktreeIncludes(from repoPath: String, to worktreePath: String) {
        let manifest = (repoPath as NSString).appendingPathComponent(".worktreeinclude")
        guard FileManager.default.fileExists(atPath: manifest) else { return }
        guard let listing = runGit(
            ["ls-files", "--others", "--ignored", "--exclude-from=\(manifest)"],
            in: repoPath
        ), !listing.isEmpty else { return }
        for relative in listing.split(separator: "\n").map(String.init) {
            let source = (repoPath as NSString).appendingPathComponent(relative)
            let destination = (worktreePath as NSString).appendingPathComponent(relative)
            guard !FileManager.default.fileExists(atPath: destination) else { continue }
            do {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: destination).deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(atPath: source, toPath: destination)
            } catch {
                FileHandle.standardError.write(Data("termio: .worktreeinclude copy failed for \(relative): \(error)\n".utf8))
            }
        }
    }

    /// A modal name prompt for a new worktree — one text field in an `NSAlert`,
    /// pre-filled with `defaultName` and pre-selected so the user can accept it with a
    /// single Return or type over it. Returns the trimmed entry, or `nil` if cancelled
    /// or emptied. Mirrors the file-browser rename prompt so both feel the same.
    private func promptForWorktreeName(defaultName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = localized("New Worktree")
        alert.informativeText = localized("Name the worktree. A new branch of this name is created from HEAD and nested under this project.")
        alert.addButton(withTitle: localized("Create"))
        alert.addButton(withTitle: localized("Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        field.selectText(nil)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Turns a proposed worktree name into a folder name that is safe on disk and free
    /// of any existing worktree directory. Path separators and whitespace collapse to
    /// hyphens (so "my feature/x" → "my-feature-x"); if that name is already taken under
    /// `root`, a `-2`, `-3`, … suffix is appended until the path is unused. Doubles as
    /// the default-name generator (pass the bare `<repo>-worktree` base).
    private func uniqueWorktreeDirName(from proposed: String, root: URL) -> String {
        let base = proposed
            .components(separatedBy: CharacterSet(charactersIn: "/\\").union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let safeBase = base.isEmpty ? "worktree" : base

        var candidate = safeBase
        var counter = 2
        while FileManager.default.fileExists(
            atPath: root.appendingPathComponent(candidate, isDirectory: true).path
        ) {
            candidate = "\(safeBase)-\(counter)"
            counter += 1
        }
        return candidate
    }

    /// Reports a worktree lifecycle failure instead of leaving an operation's
    /// partial or refused outcome silent.
    private func presentWorktreeFailure(
        title: String = localized("Couldn’t create worktree session"),
        message: String
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Opens a fresh scratch terminal — a plain login shell in the user's home
    /// directory, the way launching a new iTerm2 window drops you at `~`. Loose
    /// terminals aren't tied to a real project, so they belong to the workspace
    /// itself; each later click adds another `Terminal N` row to its Terminals
    /// section and selects it (the same grow-in-place a project's own header
    /// buttons do). The rows persist with the workspace, so they reappear on
    /// relaunch (the shells themselves restart fresh).
    func addScratchTerminal() {
        // A machine's fallback workspace *is* that machine, so a shell opened in
        // it opens over there. Every other workspace is this Mac's unless the row
        // that started the shell said otherwise.
        if let alias = currentWorkspace.deviceAlias {
            addRemoteTerminal(host: alias)
            return
        }
        addScratchSession(agent: .terminal)
    }

    /// Opens a terminal where the user already is — New Terminal (⌘T). The shell
    /// starts in the focused session's working directory and the row lands beside it:
    /// in the same project and worktree bucket for a real project, in the Terminals
    /// section for a loose shell or a scratch chat (a shell has no business in the
    /// Chats funnel).
    ///
    /// The directory is the cwd the session reported over OSC 7. A shell without
    /// integration never reports one, and an SSH terminal reports a path that exists
    /// only on the remote host, so anything that isn't a local directory falls through
    /// to the session's own anchor — and to `$HOME` with nothing focused, which is
    /// what New Terminal at Home does on purpose.
    func addTerminalHere() {
        guard let id = selectedSessionID, let slot = locate(id) else {
            addScratchTerminal()
            return
        }
        let session = self[slot]
        // "Here" is a directory on this Mac and does not exist on another
        // machine, so a session that runs elsewhere degrades to that machine's
        // `$HOME` rather than pointing at a path that isn't there.
        if let alias = session.termiodRemoteHost ?? session.sshHost {
            addRemoteTerminal(host: alias)
            return
        }
        let reported = Self.existingDirectory(
            workingDirectory(for: id) ?? session.lastWorkingDirectory)
        guard case .project(let index, _) = slot else {
            let directory = reported ?? session.spawnDirectory
            addScratchSession(agent: .terminal, spawnDirectory: directory)
            return
        }
        let directory = reported
            ?? session.spawnDirectory
            ?? session.worktreePath
            ?? projects[index].path
        addSession(to: projects[index].id, agent: .terminal,
                   worktreePath: session.worktreePath, spawnDirectory: directory)
    }

    /// The agent a bare **New Chat** launches, resolved in priority order:
    /// 1. the agent the user pinned in Settings ▸ Agents (`defaultChatAgentID`),
    /// 2. else "Last used" — the last agent a chat was started with,
    /// 3. else the first enabled coding agent.
    /// Every step is guarded by "still enabled", so a pinned or last-used agent that
    /// is later disabled degrades gracefully instead of launching a hidden agent.
    /// `nil` only when the user has disabled *every* agent — then New Chat is a no-op
    /// and its menu entry hides. The per-agent picker (welcome page, command palette)
    /// is where a *specific* agent is still chosen; the menus offer one New Chat.
    func defaultChatAgent() -> AgentPreset? {
        let enabled = enabledAgentPresets(settings).filter { $0 != .terminal }
        if let id = settings.defaultChatAgentID,
           let pinned = enabled.first(where: { $0.id == id }) { return pinned }
        if let id = settings.lastChatAgentID,
           let last = enabled.first(where: { $0.id == id }) { return last }
        return enabled.first
    }

    /// Starts one scratch chat with the default agent — the single action behind
    /// File ▸ New Chat (⌘N), the `+` menu's New Chat, and the Chats section header.
    func addDefaultChat() {
        guard let agent = defaultChatAgent() else { return }
        addScratchSession(agent: agent)
    }

    /// Opens a fresh scratch session that isn't tied to a real project — the welcome
    /// page's agent chips and the `+` button both land here.
    ///
    /// *Where* it runs depends on what it runs. A plain **terminal** drops at `~`,
    /// the way iTerm2/Terminal.app open a new window — a human shell at home is
    /// expected and harmless. An **agent**, though, must never be handed `$HOME` as
    /// its working directory: an autonomous agent there can read and write the user's
    /// whole home (`~/.ssh`, `~/Documents`, …). So agents get a dedicated, scoped
    /// scratch directory at `~/.termio/chats/` (created on first use, sibling to
    /// the existing `~/.termio/worktrees/`), a clean folder that's safe to let an
    /// agent loose in.
    ///
    /// The row lands in the current workspace's own collection — Terminals for a
    /// shell, Chats for an agent — so a second click grows the section rather than
    /// piling up duplicates.
    ///
    /// `spawnDirectory` overrides where a scratch *terminal* starts, so ⌘T from a
    /// loose shell opens its sibling at the same cwd. Agents ignore it: being
    /// confined to the scoped directory is the point.
    func addScratchSession(agent: AgentPreset = .terminal, spawnDirectory: String? = nil) {
        // A workspace on another machine holds what runs over there, and this
        // session runs here — filing it there would make the workspace say
        // something untrue. It lands in a workspace on this Mac instead, and the
        // selection carries the scope over with it.
        let home = workspaceForThisMac
        guard let index = workspaces.firstIndex(where: { $0.id == home.id }) else { return }
        // Remember the agent behind a bare "New Chat", so the single ⌘N / `+` / menu
        // action relaunches whatever you actually use (see `defaultChatAgent`).
        if agent != .terminal { settings.lastChatAgentID = agent.rawValue }
        var session = Session(title: "", agent: agent)
        if agent == .terminal {
            session.title = "Terminal \(workspaces[index].terminals.count + 1)"
            session.spawnDirectory = spawnDirectory
            workspaces[index].terminals.append(session)
        } else {
            // Creating the directory is what makes it safe to spawn in; the
            // guidance files seeded alongside tell the agent what it is.
            _ = ensureLooseChatRoot()
            session.title = agent.displayName
            workspaces[index].chats.append(session)
        }
        selectedSessionID = session.id
    }

    /// Opens an **SSH terminal** to `host` — a terminal that launches `ssh <host>`
    /// in a local PTY instead of a local shell (see `Session.sshHost`). It lands in
    /// that machine's fallback workspace, so an `ssh` shell and a durable termiod
    /// session on the same box sit together rather than scattering among loose
    /// local terminals. `host` is a `~/.ssh/config` alias or a bare `user@host`.
    ///
    /// `preferring` settles which of that box's workspaces when a caller knows —
    /// the phone names the workspace on its screen, and a box can hold more than
    /// one. It is only ever a preference: a caller that names a workspace on
    /// another machine gets the fallback, because the machine rule above is what
    /// keeps a workspace from claiming a box it isn't on.
    func addSSHSession(host: String, preferring preferred: Workspace.ID? = nil) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        // Named for what it is, not for the box — the workspace already says which
        // machine. The distinction matters beside the numbered rows: an "SSH Shell"
        // dies with the connection, while a durable termiod session survives a detach.
        var session = Session(title: "SSH Shell", agent: .terminal)
        // A name, not a placeholder: it is what makes an `ssh` shell legible next to
        // the durable rows, and nothing better is waiting behind it — the cwd a
        // loose terminal falls back to reports a directory on the far box, which is
        // how this row would end up called `ubuntu`.
        session.givenTitle = session.title
        session.sshHost = host

        let workspaceID = preferred.flatMap { id in
            workspaces.first { $0.id == id && $0.isOn(alias: host, device: nil) }?.id
        } ?? deviceWorkspace(for: host)
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[index].terminals.append(session)
        selectedSessionID = session.id
    }

    /// Opens a terminal running `ssh-copy-id` against `host`, installing
    /// `publicKey` in its `authorized_keys`. Used by Settings ▸ Devices when a
    /// probe finds a host that wants a password: the session exists so the
    /// server's password prompt has somewhere to be answered, and what it leaves
    /// behind — a key — is what the rest of termio can actually use.
    func addKeyInstallSession(host: String, publicKey: String) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        var session = Session(title: localized("Set Up Key"), agent: .terminal)
        session.givenTitle = session.title
        session.sshHost = host
        session.sshKeyToInstall = publicKey

        let workspaceID = deviceWorkspace(for: host)
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[index].terminals.append(session)
        selectedSessionID = session.id
    }

    /// Prompts for an SSH destination, then opens a terminal to it. The combo box is
    /// pre-populated with the connectable `Host` aliases from `~/.ssh/config` (the
    /// same list the phone imports), but stays editable so a one-off `user@host` that
    /// isn't in the config still works. Empty entry or Cancel does nothing.
    func presentSSHConnectPanel() {
        let alert = NSAlert()
        alert.messageText = localized("New SSH Connection")
        alert.informativeText = localized("Enter a host from your ~/.ssh/config, or a user@host to connect to.")
        alert.addButton(withTitle: localized("Connect"))
        alert.addButton(withTitle: localized("Cancel"))

        let combo = NSComboBox(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        combo.completes = true
        combo.addItems(withObjectValues: SSHConfigFile.hosts().map(\.alias))
        alert.accessoryView = combo
        alert.window.initialFirstResponder = combo

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let host = combo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        addSSHSession(host: host)
    }

    /// Where a workspace's loose **shells** spawn: the user's home directory, the
    /// way launching a new iTerm2 window drops you at `~`. Never
    /// `currentDirectoryPath`, which is `/` when the app is launched from Finder
    /// (that is what left the shell sitting at `/ %` on first launch).
    static var looseTerminalRoot: String {
        FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    }

    /// Where a workspace's loose **agent** sessions spawn: a scoped scratch
    /// directory, never `$HOME`. See `addScratchSession` for why.
    static var looseChatRoot: String {
        FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            .appendingPathComponent(".termio/chats", isDirectory: true)
            .standardizedFileURL.path
    }

    /// Creates the loose-chat directory and seeds its agent guidance, returning the
    /// path. Called before an agent is turned loose in it, never on read.
    @discardableResult
    func ensureLooseChatRoot() -> String {
        let root = URL(fileURLWithPath: Self.looseChatRoot, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        seedLooseChatDocs(at: root)
        return root.path
    }

    /// Drops a `CLAUDE.md` and an `AGENTS.md` into the scratch directory so an
    /// agent that spawns here reads, up front, that this is a throwaway scratchpad —
    /// not a real project to explore or a place to put anything it should keep. Both
    /// filenames are seeded because agents split on the convention (`CLAUDE.md` for
    /// Claude Code, `AGENTS.md` for Codex/Cursor/Amp and the rest). Only written when
    /// absent, so anything the user later edits into them is preserved.
    private func seedLooseChatDocs(at root: URL) {
        let guidance = """
        # termio scratch directory

        This is termio's scratch directory (`~/.termio/chats`) — an empty,
        throwaway space for quick one-off sessions that aren't tied to any project.

        - Treat it as a clean scratchpad: nothing important lives here, and files you
          create here belong to no repository.
        - Don't go exploring for a codebase — there isn't one. If the user wants to
          work on a real project, ask them to open it in termio (or `cd` into it)
          instead of working here.
        """
        for name in ["CLAUDE.md", "AGENTS.md"] {
            let url = root.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try? guidance.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Pins or unpins a project. Pinned projects sort ahead of the rest in the sidebar
    /// (see `orderedProjects`); the flag persists via `projects`' `didSet`.
    func togglePinned(_ id: Project.ID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].pinned.toggle()
    }

    /// Pins or unpins a session into the sidebar's top "Pinned" working set. The row
    /// stays in its normal tree spot; the pin adds a shortcut up top.
    func toggleSessionPinned(_ id: Session.ID) {
        updateSession(id) { $0.pinned.toggle() }
    }

    /// Pins or unpins a worktree into the sidebar's top "Pinned" working set (as a
    /// mini-block of its own sessions). The worktree stays nested under its project
    /// too; the pin adds the top shortcut. Persists via `projects`' `didSet`.
    func toggleWorktreePinned(_ id: Worktree.ID) {
        for pi in projects.indices {
            if let wi = projects[pi].worktrees.firstIndex(where: { $0.id == id }) {
                projects[pi].worktrees[wi].pinned.toggle()
                return
            }
        }
    }

    /// Opens a project on the machine the current workspace belongs to.
    ///
    /// The device is inherited, never asked for. A checkout takes its machine from
    /// the workspace that owns it, so the scope on screen has already answered
    /// "which machine" — the same reason `New Terminal` opens on the device you
    /// are looking at instead of growing a picker. Asking again turns one decision
    /// into two, and it is what used to pin ⌘O to this Mac while the window was
    /// showing a box: the folder landed in a workspace the user was not in, and
    /// selecting it threw them out of the one they were.
    ///
    /// Opening a project on a *different* machine is therefore two steps now —
    /// switch workspace, then open — which is what the hierarchy says anyway: you
    /// switch workspaces, never machines. The single step was never one either;
    /// `addRemoteProject` ends in `switchToWorkspace`, so the scope moved regardless
    /// of which menu row was clicked.
    func presentOpenProjectPanel() {
        switch currentWorkspace.device {
        case .thisMac:
            presentLocalProjectPanel()
        case .ssh(let alias):
            presentRemoteProjectPanel(
                on: KnownDevice(alias: alias, deviceID: currentWorkspace.deviceID))
        }
    }

    /// Presents a folder picker that opens the chosen directory as a new project.
    private func presentLocalProjectPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = localized("Open")
        panel.message = localized("Choose a project folder to open in Termio.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addProject(at: url)
    }

    /// Adds the directory at `url` as a new project section in the current
    /// workspace, seeded with a single terminal session which becomes the
    /// selection. A folder already open as a project is not duplicated — its
    /// first session is selected instead, wherever it is filed.
    func addProject(at url: URL) {
        let path = url.standardizedFileURL.path
        settings.noteRecentProject(name: url.lastPathComponent, path: path)
        // Matched among this Mac's projects only: a checkout on another machine
        // can carry the same path string and is not the same folder.
        if let existing = projects.first(where: { !isOnAnotherDevice($0) && $0.path == path }) {
            selectedSessionID = existing.sessions.first?.id
            return
        }
        let session = Session(title: "Terminal 1")
        // The folder is on this Mac, so it is filed under a workspace on this Mac —
        // ⌘O and the welcome page reach here with any workspace current, a box's
        // included, and a local checkout in a workspace on a box is a row nothing
        // over there can account for. Redirected rather than refused: the user
        // picked a real folder, and a picker that closes having done nothing reads
        // as a bug.
        let project = Project(
            workspaceID: workspaceForThisMac.id,
            name: url.lastPathComponent,
            path: path,
            branch: "—",
            sessions: [session]
        )
        projects.append(project)
        selectedSessionID = project.sessions.first?.id
        resolveBranchLabel(for: project.id, at: path)
    }

    // MARK: - A project on another machine

    /// Opens a project that lives on `device`, browsed the way a folder on this Mac
    /// is: a column picker over the machine's own directories
    /// (`RemoteFolderPicker`), because a path you cannot see is a path you have to
    /// already know.
    ///
    /// Cloning a repository onto the machine leaves through the picker's third
    /// button. It names a folder that does not exist yet, so there is nothing to
    /// browse to — a different question, and now a different panel.
    func presentRemoteProjectPanel(on device: KnownDevice) {
        // Straight to the picker rather than back through `presentOpenProjectPanel`,
        // which dispatches on the current workspace: this one has already been told
        // which machine, and routing through the dispatcher would send a `.thisMac`
        // caller back here whenever the scope on screen is a box's.
        guard let alias = device.alias else {
            presentLocalProjectPanel()
            return
        }
        RemoteFolderPicker(alias: alias).present(over: NSApp.mainWindow) { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .cancelled:
                return
            case .folder(let path):
                openRemoteProject(at: path, on: alias)
            case .clone:
                presentRemoteClonePanel(on: alias)
            }
        }
    }

    /// Asks for a repository to clone onto `alias`. One field, because the
    /// destination is not the user's to name: the clone lands in the machine's home
    /// directory and reports back the absolute path it created (`performRemoteClone`).
    private func presentRemoteClonePanel(on alias: String) {
        let alert = NSAlert()
        alert.messageText = localized("Clone a Repository onto \(alias)")
        alert.informativeText = localized(
            "The clone runs on \(alias) and opens as a project there.")
        alert.addButton(withTitle: localized("Clone"))
        alert.addButton(withTitle: localized("Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        // Not localized: a repository URL reads the same in every language.
        field.placeholderString = "https://github.com/owner/repo.git"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let origin = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !origin.isEmpty else { return }
        cloneProject(from: origin, on: alias)
    }

    /// Clones `originURL` onto `alias` and files the result as a project in a
    /// workspace on `alias`. Reuses the same clone `Clone to <device>…` runs — deploy
    /// gate, HUD, verbatim remote stderr — rather than a second path that would
    /// drift from it.
    private func cloneProject(from originURL: String, on alias: String) {
        let name = GitService.repositoryName(fromRemote: originURL)
        // `unpushedCommits: nil` skips the divergence warning, correctly: the URL
        // *is* the origin, so there is no local branch that could be ahead of it.
        let info = GitService.CloneInfo(
            originURL: originURL, repositoryName: name, unpushedCommits: nil)
        cloneOnRemote(host: alias, info: info, into: .new(name: name))
    }

    /// Files a directory that is already on `alias` as a project, then opens its
    /// first terminal. That terminal is also the check: the daemon fails visibly
    /// if the path isn't there, rather than the row quietly pointing at nothing.
    private func openRemoteProject(at entry: String, on alias: String) {
        // termiod spawns the shell with a raw `chdir` and expands neither `~` nor a
        // relative path (termiod/src/session.rs `Pty::spawn`). The panel has already
        // expanded `~` against the home the handshake reported, so anything still
        // not absolute here is a path no machine could resolve.
        guard entry.hasPrefix("/") else {
            let alert = NSAlert()
            alert.messageText = localized("Enter an absolute path")
            alert.informativeText = localized(
                "Enter a path that starts with “/”. “~/” works too, once \(alias) has said where home is.")
            alert.alertStyle = .informational
            alert.addButton(withTitle: localized("OK"))
            alert.runModal()
            return
        }
        var path = entry
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let name = (path as NSString).lastPathComponent
        let id = addRemoteProject(
            name: name.isEmpty ? alias : name,
            at: path,
            on: alias,
            device: TermiodDeviceRegistry.shared.deviceID(for: TermiodRoute(sshAlias: alias)))
        addRemoteTerminal(host: alias, project: id)
    }

    /// Adds a project whose checkout is on another machine — a normal project row,
    /// filed in a workspace on that machine. Reopening the same directory on the
    /// same machine selects the row that is already there.
    ///
    /// The workspace is not the caller's to choose: a checkout takes its machine
    /// from the workspace that owns it, so one on `alias` goes to a workspace on
    /// `alias` — the current one when it is already that machine's, and that
    /// machine's own otherwise. The mirror of `addProject`, which redirects a local
    /// folder to `workspaceForThisMac`.
    ///
    /// No branch probe and no recents entry: both read this Mac's disk, and this
    /// project's folder is not on it.
    @discardableResult
    func addRemoteProject(
        name: String, at path: String, on alias: String, device deviceID: String?
    ) -> Project.ID {
        if let existing = checkout(at: path, on: alias, device: deviceID) {
            selectedSessionID = existing.sessions.first?.id
            return existing.id
        }
        var project = Project(
            workspaceID: workspace(forDevice: alias, deviceID: deviceID),
            name: name,
            path: path,
            // No local git to ask, and the daemon reports no branch yet. The em
            // dash is the same "not a repo we can read" mark a plain folder gets,
            // and it is what keeps the worktree verbs off this row.
            branch: "—",
            sessions: []
        )
        // The checkout `New Terminal` reads. Keyed by device once a handshake has
        // said which one this alias reaches, by alias until then —
        // `remoteCheckout(device:alias:)` answers from either, and `adoptDevice`
        // promotes the alias key when the machine finally identifies itself.
        project.remoteCheckouts[deviceID ?? alias] = path
        projects.append(project)
        // The row is filed on its machine, which need not be the workspace on
        // screen, so the scope follows it there. Done here rather than left to the
        // terminal that opens next: that terminal can fail — an unreachable box, a
        // refused deploy — and a project the user just asked for must not land in a
        // scope they are not looking at.
        switchToWorkspace(project.workspaceID)
        return project.id
    }

    /// Removes a project from the sidebar: tears down every session's live surface
    /// (and its PTY) and drops the project from the tree. Only the sidebar entry is
    /// removed — the folder on disk, and any git worktrees the sessions created, are
    /// deliberately left untouched, the same hands-off stance `closeSession` takes
    /// (they may hold uncommitted agent work, so deletion is the user's call).
    func removeProject(_ id: Project.ID) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == id }) else { return }

        let removedSessionIDs = Set(projects[projectIndex].sessions.map(\.id))
        for sessionID in removedSessionIDs {
            // Removing the project destroys its sessions, so the daemon has to
            // be told — the same verb Close Session uses. Detaching instead
            // would leave every agent of a removed project running with nothing
            // left on this side that can reach it.
            termiodLinks[sessionID]?.killAndClose()
            termiodLinks[sessionID] = nil
            surfaces[sessionID] = nil
            monitors[sessionID] = nil
            removeRuntime(for: sessionID)
            processSpawnedAt[sessionID] = nil
            transcriptPaths[sessionID] = nil
            clearActivityTracking(for: sessionID)
        }
        projects.remove(at: projectIndex)

        // Drop the removed sessions out of any split layout first — the prune
        // may already have moved the selection onto a surviving pane.
        pruneSessionsFromSplit(removedSessionIDs)

        // If the active session lived in the removed project, fall back to the first
        // session left in the same workspace (nil when the sidebar is now empty).
        if let selected = selectedSessionID, removedSessionIDs.contains(selected) {
            selectedSessionID = sessions(inWorkspace: currentWorkspace.id).first?.id
        }
    }

    /// Renames a session via a one-field prompt (the same `NSAlert` shape the
    /// worktree and file-browser prompts use), pre-filled with the current label
    /// and pre-selected so a new name can just be typed over it. The entry becomes
    /// the stored `title`, which `displayTitle(for:)` treats as user-chosen and
    /// shows verbatim from then on; renaming an agent session back to its agent's
    /// plain name hands the label back to the live terminal title.
    func renameSession(_ id: Session.ID) {
        guard let session = session(id) else { return }

        let alert = NSAlert()
        alert.messageText = localized("Rename Session")
        alert.addButton(withTitle: localized("Rename"))
        alert.addButton(withTitle: localized("Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = displayTitle(for: session)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        field.selectText(nil)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        // Typing one of Termio's own conventions back into the field is how a row is
        // handed to automatic naming again: the agent's plain name returns an agent
        // session to its live terminal title, `Terminal N` returns a shell to its
        // numbering. Anything else is a name, and names are kept verbatim.
        //
        // `title` is deliberately not written: it is the app's own placeholder, and
        // leaving it alone is what lets a row that is later un-named fall back to a
        // sensible label instead of to whatever it was once called.
        let composed = name == effectiveAgent(for: session).displayName
            || Self.isAutoTerminalName(name)
        updateSession(id) { $0.givenTitle = composed ? nil : name }
    }

    /// The user-facing "Close Session": the same teardown as `closeSession`, but it
    /// asks first in the one case that loses something with no other record — a plain
    /// shell with a command running in front of it. Only the interactive entry points
    /// (the sidebar row, the terminal's context menu) route through here — a session
    /// whose process already exited, the `termio sessions close` CLI, and the phone's
    /// stop button all closed deliberately and call `closeSession` directly.
    func requestCloseSession(_ id: Session.ID) {
        guard let session = session(id) else { return }
        guard let reason = closeConfirmationReason(for: session) else {
            closeSession(id)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close “\(displayTitle(for: session))”?"
        alert.informativeText = reason
        alert.addButton(withTitle: "Close Session")
        alert.addButton(withTitle: "Cancel")
        Self.applyConfirmationKeys(to: alert)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        closeSession(id)
    }

    /// Wires the two keys every close confirmation answers to: **Return confirms**
    /// and Escape cancels. The confirm button goes first and is made the default
    /// and the initial first responder — a destructive button doesn't get default
    /// treatment on its own, so Return would otherwise land nowhere.
    ///
    /// This is the reverse of the first cut, which put Cancel first so Return
    /// cancelled and the destructive button took ⌘D. cmux shipped exactly that
    /// design and removed it the same day
    /// ([#1219](https://github.com/manaflow-ai/cmux/pull/1219) →
    /// [#1279](https://github.com/manaflow-ai/cmux/pull/1279), with an XCUITest
    /// pinning Return). The dialog answers a key the user just pressed on purpose;
    /// making the answer unreachable from the keyboard isn't safety, it's a dead end.
    static func applyConfirmationKeys(to alert: NSAlert) {
        guard let confirm = alert.buttons.first else { return }
        confirm.hasDestructiveAction = true
        confirm.keyEquivalent = "\r"
        confirm.keyEquivalentModifierMask = []
        alert.window.initialFirstResponder = confirm
        alert.buttons.dropFirst().first?.keyEquivalent = "\u{1b}"
    }

    /// Whether a command is running in front of the session's shell, given what
    /// each possible producer says. The one that **owns the process** answers:
    /// an in-process PTY is asked `tcgetpgrp` at the instant of the question, so
    /// its answer wins outright — including its `false`, which is a fresher no
    /// than any cached yes. Only a session this app does not host falls through
    /// to the device's last roster push. `nil` is nobody answering.
    ///
    /// Split out from `closeConfirmationReason` because the precedence is the
    /// part worth pinning: the two producers disagree only while a link and a PTY
    /// both exist for one row, and picking the wrong one there is silent.
    static func foregroundJob(reportedLocally: Bool?, reportedByDevice: Bool?) -> Bool? {
        reportedLocally ?? reportedByDevice
    }

    /// Why closing this session needs confirming, or `nil` when it doesn't. The only
    /// case left is a plain shell with a command in front of it: that command exists
    /// nowhere else, so closing loses it outright. Agent sessions never ask — their
    /// PTY is alive for the whole life of the session, so confirming on a live PTY
    /// taxed *every* close to protect a conversation the agent can resume anyway.
    ///
    /// A daemon-hosted session answers from the last roster push — a sample up to
    /// one host poll old — and **asking again would not help**: `list` rebuilds its
    /// answer from that same cached sample, so a synchronous round trip buys no
    /// freshness while costing 216–292 ms on the main thread over SSH. The
    /// staleness is bounded either way: a job that ended within the poll costs one
    /// dialog the user dismisses, and one that started within it closes unasked —
    /// which is exactly the shipped no-confirm rule. So only an explicit `true`
    /// confirms; an absent field must never read as "unknown, so confirm"
    /// (`20260814-remote-to-device.decisions.md` §2).
    func closeConfirmationReason(for session: Session) -> String? {
        guard session.agent.isShell else { return nil }
        let running = termiodLinks[session.id]?.latestInformation?.foregroundJob
        guard running == true else { return nil }
        return "A command is still running in this session. Closing it stops the command."
    }

    /// Closes a session: drops its cached surface (which tears down the PTY) and
    /// moves the selection to a neighbouring session if the closed one was active.
    /// Any git worktree created for the session is deliberately left on disk — it
    /// may hold uncommitted agent work, so cleanup is the user's call, not ours.
    func closeSession(_ id: Session.ID) {
        guard let slot = locate(id) else { return }
        let sessionIndex = slot.sessionIndex
        removeSession(at: slot)
        // Close Session is the destroy verb, so a termiod-backed session is
        // killed in the daemon too — unlike quit/detach, which keeps it alive.
        termiodLinks[id]?.killAndClose()
        termiodLinks[id] = nil
        surfaces[id] = nil
        monitors[id] = nil
        removeRuntime(for: id)
        processSpawnedAt[id] = nil
        transcriptPaths[id] = nil
        clearActivityTracking(for: id)

        // If the session held a split pane, collapse that pane; when it was also
        // the focused pane the prune moves the selection to its layout neighbor,
        // which then wins over the sidebar-order fallback below.
        pruneSessionsFromSplit([id])

        if selectedSessionID == id {
            let remaining = roster(at: slot.atSession(0))
            if remaining.isEmpty {
                selectedSessionID = sessions(inWorkspace: currentWorkspace.id).first?.id
            } else {
                selectedSessionID = remaining[min(sessionIndex, remaining.count - 1)].id
            }
        }
        // A machine's fallback workspace exists only to hold the sessions nothing
        // else accounts for. Emptied, it is bookkeeping: it goes, and the switcher
        // stops offering a scope with nothing in it. A workspace the user made
        // stays — they made it on purpose.
        pruneEmptyDeviceWorkspaces()
    }

    /// Drops any workspace Termio made itself that is left holding nothing, except
    /// the one the sidebar is currently showing — pulling the scope out from under
    /// the user as they close the last row on a box is a jump they did not ask for.
    ///
    /// Gated on `isAutoCreated`, not on the workspace naming a machine. Those were
    /// the same set until `reconcile` began stamping a device onto every workspace;
    /// after it, a workspace the user named and filled with checkouts on one box
    /// also names that box, and sweeping it would delete something they made. A
    /// name someone chose is not Termio's to reclaim.
    private func pruneEmptyDeviceWorkspaces() {
        let occupied = Set(projects.map(\.workspaceID))
        workspaces.removeAll { workspace in
            workspace.isAutoCreated == true
                && workspace.looseSessions.isEmpty
                && !occupied.contains(workspace.id)
                && workspace.id != currentWorkspaceID
        }
    }

    /// Respawns a session's process in place: drops the cached surface (the PTY is
    /// already gone — this runs after its child exited) and nudges a re-render, so
    /// the mounted pane's next `surface(for:)` relaunches the agent with its usual
    /// resume arguments. The session row, title, and split slot all stay put; only
    /// the surface is remade. Used by the self-update exit path (`onExit`'s
    /// binary-replaced check): the "restart Codex" the agent asks for, done for the
    /// user, conversation resumed.
    func relaunchSession(_ id: Session.ID) {
        guard session(id) != nil else { return }
        // A respawn-in-place must not leave the old daemon-side process
        // running under the same name, or the fresh surface would reattach to
        // it instead of spawning the replacement.
        termiodLinks[id]?.killAndClose()
        termiodLinks[id] = nil
        surfaces[id] = nil
        monitors[id] = nil
        processSpawnedAt[id] = nil
        // The dead child's status must not carry into the respawn: a leftover
        // spinner would read as the new process already working (and with the
        // trackers cleared below, the stale-working sweep — which only visits
        // sessions present in `lastWorkingAt` — could never correct it).
        setStatus(.idle, for: id)
        setCurrentTool(nil, for: id)
        clearActivityTracking(for: id)
        // `transcriptPaths` deliberately survives: the respawn resumes the same
        // conversation, so the Info pane's trace should keep pointing at it.
        // `surfaces` is a plain cache, not `@Published` — nothing re-renders on
        // its own, so poke observers; the pane then rebuilds via `surface(for:)`.
        objectWillChange.send()
    }

    /// A declared agent that quit cleanly (`/quit`, `/exit`) hands its pane back to
    /// a shell in the same directory — the place a hand-started agent leaves you —
    /// instead of parking on the exit prompt. The session demotes to a plain
    /// terminal first (identity follows what the pane runs; `noteForegroundAgent`
    /// is the promotion mirror), so the respawn resolves to a login shell — from
    /// which typing the agent's command re-promotes the very same row.
    func revertSessionToShell(_ id: Session.ID) {
        demoteSessionToTerminal(id)
        relaunchSession(id)
    }

    /// Fills in a just-created project's branch label off the main thread. Creation
    /// seeds the label with "—" (the non-repo rendering) because resolving it means
    /// spawning a `git rev-parse` subprocess and blocking on its exit — a visible
    /// hitch to pay on the main thread just for sidebar chrome. The patch keys on
    /// the project id, so a project closed before git answers is simply a no-op.
    private func resolveBranchLabel(for projectID: Project.ID, at path: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let branch = Self.gitOutput(["rev-parse", "--abbrev-ref", "HEAD"], in: path),
                  !branch.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let index = self.projects.firstIndex(where: { $0.id == projectID })
                else { return }
                self.projects[index].branch = branch
            }
        }
    }

    /// Runs `git -C <directory> <arguments…>` synchronously, returning trimmed
    /// stdout on success or `nil` on a launch failure or non-zero exit. Callers
    /// treat `nil` as "couldn’t do it" and fall back rather than trapping.
    @discardableResult
    private func runGit(_ arguments: [String], in directory: String) -> String? {
        Self.gitOutput(arguments, in: directory)
    }

    /// The blocking body behind `runGit`, isolation-free so background work (the
    /// branch-label resolve) can call it without hopping through the main actor.
    private nonisolated static func gitOutput(_ arguments: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
        process.environment = GitEnvironment.optionalLocksDisabled
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("termio: git could not be launched: \(error)\n".utf8))
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// The two string rules the remote path field runs on, apart from the field so
/// they can be tested without a window.
enum RemotePathEntry {
    /// `/srv/ap` → (`/srv/`, `ap`). The directory keeps its trailing slash: it is
    /// what gets sent to `fs.list`, and a listing of `/srv` and of `/srv/` are the
    /// same request. A path with no `/` at all names no directory, which is right —
    /// it is not yet a place on that machine.
    static func split(_ path: String) -> (directory: String, partial: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[...slash]), String(path[path.index(after: slash)...]))
    }

    /// Expands a leading `~` against the machine's own home, which the handshake
    /// reported. Only a leading one, and only when it stands alone or is followed
    /// by `/`: `~user` names *another* account's home, which this cannot resolve
    /// and must not silently rewrite into this one's.
    static func expandingTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        guard path.hasPrefix("~/") else { return path }
        let tail = path.dropFirst(2)
        return home.hasSuffix("/") ? home + tail : home + "/" + tail
    }
}
