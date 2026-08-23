import AppKit
import Foundation
import SwiftUI

/// Where a session sits in the tree: inside a project's roster, or inside one of
/// a workspace's own loose collections.
///
/// Sessions live in three arrays now instead of one, so every edit that used to
/// index `projects[p].sessions[s]` addresses a slot instead. Indices go stale the
/// moment anything is inserted or removed, exactly as they did before — resolve a
/// slot immediately before using it, never across a mutation.
enum SessionSlot: Hashable {
    case project(project: Int, session: Int)
    case terminals(workspace: Int, session: Int)
    case chats(workspace: Int, session: Int)

    /// The session's index inside whichever array holds it. The sidebar's reorder
    /// and the split-pane insert both need it without caring which array it is.
    var sessionIndex: Int {
        switch self {
        case .project(_, let session), .terminals(_, let session), .chats(_, let session):
            return session
        }
    }

    /// The same slot pointing at a different row of the same array.
    func atSession(_ index: Int) -> SessionSlot {
        switch self {
        case .project(let owner, _): return .project(project: owner, session: index)
        case .terminals(let owner, _): return .terminals(workspace: owner, session: index)
        case .chats(let owner, _): return .chats(workspace: owner, session: index)
        }
    }

    /// Whether two slots address the same array — the test behind "can these two
    /// rows be reordered against each other".
    func sharesRoster(with other: SessionSlot) -> Bool {
        switch (self, other) {
        case let (.project(a, _), .project(b, _)): return a == b
        case let (.terminals(a, _), .terminals(b, _)): return a == b
        case let (.chats(a, _), .chats(b, _)): return a == b
        default: return false
        }
    }
}

/// Every session's slot, keyed by id, so `locate(_:)` is one dictionary read
/// instead of a walk of the whole tree.
///
/// Sessions live in three arrays now, and the sidebar asks where one lives
/// several times per row per render — the title, the right-click menu, the
/// tombstone check. A walk made that cost rows × sessions, and a workspace switch
/// pays it in full because it rebuilds the list.
///
/// Precedence matches the walk it replaces: a workspace's terminals, then its
/// chats, then the projects, first match wins. A value type holding no reference
/// to the store, so its agreement with the walk is testable on its own — see
/// `SessionSlotIndexTests`.
struct SessionSlotIndex {
    private var slots: [Session.ID: SessionSlot] = [:]

    init() {}

    init(workspaces: [Workspace], projects: [Project]) {
        for (w, workspace) in workspaces.enumerated() {
            for (s, session) in workspace.terminals.enumerated() where slots[session.id] == nil {
                slots[session.id] = .terminals(workspace: w, session: s)
            }
            for (s, session) in workspace.chats.enumerated() where slots[session.id] == nil {
                slots[session.id] = .chats(workspace: w, session: s)
            }
        }
        for (p, project) in projects.enumerated() {
            for (s, session) in project.sessions.enumerated() where slots[session.id] == nil {
                slots[session.id] = .project(project: p, session: s)
            }
        }
    }

    subscript(id: Session.ID) -> SessionSlot? { slots[id] }

    /// The ids the tree holds. Callers that want the live set (the runtime map's
    /// reconcile) read this rather than flattening `allSessions`, which would copy
    /// every session to answer a question about ids.
    var sessionIDs: Dictionary<Session.ID, SessionSlot>.Keys { slots.keys }
}

extension TermioStore {
    // MARK: - Reading the roster

    /// Every session in the tree: a workspace's loose terminals and chats, plus
    /// every project's own. The order is the one the sidebar draws, workspace by
    /// workspace, so a caller that flattens it gets something stable.
    var allSessions: [Session] {
        var sessions: [Session] = []
        for workspace in workspaces {
            sessions.append(contentsOf: workspace.terminals)
            sessions.append(contentsOf: workspace.chats)
        }
        for project in projects { sessions.append(contentsOf: project.sessions) }
        return sessions
    }

