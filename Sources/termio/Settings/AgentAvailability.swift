import Foundation

/// Whether an agent's launch command resolves to a real executable on the same PATH
/// termio's sessions launch with — the user's *login-shell* PATH (`-ilc`, matching
/// `TermioStore.launchArgv`), not the minimal PATH a Finder-launched app inherits.
///
/// Used by the Agents settings tab to flag an agent whose CLI isn't installed (or
/// lives somewhere off PATH) so the user can enter a full path in the command field
/// or follow the install link — turning the cryptic "failed to launch / 0 ms" pane
/// into a fixable, up-front signal.
enum AgentAvailability {
    /// The login-shell PATH directories, resolved once off the main thread and cached
    /// for the app run. The probe is bounded so a slow/hung rc can't wedge Settings;
    /// on failure it yields an empty list, which makes every check fall back to
    /// "assume available" rather than raise a false alarm.
    private static let resolvedPath = Task.detached(priority: .utility) { pathDirectories() }

    /// The resolved login-shell PATH, shared between the async probe and the
    /// synchronous installer check so both agree on one answer. The detached task
    /// populates it when it finishes; the sync check reads it without blocking.
    private static let pathLock = NSLock()
    // Guarded by `pathLock` on every access; the lock is the synchronization the
    // compiler cannot see.
    nonisolated(unsafe) private static var pathCache: [String]?

    private static func pathDirectories() -> [String] {
        pathLock.withLock {
            if let cached = pathCache { return cached }
            let resolved = resolvePathDirectories()
            pathCache = resolved
            return resolved
        }
    }

    /// Whether the first word of `command` (its binary) is an executable on PATH. An
    /// absolute/`~` path is checked directly; an empty command (the plain login shell)
    /// is always "available".
    static func isCommandAvailable(_ command: String) async -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard let binary = trimmed.split(separator: " ").first.map(String.init), !binary.isEmpty
        else { return true }
        if binary.hasPrefix("/") || binary.hasPrefix("~") {
            return FileManager.default.isExecutableFile(atPath: (binary as NSString).expandingTildeInPath)
        }
        let directories = await resolvedPath.value
        // Probe failed (no PATH) → don't cry wolf; only flag when we actually looked.
        guard !directories.isEmpty else { return true }
        return directories.contains {
            FileManager.default.isExecutableFile(atPath: $0 + "/" + binary)
        }
    }

    /// A non-blocking, synchronous check for call sites that can't await (the skill
    /// installer's per-launch sync). Absolute/`~` commands are checked directly;
    /// relative binaries resolve against the login-shell PATH once the async probe
    /// has populated the cache, and the process PATH before that — so a very early
    /// call may under-report an installed agent, but never blocks on the shell, and
    /// the next launch's sync re-checks and picks it up.
    static func isCommandInstalled(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard let binary = trimmed.split(separator: " ").first.map(String.init), !binary.isEmpty
        else { return true }
        if binary.hasPrefix("/") || binary.hasPrefix("~") {
            return FileManager.default.isExecutableFile(atPath: (binary as NSString).expandingTildeInPath)
        }
        var directories: [String] = []
        pathLock.withLock { directories = pathCache ?? [] }
        if directories.isEmpty {
            directories = ProcessInfo.processInfo.environment["PATH"]?
                .split(separator: ":").map(String.init) ?? []
        }
        return directories.contains {
            FileManager.default.isExecutableFile(atPath: $0 + "/" + binary)
        }
    }

    private static func resolvePathDirectories() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShell)
        process.arguments = ["-ilc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        // Bound the probe: a login shell whose rc blocks must not hang forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: ":").map(String.init)
    }

    /// The user's real login shell, read from the password database rather than the
    /// ambient `SHELL` (which a GUI launch may leave unset or `/bin/sh`) — the same
    /// resolution `TermioStore.launchArgv` uses, so this checks the exact PATH a
    /// session would launch with.
    private static var loginShell: String {
        if let entry = getpwuid(getuid()), let cString = entry.pointee.pw_shell {
            let value = String(cString: cString)
            if !value.isEmpty { return value }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}
