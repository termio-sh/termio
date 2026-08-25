import Foundation
import TermioShared

/// `DeviceClient` over the Mac companion wire: one `CompanionClient` socket,
/// with every wire type mapped to the app's own models on the way through.
///
/// The mapping is the point. Before this seam the inspector, the file viewer
/// and the diff reader all took `Wire*` structs straight off the socket, so
/// the companion protocol reached the leaf views — and a second backend would
/// have had to impersonate it. Now the wire stops here.
final class CompanionBackend: DeviceClient {
    var onRoster: ((DeviceRoster) -> Void)?
    var onConnected: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onConnectionFailure: ((String) -> Void)?
    var onStarted: ((String, String?) -> Void)?
    var onFileList: ((String, [DeviceFileEntry]) -> Void)?
    var onFile: ((DeviceFile) -> Void)?
    var onWritten: ((String, Int) -> Void)?
    var onUploaded: ((String) -> Void)?
    var onSearchResults: ((String, [String], Bool) -> Void)?
    var onChanges: (([DeviceChange]) -> Void)?
    var onDiff: ((DeviceDiff) -> Void)?
    var onSSHHosts: (([DeviceSSHHost]) -> Void)?

    private let client: CompanionClient

    init(url: URL) {
        client = CompanionClient(url: url)
        client.onRoster = { [weak self] roster in
            self?.onRoster?(DeviceRoster(companion: roster))
        }
        client.onConnected = { [weak self] connected in self?.onConnected?(connected) }
        client.onError = { [weak self] reason in self?.onError?(reason) }
        client.onConnectionFailure = { [weak self] reason in self?.onConnectionFailure?(reason) }
        client.onStarted = { [weak self] sessionID, agentID in self?.onStarted?(sessionID, agentID) }
        client.onFileList = { [weak self] path, entries in
            self?.onFileList?(path, entries.map(DeviceFileEntry.init(wire:)))
        }
        client.onFile = { [weak self] file in self?.onFile?(DeviceFile(wire: file)) }
        client.onWritten = { [weak self] path, modified in self?.onWritten?(path, modified) }
        client.onUploaded = { [weak self] path in self?.onUploaded?(path) }
        client.onSearchResults = { [weak self] query, paths, truncated in
            self?.onSearchResults?(query, paths, truncated)
        }
        client.onChanges = { [weak self] changes in
            self?.onChanges?(changes.map(DeviceChange.init(wire:)))
        }
        client.onDiff = { [weak self] diff in self?.onDiff?(DeviceDiff(wire: diff)) }
        client.onSSHConfig = { [weak self] hosts in
            self?.onSSHHosts?(hosts.map(DeviceSSHHost.init(wire:)))
        }
    }

    func start() { client.start() }
    func stop() { client.stop() }
    func reconnectNow() { client.reconnectNow() }

    func startSession(projectID: String, agentID: String) {
        client.send(.start(projectID: projectID, agent: agentID))
    }

    func startTerminal(workspaceID: String?) {
        client.send(.startTerminal(workspaceID: workspaceID))
    }

    func startSSH(host: String, workspaceID: String?) {
        client.send(.startSSH(host: host, workspaceID: workspaceID))
    }

    func stopSession(id: String) { client.send(.stop(sessionID: id)) }

    func requestSSHHosts() { client.send(.sshConfigHosts) }

    func listFiles(projectID: String, path: String) {
        client.send(.listFiles(projectID: projectID, path: path))
    }

    func readFile(projectID: String, path: String, darkAppearance: Bool) {
        client.send(.readFile(projectID: projectID, path: path, dark: darkAppearance))
    }

    func writeFile(projectID: String, path: String, data: Data, baseModifiedMilliseconds: Int) {
        client.send(.writeFile(
            projectID: projectID, path: path,
            base64: data.base64EncodedString(), baseMtime: baseModifiedMilliseconds
        ))
    }

    func searchFiles(projectID: String, query: String) {
        client.send(.searchFiles(projectID: projectID, query: query))
    }

    func upload(projectID: String, name: String, data: Data) {
        client.send(.upload(projectID: projectID, name: name, base64: data.base64EncodedString()))
    }

    func listChanges(projectID: String) {
        client.send(.listChanges(projectID: projectID))
    }

    func readDiff(projectID: String, path: String, status: String) {
        client.send(.readDiff(projectID: projectID, path: path, status: status))
    }
}

/// `DeviceSession` over the companion wire: the terminal's own socket, which
/// carries raw PTY bytes as binary frames once its attach lands.
final class CompanionDeviceSession: DeviceSession {
    var onOutput: ((Data) -> Void)? {
        get { transport.onOutput }
        set { transport.onOutput = newValue }
    }

    var onState: ((DeviceSessionState) -> Void)?

    private let transport: CompanionTransport

    init(url: URL, attachSessionID: String?) {
        transport = CompanionTransport(url: url, attachSessionID: attachSessionID)
        transport.onState = { [weak self] state in
            self?.onState?(DeviceSessionState(companion: state))
        }
    }

    func start() { transport.start() }
    func stop() { transport.stop() }
    func send(_ data: Data) { transport.send(data) }
    func resize(columns: Int, rows: Int) { transport.resize(cols: columns, rows: rows) }
    func reassertGrid() { transport.reassertGrid() }
}

// MARK: - Wire → model

private extension DeviceRoster {
    init(companion roster: CompanionRoster) {
        let agentsByID = Dictionary(
            roster.agents.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest })
        self.init(
            deviceID: roster.macID,
            deviceName: roster.macName,
            agents: roster.agents,
            projects: roster.projects.map { MockProject(roster: $0, agentsByID: agentsByID) }
        )
    }
}

private extension DeviceFileEntry {
    init(wire: WireFileEntry) {
        self.init(name: wire.name, isDirectory: wire.isDir, changed: wire.changed)
    }
}

private extension DeviceFile {
    init(wire: WireFile) {
        self.init(
            path: wire.path,
            data: wire.data,
            size: wire.size,
            isBinary: wire.binary,
            isTruncated: wire.truncated,
            modifiedMilliseconds: wire.mtime,
            renderedHTML: wire.html
        )
    }
}

private extension DeviceChange {
    init(wire: WireChange) {
        self.init(
            path: wire.path, status: wire.status,
            additions: wire.additions, deletions: wire.deletions,
            isBinary: wire.isBinary, isStaged: wire.isStaged
        )
    }
}

private extension DeviceDiff {
    init(wire: WireDiff) {
        self.init(path: wire.path, text: wire.text, isBinary: wire.binary)
    }
}

private extension DeviceSSHHost {
    init(wire: WireSSHHost) {
        self.init(alias: wire.alias, hostName: wire.hostName, user: wire.user, port: wire.port)
    }
}

private extension DeviceSessionState {
    init(companion state: CompanionTransport.State) {
        switch state {
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .reconnecting: self = .reconnecting
        case .failed(let reason): self = .failed(reason)
        case .closed: self = .closed
        }
    }
}
