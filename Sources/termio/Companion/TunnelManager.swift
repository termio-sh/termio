import AppKit
import Foundation

/// Fronts the companion server with a public tunnel so the iPhone can connect
/// away from the LAN. Every provider has the same shape: spawn the CLI pointed
/// at the companion port, scrape the public URL it prints, publish it for the
/// QR. All of a provider's per-tool knowledge — argv, the URL it prints, where
/// to fetch its binary, how to reap a stray copy — lives in one `Spec`, so
/// adding a tunnel is a single new `case` plus one `spec` arm, not edits smeared
/// across spawn / scan / install / reap.
///
/// The CLI is found on the usual install paths or (when the spec carries a
/// download) fetched once from its GitHub release into Application Support — the
/// app itself stays small and tunnel updates stay decoupled from app releases.
/// A provider with no download is bring-your-own: it must already be on PATH
/// (e.g. `brew install ngrok`, plus a one-time `ngrok config add-authtoken`).
///
/// The tunnel is a dumb pipe: every connection that arrives through it still
/// has to present the pairing token before the server serves it anything.
@MainActor
final class TunnelManager: ObservableObject {
    enum Provider: String, CaseIterable, Identifiable {
        case off
        case tunelo
        case cloudflared
        case ngrok
        case custom

        var id: String { rawValue }
        var label: String {
            // Custom's spec is nil until the user fills it in, so its name can't
            // come from the spec the way the bundled providers' do.
            if self == .custom { return "Custom" }
            return spec?.label ?? "Off"
        }
        var binaryName: String { spec?.binaryName ?? "" }

        /// Everything the manager needs to run this provider, in one place.
        /// `nil` for `.off`. Bakes in the companion port and the host arch so
        /// the call sites stay provider-agnostic.
        var spec: Spec? {
            let port = String(CompanionServer.defaultPort)
            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "amd64"
            #endif
            switch self {
            case .off:
                return nil
            case .tunelo:
                return Spec(
                    binaryName: "tunelo",
                    label: "Tunelo",
                    arguments: ["port", port],
                    urlPattern: #"https://[a-zA-Z0-9-]+\.tunelo\.net"#,
                    download: Spec.Download(
                        url: "https://github.com/jiweiyuan/tunelo/releases/latest/download/tunelo-macos-\(arch)",
                        isArchive: false
                    )
                )
            case .cloudflared:
                return Spec(
                    binaryName: "cloudflared",
                    label: "Cloudflare",
                    arguments: ["tunnel", "--url", "http://127.0.0.1:\(port)", "--no-autoupdate"],
                    urlPattern: #"https://[a-zA-Z0-9-]+\.trycloudflare\.com"#,
                    download: Spec.Download(
                        url: "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-\(arch).tgz",
                        isArchive: true
                    )
                )
            case .ngrok:
                return Spec(
                    binaryName: "ngrok",
                    label: "ngrok",
                    // `--log stdout` turns off the interactive TUI and prints the
                    // public URL as a logfmt `url=…` field we can scrape.
                    arguments: ["http", port, "--log", "stdout"],
                    urlPattern: #"https://[a-zA-Z0-9-]+\.ngrok(?:-free)?\.(?:app|io)"#,
                    // Bring-your-own: ngrok needs `ngrok config add-authtoken`
                    // run once against the user's account, so auto-fetching the
                    // bare binary wouldn't save the real setup step. Discover a
                    // brew/manual install on PATH, or fail with a hint.
                    download: nil
                )
            case .custom:
                // A relay the user runs themselves: the command and the URL
                // pattern come from settings, not baked-in constants. `nil` (Off-
                // like: no spawn, an inert picker entry) until the user has
                // supplied both a command and a regex that actually compiles —
                // spawning half a spec would only strand the tunnel in
                // `.starting`. `{port}` in the command stands in for the
                // companion port so the user needn't hardcode it.
                return CustomTunnel.current.spec(port: port)
            }
        }

