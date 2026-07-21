import Foundation

/// The companion wire protocol, shared by the Mac companion server and the iOS
/// client so the two never drift. v1 is deliberately tiny:
///
/// - **Binary** WebSocket frames carry raw PTY bytes in both directions
///   (server → client = terminal output, client → server = keystrokes).
/// - **Text** WebSocket frames carry JSON control messages (resize, and room
///   to grow: attention, exit, seq catch-up).
///
/// E2E encryption wraps the binary payloads in a later pass; the framing here
/// is transport-agnostic (works identically over ws:// localhost, wss:// via a
/// tunnel, or a QUIC stream).
public enum CompanionControl: Codable, Sendable, Equatable {
    /// The client's first message on any connection: proves possession of the
    /// pairing token from the Mac's QR code. Until it lands, the server sends
    /// nothing and refuses every other message — the port may sit behind a
    /// public tunnel URL, where "connected" must not mean "trusted".
    case auth(token: String)
    /// The client asks to bridge a specific session's PTY (roster session id).
    /// Sent once, immediately after the socket opens; the server replays its
    /// recent output and starts streaming.
    case attach(sessionID: String)
    /// The client asks the Mac to create a session in a project — the phone's
    /// equivalent of the sidebar's new-session buttons. Answered with
    /// `.started` (or `.error`). `agent` nil is the phone's bare "New Chat":
    /// the Mac resolves the agent itself (pinned → last used → first enabled,
    /// the same policy behind ⌘N) so the habit lives in exactly one place —
    /// the phone never re-implements it. Older Macs drop an agent-less start
    /// (their decoder required the field), which degrades to "nothing
    /// happens", never to a wrong agent.
    case start(projectID: String, agent: String?)
    /// A `start` succeeded; the new session is ready to `attach`. `agent`
    /// echoes the wire id the Mac actually launched — the client can't know
    /// it for an agent-less start until the next roster push. nil from an
    /// older Mac; the client falls back to the agent it asked for.
    case started(sessionID: String, agent: String?)
    /// The client asks the Mac to close a session (the phone's swipe-to-remove).
    /// No success reply — the next roster push drops the row everywhere.
    case stop(sessionID: String)
    /// The client's terminal grid changed; the server resizes the PTY.
    case resize(cols: Int, rows: Int)
    /// The remote process exited.
    case exit(code: Int32)
    /// The client asks for one directory's entries (`path` relative to the
    /// project root, "" = the root itself). Answered with `.fileList`.
    case listFiles(projectID: String, path: String)
    /// One directory listing (server → client).
    case fileList(path: String, entries: [WireFileEntry])
    /// The client asks for a file's contents. Answered with `.file` or `.error`.
    /// `dark` is the client's light/dark trait — the server bakes it into the
    /// rendered Markdown preview (`WireFile.html`) so the page matches, the
    /// same contract as `.trace`.
    case readFile(projectID: String, path: String, dark: Bool)
    /// File contents (server → client).
    case file(WireFile)
    /// The client writes edited contents back. `baseMtime` is the mtime (ms)
    /// the edit started from — the server refuses if the file moved on (the
    /// agent may be writing it too); 0 skips the check (explicit overwrite).
    /// Answered with `.written` or `.error` (conflicts prefixed "conflict:").
    case writeFile(projectID: String, path: String, base64: String, baseMtime: Int)
    /// A `writeFile` landed; `mtime` is the file's new mtime (ms), the base
    /// for the next write.
    case written(path: String, mtime: Int)
    /// The client pushes an attachment for the agent (a photo or file picked
    /// on the phone). Unlike `writeFile` this creates: the server drops it
    /// under `<project>/.termio/uploads/` and answers `.uploaded`.
    case upload(projectID: String, name: String, base64: String)
    /// An `upload` landed; `path` is absolute on the Mac — ready to paste
    /// into an agent prompt (the Moshi pattern: agents take file paths).
    case uploaded(path: String)
    /// The client asks the Mac to search the whole project for files whose
    /// name contains `query` (case-insensitive). Unlike the lazily-loaded
    /// tree, this walks the entire repo server-side. Answered with
    /// `.searchResults`.
    case searchFiles(projectID: String, query: String)
    /// Filename-search matches (server → client): repo-relative paths, capped;
    /// `truncated` marks that more matched than the returned batch. `query`
    /// echoes the request so a stale reply for an old keystroke is discardable.
    case searchResults(query: String, paths: [String], truncated: Bool)
    /// The server rejected a request (unknown session, no live PTY).
    /// Phone → Mac: render this session's agent transcript as an HTML trace
    /// (the same dashboard-over-conversation the desktop Info pane shows). The
    /// phone passes its own light/dark trait so the returned page matches.
    case trace(sessionID: String, dark: Bool)