    /// Where `id` lives, or `nil` when nothing holds it. Read straight out of
    /// `sessionSlots`, which every change to the tree rebuilds before anything
    /// else runs, so the slot this returns is the one the last mutation produced.
    func locate(_ id: Session.ID) -> SessionSlot? {
        sessionSlots[id]
    }

    subscript(slot: SessionSlot) -> Session {
        get {
            switch slot {
            case let .project(p, s): return projects[p].sessions[s]
            case let .terminals(w, s): return workspaces[w].terminals[s]
            case let .chats(w, s): return workspaces[w].chats[s]
            }
        }
        set {
            switch slot {
            case let .project(p, s): projects[p].sessions[s] = newValue
            case let .terminals(w, s): workspaces[w].terminals[s] = newValue
            case let .chats(w, s): workspaces[w].chats[s] = newValue
            }
        }
    }

    /// The array the slot indexes — the session's siblings, itself included.
    func roster(at slot: SessionSlot) -> [Session] {
        switch slot {
        case let .project(p, _): return projects[p].sessions
        case let .terminals(w, _): return workspaces[w].terminals
        case let .chats(w, _): return workspaces[w].chats
        }
    }

    func setRoster(_ sessions: [Session], at slot: SessionSlot) {
        switch slot {
        case let .project(p, _): projects[p].sessions = sessions
        case let .terminals(w, _): workspaces[w].terminals = sessions
        case let .chats(w, _): workspaces[w].chats = sessions
        }
    }

    /// Edits a session in place wherever it lives. The one write path for
    /// "change this session", so no caller has to know which array holds it.
    func updateSession(_ id: Session.ID, _ edit: (inout Session) -> Void) {
        guard let slot = locate(id) else { return }
        var session = self[slot]
        edit(&session)
        guard session != self[slot] else { return }
        self[slot] = session
    }

    @discardableResult
    func removeSession(at slot: SessionSlot) -> Session {
        switch slot {
        case let .project(p, s): return projects[p].sessions.remove(at: s)
        case let .terminals(w, s): return workspaces[w].terminals.remove(at: s)
        case let .chats(w, s): return workspaces[w].chats.remove(at: s)
        }
    }

    func insertSession(_ session: Session, at slot: SessionSlot) {
        switch slot {
        case let .project(p, s): projects[p].sessions.insert(session, at: s)
        case let .terminals(w, s): workspaces[w].terminals.insert(session, at: s)
        case let .chats(w, s): workspaces[w].chats.insert(session, at: s)
        }
    }

    /// Whether the session is one of a workspace's loose shells — the rows the
    /// Terminals section draws. A loose terminal owns its own cwd, follows a `cd`
    /// in its sidebar label, and respawns where it was left; a project's terminal
    /// does none of that, because its place is the project.
    func isLooseTerminal(_ id: Session.ID) -> Bool {
        if case .terminals? = locate(id) { return true }
        return false
    }

    /// The workspace a session belongs to: the one that owns it directly for a
    /// loose session, its project's owner otherwise.
    func workspace(for sessionID: Session.ID) -> Workspace? {
        guard let slot = locate(sessionID) else { return nil }
        switch slot {
        case let .terminals(w, _), let .chats(w, _): return workspaces[w]
        case let .project(p, _):
            let owner = projects[p].workspaceID
            return workspaces.first { $0.id == owner }
        }
    }

    // MARK: - The scope

    /// The workspace the sidebar is showing. Falls back to the first one when the
    /// stored id names a workspace that is gone, so the column is never blank
    /// because of bookkeeping.
    var currentWorkspace: Workspace {
        workspaces.first { $0.id == currentWorkspaceID }
            ?? workspaces.first
            ?? Workspace(name: Workspace.defaultName)
    }

    /// Whether the switcher has anything to switch between. With one workspace it
    /// stays out of sight: a control that always reads the same thing is a label
    /// for a decision nobody took.
    var hasMultipleWorkspaces: Bool { workspaces.count > 1 }