        /// A `pkill -f` substring that matches *our* tunnel for this provider and
        /// nothing else. Always port-scoped (the argv carries the companion port),
        /// so a user's unrelated tunnel on another port is spared.
        ///
        /// A custom relay is deliberately excluded: its argv is a user-typed
        /// string carrying no such guarantee. A one-token command yields the
        /// pattern `"ssh "`, and `pkill -f` matches that as a *substring* of
        /// every ssh on the machine — SIGKILLing the user's own sessions, and
        /// doing it on every restart for as long as the command sits in
        /// settings, whichever provider is actually selected. Custom orphans
        /// are reaped by recorded pid instead; see `reapStrayCustomTunnel`.
        var reapPattern: String? {
            guard self != .custom else { return nil }
            return spec.map { "\($0.binaryName) \($0.arguments.joined(separator: " "))" }
        }
    }

    /// One provider's full recipe. See `Provider.spec`.
    struct Spec {
        let binaryName: String
        let label: String
        /// argv (after the binary) that exposes the companion port.
        let arguments: [String]
        /// Regex matching the public https URL the CLI prints on start-up.
        let urlPattern: String
        /// A one-time binary fetch, or `nil` for bring-your-own-on-PATH.
        let download: Download?

        struct Download {
            let url: String
            /// A `.tgz` to unpack vs a bare binary to move into place.
            let isArchive: Bool
        }
    }

    enum Status: Equatable {
        case off
        /// First use on a machine without the CLI: fetching it from GitHub.
        case installing
        /// Process spawned, waiting for it to print its public URL.
        case starting
        /// Tunnel up; the URL is the public https endpoint.
        case running(URL)
        case failed(String)
    }

    static let shared = TunnelManager()
    private static let providerKey = "companion.tunnelProvider"

    @Published private(set) var provider: Provider
    @Published private(set) var status: Status = .off

    private var process: Process?
    private var outputBuffer = Data()
    private var terminationObserver: NSObjectProtocol?
    /// Unexpected exits since the last healthy URL: the tunnel self-heals on
    /// relay hiccups but refuses to hot-loop against a hard failure.
    private var consecutiveFailures = 0

