import Foundation

/// Turns a pre-workspace state file into workspaces, and carries the older
/// container migrations that used to live in `TermioStore`.
///
/// Everything here is pure and static: it takes the decoded on-disk shape and
/// returns the live one, so a test can pin the upgrade without standing up a
/// store, a window, or a disk. The one rule the whole file exists to keep is
/// that **no session may be lost** — a row the user could see before the upgrade
/// is a row they can see after it.
enum WorkspaceMigration {
    /// A project as state files wrote it before workspaces existed.
    ///
    /// It is decoded separately from `Project` rather than being kept alive as
    /// dead fields on the live model: `kind`, `sshHost`, and the host container's
    /// remote `path` mean nothing once a workspace owns the loose collections, and
    /// a live type carrying them would invite new code to read them.
    struct LegacyProject: Codable {
        /// `.host` is the only kind whose identity is a machine rather than a
        /// local path; the other three are the funnels a workspace replaces.
        enum Kind: String, Codable {
            case folder, terminals, chats, host
        }

        var id: UUID
        var name: String
        var path: String
        var branch: String
        var sessions: [Session]
        var worktrees: [Worktree]
        var pinned: Bool
        var kind: Kind
        var remoteCheckouts: [String: String]
        var sshHost: String?
        var deviceID: String?

        init(
            id: UUID = UUID(), name: String, path: String, branch: String,
            sessions: [Session], worktrees: [Worktree] = [], pinned: Bool = false,
            kind: Kind = .folder, remoteCheckouts: [String: String] = [:],
            sshHost: String? = nil, deviceID: String? = nil
        ) {
            self.id = id
            self.name = name
            self.path = path
            self.branch = branch
            self.sessions = sessions
            self.worktrees = worktrees
            self.pinned = pinned
            self.kind = kind
            self.remoteCheckouts = remoteCheckouts
            self.sshHost = sshHost
            self.deviceID = deviceID
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, path, branch, sessions, worktrees, pinned, kind, remoteCheckouts,
                 sshHost, deviceID
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            path = try c.decode(String.self, forKey: .path)
            branch = try c.decode(String.self, forKey: .branch)
            sessions = try c.decode([Session].self, forKey: .sessions)
            worktrees = try c.decodeIfPresent([Worktree].self, forKey: .worktrees) ?? []
            pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
            kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .folder
            remoteCheckouts =
                try c.decodeIfPresent([String: String].self, forKey: .remoteCheckouts) ?? [:]
            sshHost = try c.decodeIfPresent(String.self, forKey: .sshHost)
            deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
        }
    }

    /// The whole upgrade, in the order the steps have to run: the old per-container
    /// migrations first (each still describes the file it was written for), then
    /// the fold into workspaces.
    ///
    /// The user opens to the sidebar they closed. Everything the sidebar drew for
    /// this Mac — the Terminals funnel, the Chats funnel, every folder project —
    /// becomes workspace #1, so the column looks the way it did. Each `.host`
    /// container becomes that machine's fallback workspace, which is what the
    /// sidebar showed after switching to that device.
    static func migrate(_ legacy: [LegacyProject]) -> (workspaces: [Workspace], projects: [Project]) {
        let upgraded = liftingRemoteSessionsToHosts(
            migratingScratchProject(migratingHomeProject(normalizingAgentTitles(legacy))))

        var home = Workspace(name: Workspace.defaultName)
        var fallbacks: [Workspace] = []
        var projects: [Project] = []

        for container in upgraded {
            switch container.kind {
            case .terminals:
                home.terminals.append(contentsOf: container.sessions)
            case .chats:
                home.chats.append(contentsOf: container.sessions)
            case .host:
                // A machine's container was never a folder: its `path` is a
                // directory on that box and its sessions are loose shells there.
                // As a workspace it keeps both facts and loses the disguise.
                fallbacks.append(Workspace(
                    name: container.sshHost ?? container.name,
                    terminals: container.sessions,
                    deviceAlias: container.sshHost ?? container.name,
                    deviceID: container.deviceID,
                    isAutoCreated: true
                ))
            case .folder:
                projects.append(Project(
                    id: container.id,
                    workspaceID: home.id,
                    name: container.name,
                    path: container.path,
                    branch: container.branch,
                    sessions: container.sessions,
                    worktrees: container.worktrees,
                    pinned: container.pinned,
                    remoteCheckouts: container.remoteCheckouts
                ))
            }
        }
        return ([home] + fallbacks, projects)
    }

