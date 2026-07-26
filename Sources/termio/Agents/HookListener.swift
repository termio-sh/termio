import Darwin
import Foundation

/// A normalized status report sent by an agent's hook into termio's local socket.
/// The agent-specific knowledge ("this lifecycle event means the agent is now
/// working") is baked into the hook command installed per agent, so every agent
/// speaks the same tiny vocabulary and termio needs no per-agent parsing:
///
/// - `termioSession` — the `TERMIO_SESSION` env value termio stamped into the PTY
///   (see `TermioStore.surface`), echoed back so the event maps to the exact
///   session even when several share one project directory.
/// - `state` — one of `working` / `attention` / `done` / `idle`.
/// - `cwd` — the agent's working directory, a correlation fallback for any agent
///   whose environment didn't carry `TERMIO_SESSION` through to the hook.
struct StatusReport: Decodable {
    let termioSession: String?
    let state: String
    let tool: String?
    let cwd: String?
    /// The agent's own conversation log for this session (Claude Code's
    /// `transcript_path`), forwarded by the hook so termio can hand a caller the
    /// address of the raw Q&A instead of scraping the terminal. Absent for agents
    /// whose hook doesn't carry it.
    let transcriptPath: String?
    /// The agent's own id for the conversation this session is currently writing,
    /// forwarded by hooks/plugins whose host exposes it (the manifest's
    /// `hooks.conversation` locator). Lets termio advance the resume pin the moment
    /// the agent rotates conversations in-process (`/new`), without needing the id
    /// to be encoded in a transcript filename. Absent for identity-blind hooks.
    let conversationID: String?

    private enum CodingKeys: String, CodingKey {
        case termioSession = "termio_session"
        case state
        case tool
        case cwd
        case transcriptPath = "transcript_path"
        case conversationID = "conversation_id"
    }
}

/// A local Unix-domain socket that agent hooks report into. This is what gives
/// termio per-turn activity ("working", the rotating spinner): the zero-config
/// bell/OSC signals fire on command *finish*, never *start*, so "is the agent
/// thinking right now" can't be inferred from them alone. Each agent's hook
/// command (installed by `AgentStatusHooks`) pipes a `StatusReport` straight here.
///
/// This type owns only the transport: it decodes one `StatusReport` per connection
/// and hands it to `onReport` on the main actor. Correlating a report to a session
/// and the resulting state transition live in `TermioStore`.
final class HookListener {
    /// The socket file, under termio's Application Support directory — the same
    /// place the session tree is saved.
    static var socketURL: URL {
        AppChannel.supportDirectory.appendingPathComponent("agent-status.sock")
    }

    private let onReport: @MainActor (StatusReport) -> Void
    private let queue = DispatchQueue(label: "com.termio.hook-listener")
    private var source: DispatchSourceRead?
    private var listenDescriptor: Int32 = -1

    init(onReport: @escaping @MainActor (StatusReport) -> Void) {
        self.onReport = onReport
    }

    /// Binds the socket and begins accepting connections. All socket work happens
    /// on a private serial queue; failures are logged and degrade to "no hook
    /// signal" rather than trapping, per the project's no-crash rule.
    func start() {
        queue.async { [weak self] in self?.bindAndListen() }
    }

    private func bindAndListen() {
        let url = Self.socketURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = url.path
        // A stale socket file from a previous run would make bind() fail with
        // EADDRINUSE, so clear it first. (Errors here are fine — it may not exist.)
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
        // Non-blocking listen socket so the accept loop drains every pending
        // connection per readable event and then stops cleanly on EAGAIN.
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
        defer { close(descriptor) }
        // A receive timeout is the backstop for a client that connects and then
        // neither sends a full payload nor closes — it can't wedge the queue.
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        // Decode after each chunk so we react the instant a complete JSON object
        // has arrived, regardless of whether the sender (`nc`) keeps the
        // connection open afterwards. The cap guards against a runaway stream.
        while data.count < 64 * 1024 {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
            if let report = Self.decode(data) { Self.trace(data); dispatch(report); return }
        }
        Self.trace(data)
        if let report = Self.decode(data) { dispatch(report) }
    }

