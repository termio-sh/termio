import XCTest
@testable import termio

/// The `host_id ↔ routes` map (`TermiodDeviceRegistry`). Its whole reason to
/// exist is that a route is not an identity: the cases that matter are the ones
/// where keying by alias would quietly give the wrong answer — one machine seen
/// down two roads, and one road that starts leading somewhere else.
final class TermiodDeviceRegistryTests: XCTestCase {
    /// The `hello_ok` `host` banner verbatim, as captured from a running daemon.
    private let macDaemon = "termiod/0.1.0 macos-aarch64"
    private let linuxDaemon = "termiod/0.1.0 linux-aarch64"

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("termiod-devices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeRegistry() -> TermiodDeviceRegistry {
        TermiodDeviceRegistry(fileURL: directory.appendingPathComponent("devices.json"))
    }

    /// The load-bearing case: one VPS in `~/.ssh/config` as `vps-lan`, `vps-wan`,
    /// and a tailnet name is one machine with three roads. Keyed by alias it
    /// would be three devices with three session lists, and switching networks
    /// would fork the user's state.
    func testOneHostIDOverSeveralRoutesIsOneDevice() {
        let registry = makeRegistry()
        for alias in ["vps-lan", "vps-wan", "vps-tailnet"] {
            registry.record(hostID: "h_aaaa", daemonVersion: linuxDaemon, route: .ssh(alias))
        }

        XCTAssertEqual(registry.all.count, 1)
        XCTAssertEqual(
            Set(registry.routes(forDevice: "h_aaaa")),
            [.ssh("vps-lan"), .ssh("vps-wan"), .ssh("vps-tailnet")]
        )
        XCTAssertEqual(registry.deviceID(for: .ssh("vps-wan")), "h_aaaa")
    }

    /// The route that just worked is the one to try first next time.
    func testMostRecentlyUsedRouteSortsFirst() {
        let registry = makeRegistry()
        registry.record(hostID: "h_aaaa", daemonVersion: linuxDaemon, route: .ssh("vps-lan"))
        registry.record(hostID: "h_aaaa", daemonVersion: linuxDaemon, route: .ssh("vps-wan"))
        XCTAssertEqual(registry.routes(forDevice: "h_aaaa").first, .ssh("vps-wan"))

        registry.record(hostID: "h_aaaa", daemonVersion: linuxDaemon, route: .ssh("vps-lan"))
        XCTAssertEqual(registry.routes(forDevice: "h_aaaa").first, .ssh("vps-lan"))
        XCTAssertEqual(registry.routes(forDevice: "h_aaaa").count, 2, "no duplicate route")
    }

    /// A rebuilt box behind the same alias is a different device. The alias moves
    /// wholesale — it must never end up claimed by both.
    func testARouteThatChangesDeviceMovesRatherThanForks() {
        let registry = makeRegistry()
        registry.record(hostID: "h_old", daemonVersion: linuxDaemon, route: .ssh("vps"))
        registry.record(hostID: "h_new", daemonVersion: linuxDaemon, route: .ssh("vps"))

        XCTAssertEqual(registry.deviceID(for: .ssh("vps")), "h_new")
        XCTAssertEqual(registry.routes(forDevice: "h_old"), [])
        XCTAssertEqual(registry.routes(forDevice: "h_new"), [.ssh("vps")])
    }

    /// Two machines that happen to share a hostname stay two devices — the
    /// identity is the daemon's `host_id`, never a name.
    func testSameHostnameOnDifferentDevicesStaysTwoDevices() {
        let registry = makeRegistry()
        registry.record(hostID: "h_aaaa", daemonVersion: linuxDaemon, route: .ssh("box-a"))
        registry.record(hostID: "h_bbbb", daemonVersion: linuxDaemon, route: .ssh("box-b"))

        XCTAssertEqual(registry.all.map(\.id), ["h_aaaa", "h_bbbb"])
    }

    /// This Mac is a device like any other, reached over its Unix socket.
    func testLocalIsJustAnotherRoute() {
        let registry = makeRegistry()
        let device = registry.record(hostID: "h_mac", daemonVersion: macDaemon, route: .local)

        XCTAssertEqual(device.routes, [.local])
        XCTAssertEqual(registry.device(for: .local)?.id, "h_mac")
    }

