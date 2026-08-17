import Foundation

/// A way to reach a device — never the device's identity. One machine commonly
/// answers to several routes at once (`vps-lan`, `vps-wan`, a tailnet name), and
/// which of them works depends on the network you happen to be on. Keying state
/// by route is what makes a VPS silently become three machines the day the user
/// moves between home and office.
///
/// Spelled on disk as the endpoint form the protocol doc uses (`unix`,
/// `ssh:<alias>`) so `devices.json` reads like configuration rather than an
/// encoder's idea of an enum.
enum TermiodRoute: Hashable, Codable, CustomStringConvertible {
    /// This Mac's own daemon, over its Unix socket. There is exactly one — the
    /// socket path is derived, not chosen (`Termiod.socketPath()`).
    case local
    /// A `~/.ssh/config` alias, reached with `ssh <alias> termiod stdio`.
    case ssh(String)

    var description: String {
        switch self {
        case .local: return "unix"
        case .ssh(let alias): return "ssh:\(alias)"
        }
    }

    /// The SSH alias, or `nil` for the local route. Lets callers that still think
    /// in aliases (the `~/.ssh/config` picker, `Termiod.Transport`) round-trip
    /// through a route without a switch at every site.
    var sshAlias: String? {
        if case .ssh(let alias) = self { return alias }
        return nil
    }

    init(sshAlias: String?) {
        self = sshAlias.map(TermiodRoute.ssh) ?? .local
    }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        if text == "unix" {
            self = .local
        } else if text.hasPrefix("ssh:") {
            self = .ssh(String(text.dropFirst(4)))
        } else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "unrecognised termiod route \"\(text)\""
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// One machine running one `termiod`. Its identity is the daemon's `host_id` —
/// a stable random 128-bit value minted on the daemon's first run and persisted
/// beside its socket (termiod/src/paths.rs). Everything else about a device,
/// routes included, is discovered by connecting and can change underneath it.
struct TermiodDevice: Codable, Identifiable, Hashable {
    /// The daemon's `host_id`, e.g. `h_3f0a…`.
    let id: String
    /// The daemon's self-description from `hello_ok` — version and platform,
    /// `termiod/0.1.0 macos-aarch64`. Not a hostname and not a display name: it
    /// is what §6's version-skew negotiation reads. A device's human label is a
    /// client concern (the route alias the user typed), because the host
    /// describes state and never decides presentation.
    var daemonVersion: String
    /// Every route this device has been seen on, most recently used first.
    var routes: [TermiodRoute]
    /// When *this run* of the app last completed a handshake with the device.
    /// Deliberately not persisted: a timestamp restored from disk would claim
    /// reachability the app has not verified since launch.
    var lastSeen: Date?

    private enum CodingKeys: String, CodingKey {
        case id, daemonVersion, routes
    }
}

/// The `host_id ↔ routes` map, learned from `hello_ok` and nothing else.
///
/// Devices are **discovered, not configured**: you cannot know which machine a
/// route leads to until you connect, read `host_id`, and record it. The same
/// `host_id` arriving over a second route joins that device's route list instead
/// of creating a twin — which is the entire point, and why `~/.ssh/config`
/// remains the only host database termio has (§H #8, never embed SSH).
///
/// Thread-safe by lock rather than by actor: handshakes complete on the attach
/// link's private queue, on the roster's utility queue, and on the main actor,
/// and none of those callers can afford to await.
final class TermiodDeviceRegistry: @unchecked Sendable {
    static let shared = TermiodDeviceRegistry(
        fileURL: AppChannel.supportDirectory.appendingPathComponent("devices.json"))

    private let fileURL: URL
    private let lock = NSLock()
    private var devicesByID: [String: TermiodDevice] = [:]
    /// Which device a route last resolved to. A route belongs to exactly one
    /// device: a reinstall (new `host_id` behind the same alias) moves it rather
    /// than leaving the alias pointing at two machines.
    private var deviceIDByRoute: [TermiodRoute: String] = [:]

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    /// Records what a completed handshake just revealed. Returns the merged
    /// device so the caller can log or act on the identity it actually reached.
    @discardableResult
    func record(hostID: String, daemonVersion: String, route: TermiodRoute) -> TermiodDevice {
        lock.lock()
        defer { lock.unlock() }

        // A route that used to lead elsewhere is taken away from its old device
        // first, so the two never both claim it.
        if let previous = deviceIDByRoute[route], previous != hostID {
            devicesByID[previous]?.routes.removeAll { $0 == route }
        }
        deviceIDByRoute[route] = hostID

        var device = devicesByID[hostID]
            ?? TermiodDevice(id: hostID, daemonVersion: daemonVersion, routes: [], lastSeen: nil)
        device.daemonVersion = daemonVersion
        // Most recently used first: the route that just worked is the one to try
        // again before probing the others.
        device.routes.removeAll { $0 == route }
        device.routes.insert(route, at: 0)
        device.lastSeen = Date()
        devicesByID[hostID] = device

        save()
        return device
    }

    /// The device a route is known to lead to, from an earlier handshake. `nil`
    /// before the first successful connection — a route with no device behind it
    /// yet is the normal state, not an error.
    func device(for route: TermiodRoute) -> TermiodDevice? {
        lock.lock()
        defer { lock.unlock() }
        return deviceIDByRoute[route].flatMap { devicesByID[$0] }
    }

    func deviceID(for route: TermiodRoute) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return deviceIDByRoute[route]
    }

    func device(id: String) -> TermiodDevice? {
        lock.lock()
        defer { lock.unlock() }
        return devicesByID[id]
    }

    /// Every route the device has answered on, most recently used first.
    func routes(forDevice id: String) -> [TermiodRoute] {
        lock.lock()
        defer { lock.unlock() }
        return devicesByID[id]?.routes ?? []
    }

    /// Known devices, ordered by identity so callers get a stable list.
    var all: [TermiodDevice] {
        lock.lock()
        defer { lock.unlock() }
        return devicesByID.values.sorted { $0.id < $1.id }
    }

    // MARK: - Persistence

    /// Must hold `lock`. Best-effort and atomic: losing the map costs one
    /// re-discovery on the next handshake, so a write failure is logged, never
    /// fatal. `lastSeen` is not written (see `TermiodDevice`).
    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let devices = devicesByID.values.sorted { $0.id < $1.id }
            try encoder.encode(devices).write(to: fileURL, options: .atomic)
        } catch {
            Log.termiod.error("""
            persisting device map failed: \(error.localizedDescription, privacy: .public)
            """)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let devices = try? JSONDecoder().decode([TermiodDevice].self, from: data)
        else { return }
        for device in devices {
            devicesByID[device.id] = device
            for route in device.routes {
                deviceIDByRoute[route] = device.id
            }
        }
    }
}
