import Foundation

/// Split-pane actions. The groups themselves live on the store as `splitGroups`
/// and the on-screen layout is the derived `splitRoot` (see `TermioStore.swift`);
/// everything here is a small, pure-tree mutation plus the session bookkeeping
/// around it.
extension TermioStore {
    /// The sessions the terminal area is showing right now: the selected
    /// session's group, or just the selected session when it is ungrouped.
    /// `TerminalPane` mounts and reveals exactly these.
    var visiblePaneIDs: [Session.ID] {
        if let root = splitRoot { return root.leafIDs }
        return selectedSessionID.map { [$0] } ?? []
    }

    /// The group `id` belongs to, as an index into `splitGroups` — a session is
    /// in at most one group, so the first hit is the only one.
    private func groupIndex(containing id: Session.ID) -> Int? {
        splitGroups.firstIndex { $0.contains(id) }
    }

    /// Splits the focused pane, putting a fresh plain terminal (in the focused
    /// session's project) in the new half. A plain shell — not a second copy of
    /// the agent — because the dominant reason to split is a companion terminal
    /// beside a working agent, and silently auto-launching another agent
    /// instance is a side effect ⌘D shouldn't have; an agent can still be put
    /// there by splitting from it or grouping it later.
    func splitSelectedPane(_ direction: SplitDirection) {
        guard let focusedID = selectedSessionID,
              let projectIndex = projects.firstIndex(where: { $0.sessions.contains { $0.id == focusedID } }),
              let sessionIndex = projects[projectIndex].sessions.firstIndex(where: { $0.id == focusedID })
        else { return }

        let project = projects[projectIndex]
        let terminalCount = project.sessions.filter { $0.agent == .terminal }.count
        var newSession = Session(title: "Terminal \(terminalCount + 1)")
        // A worktree session runs somewhere other than the project root; the
        // companion shell should land where the focused session actually works.
        newSession.worktreePath = session(focusedID)?.worktreePath
        // Right below the session it splits, not at the end of the project — the
        // sidebar then reads the split group as adjacent rows, which is what lets
        // it draw the VS Code-style ┌/└ group bracket (see `splitLinkMarks`).
        projects[projectIndex].sessions.insert(newSession, at: sessionIndex + 1)

        if let group = groupIndex(containing: focusedID) {
            splitGroups[group] = splitGroups[group]
                .splitting(leaf: focusedID, direction: direction, adding: newSession.id)
        } else {
            splitGroups.append(.split(SplitBranch(direction: direction, ratio: 0.5,
                                                  first: .leaf(focusedID),
                                                  second: .leaf(newSession.id))))
        }
        // The new pane takes focus; it is a member of the (possibly new) group,
        // so the derived `splitRoot` keeps showing this layout.
        selectedSessionID = newSession.id
        isPaneZoomed = false
    }

    /// Splits the focused pane with a **browser pane** — the "terminal left,
    /// browser right/below" layout. The browser pane is a session like any
    /// other (see `Session.browserURL`), so it joins the project, the sidebar,
    /// and the split group through the exact same moves as `splitSelectedPane`;
    /// only its leaf view differs, and no shell is ever spawned for it.
    /// `url` nil opens a blank pane with the address bar focused (the context
    /// menu's plain "Browser Right/Down", used with no link under the pointer).
    func openBrowserPane(url: URL?, direction: SplitDirection) {
        guard let focusedID = selectedSessionID,
              let projectIndex = projects.firstIndex(where: { $0.sessions.contains { $0.id == focusedID } }),
              let sessionIndex = projects[projectIndex].sessions.firstIndex(where: { $0.id == focusedID })
        else { return }

        // Titled by host:port — for a dev server ("localhost:5173") that is more
        // useful in the sidebar than a page title that changes on every route.
        let host = url?.host.map { $0 + (url?.port.map { ":\($0)" } ?? "") }
        var newSession = Session(title: host ?? "Browser")
        // Empty string = a browser pane with no page yet; `browserURL` must stay
        // non-nil, since non-nil is what marks the session as a browser at all.
        newSession.browserURL = url?.absoluteString ?? ""
        projects[projectIndex].sessions.insert(newSession, at: sessionIndex + 1)

        if let group = groupIndex(containing: focusedID) {
            splitGroups[group] = splitGroups[group]
                .splitting(leaf: focusedID, direction: direction, adding: newSession.id)
        } else {
            splitGroups.append(.split(SplitBranch(direction: direction, ratio: 0.5,
                                                  first: .leaf(focusedID),
                                                  second: .leaf(newSession.id))))
        }
        selectedSessionID = newSession.id
    }

