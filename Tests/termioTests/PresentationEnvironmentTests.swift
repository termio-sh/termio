import XCTest
@testable import termio

/// The environment a remote session is spawned with. The rule under test is the
/// presentation boundary: how output should *look* is the client's to declare on
/// any machine, while everything naming this Mac stays behind. Both halves have
/// a real failure mode — leaking `PATH` breaks the remote shell, and withholding
/// `COLORTERM` makes a remote agent quantise the user's theme to 256 colours
/// before a single byte reaches the client.
@MainActor
final class PresentationEnvironmentTests: XCTestCase {
    private func environment(from pairs: [[String]]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: pairs.compactMap { pair in
            pair.count == 2 ? (pair[0], pair[1]) : nil
        })
    }

    func testCarriesTheKeysThatDecideHowOutputLooks() {
        let sent = environment(from: TermioStore.presentationEnvironment(from: [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "termio",
            "FORCE_HYPERLINK": "1",
        ]))

        XCTAssertEqual(sent["TERM"], "xterm-256color")
        XCTAssertEqual(sent["COLORTERM"], "truecolor")
        XCTAssertEqual(sent["TERM_PROGRAM"], "termio")
        XCTAssertEqual(sent["FORCE_HYPERLINK"], "1")
    }

    func testLeavesEveryThingThatDescribesThisMachineBehind() {
        let sent = environment(from: TermioStore.presentationEnvironment(from: [
            "COLORTERM": "truecolor",
            "PATH": "/opt/homebrew/bin:/usr/bin",
            "HOME": "/Users/someone",
            "SHELL": "/bin/zsh",
            "USER": "someone",
            "TMPDIR": "/var/folders/6q/T/",
        ]))

        XCTAssertEqual(sent, ["COLORTERM": "truecolor"])
    }

    /// Identity, not presentation: a hook on the far machine that echoed this
    /// back would be reporting to a control socket that only exists on the Mac.
    func testDoesNotCarrySessionIdentity() {
        let sent = environment(from: TermioStore.presentationEnvironment(from: [
            "TERM": "xterm-256color",
            "TERMIO_SESSION": UUID().uuidString,
        ]))

        XCTAssertNil(sent["TERMIO_SESSION"])
    }

    /// An absent key is omitted rather than sent empty — `COLORTERM=""` reads as
    /// "no truecolor" to the libraries that check it, which is worse than the
    /// remote never seeing the variable at all.
    func testOmitsKeysThatAreNotSetRatherThanSendingThemEmpty() {
        let pairs = TermioStore.presentationEnvironment(from: ["TERM": "xterm-256color"])

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first, ["TERM", "xterm-256color"])
    }
}
