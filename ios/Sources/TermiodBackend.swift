import CryptoKit
import Foundation
import TermioShared

/// `DeviceClient` over the termiod Session Protocol: the phone talking straight
/// to the box a session runs on, with no Mac in the path.
///
/// The roster is built here rather than read off the wire, because the daemon
/// holds sessions and has never heard of a project. Where a plane does not exist
/// over here it refuses instead of answering with an empty list — `onChanges?([])`
/// reads as "no changes", not "this device has no git plane".
final class TermiodBackend: DeviceClient {
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

    /// The host stops here and the caller is told the batch was capped, rather
    /// than a slice of a monorepo showing as if it were everything.
    private static let searchLimit: UInt64 = 200

    private let endpoint: DeviceEndpoint
    /// Only the upload plane needs it: a paste lands in the session's scratch
    /// directory, so there is nowhere to put one without a session.
    private let sessionID: String?
    private let channel: TermiodChannel
    private var sessionsByID: [String: Termiod.SessionInformation] = [:]
    private var sessionOrder: [String] = []
    /// Status the device revised since its row was last delivered whole. Held
    /// beside the rows so a fresh row can retire the delta standing in for it.
    private var statusOverrides: [String: StatusDelta] = [:]
    /// Where a reconnect resumes from, which is the whole point of status being
    /// a resource rather than a broadcast: a screen that locked through three
    /// turns resumes at its cursor instead of rescanning (§C.10). The rule, and
    /// why the ack is not an input to it, is `ResourceCursor`.
    private var statusCursor = ResourceCursor()
    /// Holds batches that arrive while a subscribe handshake is in flight, so
    /// nothing applies against a baseline the ack has not installed yet, and
    /// nothing overtakes what is already waiting. The same ledger the Mac's
    /// `fs:` and `git:` watches use — one copy, in `Shared/`.
    private var statusLedger = DeviceWatchLedger<Termiod.StatusChangedPayload>()
    private var statusGeneration = 0
    /// The session filling the screen, or nil on a list. The one piece of
    /// status arbitration that belongs to a viewer: a turn the *device*
    /// concluded reads `idle` on the row you are looking at and `done` on one
    /// you are not, and the Mac and this phone each answer for themselves.
    /// A hook's own `done` is not this rule's business — it means done
    /// everywhere.
    var viewingSessionID: String? {
        didSet {
            guard viewingSessionID != oldValue else { return }
            // Opening a session clears the "you have not seen this" mark the
            // way looking at it on the Mac does.
            if let opened = viewingSessionID,
               let delta = statusOverrides[opened], delta.status == "done" {
                statusOverrides[opened] = StatusDelta(status: "idle", title: delta.title)
                publishRoster()
            }
        }
    }
    private var hostID: String?
    /// Requests in flight, keyed by the `re` each was sent with.
    ///
    /// Every reply the daemon sends echoes that id — `Termiod.responseID(of:)`
    /// reads it off a control payload, and `decodeFileChunk` carries it on the
    /// bytes behind an `fs_read` — so a reply reaches the caller that asked
    /// rather than the one that asked first. Order used to be the only thing
    /// matching them, which held solely because this backend issued one request
    /// per verb at a time; two in flight and the second reply landed on the
    /// first caller.
    private var pendingReads: [UInt64: String] = [:]
    private var pendingSearches: [UInt64: String] = [:]
    /// Reads past their header, keyed the same way: the `fs_file` header and the
    /// `F` chunks landing behind it. Several can stream at once without their
    /// bytes interleaving into each other's file.
    private var readsInProgress:
        [UInt64: (path: String, header: Termiod.FsFilePayload, data: Data)] = [:]
    /// Transfers waiting on the daemon's credit-of-one acks, keyed by upload id
    /// once `upload_opened` names one. The first entry is the one being opened.
    private var transfers: [Transfer] = []
    private var seq: UInt64 = 1

    private struct Transfer {
        enum Destination {
            /// Conflict-checked against the version the editor read.
            case file(path: String, root: String, baseModifiedSeconds: UInt64?)
            /// The session's scratch directory, reaped when the session dies.
            case scratch(name: String)
        }

        let destination: Destination
        let data: Data
        var uploadID: String?
        var offset: UInt64 = 0
        /// The `re` this transfer's `upload_open` and `upload_commit` went out
        /// with. Transfers stay strictly sequential — that is the credit-of-one
        /// design, not an accident — so these do not multiplex anything; they
        /// are what stops a late reply from a transfer already abandoned from
        /// shifting the queue under the one now at its head.
        var openRequest: UInt64?
        var commitRequest: UInt64?
    }