    /// Temporary diagnostic: append every raw payload received on the socket to a
    /// debug file, so we can see whether an agent (notably Codex's interactive TUI)
    /// fires its hooks at all and whether `termio_session` survives into the hook's
    /// environment. Enabled only when `TERMIO_HOOK_TRACE` is set, so it costs nothing
    /// in normal runs. Remove once the Codex-TUI question is settled.
    private static func trace(_ data: Data) {
        guard ProcessInfo.processInfo.environment["TERMIO_HOOK_TRACE"] != nil else { return }
        let text = String(data: data, encoding: .utf8) ?? "<\(data.count) non-utf8 bytes>"
        let line = "[\(Date())] decoded=\(decode(data) != nil) raw=\(text)\n"
        let url = URL(fileURLWithPath: "/tmp/termio-hooks.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private static func decode(_ data: Data) -> StatusReport? {
        try? JSONDecoder().decode(StatusReport.self, from: data)
    }

    private func dispatch(_ report: StatusReport) {
        let handler = onReport
        Task { @MainActor in handler(report) }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("termio: hook listener \(message)\n".utf8))
    }
}

/// Installs (and removes) the per-agent integrations that report a session's
/// activity into `HookListener`. Each agent has a different lifecycle mechanism —
/// Claude Code and Codex run shell hooks, OpenCode and Pi load a small plugin — but
/// they all speak one wire format: a normalized `{termio_session, state}` object
/// piped into the socket, with the state ("working"/"attention"/"done") fixed per
/// event. The session id rides in via the `TERMIO_SESSION` the PTY carries, so
/// correlation is exact regardless of agent or shared directory.
///
/// Conservative by construction: each installer preserves the user's existing
/// config, only ever adds/removes entries it recognizes as its own (their command
/// contains the socket filename), and refuses to overwrite a file it can't parse.
enum AgentStatusHooks {
    /// The substring that identifies a *legacy* raw-socket entry as termio's — the
    /// `printf … | nc -U …/agent-status.sock` hooks older builds installed, and the
    /// `// Socket marker: …` comment still embedded in the plugin files. Kept so a new
    /// build strips any leftover raw-nc hooks before writing its CLI-based ones.
    static let marker = "agent-status.sock"

    /// The substring that identifies a current, CLI-based hook as termio's: every hook
    /// termio now installs invokes the public `termio agent report <state>` contract, so
    /// the ` agent report ` fragment is our fingerprint. Strip logic matches either this
    /// or the legacy `marker`, so upgrades cleanly replace old hooks with new ones.
    static let cliMarker = "agent report"

    /// Re-applies every agent's integration (or removes them all) to match `enabled`.
    static func sync(enabled: Bool) {
        // Every hook references the channel-stable CLI copy, so make sure it carries
        // this build's content before (re)stamping its path anywhere.
        CommandLineTool.refreshSupportCopy()
        if enabled {
            // A full user override may intentionally remove/redirect a shipped hook.
            // Remove that old managed wiring before installing the merged catalog.
            for installer in staleBundledInstallers { installer.uninstall() }
            for installer in installers { installer.install() }
        } else {
            for installer in allKnownInstallers { installer.uninstall() }
        }
    }

    private static var installers: [AgentStatusInstaller] {
        AgentCatalog.shared.all.compactMap { agent in
            agent.hookSpec.flatMap { installer(id: agent.id, spec: $0) }
        }
    }

    private static var staleBundledInstallers: [AgentStatusInstaller] {
        AgentCatalog.shared.staleBundledHookSpecs.compactMap { installer(id: "bundled", spec: $0) }
    }

    private static var allKnownInstallers: [AgentStatusInstaller] {
        let specs = AgentCatalog.shared.bundled.compactMap(\.hookSpec)
            + AgentCatalog.shared.all.compactMap(\.hookSpec)
        return Set(specs).compactMap { installer(id: "catalog", spec: $0) }
    }

    private static func installer(id: String, spec: AgentHookSpec) -> AgentStatusInstaller? {
        switch spec.type {
        case .json: return JSONHookFile.manifest(id: id, spec: spec)
        case .toml: return TOMLHookBlock.manifest(id: id, spec: spec)
        case .plugin: return PluginFile.manifest(id: id, spec: spec)
        }
    }

