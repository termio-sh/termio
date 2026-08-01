import XCTest
@testable import termio

/// The spawn placement rule (`splitting(oppositeLeaf:adding:)`): an agent that
/// keeps spawning companions must keep its own full pane, with the companions
/// stacking up on the far side of its divider — never carving the agent
/// smaller on every spawn.
final class SplitTreeTests: XCTestCase {
    private let agent = Session.ID()
    private let run1 = Session.ID()
    private let run2 = Session.ID()
    private let run3 = Session.ID()

    /// First spawn opens side by side; the next two land opposite the agent,
    /// stacked on the cross axis: `[agent | [run1 / run2 / run3]]`.
    func testRepeatedSpawnsStackOppositeTheAnchor() {
        var tree = SplitNode.split(SplitBranch(direction: .horizontal, ratio: 0.5,
                                               first: .leaf(agent), second: .leaf(run1)))
        tree = tree.splitting(oppositeLeaf: agent, adding: run2)
        tree = tree.splitting(oppositeLeaf: agent, adding: run3)

        let layout = tree.layout(in: CGRect(x: 0, y: 0, width: 1, height: 1),
                                 dividerThickness: 0)
        let agentFrame = layout.frames[agent]!
        // The agent still spans the full height of the group…
        XCTAssertEqual(agentFrame.height, 1, accuracy: 0.001)
        // …and every companion sits entirely on its far side.
        for id in [run1, run2, run3] {
            XCTAssertGreaterThanOrEqual(layout.frames[id]!.minX, agentFrame.maxX - 0.001)
        }
        XCTAssertEqual(tree.leafIDs, [agent, run1, run2, run3])
    }

    /// A vertical anchor branch stacks companions horizontally — the cross axis
    /// is derived from the anchor's own divider, not hardcoded.
    func testCrossAxisFollowsTheAnchorBranch() {
        var tree = SplitNode.split(SplitBranch(direction: .vertical, ratio: 0.5,
                                               first: .leaf(agent), second: .leaf(run1)))
        tree = tree.splitting(oppositeLeaf: agent, adding: run2)

        let layout = tree.layout(in: CGRect(x: 0, y: 0, width: 1, height: 1),
                                 dividerThickness: 0)
        // The agent keeps the full top row; run1 and run2 share the bottom.
        XCTAssertEqual(layout.frames[agent]!.width, 1, accuracy: 0.001)
        XCTAssertEqual(layout.frames[run1]!.minY, layout.frames[run2]!.minY, accuracy: 0.001)
    }

    /// Swapping trades exactly the two leaves' positions; the tree's shape and
    /// every frame stay put ("Move Pane" must never reflow the layout).
    func testSwappingTradesPlacesWithoutReflow() {
        let tree = SplitNode.split(SplitBranch(
            direction: .horizontal, ratio: 0.7,
            first: .leaf(agent),
            second: .split(SplitBranch(direction: .vertical, ratio: 0.5,
                                       first: .leaf(run1), second: .leaf(run2)))))
        let swapped = tree.swapping(agent, and: run2)

        let rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let before = tree.layout(in: rect, dividerThickness: 0).frames
        let after = swapped.layout(in: rect, dividerThickness: 0).frames
        // The two panes traded frames exactly; the bystander kept its own.
        XCTAssertEqual(after[agent], before[run2])
        XCTAssertEqual(after[run2], before[agent])
        XCTAssertEqual(after[run1], before[run1])
    }

    /// Swapping with a leaf that isn't in the tree changes nothing — it must
    /// not replace the present pane with a dangling one.
    func testSwappingMissingLeafIsANoOp() {
        let tree = SplitNode.split(SplitBranch(direction: .horizontal, ratio: 0.5,
                                               first: .leaf(agent), second: .leaf(run1)))
        XCTAssertEqual(tree.swapping(agent, and: run3), tree)
        XCTAssertEqual(tree.swapping(run3, and: agent), tree)
    }

    /// A miss leaves the tree unchanged.
    func testMissingAnchorIsANoOp() {
        let tree = SplitNode.split(SplitBranch(direction: .horizontal, ratio: 0.5,
                                               first: .leaf(agent), second: .leaf(run1)))
        XCTAssertEqual(tree.splitting(oppositeLeaf: run3, adding: run2), tree)
    }

    /// The drag-drop slot: `.first` lands the added pane on the leading side of
    /// the new divider (a drop on the left/top half), where the default keeps
    /// "Split Right"/"Split Down"'s trailing placement.
    func testSplittingLeadingSlotPutsNewcomerFirst() {
        let split = SplitNode.leaf(agent)
            .splitting(leaf: agent, direction: .horizontal, adding: run1, slot: .first)
        guard case let .split(branch) = split else {
            return XCTFail("expected a branch")
        }
        XCTAssertEqual(branch.direction, .horizontal)
        XCTAssertEqual(branch.first, .leaf(run1))
        XCTAssertEqual(branch.second, .leaf(agent))
    }

