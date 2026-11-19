import Foundation
import TermioShared

/// The horizontal layout's top level: what the sidebar lists while a group's sessions sit as
/// tabs above the cards (`TabLayout.horizontal`). Terminals and Chats are groups the way a
/// project is.
enum TabGroup: Hashable {
    case project(Project.ID)
    case terminals
    case chats
}

extension TermioStore {
    /// The group `id` is filed under.
    func group(of id: Session.ID) -> TabGroup? {
        switch locate(id) {
        case .project(let index, _): return .project(projects[index].id)
        case .terminals: return .terminals
        case .chats: return .chats
        case nil: return nil
        }
    }

    /// The groups the sidebar lists in the horizontal layout: Terminals and Chats while they
    /// hold anything, then the workspace's projects in the sidebar's own order.
    var sessionGroups: [TabGroup] { sessionGroups(of: currentWorkspace) }

    /// The same list for one window's workspace, which is the current one only in
    /// the active window.
    func sessionGroups(of workspace: Workspace) -> [TabGroup] {
        var groups: [TabGroup] = []
        if !workspace.terminals.isEmpty { groups.append(.terminals) }
        if !workspace.chats.isEmpty { groups.append(.chats) }
        groups += projects(inWorkspace: workspace.id).map { .project($0.id) }
        return groups
    }

    func sessions(in group: TabGroup) -> [Session] { sessions(in: group, of: currentWorkspace) }

    func sessions(in group: TabGroup, of workspace: Workspace) -> [Session] {
        switch group {
        case .project(let id): return projects.first { $0.id == id }?.sessions ?? []
        case .terminals: return workspace.terminals
        case .chats: return workspace.chats
        }
    }

    func title(of group: TabGroup) -> String {
        switch group {
        case .project(let id): return projects.first { $0.id == id }?.name ?? ""
        case .terminals: return localized("Terminals")
        case .chats: return localized("Chats")
        }
    }

    /// A group's tabs: each split group once, at its first member's place, and every other
    /// session on its own. A tab is its sessions' ids, in the split's own order.
    func tabs(in group: TabGroup) -> [[Session.ID]] {
        var placed = Set<Session.ID>()
        var tabs: [[Session.ID]] = []
        for session in sessions(in: group) where !placed.contains(session.id) {
            if let split = splitGroups.first(where: { $0.contains(session.id) }) {
                let members = split.leafIDs
                placed.formUnion(members)
                tabs.append(members)
            } else {
                placed.insert(session.id)
                tabs.append([session.id])
            }
        }
        return tabs
    }

    /// Moves the tab at `from` to `to` in `group`, as a drag in the tab strip drops it. The tabs
    /// are the group's roster seen through its split groups, so the roster is what moves: the
    /// sidebar shows the same order in the vertical layout, and there is no second order to keep.
    func moveTab(at from: Int, to: Int, in group: TabGroup) {
        guard from != to else { return }
        let splits = splitGroups.map(\.leafIDs)
        func moved(_ sessions: [Session]) -> [Session] {
            let order = movingTab(in: sessions.map(\.id), splits: splits, from: from, to: to)
            let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return order.compactMap { byID[$0] }
        }
        switch group {
        case .project(let id):
            guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
            projects[index].sessions = moved(projects[index].sessions)
        case .terminals:
            guard let index = workspaces.firstIndex(where: { $0.id == currentWorkspace.id }) else { return }
            workspaces[index].terminals = moved(workspaces[index].terminals)
        case .chats:
            guard let index = workspaces.firstIndex(where: { $0.id == currentWorkspace.id }) else { return }
            workspaces[index].chats = moved(workspaces[index].chats)
        }
    }

    /// The status a group or a tab shows for its sessions together: whatever most needs the
    /// person — blocked on them, then working, then finished.
    func combinedStatus(of ids: [Session.ID]) -> SessionStatus {
        let statuses = ids.map(status(for:))
        if statuses.contains(.needsAttention) { return .needsAttention }
        if statuses.contains(.working) { return .working }
        if statuses.contains(.done) { return .done }
        return .idle
    }

    /// Opens a group the way a browser opens a tab group: back on the session last selected in
    /// it, else its first. A project with no sessions gets a terminal.
    func open(_ group: TabGroup) {
        let members = sessions(in: group)
        if let last = lastGroupSelection[currentWorkspaceID]?[group], members.contains(where: { $0.id == last }) {
            selectedSessionID = last
        } else if let first = members.first {
            selectedSessionID = first.id
        } else if case .project(let id) = group {
            addSession(to: id)
        }
    }
}

/// `rows` with the tab at `from` moved to `to`. A tab is a split group's members, taken in their
/// roster order (they sit together, see `gatherSplitRuns`), or a lone row; the members move as one
/// and stay together, so the sidebar's bracket survives the move.
func movingTab(in rows: [Session.ID], splits: [[Session.ID]], from: Int, to: Int) -> [Session.ID] {
    var tabs: [[Session.ID]] = []
    var placed = Set<Session.ID>()
    for row in rows where !placed.contains(row) {
        let members = splits.first { $0.contains(row) }.map { split in rows.filter(split.contains) } ?? [row]
        placed.formUnion(members)
        tabs.append(members)
    }
    guard tabs.indices.contains(from) else { return rows }
    let tab = tabs.remove(at: from)
    tabs.insert(tab, at: min(max(to, 0), tabs.count))
    return tabs.flatMap { $0 }
}