    /// The shell command a hook runs: invoke the public `termio agent report <state>`
    /// contract, which reads the session id ($TERMIO_SESSION the PTY carries) and cwd
    /// ($PWD), then writes the normalized report to the status socket. This replaces the
    /// per-dialect `printf … | nc` termio used to bake into every hook file; the socket
    /// path and JSON shaping now live behind the one documented command (see
    /// `scripts/termio`, and the design doc §4). Used by the shell-hook agents and
    /// stamped into the plugin agents' JavaScript too, so every installer converges on
    /// the same contract.
    ///
    /// The stamped path is the channel-stable CLI copy — never the bundle, whose
    /// location can vanish (a dev build launched from a deleted git worktree). The CLI
    /// broadcasts each report to every channel's status socket, so which channel's copy
    /// a hook happens to invoke doesn't matter; the receiving apps route by session id.
    /// Status reporting stays best-effort either way: the whole command degrades to a
    /// silent no-op if the copy is missing, instead of spamming every agent turn with
    /// hook-failure noise.
    static func reportCommand(
        state: String, withTranscript: Bool = false, conversationField: String? = nil,
        toolField: String? = nil, dialect: HookDialect = .claudeNested
    ) -> String {
        var command = "\(shellQuote(cliPath)) agent report \(state)"
        // Claude feeds each hook a JSON blob on stdin carrying `transcript_path`; the
        // CLI mines it out (jq-free) so termio can address the raw Q&A log. Only enabled
        // for agents that reliably provide stdin, so the CLI's `cat` can't block.
        if withTranscript { command += " --transcript" }
        // Some agents' stdin blob also names the live conversation id (Codex
        // `session_id`, Grok `sessionId`); the manifest declares the field and the CLI
        // mines it, so termio can follow an in-process `/new` rotation. Same stdin
        // caveat as `--transcript`. The field name is validated at manifest load to be
        // a bare identifier, so it embeds safely.
        if let conversationField { command += " --conversation-from \(conversationField)" }
        // Tool events' stdin blob names the running tool (Claude `tool_name`); the
        // CLI mines it so reports can tell real work from a prose-only turn. Events
        // whose blob lacks the field simply omit it — same stdin caveat as above.
        if let toolField { command += " --tool-from \(toolField)" }
        // Cursor reads the hook's stdout as its JSON reply, so the CLI must stay silent
        // and print a benign `{}`. (Claude/Codex ignore hook stdout, so they don't.)
        // The fallback keeps that contract even when the CLI itself couldn't run.
        if dialect == .cursorFlat {
            command += " --reply 2>/dev/null || printf '{}'"
        } else {
            command += " 2>/dev/null || true"
        }
        return command
    }

    /// Absolute path to this channel's stable `termio`/`termio-dev` CLI copy under
    /// Application Support (see `CommandLineTool.supportCopyURL`), stamped into each
    /// hook command so it resolves regardless of PATH, the `/usr/local/bin` symlink,
    /// or where the app bundle happens to live.
    static var cliPath: String {
        CommandLineTool.supportCopyURL.path
    }

    /// Single-quotes a path for safe embedding in a hook shell command (the bundle path
    /// can contain spaces, e.g. under `/Applications/termio dev.app`).
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("termio: agent hooks \(message)\n".utf8))
    }
}

private protocol AgentStatusInstaller {
    func install()
    func uninstall()
}

/// The on-disk shape of a JSON hook file. Agents that configure hooks via a JSON
/// file still disagree on structure, so the installer branches on this.
enum HookDialect: Hashable {
    /// Claude Code / Codex: `{ "hooks": { "<Event>": [ { "matcher"?, "hooks": [ {type,command} ] } ] } }`,
    /// and the agent ignores the hook's stdout.
    case claudeNested
    /// Cursor: `{ "version": 1, "hooks": { "<Event>": [ { "command" } ] } }` — a
    /// required top-level `version`, flat one-key entries, and the hook's stdout is
    /// read back as its JSON reply (so the report prints a clean empty object).
    case cursorFlat
    /// Kimi's marker-delimited TOML array-of-tables block.
    case kimiTOML
    /// Shipped plugin templates. Each names a closed host API; manifests provide
    /// only the destination directory and event→state data.
    case openCodePlugin
    case piPlugin
    case ampPlugin
}