    init(endpoint: DeviceEndpoint, sessionID: String? = nil) {
        self.endpoint = endpoint
        self.sessionID = sessionID
        channel = TermiodChannel(
            endpoint: endpoint, name: "device", role: "control",
            capabilities: Termiod.deviceCapabilities, delegateQueue: .main
        )
        channel.onReady = { [weak self] handshake in self?.handshakeLanded(handshake) }
        channel.onControl = { [weak self] reply in self?.receive(reply) }
        channel.onEvent = { [weak self] event in self?.receive(event) }
        channel.onFileChunk = { [weak self] payload in self?.receiveFileChunk(payload) }
        channel.onLinkState = { [weak self] up in
            guard let self else { return }
            if !up { forgetInFlight() }
            onConnected?(up)
        }
        channel.onFailure = { [weak self] reason in self?.onConnectionFailure?(reason) }
    }

    func start() { channel.start() }

    func stop() { channel.stop() }

    func reconnectNow() { channel.reconnectNow() }

    // MARK: - Sessions

    func startSession(projectID: String, agentID: String) {
        guard let root = root(ofProjectID: projectID) else {
            onError?(localized("That project isn't on this device."))
            return
        }
        // A loose chat belongs to no checkout, and the empty project below is
        // what files it under Chats rather than under a folder named after its
        // scratch directory.
        let isLooseChat = projectID == TermiodRoster.chatsProjectID
        create(
            // A spawn into a missing directory is refused, and the scratch root
            // will not exist on a box nobody has started a chat on, so the
            // shell creates it on the way in instead.
            cwd: isLooseChat ? channel.homeDirectory : root,
            argv: isLooseChat
                ? TermiodAgentLaunch.looseChatArgv(forAgent: agentID, root: root)
                : TermiodAgentLaunch.argv(forAgent: agentID),
            workstream: Termiod.WorkstreamSpecification(
                agentId: agentID, project: isLooseChat ? "" : root),
            agentID: agentID
        )
    }

    func startTerminal(workspaceID _: String?) {
        // One device is one workspace, so there is nothing to route by. No
        // workstream and no agent is what makes this a loose shell.
        create(
            cwd: TermiodRoster.looseTerminalRoot(homeDirectory: channel.homeDirectory),
            argv: [], workstream: nil, agentID: nil
        )
    }

    func startSSH(host: String, workspaceID _: String?) {
        // The Session Protocol has no verb for the host list the Mac reads out
        // of `~/.ssh/config`, so there is no choice here to honour.
        onError?(localized("Termio can't open an SSH session on \(host) from a device connection."))
    }

    func stopSession(id: String) {
        do {
            channel.send(kind: .control, payload: try Termiod.killPayload(
                target: id, seq: nextSeq()))
        } catch {
            report(error, doing: localized("Couldn't close that session."))
        }
    }

    func requestSSHHosts() {
        onError?(localized("This device doesn't report its SSH hosts."))
    }

    /// One per box, so there is nothing to find or create.
    func looseChatsContainerID(workspaceID _: String) -> String? {
        TermiodRoster.chatsProjectID
    }

    /// The device path a container id addresses. A folder carries its own; the
    /// two loose containers hang off the account's home directory, which only
    /// the handshake knows.
    private func root(ofProjectID id: String) -> String? {
        if let root = TermiodRoster.root(ofProjectID: id) { return root }
        let home = channel.homeDirectory
        switch id {
        case TermiodRoster.terminalsProjectID:
            return TermiodRoster.looseTerminalRoot(homeDirectory: home)
        case TermiodRoster.chatsProjectID:
            return TermiodRoster.looseChatRoot(homeDirectory: home)
        default:
            return nil
        }
    }

    /// `attach` with `create_if_missing` is the protocol's only spawn verb, so
    /// starting a session means attaching to a name that does not exist yet and
    /// then stepping back off it; the terminal screen attaches for real after.
    private func create(
        cwd: String,
        argv: [String],
        workstream: Termiod.WorkstreamSpecification?,
        agentID: String?
    ) {
        let name = UUID().uuidString
        let starter = TermiodChannel(
            endpoint: endpoint, name: "start", role: "attach",
            capabilities: Termiod.attachCapabilities, delegateQueue: .main
        )
        // A link self-heals rather than giving up, which is wrong for a request
        // someone is waiting on: a device that never answers has to become a
        // refusal instead of a channel dialling forever behind a ＋.
        let deadline = DispatchWorkItem { [weak self] in
            Self.retire(starter)
            self?.onError?(localized("That device didn't answer."))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: deadline)
        // These closures are the starter's only owner, so clearing them frees it.
        starter.onReady = { [weak self] _ in
            guard let self else { return }
            do {
                starter.send(kind: .control, payload: try Termiod.attachPayload(
                    target: name,
                    specification: Termiod.CreateSpecification(
                        cwd: cwd, argv: argv,
                        env: TermiodAgentLaunch.presentationEnvironment,
                        rows: 24, cols: 80,
                        workstream: workstream
                    ),
                    rows: 24, cols: 80
                ))
            } catch {
                deadline.cancel()
                Self.retire(starter)
                report(error, doing: localized("Couldn't start that session."))
            }
        }
        starter.onControl = { [weak self] reply in
            guard let self else { return }
            switch reply.control {
            case .attached:
                deadline.cancel()
                // Detach, not kill: what was just created has to outlive this.
                if let payload = try? Termiod.detachPayload() {
                    starter.send(kind: .control, payload: payload)
                }
                Self.retire(starter)
                onStarted?(name, agentID)
            case .error(let refusal):
                deadline.cancel()
                Self.retire(starter)
                onError?(refusal.message)
            default:
                break
            }
        }
        starter.onFailure = { [weak self] reason in
            deadline.cancel()
            Self.retire(starter)
            self?.onError?(reason)
        }
        starter.start()
    }

