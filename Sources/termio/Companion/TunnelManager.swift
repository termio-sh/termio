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
        /// `nil` for `.off`. Bakes in the served port and the host arch so the
        /// call sites stay provider-agnostic.
        var spec: Spec? { spec(servedPort: PhoneServing.port) }

        /// Parameterised by port because the reaper has to name a tunnel this
        /// Mac spawned under the *other* serving mode — a switch mid-run leaves
        /// an orphan advertising a public URL for a port nothing answers on.
        func spec(servedPort: UInt16) -> Spec? {
            let port = String(servedPort)
            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "amd64"
            #endif
            switch self {
            case .off:
                return nil
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
        /// nothing else. Always port-scoped (the argv carries the served port),
        /// so a user's unrelated tunnel on another port is spared.
        ///
        /// A custom relay is deliberately excluded: its argv is a user-typed
        /// string carrying no such guarantee. A one-token command yields the
        /// pattern `"ssh "`, and `pkill -f` matches that as a *substring* of
        /// every ssh on the machine — SIGKILLing the user's own sessions, and
        /// doing it on every restart for as long as the command sits in
        /// settings, whichever provider is actually selected. Custom orphans
        /// are reaped by recorded pid instead; see `reapStrayCustomTunnel`.
        func reapPattern(servedPort: UInt16) -> String? {
            guard self != .custom else { return nil }
            return spec(servedPort: servedPort)
                .map { "\($0.binaryName) \($0.arguments.joined(separator: " "))" }
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
    /// Bumped every time the tunnel is torn down, so async work started under
    /// an earlier intent can tell that it has been superseded.
    ///
    /// `provider` cannot answer that question: `suspend()` leaves it selected
    /// (turning Mobile Access back on must restore the user's choice), so a
    /// `provider == target` check passes just as happily after a suspend as
    /// before one. `restart()` installs a binary and probes it with awaits in
    /// between, and on a slow first install that is a long window in which the
    /// user can turn Mobile Access off and still get a public tunnel spawned
    /// at the end of it.
    private var generation = 0
    /// The restart waiting out its backoff, held so it can be cancelled.
    ///
    /// Without a handle it could not be: `stopProcess` returns early when no
    /// child is live, which is exactly the state a scheduled retry sits in. So
    /// turning Mobile Access off — or the companion listener failing, which now
    /// suspends too — left the queued closure alone, and it spawned a tunnel
    /// minutes later for a server that was deliberately not serving. The
    /// backoff made that window five minutes wide instead of three seconds.
    private var pendingRestart: DispatchWorkItem?
    private var outputBuffer = Data()
    private var terminationObserver: NSObjectProtocol?
    /// Unexpected exits since the last run that actually held. It does not stop
    /// the tunnel retrying — it only slows it down (`restartDelay`).
    private var consecutiveFailures = 0
    /// When the live child started, so its exit can be judged by how long it
    /// lasted. A tunnel that prints a URL and dies seconds later is a hard
    /// failure wearing a success's clothes — see `durableRun`.
    ///
    /// Monotonic (`ProcessInfo.systemUptime`), never `Date`: this measures how
    /// long the child was *live*, and a wall clock answers a different
    /// question. A Mac that slept a minute after launch would report the nap as
    /// uptime, mark a three-second flap durable, and reopen the storm below;
    /// an NTP correction would do the same. `LinkLiveness` picks this clock for
    /// the same reason.
    private var processStartedAt: TimeInterval?

    /// How long a run must last to count as healthy rather than a flap.
    ///
    /// Printing a URL used to be the proof, and it is not one: two app
    /// instances racing for the same port produced a tunnel that came up,
    /// announced a fresh public URL, and was killed ~3s later, forever. Each
    /// cycle looked like a success, so the failure count reset and the backoff
    /// below never took hold — eight public URLs in twenty-two seconds, every
    /// one of them breaking the QR a paired phone had already scanned.
    ///
    /// Well clear of the 3s first retry, so an ordinary relay hiccup on a
    /// tunnel that has been up for a while still reads as the hiccup it is.
    private static let durableRun: TimeInterval = 60

    /// How long to wait before the next restart, doubling per consecutive
    /// failure from 3s and held at 5 minutes.
    ///
    /// Backoff rather than a cap, because a cap has to answer "how bad is bad
    /// enough to stop forever" and there is no answer: a relay that drops every
    /// 50s is serving — badly — and giving up on it stranded a working tunnel
    /// until the user reselected the provider by hand. Backoff needs no such
    /// judgment. A hard failure costs one attempt per five minutes instead of
    /// one per three seconds, which is what the cap was actually for, and a
    /// relay that recovers on its own is picked back up without anyone
    /// touching Settings.
    /// The wait past which a spinner stops being an honest description of what
    /// the tunnel is doing, and the status says so in words instead.
    private static let quietRetryDelay: TimeInterval = 24

    static func restartDelay(afterFailures failures: Int) -> TimeInterval {
        // Guarded before the subtraction, not after: `failures - 1` on
        // `Int.min` traps, and a delay function is the last place that should
        // be able to bring the app down.
        guard failures > 1 else { return 3 }
        let doublings = min(failures - 1, 8)
        return min(3 * pow(2, Double(doublings)), 300)
    }

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
        Self.reapLegacyTunelo()
        if provider != .off { restart() }
    }

    /// Mobile Access was switched off: tear the tunnel down so nothing public
    /// remains, but keep the provider *preference* — turning Mobile Access back
    /// on calls `startIfEnabled()` and restores the same provider.
    func suspend() {
        stopProcess()
        // `stopProcess` deliberately says nothing about status — `restart` calls
        // it and immediately sets `.starting`. Suspending is the other case: it
        // is the end state, so it has to name one, or the pane keeps whatever
        // was last true. That was a spinner mid-start, and "Connected" with a
        // URL that no longer resolves when a live tunnel was torn down.
        status = .off
    }

    /// The served port moved under a running tunnel (the Mobile pane's Direct
    /// Attach switch). A no-op when the provider is Off, so flipping the switch
    /// on a LAN-only Mac spawns nothing.
    func restartIfRunning() {
        guard provider != .off else { return }
        consecutiveFailures = 0
        restart()
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
            status = .failed(localized("set a command and URL pattern for the custom relay"))
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
        // Read after `stopProcess` above, so this names the intent this call is
        // acting on; any later teardown moves it and strands the work below.
        let epoch = generation
        status = .starting
        Task {
            // Checked before the first side effect, not just before the spawn:
            // the body starts asynchronously, so a suspend between `restart()`
            // returning and this line would otherwise still announce
            // "Installing…" and pull a CLI down over the network for a tunnel
            // nobody is going to get.
            guard self.generation == epoch, self.provider == target else { return }
            var binary = Self.findBinary(named: target.binaryName)
            if binary == nil {
                status = .installing
                do {
                    binary = try await Self.install(target)
                } catch {
                    if self.generation == epoch, self.provider == target {
                        status = .failed(localized(
                            "couldn’t install \(target.binaryName): \(error.localizedDescription)"))
                    }
                    return
                }
            }
            // The user may have flipped the picker — or turned Mobile Access
            // off entirely — while the download ran.
            guard self.generation == epoch, self.provider == target, let binary else { return }
            spawn(binary, for: target, arguments: target.spec?.arguments ?? [])
        }
    }

    private func spawn(_ binary: URL, for provider: Provider, arguments: [String]) {
        guard let spec = provider.spec else { return }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        // CLIs print their public URL inside a stderr or stdout banner; one
        // merged pipe catches either.
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
                let uptime = self.processStartedAt.map {
                    ProcessInfo.processInfo.systemUptime - $0
                }
                self.processStartedAt = nil
                Log.tunnel.notice("""
                \(provider.binaryName, privacy: .public) exited \
                (status \(process.terminationStatus, privacy: .public)) \
                after \(Int(uptime ?? 0), privacy: .public)s
                """)
                // A run that held is what clears the count, not a URL that
                // appeared: only lasting proves the tunnel was ever usable.
                if let uptime, uptime >= Self.durableRun { self.consecutiveFailures = 0 }
                // Quick tunnels drop when the relay blips; restart while the
                // user still wants one, but slow down against a hard failure.
                // Each restart mints a NEW public URL — the open QR follows,
                // an already-paired phone must re-scan, which is the real
                // cost being rationed here.
                guard self.provider == provider else { return }
                self.consecutiveFailures += 1
                let delay = Self.restartDelay(afterFailures: self.consecutiveFailures)
                // Once the wait is long enough to look like nothing is
                // happening, say what is happening instead of spinning. The
                // cap this replaced at least told the user it had given up; an
                // indefinite "Starting tunnel…" would be the worse of the two.
                if delay >= Self.quietRetryDelay {
                    self.status = .failed(localized(
                        "\(provider.binaryName) keeps exiting — retrying every \(Int(delay))s"))
                } else {
                    self.status = .starting
                }
                Log.tunnel.notice("""
                restarting \(provider.binaryName, privacy: .public) \
                in \(Int(delay), privacy: .public)s \
                (attempt \(self.consecutiveFailures, privacy: .public))
                """)
                // The body runs on the main queue directly rather than hopping
                // through a `Task`: a hop makes the work item cancellable only
                // up to the moment it fires, after which the enqueued task is
                // beyond reach and restarts a tunnel the user has since turned
                // off. Cancelling has to mean cancelled, so there is nothing
                // between the item and the work. Safe because the item is only
                // ever scheduled on `DispatchQueue.main`.
                let retry = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        // Cleared whenever the item runs, before the guards, so
                        // the handle never outlives the work it names.
                        self.pendingRestart = nil
                        guard self.process == nil, self.provider == provider else { return }
                        self.restart()
                    }
                }
                self.pendingRestart = retry
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
            }
        }
        do {
            try process.run()
            processStartedAt = ProcessInfo.processInfo.systemUptime
            Log.tunnel.info("spawned \(provider.binaryName, privacy: .public) (pid \(process.processIdentifier, privacy: .public))")
            // A custom relay has no argv signature to match on later, so the
            // pid is the only handle a *future* run has on this child.
            if provider == .custom {
                Self.rememberCustomTunnel(pid: process.processIdentifier, binary: binary.path)
            }
        } catch {
            status = .failed(localized(
                "couldn’t launch \(provider.binaryName): \(error.localizedDescription)"))
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
                self.status = .failed(localized(
                    "\(provider.binaryName) didn’t come up — check the network and retry"))
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
        status = .running(url)
    }

    private func stopProcess() {
        // Above the guard, deliberately: a tunnel waiting out its backoff has
        // no live child, so everything below is skipped for exactly the state
        // in which a queued restart is the only thing left to stop.
        pendingRestart?.cancel()
        pendingRestart = nil
        // Also above the guard: async work started before this teardown must be
        // superseded whether or not a child was live to kill.
        generation &+= 1
        guard let process else { return }
        process.terminationHandler = nil
        processStartedAt = nil
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
        // Both ports, not just the one being served now: flipping the Mobile
        // pane's switch changes which port the next tunnel fronts, and the
        // orphan left on the old one is exactly the stale public URL a paired
        // phone is still pinned to.
        let ports = [AppChannel.companionPort, AppChannel.devicePort]
        let patterns = ports.flatMap { port in
            Provider.allCases.compactMap { $0.reapPattern(servedPort: port) }
        }
        for pattern in patterns { forceKill(matching: pattern) }
    }

    /// Tunelo was a provider until it lost its maintainer. A build from before
    /// can leave one running that still publishes the companion port, and the
    /// saved choice now reads back as Off, which never reaches `restart` and its
    /// reaper. So it is reaped on its own, whatever the provider is.
    private static func reapLegacyTunelo() {
        for port in [AppChannel.companionPort, AppChannel.devicePort] {
            forceKill(matching: "tunelo port \(port)")
        }
    }

    private static func forceKill(matching pattern: String) {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-9", "-f", pattern]
        try? pkill.run()
        pkill.waitUntilExit()
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

    /// One-time fetch from the provider's GitHub release. cloudflared ships a
    /// single-file tgz, small enough to pull on first use, and it never ends up
    /// inside the app bundle (which
    /// would bloat every Sparkle update and freeze their CVE fixes to ours).
    /// A bring-your-own provider (no `spec.download`) throws a hint instead.
    nonisolated private static func install(_ provider: Provider) async throws -> URL {
        guard let download = provider.spec?.download else {
            // A custom relay is never fetched for the user — its command is
            // whatever they typed, so point them back at that setting rather
            // than at a `brew install` for a binary we don't know the name of.
            if provider == .custom {
                throw NSError(domain: "termio.tunnel", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "custom relay command not found on PATH — check the command in Settings ▸ Server ▸ Network",
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