/// Installs hooks for agents whose config is a JSON file with the Claude-Code
/// shape — `{ "hooks": { "<Event>": [ { "matcher"?, "hooks": [ {type,command} ] } ] } }`.
/// Claude Code (`~/.claude/settings.json`) and Codex (`~/.codex/hooks.json`) both
/// use exactly this structure, differing only in path and event names.
private struct JSONHookFile: AgentStatusInstaller {
    let url: URL
    /// `(event name, normalized state, matcher)`. `matcher` is `"*"` for Claude's
    /// tool events (the shape it expects) and `nil` everywhere else — Codex treats
    /// a missing matcher as "match every occurrence".
    let events: [AgentHookEvent]
    let label: String
    /// Whether this agent's hooks pass a JSON payload on stdin we can mine for the
    /// session's `transcript_path`. Only enabled for agents verified to always
    /// supply stdin (Claude Code, Codex), so the capturing `cat` can't block.
    var capturesTranscript: Bool = false
    /// The stdin JSON field naming the live conversation id (`hooks.conversation`
    /// in the manifest), or `nil` for identity-blind hooks. Same stdin caveat as
    /// `capturesTranscript`.
    var conversationField: String?
    /// The stdin JSON field naming the tool a hook event fires for (`hooks.tool`
    /// in the manifest), or `nil` when the agent exposes none. Same stdin caveat.
    var toolField: String?
    /// The file's structural shape (see `HookDialect`). Defaults to Claude's, which
    /// Codex also uses; Cursor overrides it.
    var dialect: HookDialect = .claudeNested
    /// Dedicated `termio.json` files can disappear when their last managed hook is
    /// removed. Shared host files such as `settings.json` must remain in place.
    var removesFileWhenEmpty = false
    /// Previous termio-owned filenames to strip during both install and uninstall.
    /// Keeping this on the installer prevents a rename from loading duplicate hooks.
    var legacyURLs: [URL] = []

    static func manifest(id: String, spec: AgentHookSpec) -> JSONHookFile? {
        guard spec.type == .json, let file = spec.file else {
            AgentStatusHooks.log("\(id): incomplete JSON hook manifest")
            return nil
        }
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        let isDedicatedTermioFile = url.lastPathComponent == "termio.json"
        let legacyURLs = isDedicatedTermioFile
            ? [url.deletingLastPathComponent().appendingPathComponent("termio-status.json")]
            : []
        return JSONHookFile(
            url: url,
            events: spec.events,
            label: id,
            capturesTranscript: spec.capturesTranscript,
            conversationField: spec.conversation,
            toolField: spec.tool,
            dialect: spec.dialect,
            removesFileWhenEmpty: isDedicatedTermioFile,
            legacyURLs: legacyURLs)
    }

    private enum FileState {
        case missing
        case unreadable
        case ok([String: Any])
    }

    func install() {
        let root: [String: Any]
        switch readState(at: url) {
        case .ok(let dictionary): root = dictionary
        case .missing: root = [:]
        case .unreadable:
            AgentStatusHooks.log("refusing to modify unparseable \(url.path)")
            return
        }

        var settings = root
        // Cursor requires a top-level schema version; add it only when the user's
        // file doesn't already carry one, so we never overwrite their choice.
        if dialect == .cursorFlat, settings["version"] == nil { settings["version"] = 1 }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        // Strip every prior termio entry first — across all events, not just the
        // ones we're about to re-add — so an event we no longer manage (e.g. a
        // mapping we dropped between versions) doesn't leave an orphan behind.
        stripTermioEntries(from: &hooks)
        for event in events {
            var groups = hooks[event.name] as? [[String: Any]] ?? []
            let command = AgentStatusHooks.reportCommand(
                state: event.state, withTranscript: capturesTranscript,
                conversationField: conversationField, toolField: toolField, dialect: dialect)
            let group: [String: Any]
            if dialect == .cursorFlat {
                group = ["command": command]
            } else {
                var nested: [String: Any] = ["hooks": [["type": "command", "command": command]]]
                if let matcher = event.matcher { nested["matcher"] = matcher }
                group = nested
            }
            groups.append(group)
            hooks[event.name] = groups
        }
        settings["hooks"] = hooks
        write(settings, to: url)

        // Publish the replacement before removing its predecessor. If the new file
        // could not be written, retain the working legacy integration for next launch.
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        for legacyURL in legacyURLs {
            uninstall(at: legacyURL, removeFileWhenEmpty: true)
        }
    }