    /// Closes the focused *pane* — the layout operation, not the session one.
    /// The session stays alive in the sidebar (its shell keeps running, its
    /// surface stays cached); it just leaves its group, and focus moves to its
    /// layout neighbour. Killing the session outright remains the sidebar's
    /// close, which prunes the groups through `pruneSessionsFromSplit`.
    func closeSelectedPane() {
        guard let focusedID = selectedSessionID,
              let group = groupIndex(containing: focusedID) else { return }
        let neighbor = neighborPane(of: focusedID, in: splitGroups[group])
        setGroup(at: group, to: splitGroups[group].removing(leaf: focusedID))
        if let neighbor { selectedSessionID = neighbor }
        isPaneZoomed = false
    }

    /// Toggles zoom on the focused pane (⌘⇧↩) — maximise it to fill the terminal
    /// area, or restore the split. A no-op with no split on screen, matching
    /// tmux/iTerm2 where zoom only means something inside a group.
    func toggleSelectedPaneZoom() {
        guard splitRoot != nil else { return }
        isPaneZoomed.toggle()
    }

    /// Moves pane focus directionally (⌥⌘ arrows), scored on the visible
    /// group's normalized geometry. No-op without splits or when nothing lies
    /// that way.
    func focusPane(_ direction: PaneFocusDirection) {
        guard let root = splitRoot, let focusedID = selectedSessionID,
              let target = root.pane(direction, of: focusedID) else { return }
        selectedSessionID = target
    }

    /// Live divider drag: writes the branch's clamped ratio into the visible
    /// group (dividers only exist on screen, so the branch is always there).
    func updateSplitRatio(branchID: UUID, ratio: Double) {
        guard let selected = selectedSessionID,
              let group = groupIndex(containing: selected) else { return }
        splitGroups[group] = splitGroups[group].updatingRatio(branchID: branchID, to: ratio)
    }

    /// Drops closed sessions out of every group — called by `closeSession` /
    /// `removeProject` so a killed session never leaves a dead pane behind.
    /// Returns the pane the selection should fall back to when the closed
    /// session was the focused pane (its layout neighbor), or `nil` when no
    /// group was involved.
    @discardableResult
    func pruneSessionsFromSplit(_ removed: Set<Session.ID>) -> Session.ID? {
        // When the focused pane is among the removed, hand the selection to the
        // *surviving* member of its group nearest its old visual slot (never to
        // another removed one — removal order must not matter).
        var preferred: Session.ID?
        if let focused = selectedSessionID, removed.contains(focused),
           let group = groupIndex(containing: focused) {
            let oldLeaves = splitGroups[group].leafIDs
            if let index = oldLeaves.firstIndex(of: focused) {
                let survivors = Set(oldLeaves.filter { !removed.contains($0) })
                preferred = oldLeaves[index...].dropFirst().first(where: survivors.contains)
                    ?? oldLeaves[..<index].reversed().first(where: survivors.contains)
            }
        }

        splitGroups = splitGroups.compactMap { group in
            guard group.leafIDs.contains(where: removed.contains) else { return group }
            var pruned: SplitNode? = group
            for id in removed { pruned = pruned?.removing(leaf: id) }
            // A group needs two panes to mean anything; a lone survivor is just
            // an ungrouped session again.
            if let pruned, case .split = pruned { return pruned }
            return nil
        }
        if let preferred { selectedSessionID = preferred }
        return preferred
    }

    /// Installs a mutated group, dissolving it when fewer than two panes remain
    /// (absence of a group *is* the single-pane state).
    private func setGroup(at index: Int, to tree: SplitNode?) {
        if let tree, case .split = tree {
            splitGroups[index] = tree
        } else {
            splitGroups.remove(at: index)
        }
    }

    /// The leaf adjacent to `id` in visual order — where focus lands when that
    /// pane goes away. Prefers the next pane, falls back to the previous one.
    private func neighborPane(of id: Session.ID, in root: SplitNode) -> Session.ID? {
        let leaves = root.leafIDs
        guard let index = leaves.firstIndex(of: id) else { return nil }
        if index + 1 < leaves.count { return leaves[index + 1] }
        return index > 0 ? leaves[index - 1] : nil
    }
}
