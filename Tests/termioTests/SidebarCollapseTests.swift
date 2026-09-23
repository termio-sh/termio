import XCTest
@testable import termio

final class SidebarCollapseTests: XCTestCase {
    func testPinnedWorktreeAndProjectCopyHaveIndependentDisclosure() {
        let project = UUID()
        let worktree = UUID()
        var state = SidebarCollapseState()

        state.setCollapsed(true, projectIDs: [], worktreeIDs: [worktree], in: .pinned)
        XCTAssertEqual(state.worktrees[.pinned], [worktree])
        XCTAssertTrue(state.worktrees[.projects, default: []].isEmpty)
        XCTAssertTrue(state.projects.isEmpty)

        state.setCollapsed(true, projectIDs: [project], worktreeIDs: [worktree], in: .projects)
        state.setCollapsed(false, projectIDs: [], worktreeIDs: [worktree], in: .pinned)
        XCTAssertTrue(state.worktrees[.pinned, default: []].isEmpty)
        XCTAssertEqual(state.worktrees[.projects], [worktree])
        XCTAssertEqual(state.projects, [project])

        state.setCollapsed(true, projectIDs: [], worktreeIDs: [worktree], in: .pinned)
        state.setCollapsed(false, projectIDs: [project], worktreeIDs: [worktree], in: .projects)
        XCTAssertEqual(state.worktrees[.pinned], [worktree])
        XCTAssertTrue(state.worktrees[.projects, default: []].isEmpty)
        XCTAssertTrue(state.projects.isEmpty)
    }

    func testBulkActionsPreserveProjectsOutsideTheCurrentScope() {
        let project = UUID()
        let otherProject = UUID()
        let worktree = UUID()
        let otherWorktree = UUID()
        var state = SidebarCollapseState()
        state.setCollapsed(true, projectIDs: [otherProject], worktreeIDs: [otherWorktree], in: .projects)

        state.setCollapsed(true, projectIDs: [project], worktreeIDs: [worktree], in: .projects)
        XCTAssertEqual(state.projects, [project, otherProject])
        XCTAssertEqual(state.worktrees[.projects], [worktree, otherWorktree])

        state.setCollapsed(false, projectIDs: [project], worktreeIDs: [worktree], in: .projects)
        XCTAssertEqual(state.projects, [otherProject])
        XCTAssertEqual(state.worktrees[.projects], [otherWorktree])

        state.setCollapsed(false, projectIDs: [], worktreeIDs: [], in: .projects)
        XCTAssertEqual(state.projects, [otherProject])
        XCTAssertEqual(state.worktrees[.projects], [otherWorktree])
    }
}
