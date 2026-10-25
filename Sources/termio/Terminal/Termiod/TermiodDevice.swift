import Foundation

/// A way to reach a device — never the device's identity. One machine commonly
/// answers to several routes at once (`vps-lan`, `vps-wan`, a tailnet name), and
/// which of them works depends on the network you happen to be on. Keying state
/// by route is what makes a VPS silently become three machines the day the user
/// moves between home and office.
///
/// Spelled on disk as the endpoint form the protocol doc uses (`unix`,
/// `ssh:<alias>`, `paired:<host_id>`) so `devices.json` reads like configuration rather than an
/// encoder's idea of an enum.
enum TermiodRoute: Hashable, Codable, CustomStringConvertible {
    /// This Mac's own daemon, over its Unix socket. There is exactly one — the
    /// socket path is derived, not chosen (`Termiod.socketPath()`).
    case local
    /// A `~/.ssh/config` alias, reached with `ssh <alias> termiod stdio`.
    case ssh(String)
    /// Another Mac paired from its Pairing section, by its daemon's `host_id`,
    /// reached over the WebSocket that Mac's app splices onto its daemon. The
    /// address and token live in the keychain (`PairedDeviceStore`), not here:
    /// this value is written into the session tree on disk.
    case paired(String)

    var description: String {
        switch self {
        case .local: return "unix"
        case .ssh(let alias): return "ssh:\(alias)"
        case .paired(let hostID): return "paired:\(hostID)"
        }
    }

    /// The string the app's state keys a machine by, `nil` for this Mac: a
    /// `~/.ssh/config` alias, or `paired:<host_id>` for a paired Mac. The session
    /// tree, the workspaces and the closed-session journal all store this one
    /// string, so a paired Mac rides every path an SSH host does, and is never
    /// taken for this Mac the way a `nil` would be.
    var hostKey: String? {
        switch self {
        case .local: return nil
        case .ssh(let alias): return alias
        case .paired(let hostID): return Self.pairedPrefix + hostID
        }
    }

    init(hostKey: String?) {
        guard let hostKey else { self = .local; return }
        if hostKey.hasPrefix(Self.pairedPrefix) {
            self = .paired(String(hostKey.dropFirst(Self.pairedPrefix.count)))
        } else {
            self = .ssh(hostKey)
        }
    }

    /// The SSH alias, when this route is one. Every caller that runs `ssh`
    /// itself asks this, so a paired Mac never reaches `ssh paired:…`.
    var sshAlias: String? {
        if case .ssh(let alias) = self { return alias }
        return nil
    }

    var isPaired: Bool {
        if case .paired = self { return true }
        return false
    }

    /// A colon cannot appear in a `Host` alias anyone types, so the prefix
    /// cannot collide with one.
    static let pairedPrefix = "paired:"

