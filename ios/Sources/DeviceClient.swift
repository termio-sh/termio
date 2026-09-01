import Foundation
import TermioShared

/// The port the app's screens talk to, so they render *a machine* rather than a
/// transport. `CompanionBackend` implements it over the Mac companion wire; the
/// point of the seam is that a second implementation over the Session Protocol
/// can attach the phone straight to a Linux box with no Mac in the path — see
/// `docs/design/20260824-ios-as-device-client.md` D1.
///
/// It covers exactly what the UI asks for today and nothing more: the roster
/// push, the four session verbs, the file plane, the git plane, and the SSH
/// host list. Everything crossing it is a model of this app's, never a wire
/// type, so a backend change is a backend change.
protocol DeviceClient: AnyObject {
    /// A fresh roster arrived — the whole tree, pushed, never polled.
    var onRoster: ((DeviceRoster) -> Void)? { get set }
    /// The session filling the screen, or nil on a list.
    ///
    /// The device reports a turn ending; whether that reads as a calm "ready
    /// for you" or as nothing at all depends on whether this person is looking,
    /// and only this end knows. The Mac makes the same call from its own
    /// selection, which is what keeps two devices watching one session in
    /// agreement rather than each inventing a state.
    var viewingSessionID: String? { get set }
    /// `true` once the link is up, `false` on every drop.
    var onConnected: ((Bool) -> Void)? { get set }
    /// The device refused a request (a failed `start`, an unreadable file).
    var onError: ((String) -> Void)? { get set }
    /// The device refused the *link* and dropped it; the reason has to survive
    /// the reconnect loop or it reads as an unexplained outage.
    var onConnectionFailure: ((String) -> Void)? { get set }
    /// A `start` landed: the new session id, and the agent the device actually
    /// launched (nil from a peer that predates the echo).
    var onStarted: ((String, String?) -> Void)? { get set }
    /// A directory listing arrived, for the path that was asked for.
    var onFileList: ((String, [DeviceFileEntry]) -> Void)? { get set }
    /// One file's contents arrived.
    var onFile: ((DeviceFile) -> Void)? { get set }
    /// A write landed: the path, and the file's new modification time (ms).
    var onWritten: ((String, Int) -> Void)? { get set }
    /// An upload landed: its absolute path on the device.
    var onUploaded: ((String) -> Void)? { get set }
    /// Filename-search matches: the echoed query, device-relative paths, and
    /// whether the batch was capped.
    var onSearchResults: ((String, [String], Bool) -> Void)? { get set }
    /// The project's working-tree changes.
    var onChanges: (([DeviceChange]) -> Void)? { get set }
    /// One file's unified diff.
    var onDiff: ((DeviceDiff) -> Void)? { get set }
    /// The device's `~/.ssh/config` host blocks.
    var onSSHHosts: (([DeviceSSHHost]) -> Void)? { get set }

    func start()
    func stop()
    /// Drop any pending backoff and dial now — the stalled zero state's
    /// "Try Again".
    func reconnectNow()

    func startSession(projectID: String, agentID: String)
    /// A plain login shell, project-less so it can seed the very first one.
    /// `workspaceID` names the workspace it lands in — the one the phone is
    /// showing, so the destination is never decided by what the Mac's own
    /// window happens to be pointed at. nil leaves the choice to the device.
    func startTerminal(workspaceID: String?)
    /// `ssh <host>`, where `host` is always an alias the device already knows.
    /// `workspaceID` as above, honoured only when that workspace is on `host`.
    func startSSH(host: String, workspaceID: String?)
    func stopSession(id: String)
    func requestSSHHosts()
    /// The id to address a workspace's loose agent-session container by before
    /// it has one — how the phone seeds the very first chat there. Each backend
    /// has its own convention (the companion wire's `Wire.looseSectionID`, a
    /// device's home directory), so the caller does not carry one. nil when the
    /// backend cannot seed a container it has not been told about.
    func looseChatsContainerID(workspaceID: String) -> String?