    /// Files any project whose owner no longer exists — a workspace deleted while
    /// the app was closed, or a project written before workspaces — under the
    /// first workspace, guarantees there is a first workspace to file it under,
    /// and leaves every workspace naming exactly one machine. Runs on every load,
    /// not just the upgrade: losing the sidebar to a dangling id is the failure
    /// this rules out, and a workspace that spans two machines is the one this
    /// stage adds.
    ///
    /// This is where the device invariant is established, rather than in the
    /// decoder, because a throwing decode is swallowed (`StateFile.load`) and
    /// comes back as a first-run tree — a stricter `Workspace` decoder would
    /// silently replace the user's whole sidebar. Nothing here changes the on-disk
    /// shape: `deviceAlias` is still the stored field and `nil` is still this Mac.
    static func reconcile(
        workspaces: [Workspace], projects: [Project]
    ) -> (workspaces: [Workspace], projects: [Project]) {
        var workspaces = workspaces
        if workspaces.isEmpty { workspaces = [Workspace(name: Workspace.defaultName)] }
        // Recover "Termio made this" for files written before the flag existed,
        // and do it *before* the device pass below, which is the only moment the
        // answer is still knowable: until then a named machine can only have come
        // from `deviceWorkspace(for:)` or the pre-workspace migration, both of
        // which create a workspace nobody asked for. Afterwards every workspace
        // names a machine and the two are indistinguishable.
        //
        // Idempotent: a workspace already carrying the flag keeps it, and one the
        // user renamed away from its alias is left alone — renaming it is how they
        // claimed it.
        for index in workspaces.indices where workspaces[index].isAutoCreated == nil {
            // Only a workspace that names a machine *and* holds nothing can be one
            // `deviceWorkspace(for:)` minted: it files loose sessions and is created
            // empty, whereas a workspace the user filled is theirs however it was
            // named. Recording the answer — including `false` — is what stops this
            // running again next launch against a device this pass is about to
            // stamp on.
            let workspace = workspaces[index]
            let unclaimed = workspace.deviceAlias.map { $0 == workspace.name } ?? false
            workspaces[index].isAutoCreated =
                unclaimed && projects.allSatisfy { $0.workspaceID != workspace.id }
        }
        // A workspace on this Mac: an orphan is the user's work, and burying it
        // under a box they may never open again hides it. An orphan that turns out
        // to be a checkout over there is moved on by the device pass below.
        let fallbackID = (workspaces.first { $0.device.isThisMac } ?? workspaces[0]).id
        let known = Set(workspaces.map(\.id))
        let filed = projects.map { project -> Project in
            guard !known.contains(project.workspaceID) else { return project }
            var project = project
            project.workspaceID = fallbackID
            return project
        }
        // A colour for every workspace, including the ones written before there
        // were any and the halves the split below has just minted. Assigned
        // rather than derived from the id: a hash repeats often enough to notice
        // with a palette this small, and the point of the mark is that two rows
        // differ.
        //
        // After the split, not before — that is the whole of the idempotence.
        // Colouring first left a fresh half with none, so the *next* load filled
        // it in and the tree came back changed; `reconcile` runs on every launch,
        // and a pass that keeps finding work is a sidebar that reshuffles itself.
        let settled = stampingDevices(workspaces: workspaces, projects: filed)
        return (assigningColors(settled.workspaces), settled.projects)
    }

    /// Fills in a tint for every workspace that has none, choosing the one the
    /// fewest others already carry so a small palette spreads before it repeats.
    ///
    /// Order-independent: the workspaces that already chose are counted first, so
    /// the answer does not depend on which end of the list is walked.
    static func assigningColors(_ workspaces: [Workspace]) -> [Workspace] {
        var used: [Int: Int] = [:]
        for workspace in workspaces {
            if let color = workspace.color { used[color, default: 0] += 1 }
        }
        return workspaces.map { workspace in
            guard workspace.color == nil else { return workspace }
            var workspace = workspace
            let color = leastUsedColor(in: used)
            used[color, default: 0] += 1
            workspace.color = color
            return workspace
        }
    }

    /// The palette is the theme's and its size is not known here, so the index is
    /// chosen within a fixed span and wrapped by whoever draws it. Twelve is the
    /// count every built-in theme yields (`ChromeTheme.workspaceTints`).
    static let colorCount = 12

    private static func leastUsedColor(in used: [Int: Int]) -> Int {
        (0..<colorCount).min { left, right in
            let leftCount = used[left] ?? 0
            let rightCount = used[right] ?? 0
            if leftCount != rightCount { return leftCount < rightCount }
            return left < right
        } ?? 0
    }