    private init() {
        provider = UserDefaults.standard.string(forKey: Self.providerKey)
            .flatMap(Provider.init(rawValue:)) ?? .off
        // Process children outlive their parent; a tunnel left behind would
        // keep serving a dead socket's URL.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { TunnelManager.shared.stopProcess() }
        }
    }

    /// App-launch hook (and Mobile-Access resume): bring the tunnel the user had
    /// on last quit back up. A no-op when the provider is Off.
    func startIfEnabled() {
        if provider != .off { restart() }
    }

    /// Mobile Access was switched off: tear the tunnel down so nothing public
    /// remains, but keep the provider *preference* — turning Mobile Access back
    /// on calls `startIfEnabled()` and restores the same provider.
    func suspend() {
        stopProcess()
    }

    func setProvider(_ newProvider: Provider) {
        guard newProvider != provider else { return }
        provider = newProvider
        UserDefaults.standard.set(newProvider.rawValue, forKey: Self.providerKey)
        consecutiveFailures = 0
        restart()
    }

    /// Re-read the custom relay's settings and restart. `setProvider` early-
    /// returns when the provider is unchanged, so editing the custom command
    /// while Custom is already selected needs its own path to pick up the new
    /// spec; a no-op unless Custom is the active provider.
    func reloadCustom() {
        guard provider == .custom else { return }
        consecutiveFailures = 0
        restart()
    }

    private func restart() {
        stopProcess()
        guard provider != .off else {
            status = .off
            return
        }
        // Custom selected but not yet filled in (no command, or a URL pattern
        // that doesn't compile): its spec is nil, so there's nothing to spawn.
        // Say so plainly instead of failing deep in binary discovery on an
        // empty command.
        if provider == .custom, provider.spec == nil {
            status = .failed("set a command and URL pattern for the custom relay")
            return
        }
        // Reap any tunnel a prior run left behind. `stopProcess`'s SIGTERM (and
        // even the clean-quit `willTerminate` hook) misses two cases: a crash or
        // SIGKILL never runs the hook, and cloudflared can ignore SIGTERM — so an
        // old child gets reparented to launchd and keeps advertising a *stale*
        // trycloudflare URL the phone is still pinned to. That's the "list works
        // but the terminal can't connect" trap: the roster rides the warm old
        // socket while a fresh session socket hits a dead/rotated URL. Only this
        // app ever fronts the companion port, so killing every tunnel on it right
        // before we spawn ours is safe and converges to exactly one.
        Self.reapStrayTunnels()
        Self.reapStrayCustomTunnel()
        let target = provider
        status = .starting
        Task {
            var binary = Self.findBinary(named: target.binaryName)
            if binary == nil {
                status = .installing
                do {
                    binary = try await Self.install(target)
                } catch {
                    if self.provider == target {
                        status = .failed("couldn’t install \(target.binaryName): \(error.localizedDescription)")
                    }
                    return
                }
            }
            // The user may have flipped the picker while the download ran.
            guard self.provider == target, let binary else { return }
            spawn(binary, for: target)
        }
    }

    private func spawn(_ binary: URL, for provider: Provider) {
        guard let spec = provider.spec else { return }
        let process = Process()
        process.executableURL = binary
        process.arguments = spec.arguments
        // CLIs print their public URL to the console (tunelo on stdout,
        // cloudflared/ngrok inside a stderr/stdout banner); one merged pipe
        // catches either.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        outputBuffer.removeAll()
        let urlPattern = spec.urlPattern
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.scanOutput(data, from: process, pattern: urlPattern) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.process === process else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                Log.tunnel.notice("\(provider.binaryName, privacy: .public) exited (status \(process.terminationStatus, privacy: .public))")
                // Quick tunnels drop when the relay blips; restart while the
                // user still wants one, but don't hot-loop a hard failure.
                // Each restart mints a NEW public URL — the open QR follows,
                // an already-paired phone must re-scan (stable subdomains
                // need tunelo to grow a --subdomain flag).
                guard self.provider == provider else { return }
                self.consecutiveFailures += 1
                guard self.consecutiveFailures < 5 else {
                    self.status = .failed("\(provider.binaryName) keeps exiting — pick the tunnel again to retry")
                    return
                }
                self.status = .starting
                Log.tunnel.notice("restarting \(provider.binaryName, privacy: .public) in 3s (attempt \(self.consecutiveFailures, privacy: .public))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    Task { @MainActor in
                        guard let self, self.process == nil, self.provider == provider else { return }
                        self.restart()
                    }
                }
            }
        }
        do {
            try process.run()
            Log.tunnel.info("spawned \(provider.binaryName, privacy: .public) (pid \(process.processIdentifier, privacy: .public))")
            // A custom relay has no argv signature to match on later, so the
            // pid is the only handle a *future* run has on this child.
            if provider == .custom {
                Self.rememberCustomTunnel(pid: process.processIdentifier, binary: binary.path)
            }
        } catch {
            status = .failed("couldn’t launch \(provider.binaryName): \(error.localizedDescription)")
            return
        }
        self.process = process
        status = .starting
        // Relay unreachable, DNS down, rate-limited — the CLI can sit silent
        // for a long time; give the user an answer within half a minute.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            Task { @MainActor in
                guard let self, self.process === process, self.status == .starting else { return }
                self.stopProcess()
                self.status = .failed("\(provider.binaryName) didn’t come up — check the network and retry")
            }
        }
    }

    private func scanOutput(_ data: Data, from process: Process, pattern: String) {
        guard self.process === process, status == .starting else { return }
        outputBuffer.append(data)
        // ANSI color codes may sit right against the URL; the character class
        // stops at the escape byte either way.
        guard let text = String(data: outputBuffer, encoding: .utf8),
              let range = text.range(of: pattern, options: .regularExpression),
              let url = URL(string: String(text[range]))
        else { return }
        Log.tunnel.notice("up at \(url.absoluteString, privacy: .public)")
        consecutiveFailures = 0
        status = .running(url)
    }

    private func stopProcess() {
        guard let process else { return }
        process.terminationHandler = nil
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process.terminate()
        // We reached this child ourselves, so no later run needs to hunt it.
        Self.forgetCustomTunnel()
        self.process = nil
        status = .off
    }

    /// Force-kill any tunnel process still pointed at the companion port — an
    /// orphan from a previous run that `stopProcess`/`willTerminate` couldn't
    /// reach (crash, SIGKILL, or a cloudflared that swallows SIGTERM). Matched by
    /// the exact argv we spawn with, so it only ever hits our own tunnels.
    /// SIGKILL (not TERM) because cloudflared drains slowly on TERM and we want
    /// the port's advertised URL gone *now*, before we mint a fresh one.
    private static func reapStrayTunnels() {
        for pattern in Provider.allCases.compactMap(\.reapPattern) {
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = ["-9", "-f", pattern]
            try? pkill.run()
            pkill.waitUntilExit()
        }
    }

    // Read from the `nonisolated` reaper, so they can't inherit the type's
    // main-actor isolation.
    nonisolated private static let customPIDKey = "companion.customTunnel.pid"
    nonisolated private static let customBinaryKey = "companion.customTunnel.pidBinary"

    /// Remember the custom relay's child so a later run can reap it. The bundled
    /// providers are matched by a tool-specific, port-scoped argv; a user-typed
    /// command has no such shape, so the pid we actually spawned is the only
    /// identity narrow enough to kill safely.
    nonisolated private static func rememberCustomTunnel(pid: Int32, binary: String) {
        UserDefaults.standard.set(Int(pid), forKey: customPIDKey)
        UserDefaults.standard.set(binary, forKey: customBinaryKey)
    }

    nonisolated private static func forgetCustomTunnel() {
        UserDefaults.standard.removeObject(forKey: customPIDKey)
        UserDefaults.standard.removeObject(forKey: customBinaryKey)
    }

    /// Kill a custom relay a crashed run left behind, matched by the pid we
    /// recorded at spawn. Pids are recycled, so the executable path is checked
    /// first: an unrelated process that inherited the number is left alone, and
    /// the record is dropped either way so a stale pid can't be retried forever.
    nonisolated private static func reapStrayCustomTunnel() {
        let pid = UserDefaults.standard.integer(forKey: customPIDKey)
        guard pid > 0, let binary = UserDefaults.standard.string(forKey: customBinaryKey) else { return }
        defer { forgetCustomTunnel() }
        guard runningCommand(pid: Int32(pid))?.hasPrefix(binary) == true else {
            Log.tunnel.info("custom relay pid \(pid, privacy: .public) is gone or recycled — not reaping")
            return
        }
        Log.tunnel.notice("reaping stray custom relay (pid \(pid, privacy: .public))")
        kill(pid_t(pid), SIGKILL)
    }

    /// The full command line of a live pid, or `nil` when it isn't running.
    nonisolated private static func runningCommand(pid: Int32) -> String? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(pid), "-o", "command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do {
            try ps.run()
        } catch {
            Log.tunnel.error("couldn't inspect pid \(pid, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let command = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    // MARK: - Binary discovery & install

    /// Where a user-managed install would be, then our own downloaded copy.
    /// A brew/cargo binary wins because the user keeps it updated. A custom
    /// provider may name an absolute path or a bare command on `PATH`, so both
    /// are resolved before the fixed install locations.
    nonisolated private static func findBinary(named name: String) -> URL? {
        guard !name.isEmpty else { return nil }
        // An absolute/relative path the user typed for a custom relay: take it
        // as given rather than hunting the standard install dirs for a basename
        // that has slashes in it.
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name)
                ? URL(fileURLWithPath: name) : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.cargo/bin/\(name)",
            installDirectory.appendingPathComponent(name).path,
        ]
        // A custom relay's binary can live anywhere on the user's `PATH`; the
        // GUI app doesn't inherit a login shell's `PATH`, so consult it
        // explicitly rather than assuming the fixed dirs above cover it.
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map {
                "\($0)/\(name)"
            }
        }
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    nonisolated private static var installDirectory: URL {
        AppChannel.supportDirectory.appendingPathComponent("bin", isDirectory: true)
    }

    /// One-time fetch from the provider's GitHub release. tunelo ships a bare
    /// binary; cloudflared ships a single-file tgz. Both are small enough to
    /// pull on first use, and neither ends up inside the app bundle (which
    /// would bloat every Sparkle update and freeze their CVE fixes to ours).
    /// A bring-your-own provider (no `spec.download`) throws a hint instead.
    nonisolated private static func install(_ provider: Provider) async throws -> URL {
        guard let download = provider.spec?.download else {
            // A custom relay is never fetched for the user — its command is
            // whatever they typed, so point them back at that setting rather
            // than at a `brew install` for a binary we don't know the name of.
            if provider == .custom {
                throw NSError(domain: "termio.tunnel", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "custom relay command not found on PATH — check the command in Settings ▸ Mobile ▸ Custom Tunnel",
                ])
            }
            throw NSError(domain: "termio.tunnel", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "\(provider.binaryName) isn’t installed — `brew install \(provider.binaryName)`, then run `\(provider.binaryName) config add-authtoken <token>` once",
            ])
        }
        let (temp, response) = try await URLSession.shared.download(from: URL(string: download.url)!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "termio.tunnel", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))",
            ])
        }
        let directory = installDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(provider.binaryName)
        try? FileManager.default.removeItem(at: destination)
        if download.isArchive {
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xzf", temp.path, "-C", directory.path]
            try tar.run()
            tar.waitUntilExit()
            guard tar.terminationStatus == 0 else {
                throw NSError(domain: "termio.tunnel", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "couldn’t unpack the archive",
                ])
            }
        } else {
            try FileManager.default.moveItem(at: temp, to: destination)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination
    }
}