    /// Where something that runs on **this Mac** is filed: the current workspace
    /// when it belongs to this Mac, and the first one that does otherwise.
    ///
    /// A workspace belongs to one machine, so a local shell or a local folder put
    /// into a workspace on a box would make that workspace say something untrue —
    /// and the sidebar would draw a row nothing on that machine can account for.
    /// The selection carries the scope across with it, so the user still lands on
    /// what they just created.
    var workspaceForThisMac: Workspace {
        let current = currentWorkspace
        guard !current.device.isThisMac else { return current }
        return workspaces.first { $0.device.isThisMac } ?? current
    }

    /// The workspaces a user can move between, in the order every surface shows
    /// them: the ones the user made first, then the ones Termio made for them. A
    /// workspace nobody asked for is where sessions land that nobody filed, so it
    /// sits after the filing.
    ///
    /// Ordered by who made it, not by which machine it is on. Every workspace
    /// names a machine now, so sorting by the device would push a workspace the
    /// user named and filled with checkouts on one box to the bottom of their own
    /// list.
    var orderedWorkspaces: [Workspace] {
        workspaces.filter { $0.isAutoCreated != true } + workspaces.filter { $0.isAutoCreated == true }
    }

    // MARK: - The machine a project is on

    /// The workspace a project is filed under, or `nil` for a project whose owner
    /// is gone. `WorkspaceMigration.reconcile` files every orphan under a real
    /// workspace on load, so this answers for everything in the tree.
    func workspace(owning project: Project) -> Workspace? {
        workspaces.first { $0.id == project.workspaceID }
    }

    /// The machine a project's checkout lives on: the machine of the workspace
    /// that owns it. A checkout records none of its own — a workspace belongs to
    /// exactly one machine and everything filed under it is on that machine — so
    /// this is the only reading of the question.
    ///
    /// `nil` means the owning workspace is missing and the machine is genuinely
    /// unknown. Do not read that as this Mac: this is the gate on touching local
    /// disk, and answering "here" for a checkout that may be on a box is how the
    /// wrong machine's files get read.
    func device(of project: Project) -> WorkspaceDevice? {
        workspace(owning: project)?.device
    }

    /// Whether a project's checkout is on another machine, so nothing may read its
    /// `path` off this Mac's disk. An unknown machine counts as another one, which
    /// is the safe direction for a gate.
    func isOnAnotherDevice(_ project: Project) -> Bool {
        device(of: project) != .thisMac
    }

    /// The project that already *is* the directory `path` on that machine — what
    /// "opening the same folder twice reopens the row you have" asks.
    ///
    /// The machine comes from the owning workspace, which is also what makes the
    /// match by device identity work: a box reached by a second alias tomorrow
    /// still resolves to the row that is already there.
    func checkout(at path: String, on alias: String, device deviceID: String?) -> Project? {
        projects.first { project in
            project.path == path
                && workspace(owning: project)?.isOn(alias: alias, device: deviceID) == true
        }
    }

    /// Where a checkout on `alias` is filed: the current workspace when it is
    /// already that machine's, and the machine's own workspace otherwise, created
    /// on first use.
    ///
    /// The mirror of `workspaceForThisMac`, for the same reason — a checkout takes
    /// its machine from its workspace, so filing one that lives on a box into a
    /// workspace on this Mac would make the row claim to be here and let the panes
    /// read this Mac's disk for a directory that is over there.
    func workspace(forDevice alias: String, deviceID: String? = nil) -> Workspace.ID {
        if currentWorkspace.device == .ssh(alias: alias) { return currentWorkspace.id }
        return deviceWorkspace(for: alias, deviceID: deviceID)
    }