    /// Mac → phone: the rendered trace document for `sessionID`. The phone drops
    /// it into a `WKWebView` overlay. Large, so it rides the 8 MB-capped socket.
    case traceHTML(sessionID: String, html: String)

    /// Phone → Mac: list the hosts in the Mac's `~/.ssh/config`. The phone is
    /// sandboxed and has no `~/.ssh`, so the Mac reads it and the phone imports
    /// the results into its own SSH manager.
    case sshConfigHosts

    /// Mac → phone: the parsed `~/.ssh/config` host blocks.
    case sshConfigList(hosts: [WireSSHHost])

    case error(message: String)

    public func encoded() -> String {
        // Small, hand-stable JSON so both ends agree without a schema tool.
        switch self {
        case .auth(let token):
            return Self.json(["t": "auth", "token": token])
        case .attach(let sessionID):
            return #"{"t":"attach","session":"\#(sessionID)"}"#
        case .start(let projectID, let agent):
            // A nil agent omits the key (not `null`) so the hand-rolled
            // decoders on both ends keep reading plain `as? String`.
            var fields: [String: Any] = ["t": "start", "project": projectID]
            if let agent { fields["agent"] = agent }
            return Self.json(fields)
        case .started(let sessionID, let agent):
            var fields: [String: Any] = ["t": "started", "session": sessionID]
            if let agent { fields["agent"] = agent }
            return Self.json(fields)
        case .stop(let sessionID):
            return #"{"t":"stop","session":"\#(sessionID)"}"#
        case .resize(let cols, let rows):
            return #"{"t":"resize","cols":\#(cols),"rows":\#(rows)}"#
        case .exit(let code):
            return #"{"t":"exit","code":\#(code)}"#
        // The file messages carry arbitrary user paths, so they go through
        // JSONSerialization instead of interpolation — escaping for free.
        case .listFiles(let projectID, let path):
            return Self.json(["t": "listFiles", "project": projectID, "path": path])
        case .fileList(let path, let entries):
            return Self.json([
                "t": "fileList", "path": path,
                "entries": entries.map { ["name": $0.name, "dir": $0.isDir, "changed": $0.changed] },
            ])
        case .readFile(let projectID, let path, let dark):
            return Self.json(["t": "readFile", "project": projectID, "path": path, "dark": dark])
        case .file(let file):
            var payload: [String: Any] = [
                "t": "file", "path": file.path, "data": file.base64,
                "size": file.size, "binary": file.binary, "truncated": file.truncated,
                "mtime": file.mtime,
            ]
            // Only Markdown carries a rendered preview; absent otherwise so the
            // common case stays small.
            if let html = file.html { payload["html"] = html }
            return Self.json(payload)
        case .writeFile(let projectID, let path, let base64, let baseMtime):
            return Self.json([
                "t": "writeFile", "project": projectID, "path": path,
                "data": base64, "baseMtime": baseMtime,
            ])
        case .written(let path, let mtime):
            return Self.json(["t": "written", "path": path, "mtime": mtime])
        case .upload(let projectID, let name, let base64):
            return Self.json(["t": "upload", "project": projectID, "name": name, "data": base64])
        case .uploaded(let path):
            return Self.json(["t": "uploaded", "path": path])
        case .searchFiles(let projectID, let query):
            return Self.json(["t": "searchFiles", "project": projectID, "query": query])
        case .searchResults(let query, let paths, let truncated):
            return Self.json([
                "t": "searchResults", "query": query, "paths": paths, "truncated": truncated,
            ])
        case .trace(let sessionID, let dark):
            return Self.json(["t": "trace", "session": sessionID, "dark": dark])
        case .traceHTML(let sessionID, let html):
            return Self.json(["t": "traceHTML", "session": sessionID, "html": html])
        case .sshConfigHosts:
            return #"{"t":"sshConfigHosts"}"#
        case .sshConfigList(let hosts):
            return Self.json([
                "t": "sshConfigList",
                "hosts": hosts.map {
                    ["alias": $0.alias, "hostName": $0.hostName, "user": $0.user, "port": $0.port]
                },
            ])
        case .error(let message):
            let escaped = message
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return #"{"t":"error","message":"\#(escaped)"}"#
        }
    }