    func listFiles(projectID: String, path: String)
    /// `darkAppearance` is for the device-rendered Markdown preview, so the
    /// page matches the screen it lands on.
    func readFile(projectID: String, path: String, darkAppearance: Bool)
    func writeFile(projectID: String, path: String, data: Data, baseModifiedMilliseconds: Int)
    func searchFiles(projectID: String, query: String)
    func upload(projectID: String, name: String, data: Data)
    func listChanges(projectID: String)
    func readDiff(projectID: String, path: String, status: String)
}

/// The byte plane for one session: the terminal writes keystrokes and its grid
/// in, remote PTY output comes back out. Attach is implicit in `start()` — a
/// session object exists only to show a session.
protocol DeviceSession: AnyObject {
    /// Remote PTY bytes. Fired off the main queue; the terminal surface takes
    /// them directly and hops for anything it has to draw.
    var onOutput: ((Data) -> Void)? { get set }
    /// Link and lifecycle transitions, delivered on the main queue.
    var onState: ((DeviceSessionState) -> Void)? { get set }

    /// The PTY's actual grid and whether this device holds the write token, on
    /// the main queue: once on attach and on every change of either. The grid is
    /// the smallest viewport rendering the session — what the bytes arriving are
    /// wrapped for — and is unrelated to the token that travels beside it.
    var onSharedGrid: ((TerminalGrid, Bool) -> Void)? { get set }

    func start()
    func stop()
    /// Keystrokes, as raw bytes. Typing is what claims the write token.
    func send(_ data: Data)
    /// A reply the surface generated to a host query (`TerminalDeviceReport`).
    /// Passes only while this device is the writer, and never claims.
    func sendDeviceReport(_ data: Data)
    /// Declares this screen's viewport. The device sizes the session to the
    /// smallest viewport being rendered, so this is a fact about this screen and
    /// not a claim on the session — it goes through whether or not this device
    /// holds the write token
    /// (`docs/design/20260901-pty-size-is-not-the-write-token.md`).
    func setViewport(columns: Int, rows: Int)
    /// Whether this screen is showing the session. A screen the container parked
    /// keeps its viewport and stops counting, so a session left open on the
    /// phone does not hold a Mac pane at phone width forever.
    func setRendering(_ showing: Bool)
    /// Ask for a fresh screen: a rebuilt surface starts blank and no byte is
    /// coming to repaint it.
    func reassertGrid()
}

/// Which backend a peer needs, decided in one place so no screen has to know
/// there is more than one protocol behind the port.
enum DeviceBackends {
    /// `sessionID` scopes the client to one session, which only the upload plane
    /// needs: a transfer to a device lands in that session's scratch directory.
    static func client(for endpoint: DeviceEndpoint, sessionID: String? = nil) -> DeviceClient {
        switch endpoint.kind {
        case .companion: CompanionBackend(url: endpoint.url)
        case .termiod: TermiodBackend(endpoint: endpoint, sessionID: sessionID)
        }
    }

    /// `sessionID` is the session to attach to; nil connects to a peer that
    /// streams without one (the standalone companion proof of concept).
    static func session(for endpoint: DeviceEndpoint, sessionID: String?) -> DeviceSession? {
        switch endpoint.kind {
        case .companion:
            return CompanionDeviceSession(url: endpoint.url, attachSessionID: sessionID)
        case .termiod:
            // A device attaches to a session by name, and there is no
            // sessionless stream to fall back to.
            guard let sessionID else { return nil }
            return TermiodSession(endpoint: endpoint, sessionName: sessionID)
        }
    }
}

/// Where a session's link stands. `failed` and `closed` are terminal; the
/// others are the self-healing loop talking.
enum DeviceSessionState: Equatable {
    case connecting
    case connected
    /// The socket dropped; a reconnect is scheduled. Not fatal.
    case reconnecting
    /// The device refused us — the session no longer exists. Fatal.
    case failed(String)
    /// The session exited on the device. Fatal.
    case closed
}

// MARK: - Models