    /// Shows a different workspace. The selection moves with it, because a
    /// terminal from the scope you just left is precisely the thing the scope
    /// exists to stop showing — and the panes (files, git, issues) follow the
    /// selected session, so leaving it behind would leave them on the old repo.
    func switchToWorkspace(_ id: Workspace.ID) {
        guard let target = workspaces.first(where: { $0.id == id }),
              currentWorkspaceID != id
        else { return }
        // The switch itself, and nothing else: the column is the answer to
        // "which workspace", and it can be drawn knowing only this. Timed
        // separately from the settle below, because the two are what the user
        // means by "the switch" and by "everything after it" — reporting them
        // as one number is how a fast switch reads as a slow one.
        let span = Trace.workspace.begin("workspace switch")
        defer { Trace.workspace.end(span, "to=\(target.name)") }
        // Explicitly un-animated. The column's rows are replaced wholesale by a
        // switch — nothing moves from one place to another — so there is no
        // motion for an animation to describe, and an ambient one (a section's
        // collapse) would still catch this change and drag the whole hosted tree
        // through an animated relayout. A profile of the switch is mostly
        // `NSHostingView.layout()` inside `NSAnimationContext.runAnimationGroup`;
        // this is what takes it out.
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            currentWorkspaceID = id
        }
        settings.currentWorkspaceID = id
        workspaceArrival &+= 1
        let arrival = workspaceArrival
        // Everything below is about the *session* the new scope lands on — its
        // terminal becoming the visible surface, its saved inspector layout
        // reopening a file, its machine being asked for a roster. None of it
        // answers "which workspace", and all of it costs a layout pass, so it
        // waits for the one that puts the new column on screen. Switching reads
        // as instant because it is: the frame the user is waiting for no longer
        // has this work in front of it.
        //
        // The column span is the rest of this run-loop turn: SwiftUI applying
        // `currentWorkspaceID`, the hosted sidebar laying out, the display
        // cycle committing. The switch span above cannot see it — that work
        // runs after this function returns — which is why a 0.7 ms switch
        // still feels blocked. Measurement only; the settle is unchanged.
        let column = Trace.workspace.begin("workspace column")
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                Trace.workspace.end(column)
                guard let self, self.workspaceArrival == arrival else { return }
                self.finishArriving(in: id)
            }
        }
    }

    /// The half of a workspace switch that is about the session, run a turn after
    /// the column is drawn. Guarded by `workspaceArrival`, so a user stepping
    /// through scopes (⌃⌥⌘1…9) only ever settles the one they stop on — the
    /// intermediate ones never open a file or ask a machine anything.
    private func finishArriving(in id: Workspace.ID) {
        let span = Trace.workspace.begin("workspace settle")
        defer { Trace.workspace.end(span) }
        // Clearing beats guessing: an empty workspace shows the welcome state,
        // which is the honest picture of a scope with nothing open in it.
        let selection = Trace.workspace.begin("workspace selection")
        selectedSessionID = sessions(inWorkspace: id).first?.id
        Trace.workspace.end(selection)
        // A machine's fallback workspace is also the machine, so entering it asks
        // that device for its roster. A workspace the user made spans machines and
        // takes its device from whichever session is selected.
        if let workspace = workspaces.first(where: { $0.id == id }), let alias = workspace.deviceAlias {
            let device = Trace.workspace.begin("workspace device")
            switchToDevice(KnownDevice(alias: alias, deviceID: workspace.deviceID))
            Trace.workspace.end(device)
        }
    }

    /// Follows a session into its workspace. Called from the selection's `didSet`,
    /// so it must not move the selection back — it changes the scope only.
    func enterWorkspace(of id: Session.ID) {
        guard let workspace = workspace(for: id), workspace.id != currentWorkspaceID else { return }
        currentWorkspaceID = workspace.id
        settings.currentWorkspaceID = workspace.id
    }

    /// Every session filed under one workspace, in sidebar order.
    func sessions(inWorkspace id: Workspace.ID) -> [Session] {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return [] }
        return workspace.looseSessions + projects(inWorkspace: id).flatMap(\.sessions)
    }

    /// The workspace's projects in sidebar display order: pinned first, then the
    /// rest, each group ordered by the user's chosen sort. A computed view over
    /// `projects` — the stored array keeps its own insertion order, so ordering
    /// is a presentation concern that never mutates (or persists) the tree.
    func projects(inWorkspace id: Workspace.ID) -> [Project] {
        let order = settings.projectSortOrder
        return projects.filter { $0.workspaceID == id }.sorted { a, b in
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

    /// The projects the sidebar is showing right now.
    var orderedProjects: [Project] { projects(inWorkspace: currentWorkspace.id) }

    // MARK: - Editing the set of workspaces

    /// Creates a workspace on `device` and moves into it. Named by the user, so
    /// the prompt is the caller's job; this is the state change.
    ///
    /// The machine is the caller's too: every workspace is on one, and which one
    /// is a decision the menu carries (`refreshNewWorkspaceItem`), so nothing is
    /// guessed here from what the user happens to be looking at.
    ///
    /// Never `isAutoCreated`: that flag means Termio invented the workspace, and
    /// it is what authorises sweeping an empty one away. A workspace someone asked
    /// for is theirs even while it holds nothing.
    @discardableResult
    func addWorkspace(named name: String, on device: WorkspaceDevice, color: Int? = nil)
        -> Workspace.ID
    {
        let workspace = Workspace(
            name: name,
            deviceAlias: device.alias,
            // Usually filled in by the first `hello_ok`, but if the alias has been
            // reached before the answer is known now — and a workspace carrying it
            // matches checkouts on that box without waiting for a connection.
            deviceID: device.alias.flatMap {
                TermiodDeviceRegistry.shared.deviceID(for: TermiodRoute(sshAlias: $0))
            },
            isAutoCreated: false,
            color: color)
        workspaces.append(workspace)
        currentWorkspaceID = workspace.id
        settings.currentWorkspaceID = workspace.id
        // A fresh workspace holds nothing, so nothing can stay selected: the
        // welcome state is what an empty scope looks like.
        selectedSessionID = nil
        return workspace.id
    }

    func renameWorkspace(_ id: Workspace.ID, to name: String, color: Int? = nil) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].name = name
        // The same panel carries both, so renaming is also where a scope's colour
        // is changed — there is no second dialog for one control.
        if let color { workspaces[index].color = color }
    }

    /// Changes a workspace's mark. Its own verb because Settings ▸ Workspaces sets
    /// the colour on a row without touching the name, and renaming through this
    /// would make an unchanged name look like an edit in every observer.
    func setWorkspaceColor(_ id: Workspace.ID, to color: Int) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }),
              workspaces[index].color != color
        else { return }
        workspaces[index].color = color
    }

    /// Removes a workspace, closing everything in it. The last workspace is never
    /// removed — the sidebar has to have a scope to show — and the caller confirms
    /// first, since this ends live sessions.
    func removeWorkspace(_ id: Workspace.ID) {
        guard workspaces.count > 1, let target = workspaces.first(where: { $0.id == id })
        else { return }
        for project in projects(inWorkspace: id) { removeProject(project.id) }
        // Closing the last session in a machine's fallback may already have swept
        // the workspace away, so removal is matched by id rather than by an index
        // captured before the teardown.
        for session in target.looseSessions { closeSession(session.id) }
        workspaces.removeAll { $0.id == id }
        if currentWorkspaceID == id, let first = workspaces.first {
            currentWorkspaceID = first.id
            settings.currentWorkspaceID = first.id
            selectedSessionID = sessions(inWorkspace: first.id).first?.id
        }
    }

    /// Closes every row in one of a workspace's loose sections — the Terminals and
    /// Chats headers' "Close All". Each session tears down the way Close Session
    /// does, so a termiod-backed one is killed in its daemon rather than detached.
    func closeLooseSessions(inWorkspace id: Workspace.ID, chats: Bool) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
        for session in chats ? workspace.chats : workspace.terminals { closeSession(session.id) }
    }

    /// Files a project under another workspace. The project's sessions travel with
    /// it — they are the project's, not the workspace's.
    func moveProject(_ projectID: Project.ID, toWorkspace workspaceID: Workspace.ID) {
        guard let target = workspaces.first(where: { $0.id == workspaceID }),
              let index = projects.firstIndex(where: { $0.id == projectID }),
              projects[index].workspaceID != workspaceID,
              // Refused across machines. A checkout is a directory on one box; the
              // move would not move the directory, so the row would come to rest in
              // a workspace whose machine has never had that path. Putting the repo
              // on the other machine is a clone — a different verb, with a cost.
              // `moveToWorkspaceMenuItem` offers only same-machine targets, so this
              // is the backstop rather than the place the user learns it.
              device(of: projects[index]) == target.device
        else { return }
        projects[index].workspaceID = workspaceID
    }

    // MARK: - Prompts

    /// Asks for a name, then creates the workspace on `device` and moves into it.
    /// Bailing out leaves the tree untouched.
    ///
    /// The machine arrives already chosen, from the row that opened this panel, so
    /// the panel names it rather than asking again — "New Workspace on ukvps"
    /// beside "Open a Project on ukvps". Someone with one machine sees neither the
    /// choice nor the name of it.
    func presentNewWorkspacePanel(on device: WorkspaceDevice) {
        // The machine is named in the body as well as the title, because the body
        // is the line that makes the promise: what gets filed here will live on
        // that box. "this Mac", said over a workspace being created on ukvps, is
        // not vague — it is wrong about the one fact the sentence is for.
        //
        // Two whole sentences rather than one with the machine interpolated: this
        // Mac has no alias to drop in, and "this Mac" as a fragment key is not
        // something a translator can place inside a sentence they can't see.
        let title: String
        let message: String
        if let alias = device.alias {
            title = localized("New Workspace on \(alias)")
            message = localized("Name the workspace. It starts empty; sessions and projects you open on \(alias) from now on are filed under it.")
        } else {
            title = localized("New Workspace")
            message = localized("Name the workspace. It starts empty; sessions and projects you open on this Mac from now on are filed under it.")
        }
        guard let chosen = promptForWorkspaceName(
            title: title,
            message: message,
            confirm: localized("Create"),
            defaultName: nextFreeWorkspaceName
        ) else { return }
        addWorkspace(named: chosen.name, on: device, color: chosen.color)
    }

    /// What the new-workspace field opens with: "Workspace", bumped past the names
    /// already taken, the way `uniqueWorktreeDirName` bumps a worktree folder.
    ///
    /// The default is what makes the panel work at all. `promptForWorkspaceName`
    /// treats an empty field as a cancel, so opening empty meant Return created
    /// nothing and said nothing — a dead end at the first keystroke. Prefilled and
    /// selected, Return creates and typing over it renames, which is what a new
    /// item does everywhere else on macOS.
    private var nextFreeWorkspaceName: String {
        Self.nextFreeWorkspaceName(base: localized("Workspace"),
                                   taken: Set(workspaces.map(\.name)))
    }

    /// The counter rule on its own, so it can be tested without standing up a
    /// store: `base`, then `base 2`, `base 3`, skipping every name in use.
    /// `nonisolated` because it reads nothing but its arguments.
    nonisolated static func nextFreeWorkspaceName(base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var counter = 2
        while taken.contains("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
    }

    /// Renames a workspace in place. A machine's fallback can be renamed like any
    /// other — the alias is what identifies it, not the label.
    func presentRenameWorkspacePanel(_ id: Workspace.ID) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
        guard let chosen = promptForWorkspaceName(
            title: localized("Rename Workspace"),
            message: localized("Choose a name for this workspace."),
            confirm: localized("Rename"),
            defaultName: workspace.name,
            color: workspace.color
        ) else { return }
        renameWorkspace(id, to: chosen.name, color: chosen.color)
    }

    /// Confirms before removing a workspace, because it closes every session in
    /// it. The alert names the count rather than saying "everything".
    func confirmRemoveWorkspace(_ id: Workspace.ID) {
        guard workspaces.count > 1, let workspace = workspaces.first(where: { $0.id == id })
        else { return }
        let count = sessions(inWorkspace: id).count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localized("Remove “\(workspace.name)”?")
        alert.informativeText = count == 0
            ? localized("The workspace is empty. Projects and sessions you open later go to another workspace.")
            : localized("Closing it stops \(count) session(s). The folders on disk are left alone.")
        // Cancel first so it owns both Return and Escape; the destructive button
        // takes a deliberate click.
        alert.addButton(withTitle: localized("Cancel"))
        alert.addButton(withTitle: localized("Remove Workspace"))
        alert.buttons.last?.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        removeWorkspace(id)
    }

    /// A one-field name prompt, the same `NSAlert` shape the worktree and rename
    /// prompts use. Returns the trimmed entry, or `nil` if cancelled or emptied.
    private func promptForWorkspaceName(
        title: String, message: String, confirm: String, defaultName: String,
        color: Int? = nil
    ) -> (name: String, color: Int)? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: localized("Cancel"))

        // The colour arrives already chosen — the least-used one, the same rule
        // that fills it in for every workspace written before there were colours.
        // So this is a decision the user may change, never one they must make:
        // the panel opens with the name selected and Return still creates.
        let fields = WorkspaceFields(
            name: defaultName,
            color: color ?? WorkspaceMigration.assigningColors(workspaces + [Workspace(name: "")])
                .last?.color ?? 0,
            tints: settings.chromeTheme(for: appearanceIsDark ? .dark : .light)?.workspaceTints ?? [])
        alert.accessoryView = fields.view
        alert.window.initialFirstResponder = fields.field
        fields.field.selectText(nil)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = fields.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : (name, fields.color)
    }

    private var appearanceIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: - The machine fallback

    /// The fallback workspace for `alias`, created on first use — "the sessions on
    /// that box that nothing else accounts for". Matched by alias rather than by
    /// name, so two sessions on the same box always land together.
    ///
    /// It is a workspace like any other: the switcher lists it, the sidebar draws
    /// it with the same four sections. What makes it a fallback is only that
    /// nobody chose it — the `termiod` CLI and the phone start sessions on a
    /// machine without saying where they belong, and those sessions have to be
    /// reachable somewhere.
    ///
    /// More than one workspace can name the same machine, so this picks rather than
    /// assumes: `WorkspaceMigration.reconcile` lets a workspace the user named and
    /// filled with checkouts on one box adopt that box, and the box may already
    /// have a fallback of its own. Termio's own comes first — a session nobody
    /// filed belongs in the workspace nobody asked for, not in the middle of the
    /// user's own work. (Adoption is not the alternative: the workspace really is
    /// on that machine, and moving its projects out to say so would empty a
    /// workspace the user named.)
    @discardableResult
    func deviceWorkspace(for alias: String, deviceID: String? = nil) -> Workspace.ID {
        let onThatMachine = workspaces.indices.filter { workspaces[$0].deviceAlias == alias }
        if let index = onThatMachine.first(where: { workspaces[$0].isAutoCreated == true })
            ?? onThatMachine.first {
            if let deviceID, workspaces[index].deviceID == nil { workspaces[index].deviceID = deviceID }
            return workspaces[index].id
        }
        // Marked as Termio's own the moment it is made, which is the only place
        // that fact is known for certain. Nobody asked for this workspace; a
        // session arrived on a machine with nowhere to be filed.
        let workspace = Workspace(
            name: alias, deviceAlias: alias, deviceID: deviceID, isAutoCreated: true)
        workspaces.append(workspace)
        return workspace.id
    }
}