    public static func decode(_ text: String) -> CompanionControl? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["t"] as? String
        else { return nil }
        switch type {
        case "auth":
            guard let token = obj["token"] as? String else { return nil }
            return .auth(token: token)
        case "attach":
            guard let sessionID = obj["session"] as? String else { return nil }
            return .attach(sessionID: sessionID)
        case "start":
            guard let projectID = obj["project"] as? String else { return nil }
            // Missing agent = "Mac picks" — lenient, so today's phone can talk
            // to a Mac that still always sends one.
            return .start(projectID: projectID, agent: obj["agent"] as? String)
        case "started":
            guard let sessionID = obj["session"] as? String else { return nil }
            return .started(sessionID: sessionID, agent: obj["agent"] as? String)
        case "stop":
            guard let sessionID = obj["session"] as? String else { return nil }
            return .stop(sessionID: sessionID)
        case "resize":
            guard let cols = obj["cols"] as? Int, let rows = obj["rows"] as? Int else { return nil }
            return .resize(cols: cols, rows: rows)
        case "exit":
            let code = (obj["code"] as? Int).map(Int32.init) ?? 0
            return .exit(code: code)
        case "listFiles":
            guard let projectID = obj["project"] as? String,
                  let path = obj["path"] as? String else { return nil }
            return .listFiles(projectID: projectID, path: path)
        case "fileList":
            guard let path = obj["path"] as? String,
                  let raw = obj["entries"] as? [[String: Any]] else { return nil }
            let entries = raw.compactMap { entry -> WireFileEntry? in
                guard let name = entry["name"] as? String else { return nil }
                return WireFileEntry(
                    name: name,
                    isDir: entry["dir"] as? Bool ?? false,
                    changed: entry["changed"] as? Bool ?? false
                )
            }
            return .fileList(path: path, entries: entries)
        case "readFile":
            guard let projectID = obj["project"] as? String,
                  let path = obj["path"] as? String else { return nil }
            return .readFile(
                projectID: projectID, path: path,
                dark: obj["dark"] as? Bool ?? false
            )
        case "file":
            guard let path = obj["path"] as? String,
                  let base64 = obj["data"] as? String else { return nil }
            return .file(WireFile(
                path: path,
                base64: base64,
                size: obj["size"] as? Int ?? 0,
                binary: obj["binary"] as? Bool ?? false,
                truncated: obj["truncated"] as? Bool ?? false,
                mtime: obj["mtime"] as? Int ?? 0,
                html: obj["html"] as? String
            ))
        case "writeFile":
            guard let projectID = obj["project"] as? String,
                  let path = obj["path"] as? String,
                  let base64 = obj["data"] as? String else { return nil }
            return .writeFile(
                projectID: projectID, path: path, base64: base64,
                baseMtime: obj["baseMtime"] as? Int ?? 0
            )
        case "written":
            guard let path = obj["path"] as? String,
                  let mtime = obj["mtime"] as? Int else { return nil }
            return .written(path: path, mtime: mtime)
        case "upload":
            guard let projectID = obj["project"] as? String,
                  let name = obj["name"] as? String,
                  let base64 = obj["data"] as? String else { return nil }
            return .upload(projectID: projectID, name: name, base64: base64)
        case "uploaded":
            guard let path = obj["path"] as? String else { return nil }
            return .uploaded(path: path)
        case "searchFiles":
            guard let projectID = obj["project"] as? String,
                  let query = obj["query"] as? String else { return nil }
            return .searchFiles(projectID: projectID, query: query)
        case "searchResults":
            guard let query = obj["query"] as? String,
                  let paths = obj["paths"] as? [String] else { return nil }
            return .searchResults(
                query: query, paths: paths,
                truncated: obj["truncated"] as? Bool ?? false
            )
        case "trace":
            guard let sessionID = obj["session"] as? String else { return nil }
            return .trace(sessionID: sessionID, dark: obj["dark"] as? Bool ?? false)
        case "traceHTML":
            guard let sessionID = obj["session"] as? String,
                  let html = obj["html"] as? String else { return nil }
            return .traceHTML(sessionID: sessionID, html: html)
        case "sshConfigHosts":
            return .sshConfigHosts
        case "sshConfigList":
            let raw = obj["hosts"] as? [[String: Any]] ?? []
            let hosts = raw.compactMap { entry -> WireSSHHost? in
                guard let alias = entry["alias"] as? String else { return nil }
                return WireSSHHost(
                    alias: alias,
                    hostName: entry["hostName"] as? String ?? alias,
                    user: entry["user"] as? String ?? "",
                    port: entry["port"] as? Int ?? 22
                )
            }
            return .sshConfigList(hosts: hosts)
        case "error":
            guard let message = obj["message"] as? String else { return nil }
            return .error(message: message)
        default:
            return nil
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Files (read-only file plane)

/// One entry in a `fileList` reply — a name plus just enough for the phone's
/// tree: directory or file, and whether the working diff touches it.
public struct WireFileEntry: Codable, Sendable, Equatable {
    public let name: String
    public let isDir: Bool
    public let changed: Bool

    public init(name: String, isDir: Bool, changed: Bool = false) {
        self.name = name
        self.isDir = isDir
        self.changed = changed
    }
}

/// One `Host` block from the Mac's `~/.ssh/config`, flattened for the phone's
/// SSH import: the alias the user typed, the resolved `HostName`, and the
/// `User`/`Port` if the config set them (else empty/22).
public struct WireSSHHost: Codable, Sendable, Equatable {
    public let alias: String
    public let hostName: String
    public let user: String
    public let port: Int

    public init(alias: String, hostName: String, user: String, port: Int) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
    }
}

/// A `readFile` reply. Content rides as base64 inside the JSON text frame;
/// `truncated` marks a size-cap cut, `binary` marks content the phone should
/// hand to Quick Look rather than render as text.
public struct WireFile: Codable, Sendable, Equatable {
    public let path: String
    public let base64: String
    public let size: Int
    public let binary: Bool
    public let truncated: Bool
    /// mtime in milliseconds — the base for conflict-checked writes.
    /// 0 when the serving peer predates the write plane.
    public let mtime: Int
    /// A self-contained rendered preview document, only for Markdown files —
    /// the Mac renders with the same reader pipeline as its own Preview pane
    /// and the phone drops it into a `WKWebView`, the trace pattern. nil for
    /// every other file, and when the serving peer predates the field.
    public let html: String?