/// A relay the user runs themselves. Unlike the bundled providers, whose specs
/// are compiled in, a custom relay's command and URL pattern are user-supplied
/// and persisted in UserDefaults. Kept as plain accessors (like `PairingToken`)
/// rather than a `@MainActor` observable so `TunnelManager.Provider.spec` — and
/// through it the `nonisolated` stray-tunnel reaper — can build the spec from
/// any context.
struct CustomTunnel {
    var command: String
    var urlPattern: String

    static let commandKey = "companion.customTunnel.command"
    static let urlPatternKey = "companion.customTunnel.urlPattern"

    /// The persisted custom relay; empty strings when the user hasn't set one.
    static var current: CustomTunnel {
        CustomTunnel(
            command: UserDefaults.standard.string(forKey: commandKey) ?? "",
            urlPattern: UserDefaults.standard.string(forKey: urlPatternKey) ?? ""
        )
    }

    static func save(command: String, urlPattern: String) {
        UserDefaults.standard.set(command, forKey: commandKey)
        UserDefaults.standard.set(urlPattern, forKey: urlPatternKey)
    }

    /// Whether the URL pattern compiles as a regex. A pattern that never
    /// compiles would never match the CLI's output, stranding the tunnel in
    /// `.starting`; the spec stays `nil` until this holds so the picker entry is
    /// inert rather than broken.
    var hasValidPattern: Bool {
        !urlPattern.isEmpty && (try? NSRegularExpression(pattern: urlPattern)) != nil
    }

    /// Build a `Spec` from the user's command and pattern, or `nil` when either
    /// is missing/invalid. The command is split on whitespace into argv and run
    /// directly — never through a shell — so quotes, pipes, and redirects are
    /// not interpreted and there is no shell-injection surface; `{port}` is
    /// replaced with the companion port. The first token is the binary (a bare
    /// name resolved on PATH, or an absolute path), the rest are its arguments.
    func spec(port: String) -> TunnelManager.Spec? {
        let tokens = command
            .replacingOccurrences(of: "{port}", with: port)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard let binary = tokens.first, hasValidPattern else { return nil }
        return TunnelManager.Spec(
            binaryName: binary,
            label: "Custom",
            arguments: Array(tokens.dropFirst()),
            urlPattern: urlPattern,
            download: nil
        )
    }
}