    func uninstall() {
        uninstall(at: url, removeFileWhenEmpty: removesFileWhenEmpty)
        for legacyURL in legacyURLs {
            uninstall(at: legacyURL, removeFileWhenEmpty: true)
        }
    }

    private func uninstall(at candidateURL: URL, removeFileWhenEmpty: Bool) {
        // Nothing to remove if the file is absent; never overwrite one we can't read.
        guard case .ok(let root) = readState(at: candidateURL) else { return }
        var settings = root
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        stripTermioEntries(from: &hooks)
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        if removeFileWhenEmpty, settings.isEmpty {
            do {
                try FileManager.default.removeItem(at: candidateURL)
            } catch {
                AgentStatusHooks.log("could not remove \(candidateURL.path): \(error)")
            }
        } else {
            write(settings, to: candidateURL)
        }
    }

    /// Removes termio's own groups from every hook event, dropping any event left
    /// with no groups. Identifying our entries by the socket marker means user
    /// hooks are never touched.
    private func stripTermioEntries(from hooks: inout [String: Any]) {
        for key in Array(hooks.keys) {
            guard var groups = hooks[key] as? [[String: Any]] else { continue }
            groups.removeAll { isTermioGroup($0) }
            if groups.isEmpty {
                hooks.removeValue(forKey: key)
            } else {
                hooks[key] = groups
            }
        }
    }

    private func isTermioGroup(_ group: [String: Any]) -> Bool {
        // Recognize both the current CLI-based hook (` agent report `) and any legacy
        // raw-socket hook (`…/agent-status.sock`) an older build left, so an upgrade
        // strips the old before writing the new instead of doubling up. Cursor's flat
        // entry carries the command directly; Claude/Codex nest it.
        func isOurs(_ command: String) -> Bool {
            command.contains(AgentStatusHooks.cliMarker) || command.contains(AgentStatusHooks.marker)
        }
        if let command = group["command"] as? String { return isOurs(command) }
        guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String).map(isOurs) == true }
    }

    private func readState(at candidateURL: URL) -> FileState {
        guard FileManager.default.fileExists(atPath: candidateURL.path) else { return .missing }
        guard let data = try? Data(contentsOf: candidateURL) else { return .unreadable }
        if data.isEmpty { return .missing }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return .unreadable }
        return .ok(dictionary)
    }

    private func write(_ settings: [String: Any], to destinationURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            // Skip the write when the result is byte-identical to what's already
            // there (the common case on every launch): avoids needless churn on a
            // user-owned file and shrinks the window where this atomic write could
            // clobber a concurrent hand-edit. `.sortedKeys` makes the bytes stable.
            if (try? Data(contentsOf: destinationURL)) == data { return }
            try data.write(to: destinationURL, options: .atomic)
        } catch {
            AgentStatusHooks.log("could not write \(destinationURL.path): \(error)")
        }
    }
}

/// Installs agents whose integration is a single dropped-in plugin/extension file
/// (no host config to merge): OpenCode loads a plugin from `~/.config/opencode/plugin/`,
/// Pi an extension from `~/.pi/agent/extensions/`. Both run in-process in the PTY,
/// so they read `TERMIO_SESSION` from the environment and emit the same normalized
/// report into the socket — OpenCode via its session lifecycle events, Pi via
/// `agent_start`/`agent_end`. Uninstall removes the file only if it's ours.
private struct PluginFile: AgentStatusInstaller {
    let url: URL
    let contents: String
    let legacyURLs: [URL]

