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
}
