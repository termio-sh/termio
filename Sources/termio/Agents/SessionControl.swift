import Darwin
import Foundation

/// One request from the `termio sessions …` CLI, sent as a single JSON object
/// over `SessionControlListener`'s local socket. This is the write/drive
/// counterpart to `HookListener`'s read-only status stream: where a hook reports
/// "this session is now working", a control request *acts on* a sibling session
/// — listing them, sending a prompt, answering a menu, closing or focusing one.
///
/// - `op` — `list` / `read` / `send` / `answer` / `close` / `focus`.
/// - `format` — `text` (human-readable lines, the default) or `json`.
/// - `callerSession` / `callerCwd` — who is asking, used to scope every operation
///   to the caller's own project. `callerSession` is the `TERMIO_SESSION` the PTY
///   carries; `callerCwd` (`$PWD`) is the fallback for a shell that isn't a termio
///   session but sits inside an open project's directory.
/// - `target` — the session to act on: a `<agent>@<id>` handle from `list`, or a
///   bare id / id prefix / title. Empty for `send` means "start a fresh session".
/// - `text` — the prompt (`send`) or menu answer (`answer`).
/// - `agent` — the agent for a fresh session (`send` with no target).
struct ControlRequest: Decodable {
    let op: String
    let format: String?
    let callerSession: String?
    let callerCwd: String?
    let target: String?
    let text: String?
    let lines: Int?
    let agent: String?

    private enum CodingKeys: String, CodingKey {
        case op, format, target, text, lines, agent
        case callerSession = "caller_session"
        case callerCwd = "caller_cwd"
    }

    var wantsJSON: Bool { format == "json" }
}

/// A local Unix-domain socket the `termio sessions` CLI connects to. Unlike
/// `HookListener` (which only receives), this is request/response: it decodes one
/// `ControlRequest`, runs the handler on the main actor, and writes the handler's
/// reply back down the same connection before closing — so the CLI can print it.
///
/// This type owns only the transport. Resolving the caller's project, enforcing
/// project scope, and acting on sessions all live in `TermioStore` (the handler).
final class SessionControlListener {
    /// The control socket, alongside the status socket and session tree under
    /// termio's Application Support directory. Deliberately a *different* file from
    /// `HookListener.socketURL`: this one accepts drive commands, not status pings.
    static var socketURL: URL {
        AppChannel.supportDirectory.appendingPathComponent("session-control.sock")
    }

    private let onRequest: @MainActor (ControlRequest) async -> Data
    private let queue = DispatchQueue(label: "com.termio.session-control")
    private var source: DispatchSourceRead?
    private var listenDescriptor: Int32 = -1

    init(onRequest: @escaping @MainActor (ControlRequest) async -> Data) {
        self.onRequest = onRequest
    }

    func start() {
        queue.async { [weak self] in self?.bindAndListen() }
    }