    static func manifest(id: String, spec: AgentHookSpec) -> PluginFile? {
        guard spec.type == .plugin, let directory = spec.directory else {
            AgentStatusHooks.log("\(id): incomplete plugin hook manifest")
            return nil
        }
        let filename: String
        let legacyFilename: String
        let contents: String
        switch spec.dialect {
        case .openCodePlugin:
            filename = "termio.js"
            legacyFilename = "termio-status.js"
            contents = openCodeSource(events: spec.events, conversationPath: spec.conversation)
        case .piPlugin:
            filename = "termio.js"
            legacyFilename = "termio-status.js"
            contents = piSource(events: spec.events, conversation: spec.conversation)
        case .ampPlugin:
            filename = "termio.ts"
            legacyFilename = "termio-status.ts"
            contents = ampSource(events: spec.events)
        default:
            AgentStatusHooks.log("\(id): hook dialect is not a plugin template")
            return nil
        }
        let expanded = (directory as NSString).expandingTildeInPath
        let directoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
        return PluginFile(
            url: directoryURL.appendingPathComponent(filename),
            contents: contents,
            legacyURLs: [directoryURL.appendingPathComponent(legacyFilename)])
    }

    func install() {
        let data = Data(contents.utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            // `termio.js` is a deliberately simple name, so never claim a user's
            // pre-existing file merely because it occupies our desired path.
            guard let existing = try? String(contentsOf: url, encoding: .utf8),
                  existing == contents || isOwned(existing)
            else {
                AgentStatusHooks.log("refusing to overwrite non-termio plugin \(url.path)")
                return
            }
        }
        if (try? Data(contentsOf: url)) != data {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                AgentStatusHooks.log("could not write \(url.path): \(error)")
                return
            }
        }
        for legacyURL in legacyURLs {
            removeOwnedFile(at: legacyURL)
        }
    }

    func uninstall() {
        removeOwnedFile(at: url)
        for legacyURL in legacyURLs {
            removeOwnedFile(at: legacyURL)
        }
    }

    private func removeOwnedFile(at candidateURL: URL) {
        // Only remove a file we recognize as ours, so a user file that happens to
        // share the name is never deleted.
        guard let existing = try? String(contentsOf: candidateURL, encoding: .utf8),
              isOwned(existing) else { return }
        do {
            try FileManager.default.removeItem(at: candidateURL)
        } catch {
            AgentStatusHooks.log("could not remove \(candidateURL.path): \(error)")
        }
    }

    private func isOwned(_ source: String) -> Bool {
        source.contains(AgentStatusHooks.marker)
            || source.contains(AgentStatusHooks.cliMarker)
    }

    private static var cliPath: String { AgentStatusHooks.cliPath }

    /// OpenCode plugin: a session is `busy` while working and emits `session.idle`
    /// when the turn ends; `permission.updated` means it's waiting on the user. Each
    /// maps to the public report contract shelled out via Bun's `$`. The session id
    /// comes from `TERMIO_SESSION`, which the PTY carries into the in-process plugin.
    ///
    /// `conversationPath` (the manifest's `hooks.conversation`) is the dot key path
    /// in the event object naming OpenCode's own conversation id; when set, each
    /// report also carries it so termio can follow an in-process new-session
    /// rotation. Subagent child sessions share this event bus, and adopting a
    /// child's id would mis-pin the tab, so the plugin learns which ids are
    /// top-level from `session.created`/`session.updated` (child sessions carry
    /// `parentID`) and forwards only those.
    private static func openCodeSource(events: [AgentHookEvent], conversationPath: String?) -> String {
        let conversationExpression = conversationPath.map { path in
            "event" + path.split(separator: ".").map { "?.\($0)" }.joined()
        }
        let branches = events.map { event in
            let eventName = jsString(event.name)
            let state = jsString(event.state)
            let arguments = conversationExpression.map { "\(state), \($0)" } ?? state
            if let matcher = event.matcher {
                return "      if (event.type === \(eventName) && event.properties?.status?.type === \(jsString(matcher))) return report(\(arguments));"
            }
            return "      if (event.type === \(eventName)) return report(\(arguments));"
        }.joined(separator: "\n")
        let identity = conversationExpression == nil ? "" : """

          const roots = new Set();
          const note = (info) => {
            if (!info?.id) return;
            if (info.parentID) roots.delete(info.id); else roots.add(info.id);
          };
        """
        let identityBranches = conversationExpression == nil ? "" : """
              if (event.type === "session.created" || event.type === "session.updated") return note(event.properties?.info);
              if (event.type === "session.deleted") return roots.delete(event.properties?.info?.id);

        """
        let reportBody = conversationExpression == nil ? """
            return $`${cli} agent report ${state}`.quiet().nothrow();
        """ : """
            if (conversation && roots.has(conversation)) {
              return $`${cli} agent report ${state} --conversation ${conversation}`.quiet().nothrow();
            }
            return $`${cli} agent report ${state}`.quiet().nothrow();
        """
        let reportParameters = conversationExpression == nil ? "(state)" : "(state, conversation)"
        return """
        // termio agent status — reports OpenCode session lifecycle to termio.
        // Socket marker: \(AgentStatusHooks.marker)
        export const TermioStatus = async ({ $ }) => {
          const cli = \(jsString(cliPath));\(identity)
          const report = \(reportParameters) => {
        \(reportBody)
          };
          return {
            event: async ({ event }) => {
        \(identityBranches)\(branches)
            },
          };
        };
        """
    }

    /// Pi extension: `agent_start` fires when a turn begins, `agent_end` when it
    /// returns to the user. Pi has no shell-hook config, so the extension itself
    /// shells out via `pi.exec`; the session id rides in on `TERMIO_SESSION`.
    ///
    /// `conversation == "context"` (the manifest's `hooks.conversation`) means Pi's
    /// own conversation id is read from the extension context's session manager and
    /// forwarded with each report, so termio can follow an in-process `/new`
    /// rotation (Pi reloads extensions with a fresh context when it switches
    /// sessions). The id is embedded in a shell command, so it is forwarded only
    /// when it looks like a bare token — Pi's uuidv7 ids always do.
    private static func piSource(events: [AgentHookEvent], conversation: String?) -> String {
        guard conversation != nil else {
            let listeners = events.map { event in
                let command = AgentStatusHooks.reportCommand(state: event.state)
                return "  pi.on(\(jsString(event.name)), () => pi.exec(\"sh\", [\"-c\", \(jsString(command))]));"
            }.joined(separator: "\n")
            return """
            // termio agent status — reports Pi turn lifecycle to termio.
            // Socket marker: \(AgentStatusHooks.marker)
            export default (pi) => {
            \(listeners)
            };
            """
        }
        let listeners = events.map { event in
            "  pi.on(\(jsString(event.name)), (_event, context) => report(\(jsString(event.state)), context));"
        }.joined(separator: "\n")
        return """
        // termio agent status — reports Pi turn lifecycle to termio.
        // Socket marker: \(AgentStatusHooks.marker)
        export default (pi) => {
          const cli = \(jsString(AgentStatusHooks.shellQuote(cliPath)));
          const report = (state, context) => {
            const id = context?.sessionManager?.getSessionId?.();
            const conversation = id && /^[A-Za-z0-9._-]+$/.test(id) ? ` --conversation ${id}` : "";
            pi.exec("sh", ["-c", `${cli} agent report ${state}${conversation} 2>/dev/null || true`]);
          };
        \(listeners)
        };
        """
    }

    /// Amp plugin: `agent.start` fires when the user submits a prompt, `agent.end`
    /// when the agent finishes handling it. Amp auto-loads any plugin under
    /// `~/.config/amp/plugins/` (a default-exported function receiving the plugin
    /// API), runs on Bun, and exposes Bun's `$` shell as `amp.$`; the session id
    /// rides in on `TERMIO_SESSION` from the PTY. `.quiet().nothrow()` keeps it a
    /// silent no-op when termio isn't listening.
    private static func ampSource(events: [AgentHookEvent]) -> String {
        let listeners = events.map { event in
            "  amp.on(\(jsString(event.name)), () => report(\(jsString(event.state))));"
        }.joined(separator: "\n")
        return """
        // termio agent status — reports Amp turn lifecycle to termio.
        // Socket marker: \(AgentStatusHooks.marker)
        export default (amp) => {
          const cli = \(jsString(cliPath));
          const report = (state) => {
            return amp.$`${cli} agent report ${state}`.quiet().nothrow();
          };
        \(listeners)
        };
        """
    }

    /// JSON-encodes a string for safe embedding as a JavaScript string literal.
    private static func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}