    /// An edge drop is remove-then-resplit: the dragged pane's old slot
    /// collapses into its sibling, and the target divides on the drop zone's
    /// axis with the dragged pane on the dropped side. From `[agent | run1]`,
    /// dropping `agent` onto `run1`'s bottom half yields `[run1 / agent]`.
    func testEdgeDropRecomposesAroundTheTarget() {
        let tree = SplitNode.split(SplitBranch(direction: .horizontal, ratio: 0.7,
                                               first: .leaf(agent), second: .leaf(run1)))
        let zone = PaneDropZone.bottom
        let vacated = tree.removing(leaf: agent)!
        let dropped = vacated.splitting(leaf: run1, direction: zone.splitDirection!,
                                        adding: agent, slot: zone.slot)

        let frames = dropped.layout(in: CGRect(x: 0, y: 0, width: 1, height: 1),
                                    dividerThickness: 0).frames
        XCTAssertEqual(dropped.leafIDs, [run1, agent])
        // Stacked now: run1 owns the full-width top half, agent the bottom.
        XCTAssertEqual(frames[run1]!.width, 1, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(frames[agent]!.minY, frames[run1]!.maxY - 0.001)
    }

    /// The drop-zone hit regions (top-left-origin space): a middle box swaps,
    /// and outside it the nearest edge wins, so the regions are the four
    /// corner-to-corner triangles.
    func testDropZoneRegions() {
        let size = CGSize(width: 100, height: 100)
        XCTAssertEqual(PaneDropZone.zone(at: CGPoint(x: 50, y: 50), in: size), .center)
        XCTAssertEqual(PaneDropZone.zone(at: CGPoint(x: 65, y: 65), in: size), .center)
        XCTAssertEqual(PaneDropZone.zone(at: CGPoint(x: 5, y: 50), in: size), .left)
        XCTAssertEqual(PaneDropZone.zone(at: CGPoint(x: 95, y: 50), in: size), .right)
        XCTAssertEqual(PaneDropZone.zone(at: CGPoint(x: 50, y: 5), in: size), .top)
        XCTAssertEqual(PaneDropZone.zone(at: CGPoint(x: 50, y: 95), in: size), .bottom)
        // Diagonal tie-breaking: near a corner the closer edge wins.
        XCTAssertEqual(PaneDropZone.zone(at: CGPoint(x: 10, y: 20), in: size), .left)
        XCTAssertEqual(PaneDropZone.zone(at: CGPoint(x: 20, y: 10), in: size), .top)
    }

    /// The highlight previews exactly what the drop commits: the occupied half
    /// for an edge, the whole pane for a swap.
    func testDropZoneHighlightMatchesOutcome() {
        let frame = CGRect(x: 10, y: 20, width: 100, height: 50)
        XCTAssertEqual(PaneDropZone.left.highlightRect(in: frame),
                       CGRect(x: 10, y: 20, width: 50, height: 50))
        XCTAssertEqual(PaneDropZone.bottom.highlightRect(in: frame),
                       CGRect(x: 10, y: 45, width: 100, height: 25))
        XCTAssertEqual(PaneDropZone.center.highlightRect(in: frame), frame)
    }

    /// "Flip Layout" turns only the innermost branch: an A│B pair nested under C
    /// rotates from side-by-side to stacked, while C keeps its own axis, ratio,
    /// and slot. Both children and the ratio survive the flip.
    func testFlippingTurnsOnlyTheInnermostBranch() {
        let inner = SplitBranch(direction: .horizontal, ratio: 0.3,
                                first: .leaf(run1), second: .leaf(run2))
        let tree = SplitNode.split(SplitBranch(direction: .vertical, ratio: 0.5,
                                               first: .leaf(agent), second: .split(inner)))
        let flipped = tree.flippingBranch(containing: run1)

        guard case let .split(outer) = flipped,
              case let .split(rotated) = outer.second else {
            return XCTFail("expected the outer branch and its inner split to survive")
        }
        // The outer branch is byte-for-byte the same; only the inner axis turned.
        XCTAssertEqual(outer.direction, .vertical)
        XCTAssertEqual(outer.first, .leaf(agent))
        XCTAssertEqual(rotated.direction, .vertical)   // was .horizontal
        XCTAssertEqual(rotated.ratio, 0.3)             // ratio preserved
        XCTAssertEqual(flipped.leafIDs, [agent, run1, run2])
    }

    /// Flipping a pane that has no enclosing branch, or a leaf that isn't in the
    /// tree, changes nothing.
    func testFlippingMissIsANoOp() {
        let lone = SplitNode.leaf(agent)
        XCTAssertEqual(lone.flippingBranch(containing: agent), lone)

        let tree = SplitNode.split(SplitBranch(direction: .horizontal, ratio: 0.5,
                                               first: .leaf(agent), second: .leaf(run1)))
        XCTAssertEqual(tree.flippingBranch(containing: run3), tree)
    }
}