    /// Leaves every workspace belonging to exactly one machine — the rule the whole
    /// Device → Workspace → Project hierarchy rests on.
    ///
    /// Three cases, and only the last one is lossy:
    ///
    /// - Every project on one machine: the workspace adopts it. A workspace holding
    ///   nothing but checkouts on a box *is* that box's, whoever made it.
    /// - No projects and no device: this Mac, which is what `nil` already meant.
    /// - Projects on two machines: the workspace **splits**, one per machine. This
    ///   is reachable in shipped state files — `addRemoteProject` used to file a
    ///   checkout on a box into whatever workspace was current, and `addProject` a
    ///   local folder into it just the same, including when that workspace was a
    ///   box's. Both now file by machine, so the split is an upgrade path.
    ///
    /// Idempotent: run over its own output, every workspace already names one
    /// machine and nothing moves.
    private static func stampingDevices(
        workspaces: [Workspace], projects: [Project]
    ) -> (workspaces: [Workspace], projects: [Project]) {
        var projects = projects
        var result: [Workspace] = []
        // What a checkout that names no machine means, which is not the same thing
        // in the two shapes a state file comes in. Before the hierarchy every
        // checkout recorded its own machine, so silence there meant this Mac; now a
        // checkout inherits its workspace's machine, and silence means exactly
        // that — a remote checkout in a box's workspace records nothing at all. One
        // file is written whole by one build, so a single project still carrying a
        // record dates the tree it came from.
        //
        // Reading it the other way is what would break: taking silence for this Mac
        // in a file this build wrote would tear every remote checkout off its
        // workspace on the next launch, and taking it for inheritance in an older
        // file would let a workspace holding local *and* remote checkouts adopt the
        // box and carry the local ones with it.
        let recordsCheckoutDevices = projects.contains { $0.legacyDevice != nil }
        func claimedDevice(_ project: Project) -> WorkspaceDevice? {
            if let alias = project.legacyDevice?.alias { return .ssh(alias: alias) }
            return recordsCheckoutDevices ? .thisMac : nil
        }
        // Every machine a workspace has something on.
        //
        // A device the workspace already names counts as a claim in its own right:
        // its loose sessions were filed there because they run there, and nothing
        // else records that. A loose shell records its own machine and nothing else
        // does, so it is a claim exactly like a checkout's. Leaving it out let a
        // workspace holding local shells and one remote checkout adopt the remote
        // box — and on a one-workspace tree that left nowhere on this Mac for local
        // work to go, which is the violation this pass exists to prevent.
        func devices(of workspace: Workspace, claims: [WorkspaceDevice]) -> Set<WorkspaceDevice> {
            var devices = Set(claims)
            for session in workspace.looseSessions {
                devices.insert(WorkspaceDevice(alias: session.termiodRemoteHost ?? session.sshHost))
            }
            if !workspace.device.isThisMac { devices.insert(workspace.device) }
            return devices
        }
        // The machine a workspace ends this pass on, decided from the workspace
        // alone. It is the same three cases the loop below walks — adopt, stay,
        // split — read for their answer rather than for their effect, which is what
        // makes a home knowable before the pass has reached it.
        func settledDevice(of workspace: Workspace) -> WorkspaceDevice {
            let claims = projects.filter { $0.workspaceID == workspace.id }
                .compactMap(claimedDevice)
            let devices = devices(of: workspace, claims: claims)
            if devices.count > 1 {
                return keptDevice(of: workspace, among: devices, claims: claims)
            }
            guard let only = devices.first, workspace.deviceAlias == nil else {
                return workspace.device
            }
            return only
        }
        // Where a project split off a workspace goes when the tree already has a
        // home for its machine: an upgrade the user did not ask for must not also
        // hand them a second scope for a box they already have one for.
        //
        // Computed over the whole input before anything moves, so the answer does
        // not turn on the order `state.json` happens to list workspaces in.
        // Reading it off the part already processed is what made this asymmetric:
        // a machine's home was found wherever it sat, while this Mac's was found
        // only when it came first — and a file listing the box's workspace ahead of
        // the local one minted a second "This Mac" beside the perfectly good
        // existing one.
        var homes: [WorkspaceDevice: Workspace.ID] = [:]
        for workspace in workspaces {
            let device = settledDevice(of: workspace)
            if homes[device] == nil { homes[device] = workspace.id }
        }

        for workspace in workspaces {
            let owned = projects.filter { $0.workspaceID == workspace.id }
            let claims = owned.compactMap(claimedDevice)
            let devices = devices(of: workspace, claims: claims)

            guard devices.count > 1 else {
                var workspace = workspace
                // Adoption only ever writes an alias onto a workspace that had
                // none. This Mac stays `nil`, so the file keeps its shape.
                if let only = devices.first, workspace.deviceAlias == nil {
                    workspace.deviceAlias = only.alias
                    workspace.deviceID = owned.first {
                        claimedDevice($0) == only
                    }?.legacyDevice?.deviceID
                }
                result.append(workspace)
                continue
            }

            // The half that keeps the workspace's id, and with it the name and the
            // loose sessions. Wire ids embed this uuid — `looseWireID` builds
            // `<uuid>-terminals` for the phone to start a session by, and
            // `ControlScope.id` keys the CLI's watch streams — so it has to survive
            // on one half rather than being reissued on both.
            //
            // A workspace that already named a machine keeps that half: its loose
            // sessions run over there, and `deviceWorkspace(for:)` finds it by
            // alias. Otherwise this Mac's half keeps it, and failing that the half
            // holding the most projects (ties by alias, so the result is stable).
            let keeper = keptDevice(of: workspace, among: devices, claims: claims)
            var kept = workspace
            kept.deviceAlias = keeper.alias
            if kept.deviceID == nil {
                kept.deviceID = owned.first {
                    claimedDevice($0) == keeper
                }?.legacyDevice?.deviceID
            }
            result.append(kept)

            for device in devices.subtracting([keeper]).sorted(by: { ($0.alias ?? "") < ($1.alias ?? "") }) {
                let home: Workspace.ID
                if let existing = homes[device] {
                    home = existing
                } else {
                    // Named after the machine, which is the only thing this half is
                    // known to have in common.
                    // Termio's own: nobody asked for this half, it exists because
                    // the workspace it came from held checkouts on two machines.
                    // Set here rather than recovered later, so a second `reconcile`
                    // over this output changes nothing.
                    var half = Workspace(
                        name: device.displayName, deviceAlias: device.alias,
                        isAutoCreated: true)
                    half.deviceID = owned.first {
                        claimedDevice($0) == device
                    }?.legacyDevice?.deviceID
                    homes[device] = half.id
                    result.append(half)
                    home = half.id
                }
                for index in projects.indices
                where projects[index].workspaceID == workspace.id
                    && claimedDevice(projects[index]) == device {
                    projects[index].workspaceID = home
                }
            }
        }
        return (result, projects)
    }

