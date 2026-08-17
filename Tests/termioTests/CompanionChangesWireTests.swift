import TermioShared
import XCTest
@testable import termio

/// The changes/diff messages the phone's Changes pane rides on. The wire encoder is
/// hand-written JSON on both ends, so a round trip is the only thing standing between a
/// typo'd key and a pane that silently shows nothing.
final class CompanionChangesWireTests: XCTestCase {
    func testListChangesRoundTrips() {
        let message = CompanionControl.listChanges(projectID: "abc123")
        XCTAssertEqual(CompanionControl.decode(message.encoded()), message)
    }

    func testChangesRoundTripsEveryField() {
        let message = CompanionControl.changes(files: [
            WireChange(path: "Sources/termio/App.swift", status: "M", additions: 40, deletions: 12),
            WireChange(
                path: "assets/icon.png", status: "A", additions: 0, deletions: 0,
                isBinary: true, isStaged: true
            ),
        ])
        XCTAssertEqual(CompanionControl.decode(message.encoded()), message)
    }

    /// Paths carry quotes, backslashes and non-ASCII in the wild; the file messages go
    /// through JSONSerialization precisely so escaping is free.
    func testAwkwardPathsSurvive() {
        let path = #"src/a "quoted"/b\c/文件.swift"#
        let message = CompanionControl.changes(files: [
            WireChange(path: path, status: "R", additions: 1, deletions: 1),
        ])
        guard case .changes(let files) = CompanionControl.decode(message.encoded()) else {
            return XCTFail("changes should decode")
        }
        XCTAssertEqual(files.first?.path, path)
    }

    func testReadDiffRoundTripsItsStatus() {
        let message = CompanionControl.readDiff(
            projectID: "abc123", path: "Sources/termio/App.swift", status: "U"
        )
        XCTAssertEqual(CompanionControl.decode(message.encoded()), message)
    }

    func testDiffRoundTripsItsText() {
        let message = CompanionControl.diff(WireDiff(
            path: "App.swift",
            text: "@@ -1,2 +1,2 @@\n-let a = 1\n+let a = 2\n"
        ))
        XCTAssertEqual(CompanionControl.decode(message.encoded()), message)
    }

    /// An older peer sends no binary flag; it must read as "not binary" rather than
    /// failing the decode and blanking the reader. Likewise a `readDiff` with no status.
    func testToleratesMissingOptionalFields() {
        let json = #"{"t":"diff","path":"App.swift","text":"@@ -1 +1 @@"}"#
        guard case .diff(let diff) = CompanionControl.decode(json) else {
            return XCTFail("a diff without flags should still decode")
        }
        XCTAssertFalse(diff.binary)
        guard case .readDiff(_, _, let status) =
            CompanionControl.decode(#"{"t":"readDiff","project":"a","path":"b"}"#) else {
            return XCTFail("a readDiff without a status should still decode")
        }
        XCTAssertEqual(status, "M")
    }
}

/// The Mac reassembles parsed rows into unified-diff text for the wire, and the phone
/// re-parses it. The markers have to go back on exactly, or every line lands in the
/// wrong column on the phone.
final class DiffUnifiedTextTests: XCTestCase {
    func testMarkersAreRestored() {
        let rows = [
            DiffRow(id: 0, kind: .hunk, text: "@@ -1,3 +1,3 @@ func thing()", oldLine: 1, newLine: 1),
            DiffRow(id: 1, kind: .context, text: "let a = 1", oldLine: 1, newLine: 1),
            DiffRow(id: 2, kind: .deletion, text: "let b = 2", oldLine: 2, newLine: nil),
            DiffRow(id: 3, kind: .addition, text: "let b = 3", oldLine: nil, newLine: 2),
        ]
        XCTAssertEqual(
            CompanionServer.unifiedText(rows),
            "@@ -1,3 +1,3 @@ func thing()\n let a = 1\n-let b = 2\n+let b = 3"
        )
    }

    /// The round trip the two ends actually perform: git text → rows → wire text →
    /// `DiffParser`. Kinds, line numbers and content must all come out the far side
    /// unchanged.
    func testRoundTripThroughTheSharedParser() {
        let rows = [
            DiffRow(id: 0, kind: .hunk, text: "@@ -10,4 +10,5 @@", oldLine: 10, newLine: 10),
            DiffRow(id: 1, kind: .context, text: "", oldLine: 10, newLine: 10),
            DiffRow(id: 2, kind: .deletion, text: "    old()", oldLine: 11, newLine: nil),
            DiffRow(id: 3, kind: .addition, text: "    new()", oldLine: nil, newLine: 11),
            DiffRow(id: 4, kind: .addition, text: "    extra()", oldLine: nil, newLine: 12),
            DiffRow(id: 5, kind: .context, text: "}", oldLine: 12, newLine: 13),
        ]
        let parsed = DiffParser.lines(from: CompanionServer.unifiedText(rows))
        XCTAssertEqual(parsed.map(\.text), rows.map(\.text))
        XCTAssertEqual(parsed.map(\.oldLine), rows.map(\.oldLine))
        XCTAssertEqual(parsed.map(\.newLine), rows.map(\.newLine))
        XCTAssertEqual(parsed.map(\.kind), [.hunk, .context, .deletion, .addition, .addition, .context])
    }
}