    public init(
        path: String, base64: String, size: Int, binary: Bool, truncated: Bool,
        mtime: Int = 0, html: String? = nil
    ) {
        self.path = path
        self.base64 = base64
        self.size = size
        self.binary = binary
        self.truncated = truncated
        self.mtime = mtime
        self.html = html
    }

    public var data: Data? { Data(base64Encoded: base64) }
}

// MARK: - Roster (server → client)

/// One session as it appears in the phone's tree. `agent` is the stable id into
/// the roster catalog and `status` is a string token, keeping both apps decoupled
/// from internal runtime types.
public struct RosterSession: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let agent: String   // "claude" | "codex" | "opencode" | "terminal"
    public let status: String  // "idle" | "working" | "done" | "needsAttention"
    /// One line of live activity — the tool a working turn is in, or what the
    /// agent is waiting on ("Working — Bash", "Waiting for you"). The phone
    /// shows it as the row's preview line, Messages-style. Optional so older
    /// peers that don't send it still decode; nil when there is nothing to say.
    public let subtitle: String?
    /// The branch of the linked worktree checkout this session runs in — nil
    /// for sessions in the project's main checkout, so the phone can label
    /// only the rows that live somewhere other than the project's own branch.
    public let branch: String?

    public init(
        id: String, title: String, agent: String, status: String,
        subtitle: String? = nil, branch: String? = nil
    ) {
        self.id = id
        self.title = title
        self.agent = agent
        self.status = status
        self.subtitle = subtitle
        self.branch = branch
    }
}