/// Installs hooks for agents that declare them as TOML `[[hooks]]` tables inside
/// their main config file — currently just Kimi Code (`~/.kimi/config.toml`).
///
/// There's no structured merge like the JSON agents get: TOML arrays of tables may
/// be non-contiguous, so termio appends one marker-delimited block at the end of the
/// file and strips it back out by its markers on reinstall/uninstall. Only bytes
/// between the markers are ever touched, so the user's providers, keys, and their own
/// `[[hooks]]` are never disturbed — the same conservative contract as `JSONHookFile`,
/// but without needing a TOML parser. Kimi reads a hook's exit code (0 = allow), and
/// the shared report command ends in `|| true`, so the standard command is safe on
/// Kimi's blockable events — no clean-stdout handling is required.
private struct TOMLHookBlock: AgentStatusInstaller {
    let url: URL
    let events: [AgentHookEvent]

    private static let blockBegin = "# >>> termio agent-status hooks (managed — do not edit) >>>"
    private static let blockEnd = "# <<< termio agent-status hooks <<<"

    static func manifest(id: String, spec: AgentHookSpec) -> TOMLHookBlock? {
        guard spec.type == .toml, spec.dialect == .kimiTOML, let file = spec.file else {
            AgentStatusHooks.log("\(id): incomplete TOML hook manifest")
            return nil
        }
        return TOMLHookBlock(
            url: URL(fileURLWithPath: (file as NSString).expandingTildeInPath),
            events: spec.events)
    }