    /// Whether a host key names a paired Mac rather than an SSH alias.
    static func isPaired(hostKey: String?) -> Bool {
        hostKey?.hasPrefix(pairedPrefix) == true
    }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        if text == "unix" {
            self = .local
        } else if text.hasPrefix("ssh:") {
            self = .ssh(String(text.dropFirst(4)))
        } else if text.hasPrefix("paired:") {
            self = .paired(String(text.dropFirst(7)))
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
/// in its durable state dir (termiod/src/paths.rs). Everything else about a device,
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
    /// The protocol version the last handshake with the device negotiated —
    /// `hello_ok.proto`. `nil` for a device recorded before the field existed.
    var negotiatedProtocol: Int? = nil
    /// When the last handshake completed, persisted. Unlike `lastSeen` this
    /// never claims reachability: it stamps *when the facts above were learned*,
    /// so `termio version` can say "as of last connect, 2h ago" instead of
    /// presenting a stale row as live state.
    var observedAt: Date? = nil
    /// When *this run* of the app last completed a handshake with the device.
    /// Deliberately not persisted: a timestamp restored from disk would claim
    /// reachability the app has not verified since launch.
    var lastSeen: Date?

    private enum CodingKeys: String, CodingKey {
        case id, daemonVersion, routes
        case negotiatedProtocol = "proto"
        case observedAt
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
    func record(
        hostID: String, daemonVersion: String, negotiatedProtocol: Int? = nil,
        route: TermiodRoute
    ) -> TermiodDevice {
        lock.lock()
        defer { lock.unlock() }

        // The registry has a second, occasional writer: a CLI deploy stamps
        // what its handshake revealed (termiod/src/remote.rs). Its stamp may be
        // newer than this app's picture, and `save` writes the whole map from
        // memory — so newer on-disk observations are folded in first, or the
        // next handshake with *any* device would silently undo the deploy's.
        mergeNewerObservationsFromDiskLocked()

        // A route that used to lead elsewhere is taken away from its old device
        // first, so the two never both claim it.
        claimLocked(route, for: hostID)

        var device = devicesByID[hostID]
            ?? TermiodDevice(id: hostID, daemonVersion: daemonVersion, routes: [], lastSeen: nil)
        device.daemonVersion = daemonVersion
        // A handshake that did not carry the version keeps the last one that
        // did: overwriting a known protocol with `nil` would only unlearn it.
        if let negotiatedProtocol {
            device.negotiatedProtocol = negotiatedProtocol
        }
        // Most recently used first: the route that just worked is the one to try
        // again before probing the others.
        device.routes.removeAll { $0 == route }
        device.routes.insert(route, at: 0)
        device.observedAt = Date()
        device.lastSeen = Date()
        devicesByID[hostID] = device

        save()
        return device
    }

    /// Must hold `lock`. Points `route` at `id`, taking it away from whichever
    /// device claimed it before — a route belongs to exactly one device.
    private func claimLocked(_ route: TermiodRoute, for id: String) {
        if let previous = deviceIDByRoute[route], previous != id {
            devicesByID[previous]?.routes.removeAll { $0 == route }
        }
        deviceIDByRoute[route] = id
    }

    /// Must hold `lock`. Folds observations written to `devices.json` since the
    /// last load into memory, newest per device winning: a row this app has
    /// never seen is adopted whole, and a row observed more recently than the
    /// copy in memory updates the facts a handshake learns (version, protocol,
    /// routes, the stamp). Memory wins ties, so a normal app-only lifetime is
    /// byte-for-byte what it was before this existed.
    private func mergeNewerObservationsFromDiskLocked() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let devices = try? decoder.decode([TermiodDevice].self, from: data)
        else { return }
        for disk in devices {
            guard var memory = devicesByID[disk.id] else {
                devicesByID[disk.id] = disk
                for route in disk.routes { claimLocked(route, for: disk.id) }
                continue
            }
            guard (disk.observedAt ?? .distantPast) > (memory.observedAt ?? .distantPast) else {
                continue
            }
            memory.daemonVersion = disk.daemonVersion
            if let negotiated = disk.negotiatedProtocol {
                memory.negotiatedProtocol = negotiated
            }
            memory.observedAt = disk.observedAt
            for route in disk.routes where !memory.routes.contains(route) {
                memory.routes.append(route)
            }
            devicesByID[disk.id] = memory
            for route in disk.routes { claimLocked(route, for: disk.id) }
        }
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
        if case .paired(let hostID) = route { return hostID }
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
            // ISO 8601, not the Foundation reference-date float: `devices.json`
            // reads like configuration, and `termio version` parses it in shell.
            encoder.dateEncodingStrategy = .iso8601
            // A paired route stays in memory only. Builds before it decode this
            // file with `try?` over the whole array, so one route they cannot
            // read would empty their registry and the next save would keep it
            // empty. The route carries the `host_id`, so nothing is lost.
            let devices = devicesByID.values.sorted { $0.id < $1.id }.map { device in
                var saved = device
                saved.routes.removeAll(where: \.isPaired)
                return saved
            }
            try encoder.encode(devices).write(to: fileURL, options: .atomic)
        } catch {
            Log.termiod.error("""
            persisting device map failed: \(error.localizedDescription, privacy: .public)
            """)
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let devices = try? decoder.decode([TermiodDevice].self, from: data)
        else { return }
        for device in devices {
            devicesByID[device.id] = device
            for route in device.routes {
                deviceIDByRoute[route] = device.id
            }
        }
    }
}