    /// The map survives a relaunch, so state keyed by device can be resolved
    /// before anything has been connected to in this run.
    func testMapSurvivesARelaunch() {
        let first = makeRegistry()
        first.record(hostID: "h_aaaa", daemonVersion: linuxDaemon, route: .ssh("vps-lan"))
        first.record(hostID: "h_aaaa", daemonVersion: linuxDaemon, route: .ssh("vps-wan"))

        let second = makeRegistry()
        XCTAssertEqual(second.deviceID(for: .ssh("vps-lan")), "h_aaaa")
        XCTAssertEqual(Set(second.routes(forDevice: "h_aaaa")),
                       [.ssh("vps-lan"), .ssh("vps-wan")])
    }

    /// Reachability is never restored from disk: a persisted `lastSeen` would
    /// claim the app had reached a device it has not talked to since launch.
    func testReachabilityIsNotRestoredFromDisk() {
        let device = makeRegistry()
            .record(hostID: "h_aaaa", daemonVersion: linuxDaemon, route: .ssh("vps"))
        XCTAssertNotNil(device.lastSeen)

        XCTAssertNil(makeRegistry().device(id: "h_aaaa")?.lastSeen)
    }

    /// A route nothing has answered on yet has no device — the normal state
    /// before a first connection, not an error.
    func testAnUnprobedRouteHasNoDevice() {
        XCTAssertNil(makeRegistry().device(for: .ssh("never-touched")))
    }

    /// The bytes a real daemon sends, captured verbatim from `termiod serve` on
    /// 2026-08-05. Every device identity in the app is read out of this one
    /// frame, so a field rename on either side of the wire must fail here rather
    /// than silently produce an app that can no longer tell machines apart.
    func testDecodesAnActualDaemonHelloOk() throws {
        let wire = Data("""
        {"op":"hello_ok","proto":1,"caps":["snapshot"],\
        "host_id":"h_07414398893b68376f3d81fe5b35a245",\
        "host":"termiod/0.1.0 macos-aarch64","client_id":"c_1"}
        """.utf8)

        guard case .helloOk(let payload) = try Termiod.decodeControl(wire) else {
            return XCTFail("hello_ok did not decode as a handshake reply")
        }
        XCTAssertEqual(payload.hostId, "h_07414398893b68376f3d81fe5b35a245")
        XCTAssertEqual(payload.host, macDaemon)
        XCTAssertEqual(payload.clientId, "c_1")
        XCTAssertEqual(payload.caps, ["snapshot"])
    }

    /// A daemon that predates a field must still shake hands — negotiate, never
    /// lockstep (§6). Only the identity fields are load-bearing.
    func testHelloOkWithoutCapsStillDecodes() throws {
        let wire = Data("""
        {"op":"hello_ok","proto":1,"host_id":"h_aaaa","host":"termiod/0.0.9 linux-aarch64",\
        "client_id":"c_9"}
        """.utf8)

        guard case .helloOk(let payload) = try Termiod.decodeControl(wire) else {
            return XCTFail("hello_ok did not decode as a handshake reply")
        }
        XCTAssertEqual(payload.hostId, "h_aaaa")
        XCTAssertEqual(payload.caps, [])
    }

    /// `devices.json` reads like configuration: routes spelled the way the
    /// protocol spells endpoints, not the way an encoder spells an enum.
    func testRoutesArePersistedAsEndpointStrings() throws {
        let registry = makeRegistry()
        registry.record(hostID: "h_aaaa", daemonVersion: linuxDaemon, route: .ssh("vps-lan"))
        registry.record(hostID: "h_mac", daemonVersion: macDaemon, route: .local)

        let text = try String(contentsOf: directory.appendingPathComponent("devices.json"),
                              encoding: .utf8)
        XCTAssertTrue(text.contains("\"ssh:vps-lan\""), text)
        XCTAssertTrue(text.contains("\"unix\""), text)
    }
}
