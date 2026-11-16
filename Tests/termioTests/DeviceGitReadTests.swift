import XCTest
import TermioShared
@testable import termio

/// The read tier's wire-to-pane mappings, pinned without a connection: a
/// device's commits, commit files, refs, and comparison must land in the same
/// models the local pane renders, byte-shaped exactly as `termiod/src/git.rs`
/// serializes them.
final class DeviceGitReadTests: XCTestCase {

    private func decode<Wire: Decodable>(_ type: Wire.Type, _ json: String) throws -> Wire {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Wire.self, from: Data(json.utf8))
    }

    // MARK: - Commits

    func testAWireCommitLandsInThePanesRow() throws {
        let result = try decode(Termiod.WireGitLogResult.self, """
        {"commits": [{"sha": "aaaa1111", "short_sha": "aaaa111", "subject": "fix it",
                      "author": "Dev", "author_email": "dev@example.com",
                      "relative_date": "vor 3 Stunden", "timestamp": 1700000000,
                      "tags": ["v1.0"], "unpushed": true}],
         "truncated": true}
        """)
        let commits = Termiod.commits(from: result.commits)
        XCTAssertEqual(commits.count, 1)
        let commit = try XCTUnwrap(commits.first)
        XCTAssertEqual(commit.sha, "aaaa1111")
        XCTAssertEqual(commit.shortSHA, "aaaa111")
        XCTAssertEqual(commit.subject, "fix it")
        XCTAssertEqual(commit.tags, ["v1.0"])
        XCTAssertTrue(commit.isUnpushed)
        XCTAssertTrue(result.truncated)
        // The instant is formatted here, in this Mac's language — never the
        // box's own rendering when a timestamp is there to format.
        XCTAssertFalse(commit.relativeDate.isEmpty)
        XCTAssertNotEqual(commit.relativeDate, "vor 3 Stunden")
    }

    func testAHostTooOldForTimestampsFallsBackToItsOwnWords() throws {
        let result = try decode(Termiod.WireGitLogResult.self, """
        {"commits": [{"sha": "bbbb2222", "short_sha": "bbbb222", "subject": "old",
                      "author": "Dev", "author_email": "dev@example.com",
                      "relative_date": "3 hours ago"}]}
        """)
        XCTAssertEqual(
            Termiod.commits(from: result.commits).first?.relativeDate, "3 hours ago")
    }

    // MARK: - Commit files

    func testACommitFileKeepsItsStatusCountsAndRename() throws {
        let result = try decode(Termiod.WireGitShowResult.self, """
        {"files": [{"path": "new.swift", "original_path": "old.swift",
                    "status": "renamed", "additions": 3, "deletions": 1},
                   {"path": "kind.swift", "status": "type_changed"},
                   {"path": "weird.swift", "status": "from_the_future"}],
         "diff": "diff --git", "truncated": false}
        """)
        let changes = result.files.compactMap(\.change)
        // The unknown status dropped its row rather than drawing a guess —
        // the same additive-evolution rule the status batches follow.
        XCTAssertEqual(changes.map(\.path), ["new.swift", "kind.swift"])
        let renamed = try XCTUnwrap(changes.first)
        XCTAssertEqual(renamed.status, .renamed)
        XCTAssertEqual(renamed.originalPath, "old.swift")
        XCTAssertEqual(renamed.additions, 3)
        XCTAssertEqual(renamed.deletions, 1)
        XCTAssertEqual(changes.last?.status, .modified)
    }

    // MARK: - Branches → compare context

    func testTheRefListComposesThePickerLikeTheLocalPane() throws {
        let result = try decode(Termiod.WireGitBranchesResult.self, """
        {"branches": [{"name": "feat/x"}, {"name": "main"},
                      {"name": "origin/main", "remote": true},
                      {"name": "origin/feat/x", "remote": true}],
         "current": "feat/x", "default_branch": "origin/main"}
        """)
        let context = Termiod.compareContext(from: result)
        XCTAssertEqual(context.branch, "feat/x")
        // The checkout's own branch is the one ref that can't be a base.
        XCTAssertEqual(context.localBranches, ["main"])
        XCTAssertEqual(context.remoteBranches, ["origin/main", "origin/feat/x"])
        XCTAssertEqual(context.suggestedBase, "origin/main")
    }

    // MARK: - Compare

    func testACompareProblemArrivesInThePanesVocabulary() throws {
        func problem(_ json: String) throws -> GitService.CompareProblem? {
            try decode(Termiod.WireGitCompareResult.self, json).compareProblem
        }
        guard case .missingBase = try problem("{\"problem\": \"missing_base\"}") else {
            return XCTFail("missing_base must map to missingBase")
        }
        guard case .noCommonHistory = try problem("{\"problem\": \"no_common_history\"}") else {
            return XCTFail("no_common_history must map to noCommonHistory")
        }
        // A problem this build has never heard of still *is* one: it must not
        // fold into a clean empty comparison.
        guard case .unreadable = try problem("{\"problem\": \"paradox\"}") else {
            return XCTFail("an unknown problem must stay a problem")
        }
        XCTAssertNil(try problem("{\"files\": [], \"behind\": 2}"))
    }

    func testACompareResultCarriesFilesCommitsAndBehind() throws {
        let result = try decode(Termiod.WireGitCompareResult.self, """
        {"files": [{"path": "b.txt", "status": "added", "additions": 1}],
         "commits": [{"sha": "cccc3333", "short_sha": "cccc333",
                      "subject": "branch commit", "author": "Dev",
                      "author_email": "dev@example.com",
                      "relative_date": "now", "timestamp": 1700000000}],
         "behind": 4, "diff": ""}
        """)
        XCTAssertEqual(result.files.compactMap(\.change).map(\.path), ["b.txt"])
        // One reply carries the whole comparison, so files and commits can
        // never describe two different heads.
        XCTAssertEqual(result.commits.map(\.sha), ["cccc3333"])
        XCTAssertEqual(result.behind, 4)
        XCTAssertNil(result.compareProblem)
    }

    // MARK: - Range → base

    func testTheCompareRangeNamesItsBase() {
        XCTAssertEqual(DiffSource.compareBase(of: "origin/main...HEAD"), "origin/main")
        XCTAssertEqual(DiffSource.compareBase(of: "feat/x...HEAD"), "feat/x")
        // Anything not shaped like the pane's own ranges answers nothing —
        // guessing a base would diff the wrong thing on someone's box.
        XCTAssertNil(DiffSource.compareBase(of: "...HEAD"))
        XCTAssertNil(DiffSource.compareBase(of: "a..b"))
    }
}

