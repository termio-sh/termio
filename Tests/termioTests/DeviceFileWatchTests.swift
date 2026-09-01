import XCTest
import TermioShared
@testable import termio

/// The file tree's watch teardown rule, pinned without a connection.
///
/// `Termiod.ResourceWatch` used to send `unsubscribe_resource` from its own
/// stop path, unconditionally. The control pool gives every request to one
/// machine the same connection, and the daemon tracks resource interest per
/// *connection* (`resource.rs` `subscribers`, keyed by `ClientId`) — so two
/// panes rooted at one checkout were one entry over there, and the first pane
/// to close retired the watch the second was still drawing from. The second
/// tree then went quietly stale: no error, no refresh, nothing to notice.
///
/// The watch now retires its interest through the channel's routing table, the
/// same one the `git:` plane subscribes through, and that table is what counts
/// subscribers. This pins the count; `TermiodFilesIntegrationTests` pins the
/// same claim against a real daemon.
final class DeviceFileWatchTests: XCTestCase {
    private final class Pane {}

    func testOnlyTheLastPaneWatchingACheckoutRetiresItsWatch() {
        var table = Termiod.ResourceRoutingTable<Pane>()
        let first = Pane()
        let second = Pane()
        table.register(first, resource: "fs:/Users/me/code/termio", request: 1)
        table.register(second, resource: "fs:/Users/me/code/termio", request: 2)

        XCTAssertFalse(
            table.unregister(ObjectIdentifier(first)),
            "the second pane is still reading this tree")
        XCTAssertTrue(
            table.unregister(ObjectIdentifier(second)),
            "the last pane away is the one that may retire the device's watch")
    }

    /// Two panes can name one checkout two ways and still be two subscribers to
    /// one watch. The daemon canonicalises the root it watches, which on macOS
    /// turns every `/var/folders` root into `/private/var/folders` — so the
    /// client files under the spelling it asked with and the ack is what merges
    /// them. A count taken before that merge would read two watches where the
    /// device has one, and let the first pane away retire it.
    func testTwoSpellingsOfOneCheckoutShareOneWatch() {
        var table = Termiod.ResourceRoutingTable<Pane>()
        let asked = Pane()
        let canonical = Pane()
        table.register(asked, resource: "fs:/var/folders/x/checkout", request: 1)
        table.register(canonical, resource: "fs:/private/var/folders/x/checkout", request: 2)
        _ = table.acknowledged(request: 1, canonical: "fs:/private/var/folders/x/checkout")
        _ = table.acknowledged(request: 2, canonical: "fs:/private/var/folders/x/checkout")

        XCTAssertEqual(table.listeners(for: "fs:/private/var/folders/x/checkout").count, 2)
        XCTAssertFalse(table.unregister(ObjectIdentifier(asked)))
        XCTAssertTrue(table.unregister(ObjectIdentifier(canonical)))
    }
}
