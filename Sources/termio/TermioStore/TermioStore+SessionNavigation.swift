import Foundation

/// Menu-bar session navigation: the Session menu's live roster and the ⌘⇧]/⌘⇧[
/// cycling verbs. Both read the same flattened order, so the menu's list and
/// what "next" means always agree.
extension TermioStore {
    /// Sessions grouped by project in sidebar display order: the Terminals
    /// funnel first, then Chats, then Remote hosts, then the folder projects as `orderedProjects`
    /// sorts them; within a project the primary checkout's sessions precede each
    /// worktree's, mirroring the sidebar's nesting. Projects with no sessions
    /// are skipped — the menu is a jump list, not a project browser. (Sessions
    /// pointing at a worktree the project no longer records are dropped here
    /// exactly as the sidebar drops them.)
    var sidebarSessionGroups: [(project: Project, sessions: [Session])] {
        let ordered = orderedProjects
        let partitioned = ordered.filter { $0.kind == .terminals }
            + ordered.filter { $0.kind == .chats }
            + ordered.filter { $0.kind == .host }
            + ordered.filter { $0.kind == .folder }
        return partitioned.compactMap { project in
            guard !project.sessions.isEmpty else { return nil }
            guard !project.worktrees.isEmpty else { return (project, project.sessions) }
            let primary = project.sessions.filter {
                $0.worktreePath == nil || $0.worktreePath == project.path
            }
            let nested = project.worktrees.flatMap { worktree in
                project.sessions.filter { $0.worktreePath == worktree.path }
            }
            return (project, primary + nested)
        }
    }

    /// Selects the session `offset` steps away in the flattened sidebar order,
    /// wrapping at both ends — tab cycling for sessions. With nothing selected
    /// (the welcome page) it lands on the first/last session instead.
    func selectAdjacentSession(_ offset: Int) {
        let sessions = sidebarSessionGroups.flatMap(\.sessions)
        guard !sessions.isEmpty else { return }
        let target: Session
        if let current = selectedSessionID,
           let index = sessions.firstIndex(where: { $0.id == current }) {
            let count = sessions.count
            target = sessions[((index + offset) % count + count) % count]
        } else {
            target = offset >= 0 ? sessions.first! : sessions.last!
        }
        guard target.id != selectedSessionID else { return }
        selectedSessionID = target.id
        markSeen(target.id)
    }
}