/// One project and its sessions.
public struct RosterProject: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let path: String
    /// Current git branch of the checkout, nil for non-repos. Optional so
    /// older peers that don't send it still decode.
    public let branch: String?
    /// What this container *is* on the Mac — `ProjectKind` on the wire:
    /// "folder" (a real project), "terminals" (loose shells), "chats" (loose
    /// agent sessions). nil from an older Mac; treat as "folder".
    public let kind: String?
    public let sessions: [RosterSession]

    public init(
        id: String, name: String, path: String, branch: String? = nil,
        kind: String? = nil, sessions: [RosterSession]
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.branch = branch
        self.kind = kind
        self.sessions = sessions
    }
}

/// One agent the phone may start a new session with — mirrors an entry the user
/// has left enabled in the Mac's Settings ▸ Agents page. `id` is the wire string
/// echoed back in a `start` request; `name` is the menu label. Visual metadata is
/// optional so old clients ignore it and new clients still decode an older Mac.
public struct RosterAgent: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let tintHex: String?
    public let icon: IconRef?

    public init(id: String, name: String, tintHex: String? = nil, icon: IconRef? = nil) {
        self.id = id
        self.name = name
        self.tintHex = tintHex
        self.icon = icon
    }
}

/// The full project/session roster the companion server pushes to the phone —
/// the same data the desktop sidebar shows. Sent on connect and whenever the
/// store's projects/statuses/titles change. Carried as a text frame tagged
/// `"roster"` so it coexists with the small `CompanionControl` messages.
public struct CompanionRoster: Codable, Sendable, Equatable {
    public let t: String
    public let projects: [RosterProject]
    /// The agents the Mac has enabled in Settings ▸ Agents, in preset order —
    /// the phone's new-session menu mirrors this instead of a fixed list. Empty
    /// when talking to an older Mac that predates the field (the phone then
    /// falls back to its built-in defaults).
    public let agents: [RosterAgent]

    public init(projects: [RosterProject], agents: [RosterAgent] = []) {
        t = "roster"
        self.projects = projects
        self.agents = agents
    }

    private enum CodingKeys: String, CodingKey { case t, projects, agents }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(String.self, forKey: .t)
        projects = try c.decodeIfPresent([RosterProject].self, forKey: .projects) ?? []
        agents = try c.decodeIfPresent([RosterAgent].self, forKey: .agents) ?? []
    }

    public func encodedJSON() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return #"{"t":"roster","projects":[]}"# }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decode a text frame if it is a roster (tagged `"t":"roster"`), else nil.
    public static func decode(_ text: String) -> CompanionRoster? {
        guard let data = text.data(using: .utf8),
              let roster = try? JSONDecoder().decode(CompanionRoster.self, from: data),
              roster.t == "roster"
        else { return nil }
        return roster
    }
}