    /// Which machine's half keeps the original workspace — see the call site for
    /// why that matters. `claims` is one entry per checkout that names a machine,
    /// so the tie-break counts checkouts, the way it did when every checkout
    /// carried its own device.
    private static func keptDevice(
        of workspace: Workspace, among devices: Set<WorkspaceDevice>, claims: [WorkspaceDevice]
    ) -> WorkspaceDevice {
        if !workspace.device.isThisMac { return workspace.device }
        if devices.contains(.thisMac) { return .thisMac }
        func count(_ device: WorkspaceDevice) -> Int {
            claims.filter { $0 == device }.count
        }
        return devices.sorted {
            count($0) == count($1) ? ($0.alias ?? "") < ($1.alias ?? "") : count($0) > count($1)
        }.first ?? .thisMac
    }

    // MARK: - The container migrations that came before

    /// Earlier builds saved agent sessions with a lowercased label (`claude code`)
    /// and plain terminals as `session N`. We now keep the agent's real name
    /// (`Claude Code`, `Terminal N`), so upgrade any session whose title is still
    /// one of those old auto-generated forms. A title the user changed to anything
    /// else is left untouched.
    static func normalizingAgentTitles(_ projects: [LegacyProject]) -> [LegacyProject] {
        projects.map { project in
            var project = project
            project.sessions = project.sessions.map { session in
                var session = session
                if session.agent == .terminal {
                    let suffix = session.title.dropFirst("session ".count)
                    if session.title.hasPrefix("session "), !suffix.isEmpty,
                       suffix.allSatisfy(\.isNumber) {
                        session.title = "Terminal \(suffix)"
                    }
                } else if session.title == session.agent.displayName.lowercased() {
                    session.title = session.agent.displayName
                }
                return session
            }
            return project
        }
    }

