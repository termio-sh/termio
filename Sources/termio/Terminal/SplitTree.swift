import CoreGraphics
import Foundation

/// How a split arranges its two children: `.horizontal` places them side by side
/// (the "Split Right" action, divider running vertically), `.vertical` stacks
/// them (the "Split Down" action).
enum SplitDirection: String, Codable, Hashable {
    case horizontal
    case vertical
}

/// A direction the user can move pane focus in (⌥⌘ arrows). Separate from
/// `SplitDirection` because focus moves along an edge, not along a split axis.
enum PaneFocusDirection {
    case left, right, up, down
}

/// Which side of a new divider an added pane takes. `.second` is the trailing
/// slot — what "Split Right"/"Split Down" mean — and `.first` the leading one,
/// which is how a drag-drop onto a pane's left/top half lands the dropped pane
/// *before* its target.
enum SplitSlot {
    case first, second
}

/// Where a modifier-dragged pane is about to land on the pane under the
/// pointer (issue #183): an edge half → the target splits and the dragged pane
/// takes that side; the center → the two panes trade places (the existing
/// `swapping` behaviour). Pure math on pane-local geometry, so the hit regions
/// are testable without a view in sight. Points are in top-left-origin space.
enum PaneDropZone: Equatable {
    case left, right, top, bottom
    case center

    /// The middle box (as a fraction of each axis) that reads as "swap" rather
    /// than an edge: 0.4 keeps the swap target hittable without aiming while
    /// leaving each edge a generous 30% band.
    private static let centerFraction: CGFloat = 0.4

    /// The zone for a pointer at `point` in a pane of `size`. Outside the
    /// center box the nearest edge wins — the corner-to-corner diagonals
    /// ghostty's split drag uses, which give each edge a natural triangular
    /// region.
    static func zone(at point: CGPoint, in size: CGSize) -> PaneDropZone {
        guard size.width > 0, size.height > 0 else { return .center }
        let relX = point.x / size.width
        let relY = point.y / size.height
        let half = centerFraction / 2
        if abs(relX - 0.5) <= half, abs(relY - 0.5) <= half { return .center }
        let edges: [(PaneDropZone, CGFloat)] = [
            (.left, relX), (.right, 1 - relX), (.top, relY), (.bottom, 1 - relY),
        ]
        return edges.min { $0.1 < $1.1 }!.0
    }

    /// The part of the target pane to highlight while this zone is hovered:
    /// the half the dropped pane would occupy, or the whole pane for a swap —
    /// the preview that makes the drop unambiguous before the mouse releases.
    func highlightRect(in frame: CGRect) -> CGRect {
        switch self {
        case .left:
            CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right:
            CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .top:
            CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .bottom:
            CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        case .center:
            frame
        }
    }

    /// The split axis a drop here produces, or `nil` for the center swap.
    var splitDirection: SplitDirection? {
        switch self {
        case .left, .right: .horizontal
        case .top, .bottom: .vertical
        case .center: nil
        }
    }

    /// The slot the dragged pane takes in the new branch: leading for the
    /// left/top halves, trailing for right/bottom.
    var slot: SplitSlot {
        switch self {
        case .left, .top: .first
        case .right, .bottom, .center: .second
        }
    }
}

/// A branch of the split tree: two subtrees separated by a draggable divider.
/// `ratio` is the fraction of the branch's span given to `first`; it is clamped
/// so neither side can be dragged into an unusable sliver.
struct SplitBranch: Codable, Hashable {
    var id = UUID()
    var direction: SplitDirection
    var ratio: Double
    var first: SplitNode
    var second: SplitNode

    /// The narrowest either side may be dragged to. Matches the floor terminal
    /// panes need to stay readable; applied on every ratio write so a persisted
    /// tree can never restore into a degenerate layout either.
    static let ratioRange: ClosedRange<Double> = 0.15...0.85
}