    private func bindAndListen() {
        let url = Self.socketURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = url.path
        // A stale socket from a previous run makes bind() fail with EADDRINUSE.
        unlink(path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { Self.log("socket() failed: \(errno)"); return }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else {
            Self.log("socket path too long (\(bytes.count) ≥ \(capacity)): \(path)")
            close(descriptor)
            return
        }
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: UInt8.self, capacity: capacity) { destination in
                for (index, byte) in bytes.enumerated() { destination[index] = byte }
                destination[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
        }
        guard bound == 0 else { Self.log("bind() failed: \(errno)"); close(descriptor); return }
        guard listen(descriptor, 16) == 0 else {
            Self.log("listen() failed: \(errno)"); close(descriptor); return
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(descriptor) }
        listenDescriptor = descriptor
        self.source = source
        source.resume()
    }

    private func acceptPending() {
        while true {
            let client = accept(listenDescriptor, nil, nil)
            if client < 0 { break }
            handle(client)
        }
    }

    private func handle(_ descriptor: Int32) {
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var request: ControlRequest?
        while data.count < 256 * 1024 {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
            if let decoded = Self.decode(data) { request = decoded; break }
        }
        let decoded = request ?? Self.decode(data)
        guard let decoded else {
            Self.writeAll(descriptor, Data("error: malformed request\n".utf8))
            close(descriptor)
            return
        }
        // The handler touches `TermioStore`, so it must run on the main actor; the
        // reply is written back on this private queue so the socket work stays off
        // the main thread.
        let handler = onRequest
        Task { @MainActor in
            let response = await handler(decoded)
            self.queue.async {
                Self.writeAll(descriptor, response)
                close(descriptor)
            }
        }
    }

    private static func writeAll(_ descriptor: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = write(descriptor, base + offset, data.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    private static func decode(_ data: Data) -> ControlRequest? {
        try? JSONDecoder().decode(ControlRequest.self, from: data)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("termio: session control \(message)\n".utf8))
    }
}

/// Tells a coding agent that the `termio sessions` CLI exists and is scoped to its
/// own project, by writing a small marker-wrapped block into the user-level
/// instruction files agents read on startup (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`).
///
/// Deliberately writes to the *user-level* files, not a project's own `CLAUDE.md`
/// / `AGENTS.md`: those belong to the user's repository and editing them would
/// dirty their git tree. Conservative like `AgentStatusHooks` — it only ever
/// touches text between its own markers, leaving everything else untouched, and
/// removes exactly that block on uninstall.
enum SessionSkillInstaller {
    private static let beginMarker = "<!-- termio:sessions BEGIN -->"
    private static let endMarker = "<!-- termio:sessions END -->"

    private static var targets: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".claude/CLAUDE.md"),
            home.appendingPathComponent(".codex/AGENTS.md"),
        ]
    }

    /// The injected guidance — a compact "skill" teaching the agent the `termio
    /// sessions` CLI: the commands, and the key idea that a sibling's *response* is
    /// read from its own transcript (the address `send` returns), not by scraping the
    /// terminal. Scoped to the current project automatically.
    private static var block: String {
        """
        \(beginMarker)
        ## Driving sibling sessions (termio)

        You are running inside termio alongside other agent sessions in this same
        project. Coordinate with them through the `termio sessions` CLI. Every command
        is scoped to this project automatically; add `--json` for machine-readable
        output. Sessions are addressed by the handle `list` prints: `<agent>@<id>`
        (e.g. `claude@ab12cd34`).

        - `termio sessions list` — siblings in this project, with status (working /
          idle / needs-you / done)
        - `termio sessions spawn "<prompt>"` — start a NEW agent session on the
          prompt (`--agent codex` picks the agent; default: your own kind). The
          reply contains the new session's handle — use it for every follow-up.
        - `termio sessions send <agent>@<id> "<text>"` — type text into that existing
          sibling and submit it with a real Return keypress. Send a prompt to drive
          it, or a menu choice (`"1"`, `"yes"`) to answer a permission prompt.
        - `termio sessions close <agent>@<id> …` — close session tabs;
          `termio sessions focus <agent>@<id>` — bring one to the front in the app

        ### Targeting discipline

        - Copy handles verbatim from `list` or a `send` reply; never guess or
          construct one.
        - One request, one target. Never send the same prompt to several siblings,
          and never run multiple `send` commands in parallel — delegate to ONE
          session.
        - Unsure which sibling the user means? Ask them, or start a fresh session
          with `spawn` — don't broadcast.

        ### Reading a sibling's response

        Don't scrape the terminal. `spawn`/`send` returns the sibling's **transcript**
        — the agent's own structured Q&A log (Claude Code: a JSONL file) — plus a
        **cursor** (its line count at send time). To read the reply:

        1. `spawn`/`send` and note `transcript` + `cursor` from the output. (A just-
           started session has no transcript yet; it appears in `list --json` once the
           agent reports it — read that file from the start.)
        2. Poll `termio sessions list` until that session's status is `done` (or
           `needs-you` if it's blocked waiting on input — then `send` its answer).
        3. Read the transcript file from line `cursor` onward; the `assistant` entries
           after it are the reply. (Each line is a JSON object with a `type`/`role`.)

        Workflow: send → wait for `done` via `list` → read the transcript tail. Prefer
        this over assuming a sibling is finished.
        \(endMarker)
        """
    }

    static func sync(enabled: Bool) {
        for url in targets {
            if enabled { install(into: url) } else { uninstall(from: url) }
        }
    }

    private static func install(into url: URL) {
        let stripped = strippedExisting(at: url)
        let separator = stripped.isEmpty ? "" : "\n\n"
        write(stripped + separator + block + "\n", to: url)
    }

    private static func uninstall(from url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let stripped = strippedExisting(at: url)
        // If removing our block leaves nothing, the file held only our note (we
        // created it), so delete it rather than leaving an empty file behind. A
        // file with the user's own content is rewritten preserving it.
        if stripped.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            write(stripped + "\n", to: url)
        }
    }

    /// The file's current contents with any existing termio block (and the
    /// whitespace around it) removed, so install/uninstall never touch the user's
    /// own text. Returns "" when the file is absent or unreadable.
    private static func strippedExisting(at url: URL) -> String {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        guard let begin = contents.range(of: beginMarker),
              let end = contents.range(of: endMarker, range: begin.upperBound..<contents.endIndex)
        else { return contents.trimmingCharacters(in: .newlines) }
        var result = contents
        result.removeSubrange(begin.lowerBound..<end.upperBound)
        return result.trimmingCharacters(in: .newlines)
    }

    private static func write(_ contents: String, to url: URL) {
        let data = Data(contents.utf8)
        // Don't rewrite an unchanged note on every launch: avoids churning a
        // user-owned instruction file and the race of clobbering a concurrent edit.
        if (try? Data(contentsOf: url)) == data { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(
                Data("termio: session skill could not write \(url.path): \(error)\n".utf8))
        }
    }
}