    /// State files from before the loose-terminals entity existed (see
    /// docs/design/20260713-loose-terminal-entity.md) modeled scratch terminals as a plain
    /// project rooted at `$HOME`. Re-tag that container as `.terminals` so it folds
    /// into the workspace's Terminals section rather than becoming a fake home
    /// project. Idempotent — an already-tagged container passes through unchanged.
    /// The pre-entity seed also called its one shell "shell", which isn't an auto
    /// `Terminal N` name and would block the cwd-basename label, so it is
    /// re-numbered here.
    static func migratingHomeProject(_ projects: [LegacyProject]) -> [LegacyProject] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return projects.map { project in
            var project = project
            // A host container's `path` is a *remote* path, and its default `~`
            // tilde-expands to this Mac's home — without this guard the home rule
            // below would swallow every host into the Terminals funnel on relaunch,
            // undoing exactly what `liftingRemoteSessionsToHosts` just did.
            guard project.kind != .host else { return project }
            guard project.kind == .terminals
                || (project.path as NSString).standardizingPath == home else { return project }
            project.kind = .terminals
            project.name = "Terminals"
            project.sessions = project.sessions.enumerated().map { index, session in
                var session = session
                if session.title == "shell" { session.title = "Terminal \(index + 1)" }
                return session
            }
            return project
        }
    }

    /// State files from before the Chats funnel existed modeled scratch **agent**
    /// sessions as a plain `.folder` project named "default" at `~/.termio/default`.
    /// Re-tag that container as `.chats` so those sessions fold into the
    /// workspace's Chats section rather than a fake "default" project folder.
    /// Matched by its old scratch path; idempotent — an already-tagged `.chats`
    /// container, and any real project, pass through unchanged. Sessions restart
    /// fresh on relaunch anyway, so repointing the spawn path is free.
    static func migratingScratchProject(_ projects: [LegacyProject]) -> [LegacyProject] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let oldPath = home.appendingPathComponent(".termio/default").standardizedFileURL.path
        return projects.map { project in
            guard project.kind == .folder,
                  (project.path as NSString).standardizingPath == oldPath else { return project }
            var project = project
            project.kind = .chats
            project.name = "Chats"
            return project
        }
    }

    /// State files written before the `.host` container existed put every remote
    /// session — plain `ssh` and durable termiod alike — in the `.terminals` funnel,
    /// where a box you SSH into rendered as a loose local shell. Lift each one into
    /// its machine's own container, keyed by alias, preserving session order within
    /// each host. Only the loose funnel is drained: a remote terminal opened *from* a
    /// project belongs to that project (the row you clicked is the row it appears
    /// under), so `.folder` containers are left alone. Idempotent — a state file that
    /// already has its hosts split out has nothing remote left in `.terminals`.
    static func liftingRemoteSessionsToHosts(_ projects: [LegacyProject]) -> [LegacyProject] {
        func alias(_ session: Session) -> String? { session.termiodRemoteHost ?? session.sshHost }
        guard projects.contains(where: { $0.kind == .terminals && $0.sessions.contains { alias($0) != nil } })
        else { return projects }

        var result: [LegacyProject] = []
        // Host containers already in the file absorb the lifted sessions rather than
        // being duplicated, so the merge survives a half-migrated state.
        var hostIndex: [String: Int] = [:]
        for (offset, project) in projects.enumerated() where project.kind == .host {
            if let host = project.sshHost { hostIndex[host] = offset }
        }

        var lifted: [String: [Session]] = [:]
        for var project in projects {
            if project.kind == .terminals {
                for session in project.sessions {
                    guard let host = alias(session) else { continue }
                    lifted[host, default: []].append(session)
                }
                project.sessions = project.sessions.filter { alias($0) == nil }
            }
            result.append(project)
        }

        for (host, sessions) in lifted.sorted(by: { $0.key < $1.key }) {
            // In the funnel a remote session was auto-named for its box, since that
            // was the only thing telling it apart from the local shells around it.
            // Inside the box's own block that name is the header, so it renumbers —
            // `ukvps ▸ ukvps` says the same word twice. Titles the user (or a clone)
            // chose are left exactly as they are.
            var taken = Set(hostIndex[host].map { result[$0].sessions.map(\.title) } ?? [])
            taken.formUnion(sessions.map(\.title))
            var counter = 0
            let renamed = sessions.map { session -> Session in
                guard session.title == host else { return session }
                var session = session
                repeat { counter += 1 } while taken.contains("Terminal \(counter)")
                session.title = "Terminal \(counter)"
                taken.insert(session.title)
                return session
            }
            if let existing = hostIndex[host] {
                result[existing].sessions.append(contentsOf: renamed)
            } else {
                // The remote cwd is the session's own property, so the container's
                // root stays `~` unless a session already records one.
                let root = renamed.compactMap(\.termiodRemoteCwd).first
                result.append(LegacyProject(
                    name: host, path: root ?? "~", branch: "—",
                    sessions: renamed, kind: .host, sshHost: host
                ))
            }
        }
        // A funnel emptied by the lift is dropped: an empty Terminals section is
        // hidden in the sidebar anyway, and keeping it would resurrect on next launch.
        return result.filter { $0.kind != .terminals || !$0.sessions.isEmpty }
    }
}
