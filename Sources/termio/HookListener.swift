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

    private enum CodingKeys: String, CodingKey {
        case termioSession = "termio_session"
        case state
        case tool
        case cwd
        case transcriptPath = "transcript_path"
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

    func stop() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
        }
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
    /// The substring that identifies an entry as termio's, used to find and strip
    /// our own without disturbing the user's.
    static let marker = "agent-status.sock"

    /// Re-applies every agent's integration (or removes them all) to match `enabled`.
    static func sync(enabled: Bool) {
        for installer in installers {
            if enabled { installer.install() } else { installer.uninstall() }
        }
    }

    private static var installers: [AgentStatusInstaller] {
        var installers: [AgentStatusInstaller] = [
            JSONHookFile.claude,
            JSONHookFile.codex,
            JSONHookFile.cursor,
            JSONHookFile.grok,
            TOMLHookBlock.kimi,
            PluginFile.openCode,
            PluginFile.pi,
            PluginFile.amp,
        ]
        // User agents that declared a JSON-hook-file integration in `agent.json` get
        // the exact same installer as the built-ins — the config supplies only the file
        // path and event→state map, and termio writes the report commands. Plugin-API
        // agents can't be expressed this way and simply carry no `hookSpec`.
        for agent in AgentCatalog.shared.all {
            if let spec = agent.hookSpec {
                installers.append(JSONHookFile.userAgent(id: agent.id, spec: spec))
            }
        }
        return installers
    }

    /// The shell command a hook runs: emit the normalized report (stamped with the
    /// session id the PTY carries and the agent's `$PWD` as a fallback) and pipe it
    /// into the socket. `nc` and `printf` both ship with macOS. Used by the
    /// shell-hook agents; the plugin agents emit the same JSON from JavaScript.
    static func reportCommand(
        state: String, withTranscript: Bool = false, dialect: HookDialect = .claudeNested
    ) -> String {
        let socket = HookListener.socketURL.path
        // Cursor spawns each hook as a process and reads its stdout as the hook's
        // JSON reply, so the report must reach the socket silently and then print a
        // benign empty object — any stray byte on stdout is parsed as a malformed
        // reply. (Claude/Codex ignore hook stdout, so they don't need this.)
        if dialect == .cursorFlat {
            let json = #"{"termio_session":"%s","state":"\#(state)","cwd":"%s"}"#
            return "printf '\(json)' \"$TERMIO_SESSION\" \"$PWD\" | nc -w 1 -U \"\(socket)\" >/dev/null 2>&1; printf '{}'"
        }
        // `|| true` and `2>/dev/null` keep the hook a silent no-op when termio
        // isn't running to accept the connection — otherwise `nc`'s exit 1 surfaces
        // in the agent as a "hook failed (non-blocking)" error on every tool call.
        // `-w 1` bounds the connect so a wedged socket can't stall the agent.
        guard withTranscript else {
            let json = #"{"termio_session":"%s","state":"\#(state)","cwd":"%s"}"#
            return "printf '\(json)' \"$TERMIO_SESSION\" \"$PWD\" | nc -w 1 -U \"\(socket)\" 2>/dev/null || true"
        }
        // Claude Code feeds each hook a JSON object on stdin that includes
        // `transcript_path` — the session's full Q&A log. Capture it and forward it so
        // termio can map this session to its transcript (the address a caller records
        // and reads, instead of scraping the terminal). `grep -o`/`sed` keep this
        // jq-free; an absent field just yields an empty path. Only enabled for agents
        // whose hook reliably provides stdin, so the `cat` can't block.
        let json = #"{"termio_session":"%s","state":"\#(state)","cwd":"%s","transcript_path":"%s"}"#
        let extract = #"grep -o '"transcript_path":"[^"]*"' | head -1 | sed 's/.*:"//;s/"$//'"#
        return "input=$(cat); tp=$(printf '%s' \"$input\" | \(extract)); "
            + "printf '\(json)' \"$TERMIO_SESSION\" \"$PWD\" \"$tp\" | nc -w 1 -U \"\(socket)\" 2>/dev/null || true"
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
enum HookDialect {
    /// Claude Code / Codex: `{ "hooks": { "<Event>": [ { "matcher"?, "hooks": [ {type,command} ] } ] } }`,
    /// and the agent ignores the hook's stdout.
    case claudeNested
    /// Cursor: `{ "version": 1, "hooks": { "<Event>": [ { "command" } ] } }` — a
    /// required top-level `version`, flat one-key entries, and the hook's stdout is
    /// read back as its JSON reply (so the report prints a clean empty object).
    case cursorFlat
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
    let events: [(name: String, state: String, matcher: String?)]
    let label: String
    /// Whether this agent's hooks pass a JSON payload on stdin we can mine for the
    /// session's `transcript_path`. Only Claude Code is known to (and to always
    /// supply stdin, so the capturing `cat` can't block); others stay off.
    var capturesTranscript: Bool = false
    /// The file's structural shape (see `HookDialect`). Defaults to Claude's, which
    /// Codex also uses; Cursor overrides it.
    var dialect: HookDialect = .claudeNested

    static var claude: JSONHookFile {
        JSONHookFile(
            url: home(".claude", "settings.json"),
            events: [
                ("UserPromptSubmit", "working", nil),
                ("PreToolUse", "working", "*"),
                ("PostToolUse", "working", "*"),
                // Only an explicit permission prompt is "attention"; Claude's
                // generic `Notification` also fires for idle waiting, which would
                // wrongly turn a just-finished (`done`) turn orange. The zero-config
                // bell/OSC layer still catches any notification the agent raises, so
                // dropping it here loses no real "needs you" signal.
                ("PermissionRequest", "attention", "*"),
                ("Stop", "done", nil),
                // A subagent finishing means the parent turn is still in flight.
                ("SubagentStop", "working", nil),
            ],
            label: "claude",
            capturesTranscript: true)
    }

    static var codex: JSONHookFile {
        JSONHookFile(
            url: home(".codex", "hooks.json"),
            events: [
                ("UserPromptSubmit", "working", nil),
                ("PreToolUse", "working", nil),
                ("PostToolUse", "working", nil),
                ("PermissionRequest", "attention", nil),
                ("Stop", "done", nil),
                ("SubagentStop", "working", nil),
            ],
            label: "codex")
    }

    /// Cursor's agent hooks live in `~/.cursor/hooks.json`. Only the informational
    /// lifecycle events are mapped: a prompt/tool starting is `working`, `stop` is
    /// `done`. Cursor's permission gating happens through a hook's *return value*
    /// (a `beforeShellExecution` returning `"ask"`), not a lifecycle event, so there
    /// is no `attention` mapping — and termio deliberately does not hook the gating
    /// events, to avoid interfering with Cursor's own approval flow. The zero-config
    /// bell/OSC layer still catches any "needs you" the agent raises.
    static var cursor: JSONHookFile {
        JSONHookFile(
            url: home(".cursor", "hooks.json"),
            events: [
                ("beforeSubmitPrompt", "working", nil),
                ("preToolUse", "working", nil),
                ("postToolUse", "working", nil),
                ("subagentStop", "working", nil),
                ("stop", "done", nil),
            ],
            label: "cursor",
            dialect: .cursorFlat)
    }

    /// Grok Build discovers hooks from every `*.json` under `~/.grok/hooks/`, each in
    /// the Claude-nested shape, so termio drops its own dedicated file there rather
    /// than merging into a shared one — nothing user-owned to preserve, and Grok
    /// merges it with the user's other hook files. (Grok also reads
    /// `~/.claude/settings.json` for Claude compatibility, so it already sees termio's
    /// Claude hook; this explicit file makes the integration independent of whether
    /// Claude Code is installed.) Grok compiles a `matcher` as a tool-name regex —
    /// a bare `"*"` would fail to compile — so the tool events omit the matcher, which
    /// Grok treats as "match every tool". No `attention` mapping: Grok gates via a
    /// PreToolUse hook's return value (like Cursor), not a lifecycle event, and the
    /// zero-config bell/OSC layer still catches any "needs you" it raises.
    static var grok: JSONHookFile {
        JSONHookFile(
            url: home(".grok", "hooks", "termio-status.json"),
            events: [
                ("UserPromptSubmit", "working", nil),
                ("PreToolUse", "working", nil),
                ("PostToolUse", "working", nil),
                ("Stop", "done", nil),
                ("SubagentStop", "working", nil),
            ],
            label: "grok")
    }

    /// Builds an installer from a user agent's declarative `hooks` block. Same shape
    /// as the built-ins — only the file path, events, and dialect vary, exactly the
    /// per-agent knowledge the config carries. Never captures a transcript (only Claude
    /// reliably provides one on stdin), so a user agent's hooks just report state. A
    /// `static func` (not an `init`) so the memberwise initializer the built-in
    /// factories rely on is preserved.
    static func userAgent(id: String, spec: AgentHookSpec) -> JSONHookFile {
        JSONHookFile(
            url: URL(fileURLWithPath: (spec.file as NSString).expandingTildeInPath),
            events: spec.events,
            label: id,
            capturesTranscript: false,
            dialect: spec.dialect)
    }

    private static func home(_ components: String...) -> URL {
        components.reduce(FileManager.default.homeDirectoryForCurrentUser) {
            $0.appendingPathComponent($1)
        }
    }

    private enum FileState {
        case missing
        case unreadable
        case ok([String: Any])
    }

    func install() {
        let root: [String: Any]
        switch readState() {
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
                state: event.state, withTranscript: capturesTranscript, dialect: dialect)
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
        write(settings)
    }

    func uninstall() {
        // Nothing to remove if the file is absent; never overwrite one we can't read.
        guard case .ok(let root) = readState() else { return }
        var settings = root
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        stripTermioEntries(from: &hooks)
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        write(settings)
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
        // Cursor's flat entry carries the command directly; Claude/Codex nest it.
        if let command = group["command"] as? String {
            return command.contains(AgentStatusHooks.marker)
        }
        guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains(AgentStatusHooks.marker) == true }
    }

    private func readState() -> FileState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        if data.isEmpty { return .missing }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return .unreadable }
        return .ok(dictionary)
    }

    private func write(_ settings: [String: Any]) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            // Skip the write when the result is byte-identical to what's already
            // there (the common case on every launch): avoids needless churn on a
            // user-owned file and shrinks the window where this atomic write could
            // clobber a concurrent hand-edit. `.sortedKeys` makes the bytes stable.
            if (try? Data(contentsOf: url)) == data { return }
            try data.write(to: url, options: .atomic)
        } catch {
            AgentStatusHooks.log("could not write \(url.path): \(error)")
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

    static var openCode: PluginFile {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode/plugin/termio-status.js")
        return PluginFile(url: url, contents: openCodeSource)
    }

    static var pi: PluginFile {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/extensions/termio-status.js")
        return PluginFile(url: url, contents: piSource)
    }

    static var amp: PluginFile {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/amp/plugins/termio-status.ts")
        return PluginFile(url: url, contents: ampSource)
    }

    func install() {
        let data = Data(contents.utf8)
        // Same launch is a no-op: don't rewrite an unchanged plugin file.
        if (try? Data(contentsOf: url)) == data { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            AgentStatusHooks.log("could not write \(url.path): \(error)")
        }
    }

    func uninstall() {
        // Only remove a file we recognize as ours, so a user file that happens to
        // share the name is never deleted.
        guard let existing = try? String(contentsOf: url, encoding: .utf8),
              existing.contains(AgentStatusHooks.marker) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static var socketPath: String { HookListener.socketURL.path }

    /// OpenCode plugin: a session is `busy` while working and emits `session.idle`
    /// when the turn ends; `permission.updated` means it's waiting on the user. Each
    /// maps to a normalized report shelled out via Bun's `$` to the socket. The
    /// session id comes from `TERMIO_SESSION`, which the PTY carries into the
    /// in-process plugin.
    private static var openCodeSource: String {
        """
        // termio agent status — reports OpenCode session lifecycle to termio.
        // Socket marker: \(AgentStatusHooks.marker)
        export const TermioStatus = async ({ $ }) => {
          const socket = \(jsString(socketPath));
          const report = (state) => {
            const id = process.env.TERMIO_SESSION || "";
            const payload = JSON.stringify({ termio_session: id, state });
            return $`printf %s ${payload} | nc -w 1 -U ${socket}`.quiet().nothrow();
          };
          return {
            event: async ({ event }) => {
              if (event.type === "session.status" && event.properties?.status?.type === "busy") {
                return report("working");
              }
              if (event.type === "session.idle") return report("done");
              if (event.type === "permission.updated") return report("attention");
            },
          };
        };
        """
    }

    /// Pi extension: `agent_start` fires when a turn begins, `agent_end` when it
    /// returns to the user. Pi has no shell-hook config, so the extension itself
    /// shells out via `pi.exec`; the session id rides in on `TERMIO_SESSION`.
    private static var piSource: String {
        let working = AgentStatusHooks.reportCommand(state: "working")
        let done = AgentStatusHooks.reportCommand(state: "done")
        return """
        // termio agent status — reports Pi turn lifecycle to termio.
        // Socket marker: \(AgentStatusHooks.marker)
        export default (pi) => {
          pi.on("agent_start", () => pi.exec("sh", ["-c", \(jsString(working))]));
          pi.on("agent_end", () => pi.exec("sh", ["-c", \(jsString(done))]));
        };
        """
    }

    /// Amp plugin: `agent.start` fires when the user submits a prompt, `agent.end`
    /// when the agent finishes handling it. Amp auto-loads any plugin under
    /// `~/.config/amp/plugins/` (a default-exported function receiving the plugin
    /// API), runs on Bun, and exposes Bun's `$` shell as `amp.$`; the session id
    /// rides in on `TERMIO_SESSION` from the PTY. `.quiet().nothrow()` keeps it a
    /// silent no-op when termio isn't listening.
    private static var ampSource: String {
        """
        // termio agent status — reports Amp turn lifecycle to termio.
        // Socket marker: \(AgentStatusHooks.marker)
        export default (amp) => {
          const socket = \(jsString(socketPath));
          const report = (state) => {
            const id = process.env.TERMIO_SESSION || "";
            const payload = JSON.stringify({ termio_session: id, state });
            return amp.$`printf %s ${payload} | nc -w 1 -U ${socket}`.quiet().nothrow();
          };
          amp.on("agent.start", () => report("working"));
          amp.on("agent.end", () => report("done"));
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
    let events: [(name: String, state: String, matcher: String?)]

    private static let blockBegin = "# >>> termio agent-status hooks (managed — do not edit) >>>"
    private static let blockEnd = "# <<< termio agent-status hooks <<<"

    /// Kimi Code hooks in `~/.kimi/config.toml`. `UserPromptSubmit` opens a turn,
    /// `Stop` closes it, and `Interrupt` (Esc) closes an aborted one so the spinner
    /// doesn't stick. All three are non-tool events, so none needs a `matcher`.
    static var kimi: TOMLHookBlock {
        TOMLHookBlock(
            url: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".kimi/config.toml"),
            events: [
                ("UserPromptSubmit", "working", nil),
                ("Stop", "done", nil),
                ("Interrupt", "done", nil),
            ])
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
    private static func render(events: [(name: String, state: String, matcher: String?)]) -> String {
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