    /// Drops a one-shot channel and the closure cycle keeping it alive.
    private static func retire(_ channel: TermiodChannel) {
        channel.onReady = nil
        channel.onControl = nil
        channel.onFailure = nil
        channel.onLinkState = nil
        channel.stop()
    }

    // MARK: - Files

    func listFiles(projectID: String, path: String) {
        guard let root = root(ofProjectID: projectID) else {
            onError?(localized("That project isn't on this device."))
            return
        }
        do {
            try channel.send(control: Termiod.FsListOperation(
                root: root, paths: [path], seq: nextSeq()))
        } catch {
            report(error, doing: localized("Couldn't list that folder."))
        }
    }

    func readFile(projectID: String, path: String, darkAppearance _: Bool) {
        guard let root = root(ofProjectID: projectID) else {
            onError?(localized("That project isn't on this device."))
            return
        }
        // No rendered preview: `fs_read` answers with bytes and the device has
        // no Markdown renderer to ask, so the viewer shows the source.
        //
        // The device is addressed absolutely and answered relatively: the reply
        // carries back the path the caller asked for, and a save sends that same
        // path straight back.
        let request = nextSeq()
        pendingReads[request] = path
        do {
            try channel.send(control: Termiod.FsReadOperation(
                path: Self.absolutePath(root: root, path: path), seq: request))
        } catch {
            pendingReads[request] = nil
            report(error, doing: localized("Couldn't open that file."))
        }
    }

    func writeFile(projectID: String, path: String, data: Data, baseModifiedMilliseconds: Int) {
        guard let root = root(ofProjectID: projectID) else {
            onError?(localized("That project isn't on this device."))
            return
        }
        // The host's version is whole seconds; a millisecond base rounded down
        // is the same instant it reported, so a save it accepted still matches.
        let base = baseModifiedMilliseconds > 0
            ? UInt64(baseModifiedMilliseconds / 1000) : nil
        enqueue(Transfer(
            destination: .file(
                path: Self.absolutePath(root: root, path: path),
                root: root,
                baseModifiedSeconds: base
            ),
            data: data
        ))
    }

    func searchFiles(projectID: String, query: String) {
        guard let root = root(ofProjectID: projectID) else {
            onError?(localized("That project isn't on this device."))
            return
        }
        // `fs_match` and not `fs_search`: this field searches *names*, and
        // `fs_search` is the device's content search.
        //
        // Nothing is cancelled when a query is abandoned, and nothing needs to
        // be: `fs_match` is one reply off an index the host already holds, and
        // only `fs_search` registers a cancellable request (`daemon.rs`, the
        // `Control::Cancel` arm). That changes the day this pane gains content
        // search — an abandoned `fs_search` keeps walking the checkout until
        // the connection drops, and `Termiod.CancelOperation` is what stops it.
        let request = nextSeq()
        pendingSearches[request] = query
        do {
            try channel.send(control: Termiod.FsMatchOperation(
                root: root, query: query, limit: Self.searchLimit, seq: request))
        } catch {
            pendingSearches[request] = nil
            report(error, doing: localized("Couldn't search this project."))
        }
    }

    func upload(projectID _: String, name: String, data: Data) {
        // A paste lands in the session's scratch directory, which the device
        // reaps when that session dies. Without a session there is nowhere for
        // it to go that anything would clean up.
        guard sessionID != nil else {
            onError?(localized("Attaching a file needs an open session on this device."))
            return
        }
        enqueue(Transfer(destination: .scratch(name: name), data: data))
    }

    // MARK: - Git

    func listChanges(projectID _: String) {
        onChangesUnavailable()
    }

    func readDiff(projectID _: String, path _: String, status _: String) {
        onChangesUnavailable()
    }

    private func onChangesUnavailable() {
        onError?(localized("Working-tree changes aren't available over a device connection yet."))
    }

    // MARK: - Roster

    /// Not private, for the same reason `receive` is not: what this end asks
    /// for at handshake time — a `roster` subscription and a `status:` cursor —
    /// is the contract with the device, and a test that cannot see it sent
    /// cannot notice it stop being sent.
    func handshakeLanded(_ handshake: Termiod.HelloOkPayload) {
        // The roster is keyed by this and never by `client_id`, which names the
        // connection and changes on every reconnect.
        hostID = handshake.hostId
        do {
            // `roster` also carries `writer_changed` and `session_exited`, so
            // one name covers everything the list needs.
            channel.send(kind: .control, payload: try Termiod.subscribePayload(
                events: ["roster"], seq: nextSeq()))
            // Status comes from the resource and *not* from the `status` event
            // name, deliberately: one path, and one that carries a cursor. The
            // `stalled` signal rides the same batches, so nothing is lost by
            // dropping the broadcast. A daemon too old to know `status:`
            // answers `error`, and `resourceRefused` falls back to the
            // broadcast so an older device still lights its dots.
            // Everything from here until the ack is held, not applied.
            statusGeneration = statusLedger.begin()
            statusCursor.beginAttempt()
            channel.send(kind: .control, payload: try Termiod.subscribeResourcePayload(
                resource: Termiod.statusResource, since: statusCursor.resumeFrom,
                seq: nextSeq(statusSubscription: true)))
            channel.send(kind: .control, payload: try Termiod.listPayload(seq: nextSeq()))
        } catch {
            report(error, doing: localized("Couldn't read this device's sessions."))
        }
    }

