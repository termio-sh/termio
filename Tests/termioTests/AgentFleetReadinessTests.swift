import XCTest
@testable import termio

/// The line an Agents roster row leads with, once the roster answers for every
/// machine instead of one behind a picker (RFC §D10).
///
/// Two rules carry the whole design and are the reason this is worth a test:
/// a roster of **one** machine must read exactly as it did before there was ever
/// a second one — otherwise "machines are rows" taxes the single-machine user it
/// promised to leave alone — and "we could not ask" must not print on every agent
/// row, because that is a fact about a machine, not about an agent.
final class AgentFleetReadinessTests: XCTestCase {
    func testSaysNothingWhenEveryMachineHasIt() {
        XCTAssertNil(AgentFleetReadiness(asked: 3).summary)
    }

    // MARK: A roster of one reads exactly as it always did

    func testOneMachineDoesNotNameTheMachine() {
        let fleet = AgentFleetReadiness(missing: ["This Mac"], asked: 1)
        XCTAssertEqual(fleet.summary, "Not installed")
    }

    // MARK: Several machines — name one, count the rest

    func testNamesTheSingleMachineThatIsMissingIt() {
        let fleet = AgentFleetReadiness(missing: ["devbox"], asked: 3)
        XCTAssertEqual(fleet.summary, "Not installed on devbox")
    }

    func testCountsBeyondOneRatherThanListing() {
        let fleet = AgentFleetReadiness(missing: ["devbox", "vps"], asked: 3)
        XCTAssertEqual(fleet.summary, "Missing on 2 machines")
    }

    /// Missing outranks unknown: a machine that answered "it is not here" is
    /// actionable, and one that did not answer is not.
    func testMissingWinsOverUnknown() {
        let fleet = AgentFleetReadiness(missing: ["devbox"], unknown: ["vps"], asked: 3)
        XCTAssertEqual(fleet.summary, "Not installed on devbox")
    }

    // MARK: An unreached machine does not shout on every agent row

    func testStaysSilentWhenOnlySomeMachinesCouldNotBeAsked() {
        let fleet = AgentFleetReadiness(unknown: ["vps"], asked: 2)
        XCTAssertNil(
            fleet.summary,
            "one sleeping box must not print its status on every agent row")
    }

    /// The exception: nothing was reached at all, so silence would read as
    /// "all fine" when we in fact know nothing.
    func testSpeaksWhenNothingCouldBeAsked() {
        XCTAssertEqual(
            AgentFleetReadiness(unknown: ["vps"], asked: 1).summary,
            "Can’t check on vps")
        XCTAssertEqual(
            AgentFleetReadiness(unknown: ["vps", "devbox"], asked: 2).summary,
            "Can’t check on 2 machines")
    }

    // MARK: The badge

    /// Only a machine that answered earns `(!)`. A warning glyph for "we could
    /// not ask" is the false alarm §D4 exists to prevent.
    func testOnlyAnAnsweredMachineEarnsTheBadge() {
        XCTAssertTrue(AgentFleetReadiness(missing: ["devbox"], asked: 2).hasMissing)
        XCTAssertFalse(AgentFleetReadiness(unknown: ["vps"], asked: 2).hasMissing)
        XCTAssertFalse(AgentFleetReadiness(asked: 2).hasMissing)
    }
}
