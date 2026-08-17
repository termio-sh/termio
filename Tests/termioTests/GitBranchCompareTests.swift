import XCTest
@testable import termio

/// The branch comparison behind the History tab's compare bar: the diff a pull request
/// from this branch would carry. Two things here are easy to get wrong and invisible
/// once wrong — the three-dot range, and `-z` record parsing — so both are pinned.
final class GitBranchCompareTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("termio-git-compare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "test@termio.sh"])
        try git(["config", "user.name", "Test"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    // MARK: Range semantics

    /// The comparison must diff from the *merge base*, not from the base branch's tip.
    /// With a two-dot range, a file that only ever changed on `main` after the branch was
    /// cut shows up in the branch's list — inverted, as a change the branch never made.
    func testCompareIgnoresCommitsThatLandedOnTheBaseAfterBranching() async throws {
        try write("shared.txt", "one\n")
        try git(["add", "."])
        try git(["commit", "-qm", "base"])

        try git(["checkout", "-qb", "feature"])
        try write("feature.txt", "hello\nthere\n")
        try git(["add", "."])
        try git(["commit", "-qm", "feature work"])

        try git(["checkout", "-q", "main"])
        try write("shared.txt", "one\ntwo\n")
        try git(["commit", "-qam", "moved on"])
        try git(["checkout", "-q", "feature"])

        let loaded = await readyCompare(base: "main")
        let compare = try XCTUnwrap(loaded)
        XCTAssertEqual(compare.files.map(\.path), ["feature.txt"])
        XCTAssertEqual(compare.files.first?.additions, 2)
        XCTAssertEqual(compare.files.first?.status, .added)
        XCTAssertEqual(compare.commits.map(\.subject), ["feature work"])
        // The base moved on by exactly the one commit — surfaced, not silently folded in.
        XCTAssertEqual(compare.behind, 1)
    }

    /// A base that was deleted since it was picked reads as "missing", never as an empty
    /// comparison — an empty file list would say "nothing to review" about work that exists.
    func testMissingBaseIsStatedRatherThanShownAsAnEmptyDiff() async throws {
        try write("a.txt", "a\n")
        try git(["add", "."])
        try git(["commit", "-qm", "one"])
        let outcome = await GitService.branchCompare(base: "origin/gone", in: repo.path)
        guard case .problem(.missingBase) = outcome else {
            return XCTFail("expected a missing base, got \(outcome)")
        }
    }

    /// Unrelated histories have no merge base, so the three-dot diff fails while
    /// `base..HEAD` would still list every commit. Reporting that as "0 files, N commits"
    /// is a lie about the branch; the tab has to say what is actually wrong.
    func testUnrelatedHistoriesAreReportedRatherThanDiffedToNothing() async throws {
        try write("a.txt", "a\n")
        try git(["add", "."])
        try git(["commit", "-qm", "one"])
        try git(["checkout", "-q", "--orphan", "detached-history"])
        try write("b.txt", "b\n")
        try git(["add", "."])
        try git(["commit", "-qm", "unrelated"])

        let outcome = await GitService.branchCompare(base: "main", in: repo.path)
        guard case .problem(.noCommonHistory) = outcome else {
            return XCTFail("expected no common history, got \(outcome)")
        }
    }

    /// Git applies a path limit *before* rename detection, so asking for the destination
    /// alone turns a pure rename into the whole file arriving as additions — contradicting
    /// the row's own `R` badge and its zero counts.
    func testRenameOpensAsARenameNotAWholeFileAdd() async throws {
        try write("old.swift", (1...40).map { "line \($0)\n" }.joined())
        try git(["add", "."])
        try git(["commit", "-qm", "base"])
        try git(["checkout", "-qb", "feature"])
        try git(["mv", "old.swift", "new.swift"])
        try git(["commit", "-qm", "rename"])

        let loaded = await readyCompare(base: "main")
        let compare = try XCTUnwrap(loaded)
        let renamed = try XCTUnwrap(compare.files.first)
        XCTAssertEqual(renamed.status, .renamed)
        XCTAssertEqual(renamed.originalPath, "old.swift")

        let rows = await GitService.diffRows(for: renamed, in: repo.path, range: "main...HEAD")
        XCTAssertTrue(rows.allSatisfy { $0.kind == .context || $0.kind == .hunk },
                      "a pure rename has no added or deleted lines")
    }

    func testSuggestedBaseIsTheBranchTheCheckoutWouldMergeInto() async throws {
        try write("a.txt", "a\n")
        try git(["add", "."])
        try git(["commit", "-qm", "one"])
        try git(["checkout", "-qb", "feat/x"])

        let context = await GitService.compareContext(in: repo.path)
        XCTAssertEqual(context.branch, "feat/x")
        XCTAssertEqual(context.suggestedBase, "main")
        XCTAssertEqual(context.localBranches, ["main"], "the checkout's own branch is not a base")
    }

    /// Only the checkout's own branch is excluded from the picker. Its upstream stays:
    /// `origin/main` from a checkout of `main` answers "what haven't I pushed", and
    /// dropping it left a trunk checkout with nothing at all to pick.
    func testOnlyTheCheckoutsOwnBranchIsExcludedFromTheBases() async throws {
        let remote = repo.appendingPathExtension("remote.git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try git(["init", "-q", "--bare", remote.path])
        try write("a.txt", "a\n")
        try git(["add", "."])
        try git(["commit", "-qm", "one"])
        // Deliberately not named `origin`, so a hard-coded remote name would show up here.
        try git(["remote", "add", "fork", remote.path])
        try git(["checkout", "-qb", "feat/x"])
        try git(["push", "-q", "-u", "fork", "main", "feat/x"])
        defer { try? FileManager.default.removeItem(at: remote) }

        let context = await GitService.compareContext(in: repo.path)
        XCTAssertEqual(context.branch, "feat/x")
        XCTAssertFalse(context.localBranches.contains("feat/x"), "own branch offered as a base")
        XCTAssertTrue(context.remoteBranches.contains("fork/main"))
        XCTAssertTrue(context.remoteBranches.contains("fork/feat/x"),
                      "the upstream is a legitimate base — it answers what hasn't been pushed")
    }

    /// A checkout of the trunk opens compared against its own remote. Before the fix both
    /// the local `main` and its upstream were filtered out, leaving the tab telling the
    /// user to pick a branch from a menu that contained none.
    func testTrunkCheckoutComparesAgainstItsRemote() async throws {
        let remote = repo.appendingPathExtension("remote.git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try git(["init", "-q", "--bare", remote.path])
        try write("a.txt", "a\n")
        try git(["add", "."])
        try git(["commit", "-qm", "one"])
        try git(["remote", "add", "origin", remote.path])
        try git(["push", "-q", "-u", "origin", "main"])
        defer { try? FileManager.default.removeItem(at: remote) }

        let context = await GitService.compareContext(in: repo.path)
        XCTAssertEqual(context.branch, "main")
        XCTAssertEqual(context.remoteBranches, ["origin/main"])
        XCTAssertEqual(context.suggestedBase, "origin/main")
    }

    // MARK: Base resolution

    func testBaseResolutionPrefersTheRemoteDefaultThenRemoteTrunks() {
        // The remote's recorded default wins outright — it is what the forge will default
        // the pull request's base to.
        XCTAssertEqual(
            GitService.suggestedCompareBase(
                branch: "feat/x", originHead: "origin/dev",
                remoteBranches: ["origin/dev", "origin/main"], localBranches: ["main"]),
            "origin/dev")
        // Without one, a remote trunk beats the same-named local branch, which in a
        // long-lived clone is usually stale.
        XCTAssertEqual(
            GitService.suggestedCompareBase(
                branch: "feat/x", originHead: nil,
                remoteBranches: ["origin/main"], localBranches: ["main", "feat/x"]),
            "origin/main")
        // A local trunk is the fallback when nothing is on a remote.
        XCTAssertEqual(
            GitService.suggestedCompareBase(
                branch: "feat/x", originHead: nil,
                remoteBranches: [], localBranches: ["master", "feat/x"]),
            "master")
    }

    func testTheTrunkComparesAgainstItsOwnRemote() {
        // On `main`, the useful comparison is against `origin/main` — what hasn't been
        // pushed. Suggesting nothing left the tab on an empty state with no way forward.
        XCTAssertEqual(
            GitService.suggestedCompareBase(
                branch: "main", originHead: "origin/main",
                remoteBranches: ["origin/main"], localBranches: []),
            "origin/main")
        // A local branch that *is* the checkout stays excluded — that comparison is
        // always empty — and a detached HEAD has no branch to compare at all.
        XCTAssertNil(
            GitService.suggestedCompareBase(
                branch: "main", originHead: nil, remoteBranches: [], localBranches: []))
        XCTAssertNil(
            GitService.suggestedCompareBase(
                branch: nil, originHead: nil, remoteBranches: [], localBranches: ["main"]))
    }

    // MARK: `-z` record parsing

    /// `--numstat -z` writes a rename as an empty path field followed by the old and new
    /// paths as their own records, and binary files as `-` counts. Both must survive, and
    /// paths must arrive unquoted so they match the ones the diff overlay addresses.
    func testRangeChangesParsesRenamesBinariesAndAwkwardPaths() {
        let numstat = [
            "3\t1\tSources/a.swift",
            "0\t0\t", "old name.swift", "new name.swift",
            "-\t-\tassets/icon.png",
            "0\t9\tgone.txt",
        ].joined(separator: "\0") + "\0"
        let nameStatus = [
            "M", "Sources/a.swift",
            "R096", "old name.swift", "new name.swift",
            "M", "assets/icon.png",
            "D", "gone.txt",
        ].joined(separator: "\0") + "\0"

        let changes = GitService.rangeChanges(numstat: numstat, nameStatus: nameStatus)
        XCTAssertEqual(changes.map(\.path),
                       ["assets/icon.png", "gone.txt", "new name.swift", "Sources/a.swift"])

        let renamed = changes.first { $0.path == "new name.swift" }
        XCTAssertEqual(renamed?.status, .renamed)
        XCTAssertEqual(renamed?.originalPath, "old name.swift")

        let binary = changes.first { $0.path == "assets/icon.png" }
        XCTAssertEqual(binary?.isBinary, true)
        XCTAssertEqual(binary?.additions, 0)

        let deleted = changes.first { $0.path == "gone.txt" }
        XCTAssertEqual(deleted?.status, .deleted)
        XCTAssertEqual(deleted?.deletions, 9)

        let modified = changes.first { $0.path == "Sources/a.swift" }
        XCTAssertEqual(modified?.status, .modified)
        XCTAssertEqual(modified?.additions, 3)
        XCTAssertEqual(modified?.deletions, 1)
        XCTAssertEqual(modified?.isBinary, false)
    }

    func testRangeChangesIsEmptyForAnEmptyDiff() {
        XCTAssertTrue(GitService.rangeChanges(numstat: "", nameStatus: "").isEmpty)
    }

    // MARK: Helpers

    /// The comparison when it could be made, `nil` when the service reported a problem.
    private func readyCompare(base: String) async -> GitService.BranchCompare? {
        if case .ready(let compare) = await GitService.branchCompare(base: base, in: repo.path) {
            return compare
        }
        return nil
    }

    private func git(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = repo
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " ")) failed")
    }

    private func write(_ relative: String, _ contents: String) throws {
        let url = repo.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
}
