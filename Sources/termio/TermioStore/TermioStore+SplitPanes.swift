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

    /// Adds a session to a project and drops it in **beside** a visible pane as a
    /// split, instead of replacing the view the way `addSession` does. This is the
    /// path the CLI / an agent spawning a sibling takes (`termio sessions spawn`):
    /// there the whole point is to *see* the new agent next to the one you were
    /// watching, not to have it hijack the terminal area and push its predecessor
    /// off to a sidebar row.
    ///
    /// The anchor is the caller's own pane when one is passed (a CLI spawn from a
    /// sibling agent lands beside that agent, wherever the user is looking), else
    /// the pane you're looking at when it belongs to this project, else the
    /// project's last session (a cross-project selection is ignored, so a
    /// background agent's sibling never gets dragged into another project's group).
    /// A lone anchor opens side by side; further spawns land on the *far side*
    /// of the anchor's divider, stacked on the cross axis — the anchor (the
    /// agent you're watching) keeps its full pane and its companions tile up
    /// opposite it, instead of the anchor being carved smaller on every spawn.
    /// With no pane to anchor to (an empty project) it falls back to a plain
    /// `addSession`.
    ///
    /// With `takeFocus` false the selection stays where the user put it: the new
    /// pane is mounted invisibly instead (see `activateInBackground`), so its
    /// surface still attaches and can take a queued prompt.
    @discardableResult
    func addSplitSession(
        to projectID: Project.ID, agent: AgentPreset = .terminal,
        anchor: Session.ID? = nil, takeFocus: Bool = true
    ) -> Session.ID? {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { return nil }

        let anchorID = anchor.flatMap { id in
            projects[projectIndex].sessions.contains { $0.id == id } ? id : nil
        } ?? selectedSessionID.flatMap { id in
            projects[projectIndex].sessions.contains { $0.id == id } ? id : nil
        } ?? projects[projectIndex].sessions.last?.id

        guard let anchorID,
              let anchorIndex = projects[projectIndex].sessions.firstIndex(where: { $0.id == anchorID })
        else {
            // Empty project — nothing to split against; behave like a normal add.
            return addSession(to: projectID, agent: agent, takeFocus: takeFocus)
        }

        let project = projects[projectIndex]
        let title = agent == .terminal
            ? "Terminal \(project.sessions.filter { $0.agent == .terminal }.count + 1)"
            : agent.displayName
        var newSession = Session(title: title, agent: agent)
        // Share the anchor's working directory so a worktree agent's sibling lands
        // in the same checkout — the same courtesy `splitSelectedPane` extends.
        newSession.worktreePath = session(anchorID)?.worktreePath
        // Adjacent to the anchor, so the sidebar reads the group as neighbouring
        // rows and draws its ┌/└ bracket (see `splitLinkMarks`).
        projects[projectIndex].sessions.insert(newSession, at: anchorIndex + 1)

        // A lone anchor opens side by side; an anchor that already has a
        // neighbour keeps its full pane, with the newcomer stacked into the
        // opposite side of its divider (see `splitting(oppositeLeaf:adding:)`).
        if let group = groupIndex(containing: anchorID) {
            if splitGroups[group].branchDirection(childLeaf: anchorID) != nil {
                splitGroups[group] = splitGroups[group]
                    .splitting(oppositeLeaf: anchorID, adding: newSession.id)
            } else {
                splitGroups[group] = splitGroups[group]
                    .splitting(leaf: anchorID, direction: .horizontal, adding: newSession.id)
            }
        } else {
            splitGroups.append(.split(SplitBranch(direction: .horizontal, ratio: 0.5,
                                                  first: .leaf(anchorID),
                                                  second: .leaf(newSession.id))))
        }
        if takeFocus {
            selectedSessionID = newSession.id
            isPaneZoomed = false
        } else {
            activateInBackground(newSession.id)
        }
        return newSession.id
    }

    // MARK: - Type switching (联合 ⇄ 独立)

    /// Whether `id` is currently part of a split group (联合) rather than a
    /// standalone session (独立). Drives which switch action the sidebar offers.
    func isInSplitGroup(_ id: Session.ID) -> Bool {
        groupIndex(containing: id) != nil
    }

    /// The sessions `id` can be grouped *with* — same project, same working
    /// bucket (root vs a given worktree, keyed by `worktreePath`), and not
    /// already grouped with `id`. The bucket match is what keeps the resulting
    /// group a single adjacent run in the sidebar, so its ┌/└ bracket draws.
    func groupableTargets(for id: Session.ID) -> [Session] {
        guard let project = projects.first(where: { $0.sessions.contains { $0.id == id } }),
              let me = session(id) else { return [] }
        let myGroup = groupIndex(containing: id)
        return project.sessions.filter { other in
            other.id != id
                && other.worktreePath == me.worktreePath
                && !(myGroup != nil && groupIndex(containing: other.id) == myGroup)
        }
    }

    /// Pulls a pane out of its split group into a standalone session — the
    /// sidebar's "Ungroup" (联合 → 独立). The session itself is untouched (its shell
    /// keeps running, its surface stays cached); it just leaves the tree, the
    /// group dissolves when a lone pane is left, and the selection *follows* the
    /// detached pane so you see it come up on its own (the difference from
    /// `ungroupSelectedPane`, which hands focus to the neighbour it leaves behind).
    func detachFromSplit(_ id: Session.ID) {
        guard let group = groupIndex(containing: id) else { return }
        setGroup(at: group, to: splitGroups[group].removing(leaf: id))
        selectedSessionID = id
        isPaneZoomed = false
    }

    /// Groups an existing `moved` session in beside `anchor` (独立 → 联合) — VS
    /// Code's drag-a-tab-into-a-pane / "Move to Group". Unlike `splitSelectedPane`
    /// this reuses a session already in the sidebar instead of spawning a fresh
    /// one, so it's how two scattered sessions become one combined split.
    ///
    /// `moved` is first detached from any prior group (a session is a leaf in at
    /// most one tree, so it can never appear twice), then spliced beside the
    /// anchor with the axis alternated across the anchor's current one — the same
    /// tiling-WM rule `addSplitSession` uses. Finally the sidebar rows are
    /// reordered so the group reads as an adjacent run, which is what lets
    /// `splitLinkMarks` draw its bracket over them.
    func groupSession(_ moved: Session.ID, with anchor: Session.ID) {
        guard moved != anchor,
              let projectIndex = projects.firstIndex(where: { $0.sessions.contains { $0.id == anchor } }),
              projects[projectIndex].sessions.contains(where: { $0.id == moved })
        else { return }
        // Already sharing the anchor's group — nothing to switch.
        if let anchorGroup = groupIndex(containing: anchor),
           groupIndex(containing: moved) == anchorGroup { return }

        // 1. Detach `moved` from any prior group, keeping the "one leaf, one tree"
        //    invariant. This may dissolve that group and shift `splitGroups`
        //    indices, so the anchor's group is (re)resolved only afterwards.
        if let previous = groupIndex(containing: moved) {
            setGroup(at: previous, to: splitGroups[previous].removing(leaf: moved))
        }

        // 2. Splice beside the anchor, alternating the split axis across its
        //    current one; a lone anchor (no branch yet) opens side by side.
        let anchorGroup = groupIndex(containing: anchor)
        let direction: SplitDirection
        if let group = anchorGroup, let current = splitGroups[group].branchDirection(childLeaf: anchor) {
            direction = current == .horizontal ? .vertical : .horizontal
        } else {
            direction = .horizontal
        }
        if let group = anchorGroup {
            splitGroups[group] = splitGroups[group]
                .splitting(leaf: anchor, direction: direction, adding: moved)
        } else {
            splitGroups.append(.split(SplitBranch(direction: direction, ratio: 0.5,
                                                  first: .leaf(anchor), second: .leaf(moved))))
        }

        // 3. Sit `moved`'s row right after the anchor's so the sidebar reads the
        //    group as a contiguous run (see `splitLinkMarks`).
        moveSessionRow(moved, besideAnchor: anchor, in: projectIndex)
        selectedSessionID = moved
        isPaneZoomed = false
    }

    /// Moves `moved`'s row to immediately follow the anchor's within the project,
    /// keeping a split group's sidebar rows adjacent. The anchor index is read
    /// *after* the removal so it stays valid regardless of which row came first.
    private func moveSessionRow(_ moved: Session.ID, besideAnchor anchor: Session.ID,
                                in projectIndex: Int) {
        guard let from = projects[projectIndex].sessions.firstIndex(where: { $0.id == moved })
        else { return }
        let row = projects[projectIndex].sessions.remove(at: from)
        let anchorIndex = projects[projectIndex].sessions.firstIndex { $0.id == anchor }
            ?? projects[projectIndex].sessions.count - 1
        projects[projectIndex].sessions.insert(row, at: anchorIndex + 1)
    }

    /// Ungroups the focused *pane* — the layout operation, not the session one.
    /// The session stays alive in the sidebar (its shell keeps running, its
    /// surface stays cached); it just leaves its group, and focus moves to its
    /// layout neighbour. Killing the session outright remains "Close Session",
    /// which prunes the groups through `pruneSessionsFromSplit`.
    func ungroupSelectedPane() {
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

    /// The pane `id` would trade places with when moved `direction`, or `nil`
    /// when nothing lies that way — what greys out the "Move Pane" menu items.
    /// Uses the same directional scoring as focus movement, so "Move Left" and
    /// ⌥⌘← always agree on which pane is the neighbour.
    func movePaneTarget(of id: Session.ID, _ direction: PaneFocusDirection) -> Session.ID? {
        groupIndex(containing: id).flatMap { splitGroups[$0].pane(direction, of: id) }
    }

    /// Moves a pane by trading places with its directional neighbour (tmux's
    /// swap-pane) — the context menu's "Move Pane". The tree's shape and every
    /// divider ratio stay put; only the two leaves change slots. Zoom is
    /// dropped so the result is visible, and the selection sticks with the
    /// moved pane.
    func movePane(_ id: Session.ID, _ direction: PaneFocusDirection) {
        guard let group = groupIndex(containing: id),
              let target = movePaneTarget(of: id, direction) else { return }
        splitGroups[group] = splitGroups[group].swapping(id, and: target)
        selectedSessionID = id
        isPaneZoomed = false
    }

    /// Lands a modifier-dragged pane on `target` (issue #183). An edge zone
    /// re-splits the target with the dragged pane on that side — the pane
    /// leaves its old slot first, its vacated space collapsing into the
    /// sibling exactly as if it had closed, so one gesture subsumes move +
    /// re-split + orientation. The center zone trades places, same as "Move
    /// Pane". Dropping a pane on itself, or across groups, is a no-op — the
    /// self-drop guard matters, because removing the pane and then missing
    /// the (gone) target would otherwise drop it from the tree entirely.
    func dropPane(_ source: Session.ID, onto target: Session.ID, zone: PaneDropZone) {
        guard source != target,
              let group = groupIndex(containing: source),
              group == groupIndex(containing: target) else { return }
        if let direction = zone.splitDirection {
            guard let vacated = splitGroups[group].removing(leaf: source) else { return }
            splitGroups[group] = vacated.splitting(leaf: target, direction: direction,
                                                   adding: source, slot: zone.slot)
        } else {
            splitGroups[group] = splitGroups[group].swapping(source, and: target)
        }
        selectedSessionID = source
        isPaneZoomed = false
    }

    /// Flips the layout of the branch immediately enclosing a pane — side-by-side
    /// ⇄ stacked — via the context menu's "Flip Layout". Only that one divider's
    /// axis turns; the tree's shape, its ratios, and every other pane stay put,
    /// the same restraint "Move Pane" keeps. Zoom is dropped so the result is
    /// visible and the selection sticks with the flipped pane. A no-op when the
    /// pane isn't grouped (a lone pane has no branch to flip).
    func flipPaneLayout(_ id: Session.ID) {
        guard let group = groupIndex(containing: id) else { return }
        splitGroups[group] = splitGroups[group].flippingBranch(containing: id)
        selectedSessionID = id
        isPaneZoomed = false
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
