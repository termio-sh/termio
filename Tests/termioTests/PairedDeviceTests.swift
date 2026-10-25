import XCTest
import TermioShared
@testable import termio

/// The link another Mac pastes, and the host key a paired Mac is filed under.
final class PairedDeviceTests: XCTestCase {
    private let link = "termio://device?url=http://100.74.228.124:8795&token=s3cret&host_id=h_abc&proto=1&name=Studio"

    func testALinkFromThePairingSheetParses() throws {
        let device = try XCTUnwrap(PairedDevice(link: link))
        XCTAssertEqual(device.hostID, "h_abc")
        XCTAssertEqual(device.token, "s3cret")
        XCTAssertEqual(device.name, "Studio")
        XCTAssertEqual(device.websocketURL?.absoluteString, "ws://100.74.228.124:8795/ws")
        XCTAssertEqual(device.origin, "http://100.74.228.124:8795")
    }

    func testALinkWithoutANameIsNamedByItsHost() throws {
        let device = try XCTUnwrap(PairedDevice(
            link: "termio://device?url=https://mini.tail1.ts.net/termio&token=t&host_id=h"))
        XCTAssertEqual(device.name, "mini.tail1.ts.net")
        XCTAssertEqual(device.websocketURL?.absoluteString, "wss://mini.tail1.ts.net/termio/ws")
        XCTAssertEqual(device.origin, "https://mini.tail1.ts.net")
    }

    func testAnIPv6LinkKeepsItsBracketsInTheOrigin() throws {
        let device = try XCTUnwrap(PairedDevice(
            link: "termio://device?url=http://[fd7a:115c:a1e0::7]:8795&token=t&host_id=h"))
        XCTAssertEqual(device.origin, "http://[fd7a:115c:a1e0::7]:8795")
        XCTAssertEqual(device.websocketURL?.absoluteString, "ws://[fd7a:115c:a1e0::7]:8795/ws")
    }

    func testAnInternationalHostKeepsItsPunycodeInTheOrigin() throws {
        let device = try XCTUnwrap(PairedDevice(
            link: "termio://device?url=https://xn--bcher-kva.example&token=t&host_id=h"))
        XCTAssertEqual(device.origin, "https://xn--bcher-kva.example")
    }

    func testALinkMissingWhatTheDialNeedsIsRefused() {
        XCTAssertNil(PairedDevice(link: "termio://device?url=http://h:1&host_id=h"))
        XCTAssertNil(PairedDevice(link: "termio://device?token=t&host_id=h"))
        XCTAssertNil(PairedDevice(link: "termio://device?url=ftp://h:1&token=t&host_id=h"))
        XCTAssertNil(PairedDevice(link: "https://example.com/?url=http://h:1&token=t&host_id=h"))
    }

    func testAPairedMacIsNeverFiledAsThisMac() {
        // The app's state keys machines by one string, nil for this Mac. A paired
        // Mac must come back as itself, not as the local route.
        let route = TermiodRoute.paired("h_abc")
        XCTAssertEqual(route.hostKey, "paired:h_abc")
        XCTAssertEqual(TermiodRoute(hostKey: route.hostKey), route)
        XCTAssertNil(route.sshAlias, "nothing may run ssh against a paired Mac")
        XCTAssertEqual(TermiodRoute(hostKey: "vps"), .ssh("vps"))
        XCTAssertEqual(TermiodRoute(hostKey: nil), .local)
    }

    func testAPairedRouteRoundTripsThroughItsSpelling() throws {
        let data = try JSONEncoder().encode([TermiodRoute.paired("h_abc")])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["paired:h_abc"]"#)
        XCTAssertEqual(try JSONDecoder().decode([TermiodRoute].self, from: data), [.paired("h_abc")])
    }
}

/// Against a real `termiod` WebSocket listener, the one a Linux box serves:
/// handshake, then a request answered over the bridge. Skipped unless
/// `TERMIO_TEST_PAIR_LINK` holds a link from `termiod pair` on a running daemon,
/// because a unit run must not start one.
final class PairedDeviceLiveTests: XCTestCase {
    func testABoxsOwnListenerAnswersThroughTheBridge() throws {
        guard let raw = ProcessInfo.processInfo.environment["TERMIO_TEST_PAIR_LINK"] else {
            throw XCTSkip("set TERMIO_TEST_PAIR_LINK to a `termiod pair` link to run")
        }
        let paired = try XCTUnwrap(PairedDevice(link: raw))

        let device = try Termiod.probePairedDevice(paired)
        XCTAssertEqual(device.id, paired.hostID)

        let transport = try Termiod.Transport.paired(paired, requiresPairing: false)
        defer { transport.close() }
        _ = try Termiod.performHello(transport, role: "control")
        try Termiod.writeFrame(transport.writeDescriptor, kind: .control, payload: Termiod.listPayload())
        var answered = false
        while !answered {
            let frame = try Termiod.readFrame(transport.readDescriptor)
            guard frame.kind == .control else { continue }
            if case .sessions = try Termiod.decodeControl(frame.payload) { answered = true }
        }
        XCTAssertTrue(answered)
    }

    func testABoxRefusesAStaleToken() throws {
        guard let raw = ProcessInfo.processInfo.environment["TERMIO_TEST_PAIR_LINK"] else {
            throw XCTSkip("set TERMIO_TEST_PAIR_LINK to a `termiod pair` link to run")
        }
        let real = try XCTUnwrap(PairedDevice(link: raw))
        let stale = PairedDevice(hostID: real.hostID, name: real.name, url: real.url, token: "revoked")
        XCTAssertThrowsError(try Termiod.probePairedDevice(stale))
    }
}