    func install() {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let base = Self.stripBlock(from: existing).trimmingCharacters(in: .newlines)
        let block = Self.render(events: events)
        let updated = base.isEmpty ? block + "\n" : base + "\n\n" + block + "\n"
        Self.write(updated, to: url)
    }

    func uninstall() {
        guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return }
        let base = Self.stripBlock(from: existing).trimmingCharacters(in: .newlines)
        Self.write(base.isEmpty ? "" : base + "\n", to: url)
    }

    /// The termio-managed block: a comment banner around one `[[hooks]]` table per
    /// event. The command is embedded as a TOML multi-line literal string (`'''…'''`)
    /// so the shell one-liner's single and double quotes need no escaping — it never
    /// contains three consecutive single quotes.
    private static func render(events: [AgentHookEvent]) -> String {
        var lines = [blockBegin]
        for event in events {
            let command = AgentStatusHooks.reportCommand(state: event.state)
            lines.append("[[hooks]]")
            lines.append("event = \"\(event.name)\"")
            if let matcher = event.matcher { lines.append("matcher = \"\(matcher)\"") }
            lines.append("command = '''\(command)'''")
            lines.append("timeout = 5")
            lines.append("")
        }
        if lines.last == "" { lines.removeLast() }
        lines.append(blockEnd)
        return lines.joined(separator: "\n")
    }

    /// Removes a previously written termio block (markers inclusive). If both markers
    /// aren't present the text is returned unchanged, so a hand-edited file is never
    /// mangled.
    private static func stripBlock(from text: String) -> String {
        guard let begin = text.range(of: blockBegin),
              let end = text.range(of: blockEnd, range: begin.upperBound..<text.endIndex)
        else { return text }
        var result = text
        result.removeSubrange(begin.lowerBound..<end.upperBound)
        return result
    }

    private static func write(_ contents: String, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(contents.utf8)
            // No-op when the result is byte-identical (the common case each launch).
            if (try? Data(contentsOf: url)) == data { return }
            try data.write(to: url, options: .atomic)
        } catch {
            AgentStatusHooks.log("could not write \(url.path): \(error)")
        }
    }
}
