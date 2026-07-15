import AppKit
import Foundation

extension TermioStore {
    /// Adds a session to a project, running in the project's directory.
    func addSession(to projectID: Project.ID, agent: AgentPreset = .terminal) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let project = projects[index]
        let terminalCount = project.sessions.filter { $0.agent == .terminal }.count
        let title = agent == .terminal
            ? "Terminal \(terminalCount + 1)"
            : agent.displayName
        let session = Session(title: title, agent: agent)
        projects[index].sessions.append(session)
        selectedSessionID = session.id
    }

    /// Creates a fresh *detached* git worktree of the project and adds it to the sidebar
    /// as its own top-level entry — no session is started (you add those yourself, the
    /// same way any project offers "New … Session"). The user names it first (a prompt
    /// pre-filled with the next free `<repo>-worktree-N`); that name becomes both the
    /// folder under `~/.termio/worktrees/` and the sidebar label, so worktrees stay
    /// identifiable instead of reading as opaque hashes. The checkout is detached at the
    /// project's current `HEAD` so a throwaway checkout never locks a branch out of the
    /// primary one; a branch is materialized later on intent (see
    /// `docs/design/worktree-creation-lifecycle.md`). Files the repo lists in
    /// `.worktreeinclude` (`.env` and friends) are copied in so the checkout can run. On
    /// cancel nothing happens; on failure (not a repo, git error) nothing is added and
    /// the user is told why.
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
            presentWorktreeFailure("Couldn't create the worktrees folder: \(error.localizedDescription)")
            return
        }
        guard runGit(["worktree", "add", "--detach", worktreePath, "HEAD"], in: project.path) != nil else {
            presentWorktreeFailure("git couldn't create a worktree for “\(project.name)”. Is it a git repository with at least one commit?")
            return
        }

        copyWorktreeIncludes(from: project.path, to: worktreePath)

        // Surface the worktree as its own top-level sidebar entry: a plain project
        // rooted at the worktree folder, with no sessions yet. `currentBranch` reports
        // "HEAD" for a detached checkout, so fall back to the short SHA for a readable
        // label (the live branch is tracked by BranchModel once it's watched anyway). It
        // inherits the repo's sandbox posture so a sandboxed project's worktree isn't a
        // way around the sandbox.
        let branchLabel = currentBranch(in: worktreePath).flatMap { ref in
            ref == "HEAD" ? runGit(["rev-parse", "--short", "HEAD"], in: worktreePath) : ref
        } ?? "—"
        let worktreeProject = Project(
            name: dirName,
            path: worktreePath,
            branch: branchLabel,
            sessions: [],
            sandbox: project.sandbox
        )
        projects.append(worktreeProject)
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
        alert.informativeText = "Name the worktree. It's created from HEAD and added to the sidebar as its own project until you remove it."
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

    /// Reports a worktree-creation failure as a simple warning alert. Kept here so both
    /// the failure paths above surface the reason rather than silently doing nothing.
    private func presentWorktreeFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't create worktree session"
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

    /// Opens a fresh scratch session that isn't tied to a real project — the welcome
    /// page's agent chips and the `+` button both land here.
    ///
    /// *Where* it runs depends on what it runs. A plain **terminal** drops at `~`,
    /// the way iTerm2/Terminal.app open a new window — a human shell at home is
    /// expected and harmless. An **agent**, though, must never be handed `$HOME` as
    /// its working directory: an autonomous agent there can read and write the user's
    /// whole home (`~/.ssh`, `~/Documents`, …). So agents get a dedicated, scoped
    /// scratch workspace at `~/.termio/default/` (created on first use, sibling to
    /// the existing `~/.termio/worktrees/`), a clean directory that's safe to let an
    /// agent loose in.
    ///
    /// Each destination gathers its loose sessions under one persistent section, so a
    /// second click just grows another row there and selects it, rather than piling
    /// up duplicate sections.
    func addScratchSession(agent: AgentPreset = .terminal) {
        // Loose terminals gather in the `.terminals` container (matched by kind,
        // not path — its `path` is just the `$HOME` spawn fallback); scratch
        // agents keep matching their scoped workspace by path.
        let path = scratchWorkspacePath(for: agent)
        let existing = agent == .terminal
            ? projects.first(where: { $0.kind == .terminals })
            : projects.first(where: { $0.path == path })
        if let existing {
            addSession(to: existing.id, agent: agent)
            return
        }
        let title = agent == .terminal ? "Terminal 1" : agent.displayName
        let session = Session(title: title, agent: agent)
        let project = Project(
            name: agent == .terminal ? "Terminals" : (path as NSString).lastPathComponent,
            path: path,
            branch: currentBranch(in: path) ?? "—",
            sessions: [session],
            kind: agent == .terminal ? .terminals : .folder
        )
        projects.append(project)
        selectedSessionID = session.id
    }

    /// The working directory for a scratch session: `~` for a plain terminal, and the
    /// scoped `~/.termio/default/` workspace for any agent (created on demand). See
    /// `addScratchSession` for why agents are kept out of `$HOME`.
    private func scratchWorkspacePath(for agent: AgentPreset) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        guard agent != .terminal else { return home.path }
        let workspace = home.appendingPathComponent(".termio/default", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        seedScratchWorkspaceDocs(at: workspace)
        return workspace.standardizedFileURL.path
    }

    /// Drops a `CLAUDE.md` and an `AGENTS.md` into the default scratch workspace so an
    /// agent that spawns here reads, up front, that this is a throwaway scratchpad —
    /// not a real project to explore or a place to put anything it should keep. Both
    /// filenames are seeded because agents split on the convention (`CLAUDE.md` for
    /// Claude Code, `AGENTS.md` for Codex/Cursor/Amp and the rest). Only written when
    /// absent, so anything the user later edits into them is preserved.
    private func seedScratchWorkspaceDocs(at workspace: URL) {
        let guidance = """
        # termio scratch workspace

        This is termio's default scratch workspace (`~/.termio/default`) — an empty,
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

    /// The projects in sidebar display order. Without grouping this preserves the stored
    /// order; active grouping orders each pinned/unpinned set. The computed view never
    /// mutates (or persists) the stored tree.
    var orderedProjects: [Project] {
        let order = settings.projectSortOrder
        if order == .none {
            // Keep the original insertion order while retaining the existing Terminals
            // and pinned sections at the top of the navigator.
            let terminals = projects.filter { $0.kind == .terminals }
            let folders = projects.filter { $0.kind != .terminals }
            return terminals + folders.filter(\.pinned) + folders.filter { !$0.pinned }
        }
        return projects.sorted { a, b in
            // The Terminals section is the entry funnel, so it sits above every
            // project — ahead even of pinned ones, whichever sort is active.
            if (a.kind == .terminals) != (b.kind == .terminals) { return a.kind == .terminals }
            // Pinned projects always float to the top, whichever sort is active.
            if a.pinned != b.pinned { return a.pinned }
            switch order {
            case .none:
                return false
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

    /// Presents a folder picker. `sandboxed` decides whether the opened project runs
    /// its sessions under a Seatbelt sandbox (File ▸ Open Project Sandboxed…) or on the
    /// host (File ▸ Open Project…) — the sandbox is decided when the project is brought
    /// in, and can be adjusted later from the project's Security panel.
    func presentOpenProjectPanel(sandboxed: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = sandboxed ? "Open Sandboxed" : "Open"
        panel.message = sandboxed
            ? "Choose a project folder to open under a Seatbelt sandbox."
            : "Choose a project folder to open in termio."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addProject(at: url, sandboxed: sandboxed)
    }

    /// Adds the directory at `url` as a new project section seeded with a single
    /// terminal session, which becomes the selection. A folder already open as a
    /// project is not duplicated — its first session is selected instead. `sandboxed`
    /// seeds the project's sandbox profile so its sessions run under a Seatbelt profile.
    func addProject(at url: URL, sandboxed: Bool = false) {
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
            sessions: [session],
            sandbox: sandboxed ? SandboxProfile() : nil
        )
        projects.append(project)
        selectedSessionID = project.sessions.first?.id
    }

    /// Turns the per-project sandbox on or off. On flips `sandbox` to a default
    /// `SandboxProfile`; off clears it. Only sessions opened *after* the change pick
    /// it up — an already-running session keeps its cached surface — so the user opens
    /// a fresh session to enter (or leave) the sandbox. The change persists via the
    /// `projects` `didSet`.
    func setSandbox(_ enabled: Bool, for id: Project.ID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].sandbox = enabled ? SandboxProfile() : nil
    }

    /// The sandbox profile of a project, or `nil` when the project runs on the host.
    func sandboxProfile(for id: Project.ID) -> SandboxProfile? {
        projects.first(where: { $0.id == id })?.sandbox
    }

    /// Edits a sandboxed project's profile in place (a no-op when the project isn't
    /// sandboxed). The mutation persists via the `projects` `didSet`, and is picked up by
    /// sessions opened after the change — the Security panel edits through here.
    func updateSandbox(for id: Project.ID, _ mutate: (inout SandboxProfile) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }),
              var profile = projects[index].sandbox else { return }
        mutate(&profile)
        projects[index].sandbox = profile
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
            SandboxLauncher.cleanUp(sessionID: sessionID)
            ptyProcesses[sessionID]?.terminate()
            ptyProcesses[sessionID] = nil
            surfaces[sessionID] = nil
            browserPanes[sessionID] = nil
            monitors[sessionID] = nil
            statuses[sessionID] = nil
            currentTool[sessionID] = nil
            liveTitles[sessionID] = nil
            lastWorkingAt[sessionID] = nil
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
        SandboxLauncher.cleanUp(sessionID: id)
        ptyProcesses[id]?.terminate()
        ptyProcesses[id] = nil
        surfaces[id] = nil
        browserPanes[id] = nil
        monitors[id] = nil
        statuses[id] = nil
        currentTool[id] = nil
        liveTitles[id] = nil
        lastWorkingAt[id] = nil

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