/// Installs and audits the `termio` command-line tool — the bundled script the
/// app symlinks onto the user's PATH so any shell (and any agent's shell tool)
/// can run `termio sessions …` and `termio .`. Modeled on VS Code's `code` tool,
/// with one twist: the symlink (and every agent hook) points at a channel-stable
/// *copy* under Application Support, not into the bundle, because the bundle's
/// location is transient — a dev build launched from a since-deleted git worktree
/// once took every hook that referenced its path down with it. The copy's path
/// never changes; each launch refreshes its content from the running bundle.
enum CommandLineTool {
    /// The tool's name on PATH and inside the bundle: `termio` for a release build,
    /// `termio-dev` for the side-by-side dev channel, so the dev app links its own
    /// CLI instead of clobbering the release one.
    static var toolName: String { "termio" + AppChannel.suffix }

    /// Where the tool is linked onto PATH. `/usr/local/bin` is on the default PATH
    /// and is user-writable on Homebrew Macs; otherwise install falls back to a
    /// one-time admin prompt.
    static var installURL: URL { URL(fileURLWithPath: "/usr/local/bin/\(toolName)") }

    enum Status: Equatable {
        /// Linked to this channel's stable tool copy — nothing to do.
        case installed
        /// Linked to an old-style bundle path, or the copy behind the link is
        /// missing; offer to update the install.
        case stale(String)
        /// Nothing occupies the PATH location yet.
        case notInstalled
        /// A file that termio did not create sits at the location; never clobber it.
        case conflict
        /// No bundled tool and no previously installed copy (a bare `swift run`
        /// binary on a fresh machine), so there is nothing to link.
        case unavailable
    }

    /// The bundled tool inside the running `.app`, or `nil` when running as a bare
    /// SwiftPM binary (`swift run`) where there is no Resources directory.
    static var bundledURL: URL? {
        Bundle.main.url(forResource: toolName, withExtension: nil)
    }

