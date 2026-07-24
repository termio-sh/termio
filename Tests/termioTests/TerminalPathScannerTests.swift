import XCTest
@testable import termio

/// `TerminalPathScanner` is the stability-critical half of cmd-click-to-open: it decides
/// which bare token on a terminal row is a real file. The guard against false positives is
/// filesystem validation, so these tests run against real files in a temp directory — the
/// same thing the scanner checks at runtime.
final class TerminalPathScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("path-scanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func touch(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: url)
        return url
    }

    private func resolve(_ row: String, near column: Int = 0) -> TerminalPathScanner.Match? {
        TerminalPathScanner.resolve(in: row, nearColumn: column, baseDirectories: [root.path])
    }

    // MARK: - The happy paths agents actually print

    func testBareRelativePathResolvesAgainstWorkingDirectory() throws {
        let file = try touch("BranchModel.swift")
        let match = resolve("edited BranchModel.swift ok", near: 7)
        XCTAssertEqual(match?.url, file.standardizedFileURL)
        XCTAssertNil(match?.line)
    }

    func testNestedRelativePath() throws {
        let file = try touch("Sources/App/App.swift")
        XCTAssertEqual(resolve("Sources/App/App.swift")?.url, file.standardizedFileURL)
    }

    func testLineSuffixIsPeeledAndReported() throws {
        try touch("src/module.ts")
        let match = resolve("src/module.ts:42")
        XCTAssertEqual(match?.url.lastPathComponent, "module.ts")
        XCTAssertEqual(match?.line, 42)
    }

    func testLineAndColumnSuffixKeepsLineOnly() throws {
        try touch("src/module.ts")
        let match = resolve("src/module.ts:42:15")
        XCTAssertEqual(match?.line, 42)
    }

    func testAbsolutePath() throws {
        let file = try touch("abs.txt")
        let match = TerminalPathScanner.resolve(
            in: "see \(file.path):3", nearColumn: 4, baseDirectories: []
        )
        XCTAssertEqual(match?.url, file.standardizedFileURL)
        XCTAssertEqual(match?.line, 3)
    }

    // MARK: - Real-world noise around the token

    func testSurroundingPunctuationIsStripped() throws {
        try touch("file.swift")
        XCTAssertNotNil(resolve("here (file.swift:10)."))
        XCTAssertEqual(resolve("here (file.swift:10).")?.line, 10)
        try touch("trailing.swift")
        XCTAssertNotNil(resolve("open trailing.swift, then"))
    }

    func testGitDiffPrefixIsTriedWithoutPrefix() throws {
        let file = try touch("lib/core.rs")
        // Diff output prints `b/lib/core.rs`; the real file has no `b/`.
        XCTAssertEqual(resolve("b/lib/core.rs:8")?.url, file.standardizedFileURL)
    }

    func testResolvesAgainstProjectRootWhenCwdIsWrong() throws {
        // The bug from the field: terminal reported cwd `~`, but the file lives in the
        // project. Passing both bases (stale cwd first, project root second) must still
        // open it — mirrors VS Code/Zed validating against the workspace, not just cwd.
        let file = try touch("package.json")
        let match = TerminalPathScanner.resolve(
            in: "  package.json", nearColumn: 3,
            baseDirectories: ["/Users/nobody", root.path]
        )
        XCTAssertEqual(match?.url, file.standardizedFileURL)
    }

    // MARK: - The false-positive guard

    func testNonexistentPathReturnsNil() {
        XCTAssertNil(resolve("nope/missing.swift:3"))
    }

    func testPlainWordsReturnNil() {
        XCTAssertNil(resolve("the quick brown fox"))
    }

    func testDirectoryIsNotAMatch() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true
        )
        XCTAssertNil(resolve("Sources"))
    }

    // MARK: - Column disambiguation

    func testNearestColumnWinsWhenTwoFilesOnARow() throws {
        let left = try touch("left.swift")
        let right = try touch("right.swift")
        let row = "left.swift and right.swift"
        // "right.swift" starts at column 16.
        XCTAssertEqual(resolve(row, near: 18)?.url, right.standardizedFileURL)
        XCTAssertEqual(resolve(row, near: 2)?.url, left.standardizedFileURL)
    }
}
