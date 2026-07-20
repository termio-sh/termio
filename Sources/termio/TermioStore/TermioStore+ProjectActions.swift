import AppKit
import Foundation

extension TermioStore {
    /// Adds a session to a project, optionally running in one of its linked
    /// worktree folders while remaining in the project's flat session roster.
    func addSession(
        to projectID: Project.ID,
        agent: AgentPreset = .terminal,
        worktreePath: String? = nil
    ) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let project = projects[index]
        let terminalCount = project.sessions.filter { $0.agent == .terminal }.count
        let title = agent == .terminal
            ? "Terminal \(terminalCount + 1)"
            : agent.displayName
        var session = Session(title: title, agent: agent)
        session.worktreePath = worktreePath
        projects[index].sessions.append(session)
        selectedSessionID = session.id
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
            presentWorktreeFailure(message: "Couldn't create the worktrees folder: \(error.localizedDescription)")
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
            presentWorktreeFailure(message: "git couldn't create a worktree for “\(project.name)”. Is it a git repository with at least one commit?")
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
                title: "Couldn't inspect worktree",
                message: "git couldn't check “\((worktree.path as NSString).lastPathComponent)” for changes, so it was not removed."
            )
            return
        }
        guard status.isEmpty else {
            presentWorktreeFailure(
                title: "Worktree has changes",
                message: "Commit or discard the changes in “\((worktree.path as NSString).lastPathComponent)” before removing it."
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
                title: "Couldn't remove worktree",
                message: "git couldn't remove “\((worktree.path as NSString).lastPathComponent)”."
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
                title: "Worktree removed",
                message: "The folder was removed, but git couldn't prune its stale worktree metadata."
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
        alert.messageText = "New Worktree"
        alert.informativeText = "Name the worktree. A new branch of this name is created from HEAD and nested under this project."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
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
        title: String = "Couldn't create worktree session",
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
    /// terminals aren't tied to a real project, so they're gathered under a single
    /// home-rooted section that's created on first use; each later click just adds
    /// another `Terminal N` row there and selects it (the same grow-in-place a
    /// project's own header buttons do). The section persists like any project, so
    /// it reappears on relaunch (the shells themselves restart fresh).
    func addScratchTerminal() { addScratchSession(agent: .terminal) }

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
    /// scratch workspace at `~/.termio/chats/` (created on first use, sibling to
    /// the existing `~/.termio/worktrees/`), a clean directory that's safe to let an
    /// agent loose in.
    ///
    /// Each destination gathers its loose sessions under one persistent section — the
    /// `.terminals` funnel for shells, the `.chats` funnel for agents — so a second
    /// click just grows another row there and selects it, rather than piling up
    /// duplicate sections.
    func addScratchSession(agent: AgentPreset = .terminal) {
        // Both funnels are matched by kind, not path: the `.terminals` container's
        // `path` is just the `$HOME` spawn fallback, and the single `.chats` container
        // gathers every agent (Claude, Codex, …) that spawns in the scratch workspace.
        let path = scratchWorkspacePath(for: agent)
        // Remember the agent behind a bare "New Chat", so the single ⌘N / `+` / menu
        // action relaunches whatever you actually use (see `defaultChatAgent`).
        if agent != .terminal { settings.lastChatAgentID = agent.rawValue }
        let containerKind: ProjectKind = agent == .terminal ? .terminals : .chats
        if let existing = projects.first(where: { $0.kind == containerKind }) {
            addSession(to: existing.id, agent: agent)
            return
        }
        let title = agent == .terminal ? "Terminal 1" : agent.displayName
        let session = Session(title: title, agent: agent)
        let project = Project(
            name: agent == .terminal ? "Terminals" : "Chats",
            path: path,
            branch: currentBranch(in: path) ?? "—",
            sessions: [session],
            kind: containerKind
        )
        projects.append(project)
        selectedSessionID = session.id
    }

    /// Opens an **SSH terminal** to `host` — a loose terminal that launches
    /// `ssh <host>` instead of a local shell (see `Session.sshHost`). It gathers in
    /// the same Terminals container as scratch shells (an SSH session isn't tied to a
    /// local project either), titled by the host so the sidebar row reads `myserver`
    /// rather than `Terminal N`. `host` is a `~/.ssh/config` alias or a bare
    /// `user@host`.
    func addSSHSession(host: String) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        var session = Session(title: host, agent: .terminal)
        session.sshHost = host

        if let index = projects.firstIndex(where: { $0.kind == .terminals }) {
            projects[index].sessions.append(session)
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
            projects.append(Project(
                name: "Terminals", path: home, branch: "—",
                sessions: [session], kind: .terminals
            ))
        }
        selectedSessionID = session.id
    }

    /// Prompts for an SSH destination, then opens a terminal to it. The combo box is
    /// pre-populated with the connectable `Host` aliases from `~/.ssh/config` (the
    /// same list the phone imports), but stays editable so a one-off `user@host` that
    /// isn't in the config still works. Empty entry or Cancel does nothing.
    func presentSSHConnectPanel() {
        let alert = NSAlert()
        alert.messageText = "New SSH Connection"
        alert.informativeText = "Enter a host from your ~/.ssh/config, or a user@host to connect to."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let combo = NSComboBox(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        combo.completes = true
        combo.addItems(withObjectValues: CompanionServer.parseSSHConfigHosts().map(\.alias))
        alert.accessoryView = combo
        alert.window.initialFirstResponder = combo

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let host = combo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        addSSHSession(host: host)
    }

    /// The working directory for a scratch session: `~` for a plain terminal, and the
    /// scoped `~/.termio/chats/` workspace for any agent (created on demand). See
    /// `addScratchSession` for why agents are kept out of `$HOME`.
    private func scratchWorkspacePath(for agent: AgentPreset) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        guard agent != .terminal else { return home.path }
        let workspace = home.appendingPathComponent(".termio/chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        seedScratchWorkspaceDocs(at: workspace)
        return workspace.standardizedFileURL.path
    }

    /// Drops a `CLAUDE.md` and an `AGENTS.md` into the scratch workspace so an
    /// agent that spawns here reads, up front, that this is a throwaway scratchpad —
    /// not a real project to explore or a place to put anything it should keep. Both
    /// filenames are seeded because agents split on the convention (`CLAUDE.md` for
    /// Claude Code, `AGENTS.md` for Codex/Cursor/Amp and the rest). Only written when
    /// absent, so anything the user later edits into them is preserved.
    private func seedScratchWorkspaceDocs(at workspace: URL) {
        let guidance = """
        # termio scratch workspace

        This is termio's scratch workspace (`~/.termio/chats`) — an empty,
        throwaway space for quick one-off sessions that aren't tied to any project.

        - Treat it as a clean scratchpad: nothing important lives here, and files you
          create here belong to no repository.
        - Don't go exploring for a codebase — there isn't one. If the user wants to
          work on a real project, ask them to open it in termio (or `cd` into it)
          instead of working here.
        """
        for name in ["CLAUDE.md", "AGENTS.md"] {
            let url = workspace.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try? guidance.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// The projects in sidebar display order: pinned ones first, then the rest, each
    /// group ordered by the user's chosen sort (`AppSettings.projectSortOrder`). A
    /// computed view over `projects` — the stored array keeps its own insertion order,
    /// so ordering is a presentation concern that never mutates (or persists) the tree.
    var orderedProjects: [Project] {
        let order = settings.projectSortOrder
        return projects.sorted { a, b in
            // The Terminals section is the entry funnel, so it sits above every
            // project — ahead even of pinned ones, whichever sort is active.
            if (a.kind == .terminals) != (b.kind == .terminals) { return a.kind == .terminals }
            // Pinned projects always float to the top, whichever sort is active.
            if a.pinned != b.pinned { return a.pinned }
            switch order {
            case .name:
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .recentActivity:
                let da = liveActivity[a.id] ?? .distantPast
                let db = liveActivity[b.id] ?? .distantPast
                // Newer activity first; equal timestamps keep the array's stable order
                // (Swift's sort is stable), so untouched projects hold their positions.
                if da != db { return da > db }
                return false
            }
        }
    }

    /// Pins or unpins a project. Pinned projects sort ahead of the rest in the sidebar
    /// (see `orderedProjects`); the flag persists via `projects`' `didSet`.
    func togglePinned(_ id: Project.ID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].pinned.toggle()
    }

    /// Pins or unpins a session into the sidebar's top "Pinned" working set. The row
    /// stays in its normal tree spot; the pin adds a shortcut up top. Persists via
    /// `projects`' `didSet`.
    func toggleSessionPinned(_ id: Session.ID) {
        for pi in projects.indices {
            if let si = projects[pi].sessions.firstIndex(where: { $0.id == id }) {
                projects[pi].sessions[si].pinned.toggle()
                return
            }
        }
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

    /// Presents a folder picker that opens the chosen directory as a new project.
    func presentOpenProjectPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a project folder to open in termio."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addProject(at: url)
    }

    /// Adds the directory at `url` as a new project section seeded with a single
    /// terminal session, which becomes the selection. A folder already open as a
    /// project is not duplicated — its first session is selected instead.
    func addProject(at url: URL) {
        let path = url.standardizedFileURL.path
        settings.noteRecentProject(name: url.lastPathComponent, path: path)
        if let existing = projects.first(where: { $0.path == path }) {
            selectedSessionID = existing.sessions.first?.id
            return
        }
        let session = Session(title: "Terminal 1")
        let project = Project(
            name: url.lastPathComponent,
            path: path,
            branch: currentBranch(in: path) ?? "—",
            sessions: [session]
        )
        projects.append(project)
        selectedSessionID = project.sessions.first?.id
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
            ptyProcesses[sessionID]?.terminate()
            ptyProcesses[sessionID] = nil
            surfaces[sessionID] = nil
            browserPanes[sessionID] = nil
            monitors[sessionID] = nil
            statuses[sessionID] = nil
            currentTool[sessionID] = nil
            liveTitles[sessionID] = nil
            detectedAgents[sessionID] = nil
            processSpawnedAt[sessionID] = nil
            lastWorkingAt[sessionID] = nil
            lastHookReportAt[sessionID] = nil
            lastUserInputAt[sessionID] = nil
            promotionStreak[sessionID] = nil
            lastTitleActivity[sessionID] = nil
        }
        projects.remove(at: projectIndex)

        // Drop the removed sessions out of any split layout first — the prune
        // may already have moved the selection onto a surviving pane.
        pruneSessionsFromSplit(removedSessionIDs)

        // If the active session lived in the removed project, fall back to the first
        // session of whatever project remains (nil when the sidebar is now empty).
        if let selected = selectedSessionID, removedSessionIDs.contains(selected) {
            selectedSessionID = projects.first(where: { !$0.sessions.isEmpty })?.sessions.first?.id
        }
    }

    /// Renames a session via a one-field prompt (the same `NSAlert` shape the
    /// worktree and file-browser prompts use), pre-filled with the current label
    /// and pre-selected so a new name can just be typed over it. The entry becomes
    /// the stored `title`, which `displayTitle(for:)` treats as user-chosen and
    /// shows verbatim from then on; renaming an agent session back to its agent's
    /// plain name hands the label back to the live terminal title.
    func renameSession(_ id: Session.ID) {
        guard let projectIndex = projects.firstIndex(where: { $0.sessions.contains { $0.id == id } }),
              let sessionIndex = projects[projectIndex].sessions.firstIndex(where: { $0.id == id })
        else { return }
        let session = projects[projectIndex].sessions[sessionIndex]

        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = displayTitle(for: session)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        field.selectText(nil)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        projects[projectIndex].sessions[sessionIndex].title = name
    }

    /// Closes a session: drops its cached surface (which tears down the PTY) and
    /// moves the selection to a neighbouring session if the closed one was active.
    /// Any git worktree created for the session is deliberately left on disk — it
    /// may hold uncommitted agent work, so cleanup is the user's call, not ours.
    func closeSession(_ id: Session.ID) {
        guard let projectIndex = projects.firstIndex(where: { $0.sessions.contains { $0.id == id } }),
              let sessionIndex = projects[projectIndex].sessions.firstIndex(where: { $0.id == id })
        else { return }

        projects[projectIndex].sessions.remove(at: sessionIndex)
        ptyProcesses[id]?.terminate()
        ptyProcesses[id] = nil
        surfaces[id] = nil
        browserPanes[id] = nil
        monitors[id] = nil
        statuses[id] = nil
        currentTool[id] = nil
        liveTitles[id] = nil
        detectedAgents[id] = nil
        processSpawnedAt[id] = nil
        lastWorkingAt[id] = nil
        lastHookReportAt[id] = nil
        lastUserInputAt[id] = nil
        promotionStreak[id] = nil
        lastTitleActivity[id] = nil

        // If the session held a split pane, collapse that pane; when it was also
        // the focused pane the prune moves the selection to its layout neighbor,
        // which then wins over the sidebar-order fallback below.
        pruneSessionsFromSplit([id])

        if selectedSessionID == id {
            let remaining = projects[projectIndex].sessions
            if remaining.isEmpty {
                selectedSessionID = projects.first(where: { !$0.sessions.isEmpty })?.sessions.first?.id
            } else {
                selectedSessionID = remaining[min(sessionIndex, remaining.count - 1)].id
            }
        }
    }

    /// The checked-out branch of the git repository at `directory`, or `nil` when
    /// it is not a repo (rendered as "—", matching the seed projects).
    private func currentBranch(in directory: String) -> String? {
        runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)
    }

    /// Runs `git -C <directory> <arguments…>` synchronously, returning trimmed
    /// stdout on success or `nil` on a launch failure or non-zero exit. Callers
    /// treat `nil` as "couldn't do it" and fall back rather than trapping.
    @discardableResult
    private func runGit(_ arguments: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
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