/// Both sides of a file, read back out of a diff that carries the whole file as context. The
/// diff page expands hidden lines from these, so a line dropped or a final newline invented
/// here would show a file that does not exist.
final class DiffFullTextTests: XCTestCase {
    private func sides(_ patch: String) -> (old: String, new: String)? {
        guard case .sides(let old, let new) = DiffFullText(fullContextPatch: patch) else { return nil }
        return (old, new)
    }

    func testOneHunkYieldsBothFiles() {
        let patch = """
        diff --git a/a.txt b/a.txt
        index 1111111..2222222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,3 @@
         first
        -old
        +new
         last

        """
        let result = sides(patch)
        XCTAssertEqual(result?.old, "first\nold\nlast\n")
        XCTAssertEqual(result?.new, "first\nnew\nlast\n")
    }

    /// The header's `---` and `+++` lines start with the same characters as a change.
    func testHeaderLinesAreNotContent() {
        let result = sides("--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-a\n+b\n")
        XCTAssertEqual(result?.old, "a\n")
        XCTAssertEqual(result?.new, "b\n")
    }

    func testMissingFinalNewlineIsKeptPerSide() {
        let patch = "@@ -1,2 +1,2 @@\n keep\n-old\n\\ No newline at end of file\n+new\n"
        let result = sides(patch)
        XCTAssertEqual(result?.old, "keep\nold")
        XCTAssertEqual(result?.new, "keep\nnew\n")
    }

    func testMissingFinalNewlineOnAnUnchangedLineCoversBothSides() {
        let result = sides("@@ -1,2 +1,2 @@\n-old\n+new\n last\n\\ No newline at end of file\n")
        XCTAssertEqual(result?.old, "old\nlast")
        XCTAssertEqual(result?.new, "new\nlast")
    }

    /// To a Swift string a CRLF is one character, so a split on "\\n" would miss every line end.
    func testWindowsLineEndingsStayOnTheirLines() {
        let result = sides("@@ -1,2 +1,2 @@\n keep\r\n-old\r\n+new\r\n")
        XCTAssertEqual(result?.old, "keep\r\nold\r\n")
        XCTAssertEqual(result?.new, "keep\r\nnew\r\n")
    }

    func testAddedFileHasAnEmptyOldSide() {
        let result = sides("@@ -0,0 +1,2 @@\n+one\n+two\n")
        XCTAssertEqual(result?.old, "")
        XCTAssertEqual(result?.new, "one\ntwo\n")
    }

    /// Two hunks mean lines between them are missing, so neither file can be rebuilt.
    func testSeveralHunksYieldNothing() {
        XCTAssertNil(DiffFullText(fullContextPatch: "@@ -1 +1 @@\n-a\n+b\n@@ -9 +9 @@\n-c\n+d\n"))
        XCTAssertNil(DiffFullText(fullContextPatch: "diff --git a/a b/a\n"))
    }
}