    /// Routes one reply to the request that caused it.
    ///
    /// Not private so the routing can be driven with real replies: which of
    /// several in-flight requests an arriving frame lands on is the kind of
    /// thing that goes wrong silently, and a socket is not needed to prove it.
    func receive(_ reply: TermiodChannel.Reply) {
        switch reply.control {
        case .sessions(let payload):
            sessionOrder = payload.sessions.map(\.id)
            sessionsByID = Dictionary(
                payload.sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            statusOverrides.removeAll()
            publishRoster()
        case .fsListed(let payload):
            receiveListings(payload)
        case .fsFile(let header):
            receiveFileHeader(header, responseID: reply.responseID)
        case .fsMatched(let payload):
            receiveMatches(payload, responseID: reply.responseID)
        case .uploadOpened(let opened):
            receiveUploadOpened(opened, responseID: reply.responseID)
        case .uploadAck(let ack):
            receiveUploadAck(ack)
        case .uploadCommitted(let committed):
            receiveUploadCommitted(committed, responseID: reply.responseID)
        case .subscribed(let subscription):
            guard subscription.resource == Termiod.statusResource else { break }
            statusSubscriptionSeq = nil
            settleStatusSubscription(subscription)
        case .error(let failure):
            if reply.responseID != nil, reply.responseID == statusSubscriptionSeq {
                // A device that predates the `status:` resource, or one that did
                // not grant `resources`. Fall back to the broadcast: fewer
                // guarantees, same facts, and a dot that moves beats a correct
                // cursor into nothing.
                statusSubscriptionSeq = nil
                statusCursor.reset()
                // No resource, so nothing will ever settle the ledger: stop it
                // rather than leave the broadcast's batches held forever.
                statusLedger.stop()
                statusGeneration = statusLedger.generation
                if let payload = try? Termiod.subscribePayload(
                    events: ["roster", "status"], seq: nextSeq()) {
                    channel.send(kind: .control, payload: payload)
                }
                break
            }
            failInFlight(failure.message, responseID: reply.responseID)
        default:
            break
        }
    }

    /// Which outstanding request a reply belongs to.
    ///
    /// The `re` names it outright. A reply that carries none — a daemon too old
    /// to stamp them — can still be placed when exactly one request of that verb
    /// is waiting, because then there is nothing to confuse it with. Two waiting
    /// and no `re` is genuinely ambiguous, and guessing there is the behaviour
    /// this correlation exists to end.
    private func request<Value>(for responseID: UInt64?, in waiting: [UInt64: Value]) -> UInt64? {
        if let responseID { return waiting[responseID] != nil ? responseID : nil }
        return waiting.count == 1 ? waiting.keys.first : nil
    }

    /// Not private, for the same reason `receive(_ reply:)` is not: which of
    /// two status channels a batch arrived on, and what a viewer then makes of
    /// it, is exactly the kind of thing that goes wrong silently.
    func receive(_ event: Termiod.IncomingEvent) {
        switch event {
        case .roster(let update):
            if let information = update.info {
                if sessionsByID[information.id] == nil { sessionOrder.append(information.id) }
                sessionsByID[information.id] = information
                // A whole row is the device's current word, so it retires the
                // delta that was standing in for one.
                statusOverrides[information.id] = nil
            } else if update.action == "removed" {
                forget(update.session)
            } else {
                // An arrival notice with no row: nothing to redraw until the
                // `list` behind it lands.
                return
            }
            publishRoster()
        case .status(let status):
            // The fallback path only — a device too old for `status:`.
            applyStatus(status)
        case .statusChanged(let change):
            guard let admitted = statusLedger.admit(change, generation: statusGeneration)
            else { return }
            applyStatusBatch(admitted)
        case .sessionExited(let exit):
            forget(exit.session)
            publishRoster()
        default:
            break
        }
    }

    /// The ack landed: install the baseline it decided, then hand back every
    /// batch that raced it, in arrival order, before anything newer applies.
    ///
    /// Draining one at a time rather than as an array is the point — a batch
    /// arriving mid-drain queues behind what is left instead of overtaking it,
    /// which is the window a live batch used to slip through.
    private func settleStatusSubscription(_ subscription: Termiod.SubscribedPayload) {
        guard statusLedger.settle(generation: statusGeneration) else { return }
        if subscription.gap {
            // The cursor aged out of the ring, or this is a first subscribe.
            // Only the roster says what is true *now*, so the deltas standing
            // in for rows are dropped and the `list` already in flight behind
            // this is what re-establishes them. The cursor restarts at the
            // baseline the host named, because there is no continuity left to
            // preserve — that is what a gap *is*.
            statusOverrides.removeAll()
            // A gap has no continuity to preserve, and the `list` behind this
            // rebuilds every row — so the host's baseline is adopted outright
            // rather than walked to.
            statusCursor.adoptBaseline(subscription.seq)
            publishRoster()
        }
        while let held = statusLedger.releaseNext(generation: statusGeneration) {
            applyStatusBatch(held)
        }
    }

    /// Apply one `status:` batch, unless the cursor says it is already old
    /// news. A dropped batch is one that would roll a session's status
    /// backwards — a finished agent reading `working` again.
    private func applyStatusBatch(_ change: Termiod.StatusChangedPayload) {
        guard statusCursor.admit(seq: change.seq) != .drop else { return }
        applyStatus(change.report)
    }

    /// One interpretation of a status, whichever channel carried it.
    ///
    /// The device says what happened and which of its channels said so; this
    /// applies the one rule that is the viewer's. A turn the device derived
    /// (`turnEnded`) reads `idle` on the session filling the screen and `done`
    /// on one that is not — the same call `TermioStore.applyTermiodStatus`
    /// makes on the Mac, so two devices watching one session agree.
    private func applyStatus(_ report: Termiod.StatusPayload) {
        guard sessionsByID[report.session] != nil else { return }
        var status = report.status
        if report.turnEnded, status == "idle", report.session != viewingSessionID {
            status = "done"
        }
        statusOverrides[report.session] = StatusDelta(status: status, title: report.title)
        publishRoster()
    }

    /// Republish the roster on demand, so a test can read what the phone would
    /// draw rather than assert on the backend's private bookkeeping.
    func forcePublishForTests() { publishRoster() }

    /// Seed the durable cursor, so a test can start from a phone that has
    /// already applied batches rather than build that state through the wire.
    func setStatusCursorForTests(_ seq: UInt64?) {
        statusCursor.reset()
        if let seq { statusCursor.adoptBaseline(seq) }
    }

    /// The link going down, without a socket to drop. What matters to the
    /// status plane is the generation bump, and this is the door it goes
    /// through in production too.
    func simulateLinkDropForTests() { forgetInFlight() }

    /// The cursor this phone would resume from. Read by tests; the resume
    /// itself happens in `handshakeLanded`.
    var statusResumeCursor: UInt64? { statusCursor.resumeFrom }

    private func publishRoster() {
        // A workspace id that churned between pushes would reshuffle every list
        // on screen, so nothing is published until the host names itself.
        guard let hostID else { return }
        let live = sessionOrder.compactMap { sessionsByID[$0] }
        onRoster?(DeviceRoster(
            hostID: hostID,
            projects: TermiodRoster.projects(
                from: live, homeDirectory: channel.homeDirectory),
            statusOverrides: statusOverrides
        ))
    }

    private func receiveListings(_ payload: Termiod.FsListedPayload) {
        for listing in payload.listings {
            if let failure = listing.error {
                onError?(failure)
                continue
            }
            onFileList?(listing.path, listing.entries.map {
                // Nothing is marked as changed: that flag comes from the working
                // diff, and this connection has no git plane.
                DeviceFileEntry(name: $0.name, isDirectory: $0.isDirectory)
            })
        }
    }

    private func receiveFileHeader(_ header: Termiod.FsFilePayload, responseID: UInt64?) {
        guard let request = request(for: responseID, in: pendingReads),
              let path = pendingReads.removeValue(forKey: request)
        else { return }
        guard header.length > 0 else {
            deliver(path: path, header: header, data: Data())
            return
        }
        readsInProgress[request] = (path, header, Data())
    }

    /// Not private for the same reason `receive(_:)` is not: the bytes behind
    /// one read landing in another read's file is silent when it happens.
    func receiveFileChunk(_ payload: Data) {
        let chunk: (request: UInt64, offset: UInt64, last: Bool, data: Data)
        do {
            chunk = try Termiod.decodeFileChunk(payload)
        } catch {
            // The header is what says which read a chunk belongs to, so an
            // unreadable one cannot be attributed. Every read in flight is
            // abandoned rather than left waiting on a stream that has stopped
            // making sense.
            readsInProgress.removeAll()
            report(error, doing: localized("Couldn't read that file."))
            return
        }
        // A chunk names its read, so the bytes of two files streaming at once
        // never interleave into one.
        guard var pending = readsInProgress[chunk.request] else { return }
        pending.data.append(chunk.data)
        readsInProgress[chunk.request] = pending
        guard chunk.last || UInt64(pending.data.count) >= pending.header.length else { return }
        readsInProgress[chunk.request] = nil
        deliver(path: pending.path, header: pending.header, data: pending.data)
    }

    private func deliver(path: String, header: Termiod.FsFilePayload, data: Data) {
        onFile?(DeviceFile(
            path: path,
            data: data,
            size: Int(clamping: header.size),
            // The host reports bytes and says nothing about what they are, so
            // the classification is this side's.
            isBinary: data.prefix(8 << 10).contains(0),
            isTruncated: header.truncated,
            modifiedMilliseconds: Int(clamping: header.mtime) * 1000
        ))
    }

    private func receiveMatches(_ payload: Termiod.FsMatchedPayload, responseID: UInt64?) {
        guard let request = request(for: responseID, in: pendingSearches),
              let query = pendingSearches.removeValue(forKey: request)
        else { return }
        guard !payload.indexIsMissing else {
            // Reporting an unindexed checkout as "no matches" would be a claim
            // about the repository rather than about the connection.
            onError?(localized("This device hasn't indexed this project's filenames."))
            return
        }
        onSearchResults?(query, payload.paths, payload.paths.count >= Int(Self.searchLimit))
    }

    // MARK: - Transfers

    private func enqueue(_ transfer: Transfer) {
        transfers.append(transfer)
        guard transfers.count == 1 else { return }
        openNextTransfer()
    }

    private func openNextTransfer() {
        guard let transfer = transfers.first else { return }
        let digest = SHA256.hash(data: transfer.data)
            .map { String(format: "%02x", $0) }.joined()
        let request = nextSeq()
        transfers[0].openRequest = request
        let operation: Termiod.UploadOpenOperation
        switch transfer.destination {
        case .file(let path, let root, _):
            operation = Termiod.UploadOpenOperation(
                dest: path, root: root,
                size: UInt64(transfer.data.count), sha256: digest, seq: request)
        case .scratch(let name):
            operation = Termiod.UploadOpenOperation(
                dest: "temp:\(name)", session: sessionID,
                size: UInt64(transfer.data.count), sha256: digest, seq: request)
        }
        do {
            try channel.send(control: operation)
        } catch {
            transfers.removeFirst()
            report(error, doing: localized("Couldn't send that file to the device."))
            openNextTransfer()
        }
    }

    private func receiveUploadOpened(_ opened: Termiod.UploadOpenedPayload, responseID: UInt64?) {
        guard !transfers.isEmpty else { return }
        // A reply naming an open this queue has moved past belongs to a transfer
        // already abandoned; honouring it would hand the head transfer someone
        // else's upload id and send its bytes to the wrong file.
        guard responseID == nil || responseID == transfers[0].openRequest else { return }
        transfers[0].uploadID = opened.uploadId
        transfers[0].offset = opened.offset
        sendNextChunk()
    }

    /// One chunk per ack — the daemon's credit-of-one, which keeps a transfer
    /// from starving the keystrokes sharing this connection.
    private func sendNextChunk() {
        guard let transfer = transfers.first, let uploadID = transfer.uploadID else { return }
        let start = Int(clamping: transfer.offset)
        guard start < transfer.data.count else {
            commit(transfer, uploadID: uploadID)
            return
        }
        let end = min(start + Termiod.maximumDataFrameSize, transfer.data.count)
        channel.send(kind: .upload, payload: Termiod.uploadChunkPayload(
            uploadID: uploadID, offset: transfer.offset,
            data: transfer.data.subdata(in: start ..< end)))
    }

    private func receiveUploadAck(_ ack: Termiod.UploadAckPayload) {
        guard !transfers.isEmpty, transfers[0].uploadID == ack.uploadId else { return }
        transfers[0].offset = ack.offset
        sendNextChunk()
    }

    private func commit(_ transfer: Transfer, uploadID: String) {
        // Only ever reached with the head transfer, but the subscript below is
        // what would trap if that ever stopped being true.
        guard !transfers.isEmpty else { return }
        let base: UInt64?
        switch transfer.destination {
        case .file(_, _, let baseModifiedSeconds): base = baseModifiedSeconds
        case .scratch: base = nil
        }
        let request = nextSeq()
        transfers[0].commitRequest = request
        do {
            try channel.send(control: Termiod.UploadCommitOperation(
                uploadId: uploadID, ifUnmodifiedSince: base, seq: request))
        } catch {
            transfers.removeFirst()
            report(error, doing: localized("Couldn't save that file on the device."))
            openNextTransfer()
        }
    }

    private func receiveUploadCommitted(
        _ committed: Termiod.UploadCommittedPayload, responseID: UInt64?
    ) {
        guard !transfers.isEmpty else { return }
        // Same reason as `upload_opened`: a commit this queue has moved past
        // would otherwise pop the transfer now at its head and report the wrong
        // file as saved.
        guard responseID == nil || responseID == transfers[0].commitRequest else { return }
        let transfer = transfers.removeFirst()
        switch transfer.destination {
        case .file(let path, _, _):
            onWritten?(path, Int(clamping: committed.mtime) * 1000)
        case .scratch:
            onUploaded?(committed.path)
        }
        openNextTransfer()
    }

    // MARK: - Failure

    /// A device refusal names the request it answers, so it fails that caller
    /// and leaves everything else in flight alone.
    ///
    /// It used to be attributed to whatever this connection had outstanding,
    /// newest concern first — which meant a refused search could cancel a read
    /// that was still perfectly alive, and the read would then hang until the
    /// socket dropped.
    private func failInFlight(_ message: String, responseID: UInt64?) {
        defer { onError?(message) }
        guard let responseID else {
            // A rejected upload chunk names nothing — a `U` frame carries no
            // `seq`, so the refusal carries neither a `re` nor an upload id.
            // Charging it to the head is an inference, and it holds because
            // every other unaddressed refusal this daemon sends closes the
            // connection, where `forgetInFlight()` clears the queue anyway.
            // Left parked, the head would stall every transfer behind it.
            if transfers.first?.uploadID != nil {
                transfers.removeFirst()
                openNextTransfer()
            }
            return
        }
        if pendingReads.removeValue(forKey: responseID) != nil { return }
        if readsInProgress.removeValue(forKey: responseID) != nil { return }
        if pendingSearches.removeValue(forKey: responseID) != nil { return }
        guard let index = transfers.firstIndex(where: {
            $0.openRequest == responseID || $0.commitRequest == responseID
        }) else { return }
        transfers.remove(at: index)
        // Only the head transfer is ever on the wire, so a refused one has to
        // hand the queue on or everything behind it stalls.
        if index == 0 { openNextTransfer() }
    }

    /// A dropped socket takes every in-flight request with it. Left in place,
    /// a reply on the next connection could carry an id this one had already
    /// handed out, and land on a request nobody is waiting for any more.
    private func forgetInFlight() {
        pendingReads.removeAll()
        pendingSearches.removeAll()
        readsInProgress.removeAll()
        transfers.removeAll()
        // The link went down mid-handshake: an ack that arrives on the *next*
        // connection must not settle this attempt, and batches held for it must
        // not be applied against a baseline that never landed. The generation
        // bump is what makes both impossible. `statusCursor` deliberately
        // survives — it is the whole point of resuming.
        statusSubscriptionSeq = nil
        statusLedger.stop()
        statusGeneration = statusLedger.generation
    }

    private func forget(_ sessionID: String) {
        sessionsByID[sessionID] = nil
        statusOverrides[sessionID] = nil
        sessionOrder.removeAll { $0 == sessionID }
    }

    private func report(_ error: Error, doing what: String) {
        Log.device.error("""
        \(what, privacy: .public): \(error.localizedDescription, privacy: .public)
        """)
        onError?(what)
    }

    private func nextSeq() -> UInt64 {
        seq &+= 1
        return seq
    }

    /// The request id the `status:` subscription went out with, so its reply —
    /// a cursor, a `gap`, or a refusal from a device too old to know the
    /// resource — can be told from every other reply on this channel.
    private var statusSubscriptionSeq: UInt64?

    private func nextSeq(statusSubscription: Bool) -> UInt64 {
        let id = nextSeq()
        if statusSubscription { statusSubscriptionSeq = id }
        return id
    }

    /// Join a project root and a root-relative path. "" is the root itself,
    /// which is what the file pane asks for first.
    private static func absolutePath(root: String, path: String) -> String {
        path.isEmpty ? root : (root as NSString).appendingPathComponent(path)
    }
}

// MARK: - Pairing

/// A pairing dial that did not reach a device, carrying whatever said so — the
/// daemon's own refusal, or the fact that nothing answered at all.
struct DeviceUnreachable: Error {
    let message: String
}

extension TermiodBackend {
    /// Dial once, wait for `hello_ok`, hand back the device's `host_id`. Nothing
    /// is written to the paired list until this answers: saving an unverified
    /// address is what produced the companion's paired-but-unreachable state.
    ///
    /// `completion` runs on the main queue, exactly once.
    static func verify(
        endpoint: DeviceEndpoint, completion: @escaping (Result<String, DeviceUnreachable>) -> Void
    ) {
        let channel = TermiodChannel(
            endpoint: endpoint, name: "pair", role: "control",
            capabilities: Termiod.controlCapabilities, delegateQueue: .main
        )
        var answered = false
        // The link never gives up on its own, so a box that is not there has to
        // become a refusal the person can act on.
        let deadline = DispatchWorkItem {
            guard !answered else { return }
            answered = true
            retire(channel)
            completion(.failure(DeviceUnreachable(message: localized("That device didn't answer."))))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: deadline)
        channel.onReady = { handshake in
            guard !answered else { return }
            answered = true
            deadline.cancel()
            retire(channel)
            completion(.success(handshake.hostId))
        }
        channel.onFailure = { reason in
            guard !answered else { return }
            answered = true
            deadline.cancel()
            retire(channel)
            completion(.failure(DeviceUnreachable(message: reason)))
        }
        channel.start()
    }
}

// MARK: - Roster synthesis

private extension DeviceRoster {
    /// The device's flat session list as the Device → Workspace → Project →
    /// Session tree the screens draw. Three things the wire does not answer:
    ///
    /// Three things the wire does not answer, decided here:
    ///
    /// - **The name.** Device architecture §4 is explicit that the host never
    ///   supplies one, so nothing is reported and `PairedMac.name` — the name
    ///   the phone gave the box when it paired — stands.
    /// - **The agents.** Each row's agent is read off `foregroundArgv`, which
    ///   exists precisely so the client decides. The ＋ menu is the weaker half:
    ///   it offers the built-in list as a fallback, so it can offer an agent the
    ///   box does not have. `agents_probed` / `AgentPresence` is the answer to
    ///   that and is not wired up yet (see the RFC's P4 follow-ups) — a separate
    ///   change from this one, which only fixed how replies find their caller.
    /// - **The workspace.** One device is one workspace, and it carries no
    ///   `deviceAlias`: the box *is* the paired peer.
    init(
        hostID: String,
        projects: [TermiodRoster.Project],
        statusOverrides: [String: StatusDelta]
    ) {
        self.init(
            deviceID: hostID,
            deviceName: nil,
            agents: RosterAgent.legacyDefaults,
            projects: projects.map { project in
                // Named here rather than on the wire: the words a person reads
                // are the client's.
                let name = switch project.kind {
                case .terminals: localized("Terminals")
                case .chats: localized("Chats")
                case .folder: project.name
                }
                return MockProject(
                    name: name,
                    path: project.path,
                    rosterID: project.id,
                    kind: project.kind.rawValue,
                    workspaceID: hostID,
                    workspaceName: "",
                    sessions: project.sessions.map {
                        MockSession(
                            device: $0, container: project, named: name,
                            revision: statusOverrides[$0.id])
                    }
                )
            }
        )
    }
}

private extension MockSession {
    init(
        device information: Termiod.SessionInformation,
        container: TermiodRoster.Project,
        named containerName: String,
        revision: StatusDelta?
    ) {
        let agent = TermiodAgentLaunch.agent(for: information)
        let declared = information.agentID.flatMap { $0.isEmpty ? nil : $0 } != nil
        let reported = revision?.title ?? information.title
        let title = reported.flatMap { $0.isEmpty ? nil : $0 }
        self.init(
            // A reported title first, then the agent's display name when the
            // device declared one: `displayLabel` hands back the raw `agent_id`
            // there, so a chat would read `terminal` rather than `Terminal`.
            // Without a declared agent it is what names the program actually
            // running (`zsh`) instead of the daemon's uuid handle.
            title: title ?? (declared ? agent.name : information.displayLabel),
            project: containerName,
            agent: agent,
            status: SessionStatus(wire: revision?.status ?? information.status),
            subtitle: "",
            time: "",
            rosterID: information.id,
            projectRosterID: container.id,
            projectPath: container.path
        )
    }
}

/// The two fields an `E status` revises on a row the device already described.
struct StatusDelta: Equatable {
    let status: String
    let title: String?
}

/// What the client decides about a session the device merely describes: which
/// agent it is, and what to run when starting a new one.
enum TermiodAgentLaunch {
    /// How output should look, which belongs to the viewer wherever the process
    /// runs. Nothing here names a path or an identity — the device owns those.
    static let presentationEnvironment = [
        ["TERM", "xterm-ghostty"],
        ["COLORTERM", "truecolor"],
        ["TERM_PROGRAM", "termio"],
    ]