/// One roster push, as the screens consume it.
///
/// `agents` and `projects` stay in the roster's own vocabulary because they are
/// what D6's rename settles; re-modelling them now would reach into every
/// screen for no gain this phase can bank.
struct DeviceRoster {
    /// The serving machine's stable id and the name it reports, which the
    /// paired-device list keys itself by. nil from a peer that names neither.
    let deviceID: String?
    let deviceName: String?
    /// The agents the device has enabled, so the phone never offers one the
    /// desktop turned off.
    let agents: [RosterAgent]
    let projects: [MockProject]
}

/// One directory entry: a name, whether it opens, and whether the working diff
/// touches it (or anything under it).
struct DeviceFileEntry: Equatable {
    let name: String
    let isDirectory: Bool
    let changed: Bool

    init(name: String, isDirectory: Bool, changed: Bool = false) {
        self.name = name
        self.isDirectory = isDirectory
        self.changed = changed
    }
}

/// One file's contents. `data` is nil when the payload failed to decode, which
/// the viewer treats the same as unreadable.
struct DeviceFile: Equatable {
    let path: String
    let data: Data?
    let size: Int
    let isBinary: Bool
    let isTruncated: Bool
    /// Modification time in milliseconds — the base for conflict-checked
    /// writes. 0 when the serving peer predates the write plane.
    let modifiedMilliseconds: Int
    /// A self-contained rendered preview document, Markdown only: the device
    /// renders it and the phone drops it into a `WKWebView`.
    let renderedHTML: String?

    init(
        path: String, data: Data?, size: Int, isBinary: Bool, isTruncated: Bool,
        modifiedMilliseconds: Int = 0, renderedHTML: String? = nil
    ) {
        self.path = path
        self.data = data
        self.size = size
        self.isBinary = isBinary
        self.isTruncated = isTruncated
        self.modifiedMilliseconds = modifiedMilliseconds
        self.renderedHTML = renderedHTML
    }
}

/// One changed file in the device's working tree, as the Changes pane shows
/// it. Deliberately flatter than the desktop's `GitChange` — the phone lists
/// and diffs, it never stages.
struct DeviceChange: Equatable {
    let path: String
    /// git's status letter, the desktop's own vocabulary: `M`odified, `A`dded,
    /// `D`eleted, `R`enamed, `C`opied, `U`ntracked, `!` conflicted.
    let status: String
    let additions: Int
    let deletions: Int
    /// `--numstat` reported `-` for the counts, so `+`/`−` would be a lie.
    let isBinary: Bool
    /// The change sits entirely in the index — what `git commit` would take now.
    let isStaged: Bool

    init(
        path: String, status: String, additions: Int, deletions: Int,
        isBinary: Bool = false, isStaged: Bool = false
    ) {
        self.path = path
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
        self.isStaged = isStaged
    }
}

extension DeviceChange {
    /// The one-line caption both the Changes row and the diff reader's header
    /// show: where the file lives and what it gained and lost.
    var caption: String {
        let directory = (path as NSString).deletingLastPathComponent
        var parts: [String] = directory.isEmpty ? [] : [directory]
        parts.append(isBinary ? "binary" : "+\(additions) −\(deletions)")
        if isStaged { parts.append("staged") }
        return parts.joined(separator: " · ")
    }

    var name: String { (path as NSString).lastPathComponent }
}

/// One file's unified diff. Binary content arrives with empty `text` and the
/// reader says so rather than rendering git's "Binary files differ" line as
/// if it were code.
struct DeviceDiff: Equatable {
    let path: String
    let text: String
    let isBinary: Bool

    init(path: String, text: String, isBinary: Bool = false) {
        self.path = path
        self.text = text
        self.isBinary = isBinary
    }
}

/// One `Host` block from the device's `~/.ssh/config`: the alias the user
/// typed, the resolved `HostName`, and the `User`/`Port` if the config set them.
struct DeviceSSHHost: Equatable {
    let alias: String
    let hostName: String
    let user: String
    let port: Int
}