/// The new-workspace panel's accessory: the name, and the colour the scope wears
/// in the switcher.
///
/// The colour is a row of swatches rather than a pop-up because there are five of
/// them and they are the thing being chosen — a menu would hide the choice behind
/// a click and show a word for a colour. One arrives already selected, so the
/// panel is still a name field that Return commits.
///
/// A class rather than a few locals because the alert runs modally and the
/// swatches have to keep answering clicks while it is up.
@MainActor
private final class WorkspaceFields: NSObject {
    let view = NSStackView()
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    private(set) var color: Int
    private let tints: [Color]
    private var swatches: [NSButton] = []

    private static let swatchSize: CGFloat = 26
    /// The panel's one column width. The field and every swatch row share it, so
    /// the grid ends where the name field ends instead of trailing off inside it.
    private static let width: CGFloat = 260
    /// Six to a row, which is what makes a row of the palette one intensity and a
    /// column of it one hue (`ChromeTheme.workspaceTints`).
    private static let swatchesPerRow = 6

    init(name: String, color: Int, tints: [Color]) {
        self.color = color
        self.tints = tints
        super.init()
        field.stringValue = name

        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 10
        for start in stride(from: 0, to: tints.count, by: Self.swatchesPerRow) {
            let row = NSStackView()
            row.orientation = .horizontal
            // Spread rather than spaced by a fixed gap: the row is as wide as the
            // field above it, and a short last row keeps its columns under the
            // full one instead of bunching to the leading edge.
            row.distribution = .equalSpacing
            for index in start..<min(start + Self.swatchesPerRow, tints.count) {
                let button = NSButton(
                    frame: NSRect(x: 0, y: 0, width: Self.swatchSize, height: Self.swatchSize))
                button.isBordered = false
                button.title = ""
                button.setButtonType(.momentaryChange)
                button.target = self
                button.action = #selector(pick(_:))
                button.tag = index
                // A colour has no name to read out, so the position is what a
                // screen reader can say about it.
                button.setAccessibilityLabel(localized("Colour \(index + 1)"))
                button.widthAnchor.constraint(equalToConstant: Self.swatchSize).isActive = true
                button.heightAnchor.constraint(equalToConstant: Self.swatchSize).isActive = true
                swatches.append(button)
                row.addArrangedSubview(button)
            }
            row.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
            grid.addArrangedSubview(row)
        }
        redrawSwatches()

        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 10
        view.addArrangedSubview(field)
        if !tints.isEmpty { view.addArrangedSubview(grid) }
        field.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        // NSAlert lays its accessory out by frame, so the stack carries its own
        // measured size rather than a number guessed here.
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
    }

    @objc private func pick(_ sender: NSButton) {
        color = sender.tag
        redrawSwatches()
    }

    private func redrawSwatches() {
        for (index, button) in zip(tints.indices, swatches) {
            button.image = Self.swatch(NSColor(tints[index]), selected: index == color)
        }
    }

    /// The selected swatch is drawn as a ring around a gap around a smaller dot,
    /// all in its own colour — the treatment every colour picker on this system
    /// uses, and the one Dia's `ColorSwatch` builds out of a main layer and a
    /// separate selection layer.
    ///
    /// Not a checkmark and not a contrasting outline: a tick or a ring in the
    /// label colour has to be light or dark, and either choice disappears against
    /// half of a palette that comes from the user's terminal theme. A shape made
    /// of the swatch's own colour cannot lose contrast with itself.
    private static func swatch(_ color: NSColor, selected: Bool) -> NSImage {
        NSImage(size: NSSize(width: swatchSize, height: swatchSize), flipped: false) { rect in
            color.setFill()
            guard selected else {
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                return true
            }
            NSBezierPath(ovalIn: rect.insetBy(dx: 5, dy: 5)).fill()
            color.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 2
            ring.stroke()
            return true
        }
    }
}