    /// A login shell runs the agent so it is found on the user's own `PATH`; a
    /// bare exec is how agents came up dead at 0 ms on the Mac.
    static func argv(forAgent id: String) -> [String] {
        guard id != RosterAgent.terminal.id else { return [] }
        return ["/bin/sh", "-lc", "exec \(shellQuoted(id))"]
    }

    /// The same, into the scratch directory a loose agent belongs in — created
    /// on the way, because nothing on the device has made it yet.
    static func looseChatArgv(forAgent id: String, root: String) -> [String] {
        let directory = shellQuoted(root)
        guard id != RosterAgent.terminal.id else {
            return ["/bin/sh", "-lc", "mkdir -p \(directory) && cd \(directory) && exec \"$SHELL\" -l"]
        }
        return ["/bin/sh", "-lc",
                "mkdir -p \(directory) && cd \(directory) && exec \(shellQuoted(id))"]
    }

    /// Single-quoted for `sh`. Neither an agent id nor a root is hostile, but
    /// both land inside a shell command and a path with a space in it would
    /// otherwise spawn in the wrong place.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The device's own `agent_id` wins; without one the foreground argv is
    /// read, because the host reports the process and the client owns the
    /// mapping to an agent.
    static func agent(for information: Termiod.SessionInformation) -> RosterAgent {
        if let id = information.agentID, !id.isEmpty { return RosterAgent.fallback(wire: id) }
        guard let executable = information.foregroundArgv?.first, !executable.isEmpty else {
            return .terminal
        }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        let program = name.hasPrefix("-") ? String(name.dropFirst()) : name
        return RosterAgent.legacyDefaults.first { $0.id == program } ?? .terminal
    }
}