/// The split layout of the terminal area: a binary tree whose leaves are
/// sessions and whose branches are draggable dividers. The tree is a pure value
/// — every mutation returns a new tree — so `TermioStore` can hold it as one
/// `@Published` property and persistence is plain `Codable`.
///
/// There is deliberately no "tabs inside a pane" layer (the sidebar already
/// plays that role): a leaf *is* a session, which keeps the whole model to one
/// enum and a handful of recursions.
indirect enum SplitNode: Codable, Hashable {
    case leaf(Session.ID)
    case split(SplitBranch)

    /// The sessions shown by this tree, in visual order (left-to-right,
    /// top-to-bottom).
    var leafIDs: [Session.ID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(let branch): return branch.first.leafIDs + branch.second.leafIDs
        }
    }

    func contains(_ id: Session.ID) -> Bool {
        switch self {
        case .leaf(let leaf): return leaf == id
        case .split(let branch): return branch.first.contains(id) || branch.second.contains(id)
        }
    }

    /// The axis of the branch that has `id` as a direct child — the direction the
    /// pane is currently divided along. Used to add a neighbour on the *cross*
    /// axis so splits alternate the way a tiling window manager does. `nil` when
    /// `id` is a lone pane with no enclosing branch.
    func branchDirection(childLeaf id: Session.ID) -> SplitDirection? {
        switch self {
        case .leaf:
            return nil
        case .split(let branch):
            if branch.first == .leaf(id) || branch.second == .leaf(id) {
                return branch.direction
            }
            return branch.first.branchDirection(childLeaf: id)
                ?? branch.second.branchDirection(childLeaf: id)
        }
    }

    /// Replaces the `target` leaf with a split of it and `newLeaf`. The default
    /// slot puts the new pane second/trailing, matching "Split Right"/"Split
    /// Down"; a drag-drop passes `.first` to land it on the leading side.
    /// A miss returns the tree unchanged.
    func splitting(leaf target: Session.ID, direction: SplitDirection,
                   adding newLeaf: Session.ID, slot: SplitSlot = .second) -> SplitNode {
        switch self {
        case .leaf(let id) where id == target:
            return .split(SplitBranch(direction: direction, ratio: 0.5,
                                      first: slot == .first ? .leaf(newLeaf) : .leaf(id),
                                      second: slot == .first ? .leaf(id) : .leaf(newLeaf)))
        case .leaf:
            return self
        case .split(var branch):
            branch.first = branch.first.splitting(leaf: target, direction: direction,
                                                  adding: newLeaf, slot: slot)
            branch.second = branch.second.splitting(leaf: target, direction: direction,
                                                    adding: newLeaf, slot: slot)
            return .split(branch)
        }
    }

    /// Adds `newLeaf` on the far side of `target`'s divider: finds the branch
    /// that has `target` as a direct child and splits the *sibling* subtree on
    /// the cross axis, so `target`'s own pane keeps its full extent. This is the
    /// spawn placement rule — an agent that keeps spawning companions stays
    /// full-height while the companions stack up opposite it. A miss returns
    /// the tree unchanged.
    func splitting(oppositeLeaf target: Session.ID, adding newLeaf: Session.ID) -> SplitNode {
        switch self {
        case .leaf:
            return self
        case .split(var branch):
            let cross: SplitDirection = branch.direction == .horizontal ? .vertical : .horizontal
            if branch.first == .leaf(target) {
                branch.second = .split(SplitBranch(direction: cross, ratio: 0.5,
                                                   first: branch.second, second: .leaf(newLeaf)))
            } else if branch.second == .leaf(target) {
                branch.first = .split(SplitBranch(direction: cross, ratio: 0.5,
                                                  first: branch.first, second: .leaf(newLeaf)))
            } else {
                branch.first = branch.first.splitting(oppositeLeaf: target, adding: newLeaf)
                branch.second = branch.second.splitting(oppositeLeaf: target, adding: newLeaf)
            }
            return .split(branch)
        }
    }

    /// Trades the positions of two leaves, leaving the tree's shape and every
    /// divider ratio untouched — the "Move Pane" primitive (tmux's swap-pane).
    /// Swapping is what keeps moving a one-click menu action: the layout offers
    /// no ambiguous drop targets to negotiate, panes only change places.
    func swapping(_ a: Session.ID, and b: Session.ID) -> SplitNode {
        // Both leaves must be present, or the rewrite below would *replace* the
        // present one with the absent one — a dangling pane, not a swap.
        guard contains(a), contains(b) else { return self }
        return swapped(a, b)
    }

    private func swapped(_ a: Session.ID, _ b: Session.ID) -> SplitNode {
        switch self {
        case .leaf(a): return .leaf(b)
        case .leaf(b): return .leaf(a)
        case .leaf: return self
        case .split(var branch):
            branch.first = branch.first.swapped(a, b)
            branch.second = branch.second.swapped(a, b)
            return .split(branch)
        }
    }

    /// Removes a leaf, collapsing its parent branch into the surviving sibling
    /// (muxy's unwrap-one-level close). Returns `nil` when the removal consumes
    /// the whole tree.
    func removing(leaf target: Session.ID) -> SplitNode? {
        switch self {
        case .leaf(let id):
            return id == target ? nil : self
        case .split(var branch):
            let first = branch.first.removing(leaf: target)
            let second = branch.second.removing(leaf: target)
            switch (first, second) {
            case (nil, nil): return nil
            case (nil, let survivor?), (let survivor?, nil): return survivor
            case (let first?, let second?):
                branch.first = first
                branch.second = second
                return .split(branch)
            }
        }
    }

    /// Writes a divider's ratio (clamped), leaving the rest of the tree intact.
    func updatingRatio(branchID: UUID, to ratio: Double) -> SplitNode {
        switch self {
        case .leaf:
            return self
        case .split(var branch):
            if branch.id == branchID {
                branch.ratio = min(max(ratio, SplitBranch.ratioRange.lowerBound),
                                   SplitBranch.ratioRange.upperBound)
            } else {
                branch.first = branch.first.updatingRatio(branchID: branchID, to: ratio)
                branch.second = branch.second.updatingRatio(branchID: branchID, to: ratio)
            }
            return .split(branch)
        }
    }

    // MARK: - Layout

    /// One divider the view should draw and make draggable, in the same
    /// coordinate space `layout(in:)` was given.
    struct DividerSpec: Identifiable, Hashable {
        /// The owning branch's id — what `updatingRatio` is keyed by.
        let id: UUID
        let direction: SplitDirection
        /// The visible divider line (thickness `dividerThickness`).
        let frame: CGRect
        /// The branch's full span along its axis, for translating a drag delta
        /// into a ratio delta.
        let span: CGFloat
        /// The ratio at layout time — the drag's anchor value.
        let ratio: Double
    }

    struct PaneLayout {
        var frames: [Session.ID: CGRect] = [:]
        var dividers: [DividerSpec] = []
    }

    /// Computes every pane's rect and every divider from the tree — the muxy
    /// `areaFrames` idea, extended to also emit the dividers. The view layer
    /// stays a flat ZStack (termio's surfaces must never be structurally
    /// re-parented), so this is the *only* place split geometry exists.
    /// `dividerThickness: 0` yields normalized frames for focus scoring.
    func layout(in rect: CGRect, dividerThickness: CGFloat = 1) -> PaneLayout {
        var result = PaneLayout()
        accumulateLayout(in: rect, dividerThickness: dividerThickness, into: &result)
        return result
    }

    private func accumulateLayout(in rect: CGRect, dividerThickness: CGFloat,
                                  into result: inout PaneLayout) {
        switch self {
        case .leaf(let id):
            result.frames[id] = rect
        case .split(let branch):
            let horizontal = branch.direction == .horizontal
            let span = horizontal ? rect.width : rect.height
            let usable = max(0, span - dividerThickness)
            let firstSpan = usable * CGFloat(branch.ratio)
            let secondSpan = usable - firstSpan

            let firstRect: CGRect
            let dividerRect: CGRect
            let secondRect: CGRect
            if horizontal {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstSpan, height: rect.height)
                dividerRect = CGRect(x: rect.minX + firstSpan, y: rect.minY,
                                     width: dividerThickness, height: rect.height)
                secondRect = CGRect(x: dividerRect.maxX, y: rect.minY,
                                    width: secondSpan, height: rect.height)
            } else {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstSpan)
                dividerRect = CGRect(x: rect.minX, y: rect.minY + firstSpan,
                                     width: rect.width, height: dividerThickness)
                secondRect = CGRect(x: rect.minX, y: dividerRect.maxY,
                                    width: rect.width, height: secondSpan)
            }
            if dividerThickness > 0 {
                result.dividers.append(DividerSpec(id: branch.id, direction: branch.direction,
                                                   frame: dividerRect, span: span, ratio: branch.ratio))
            }
            branch.first.accumulateLayout(in: firstRect, dividerThickness: dividerThickness, into: &result)
            branch.second.accumulateLayout(in: secondRect, dividerThickness: dividerThickness, into: &result)
        }
    }

    // MARK: - Directional focus

    /// The best pane to move focus to from `focused` in `direction`, judged on
    /// normalized frames (muxy's scoring: candidates strictly on that side,
    /// preferring cross-axis overlap, then the smallest gap, then the nearest
    /// center). `nil` when there is nothing that way.
    func pane(_ direction: PaneFocusDirection, of focused: Session.ID) -> Session.ID? {
        let frames = layout(in: CGRect(x: 0, y: 0, width: 1, height: 1), dividerThickness: 0).frames
        guard let from = frames[focused] else { return nil }

        var best: (id: Session.ID, score: (Int, CGFloat, CGFloat))?
        for (id, frame) in frames where id != focused {
            guard isCandidate(frame, from: from, direction: direction) else { continue }
            let score = score(frame, from: from, direction: direction)
            if best == nil || score < best!.score { best = (id, score) }
        }
        return best?.id
    }

    private func isCandidate(_ candidate: CGRect, from: CGRect,
                             direction: PaneFocusDirection) -> Bool {
        let epsilon: CGFloat = 0.001
        switch direction {
        case .left: return candidate.maxX <= from.minX + epsilon
        case .right: return candidate.minX >= from.maxX - epsilon
        case .up: return candidate.maxY <= from.minY + epsilon
        case .down: return candidate.minY >= from.maxY - epsilon
        }
    }

    private func score(_ candidate: CGRect, from: CGRect,
                       direction: PaneFocusDirection) -> (Int, CGFloat, CGFloat) {
        let horizontal = direction == .left || direction == .right
        let overlap = horizontal
            ? min(candidate.maxY, from.maxY) - max(candidate.minY, from.minY)
            : min(candidate.maxX, from.maxX) - max(candidate.minX, from.minX)
        let gap: CGFloat
        switch direction {
        case .left: gap = from.minX - candidate.maxX
        case .right: gap = candidate.minX - from.maxX
        case .up: gap = from.minY - candidate.maxY
        case .down: gap = candidate.minY - from.maxY
        }
        let centerDistance = hypot(candidate.midX - from.midX, candidate.midY - from.midY)
        return (overlap > 0 ? 0 : 1, max(0, gap), centerDistance)
    }
}