    /// The channel-stable copy of the tool (`…/Application Support/termio[-dev]/bin/`)
    /// — the only path hook files and the PATH symlink ever reference.
    static var supportCopyURL: URL {
        AppChannel.supportDirectory.appendingPathComponent("bin/\(toolName)")
    }

    /// Aligns the support copy's content with the bundled tool. A bare `swift run`
    /// binary has no bundle to copy from, so an existing copy (from the last real
    /// app build) is left serving. Returns whether a usable copy exists afterwards.
    @discardableResult
    static func refreshSupportCopy() -> Bool {
        let fileManager = FileManager.default
        let copy = supportCopyURL
        guard let bundled = bundledURL, let content = try? Data(contentsOf: bundled) else {
            return fileManager.isExecutableFile(atPath: copy.path)
        }
        if (try? Data(contentsOf: copy)) != content {
            do {
                try fileManager.createDirectory(
                    at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: copy, options: .atomic)
            } catch {
                FileHandle.standardError.write(
                    Data("termio: command-line tool copy failed: \(error)\n".utf8))
                return fileManager.isExecutableFile(atPath: copy.path)
            }
        }
        // An atomic write lands with default (non-executable) permissions, and hooks
        // exec the copy directly, so re-assert the mode even on the unchanged path.
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
        return true
    }

    static func audit() -> Status {
        let fileManager = FileManager.default
        let copyUsable = fileManager.isExecutableFile(atPath: supportCopyURL.path)
        guard copyUsable || bundledURL != nil else { return .unavailable }
        let path = installURL.path
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            return fileManager.fileExists(atPath: path) ? .conflict : .notInstalled
        }
        // A real file (not our symlink) means someone else's `termio` — leave it.
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink,
              let destination = try? fileManager.destinationOfSymbolicLink(atPath: path) else {
            return .conflict
        }
        let resolved = URL(fileURLWithPath: destination).standardizedFileURL.path
        if resolved == supportCopyURL.standardizedFileURL.path {
            return copyUsable ? .installed : .stale(resolved)
        }
        // A link into any app bundle is a pre-copy install (or a moved app); update it.
        if resolved.hasSuffix("/Contents/Resources/\(toolName)") { return .stale(resolved) }
        return .conflict
    }

    /// Links the stable tool copy onto PATH and returns the fresh audit. Replaces
    /// our own stale link; refuses to overwrite a file we did not create.
    @discardableResult
    static func install() -> Status {
        guard refreshSupportCopy() else { return .unavailable }
        if case .conflict = audit() { return .conflict }
        let target = installURL.path
        if linkWithoutPrivileges(from: supportCopyURL.path, to: target) { return audit() }
        linkWithAdminPrompt(from: supportCopyURL.path, to: target)
        return audit()
    }

    private static func linkWithoutPrivileges(from source: String, to target: String) -> Bool {
        let fileManager = FileManager.default
        let directory = (target as NSString).deletingLastPathComponent
        try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard fileManager.isWritableFile(atPath: directory) else { return false }
        // Replace our own previous link (createSymbolicLink fails if a file exists).
        try? fileManager.removeItem(atPath: target)
        do {
            try fileManager.createSymbolicLink(atPath: target, withDestinationPath: source)
            return true
        } catch {
            return false
        }
    }

    /// One authorization prompt does `mkdir -p` + `ln -sf` as admin, for the case
    /// where `/usr/local/bin` is root-owned. The user can cancel, in which case the
    /// follow-up audit simply reports it still isn't installed.
    private static func linkWithAdminPrompt(from source: String, to target: String) {
        let directory = (target as NSString).deletingLastPathComponent
        let command = "mkdir -p \(shellQuote(directory)) && ln -sf \(shellQuote(source)) \(shellQuote(target))"
        let script = "do shell script \"\(command)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            FileHandle.standardError.write(
                Data("termio: command-line tool install declined or failed: \(error)\n".utf8))
        }
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

