import Foundation
import TermioShared

/// The host side of the content plane: turns an agent's on-disk transcript into
/// the `AgentEvent` stream clients subscribe to.
///
/// Why a store and not a renderer: `SessionTraceRenderer` answers "what did this
/// whole conversation look like" in one pass, which is the right shape for a
/// static HTML page and the wrong one for a phone that reconnects mid-turn. This
/// keeps a per-session log with a cursor, so a client can ask for the gap since
/// the last event it holds.
///
/// **An actor, not a main-actor class.** Reading and parsing a transcript tail is
/// file I/O plus JSON decoding; on a 20 MB conversation that is tens of
/// milliseconds. Doing it on the main actor would put a stutter in the Mac's UI
/// every time a phone was watching a busy agent — the content plane must never
/// be able to hitch the app that hosts it.
///
/// **Watched, not polled.** A timer ticking per subscribed session is an idle
/// wakeup storm on battery, and this codebase has already paid for one of those.
/// The transcript is watched with a vnode source and coalesced; a slow backstop
/// refresh covers the cases kqueue misses (a writer that replaces the file, a
/// network mount).
///
/// Delivery order vs display order — the one subtlety worth stating. `seq` is a
/// **delivery** counter. When a tool's result lands, its event is re-emitted
/// with a fresh `seq` so a client sitting at an older cursor learns about the
/// change. Display order is the client's business: it inserts an event at first
/// sight of its `upsertKey` and updates in place afterwards, so a tool card
/// never jumps to the bottom of the transcript when it finishes.
actor AgentEventStore {
    static let shared = AgentEventStore()

    /// Writes arrive in bursts (an agent flushes several records at once), so a
    /// vnode event is coalesced before the tail is read.
    private static let coalesceNanoseconds: UInt64 = 200_000_000
    /// Covers what kqueue does not: a writer that replaces the file rather than
    /// appending, and mounts where vnode events are unreliable.
    private static let backstopSeconds: UInt64 = 5
    /// A backstop against a pathological transcript, not a normal path. Reached
    /// only by a conversation far longer than any real session.
    private static let maximumLoggedEvents = 50_000

    private final class SessionState {
        var path: String
        /// The delivery log, ascending by `seq`. A superseded version of an
        /// upsert-keyed event is removed rather than left behind, so a cold
        /// subscribe replays each tool exactly once, already in its final state.
        var log: [AgentEvent] = []
        var nextSeq = 1
        /// Bytes of the transcript already parsed. Claude's JSONL is
        /// append-only, so a refresh only has to read the tail.
        var consumedBytes: UInt64 = 0
        /// Carry-over for a trailing partial line: the agent can flush
        /// mid-record, and parsing half a JSON object would drop the event.
        var pendingLine = ""
        var normalizer = ClaudeTranscriptNormalizer()
        var watcher: DispatchSourceFileSystemObject?

        init(path: String) { self.path = path }

        func reset(path: String) {
            self.path = path
            log.removeAll()
            nextSeq = 1
            consumedBytes = 0
            pendingLine = ""
            normalizer = ClaudeTranscriptNormalizer()
        }
    }

    /// One client's view of one session. The cursor lives here, not on the
    /// session: two phones watching the same conversation advance
    /// independently, and neither may consume the other's updates.
    private struct Subscription {
        let sessionID: String
        var cursor: Int
        let continuation: AsyncStream<[AgentEvent]>.Continuation
    }

    /// Keyed by client *and* session so one connection can hold more than one
    /// subscription without them overwriting each other.
    private struct Key: Hashable {
        let client: ObjectIdentifier
        let sessionID: String
    }

    private var sessions: [String: SessionState] = [:]
    private var subscriptions: [Key: Subscription] = [:]
    private var backstop: Task<Void, Never>?

    // MARK: - Subscribing

    /// Replays everything after `since` and then streams updates. A `since` of 0
    /// is a cold subscribe: the whole conversation, including one belonging to a
    /// session with no live process behind it.
    func subscribe(
        client: ObjectIdentifier, sessionID: String, transcriptPath: String, since: Int
    ) -> AsyncStream<[AgentEvent]> {
        let state = session(sessionID, path: transcriptPath)
        refresh(state)

        let (stream, continuation) = AsyncStream<[AgentEvent]>.makeStream()
        let key = Key(client: client, sessionID: sessionID)
        subscriptions[key] = Subscription(
            sessionID: sessionID, cursor: since, continuation: continuation)

        deliver(to: key)
        startWatching(sessionID)
        startBackstopIfNeeded()

        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(client: client, sessionID: sessionID) }
        }
        return stream
    }

    func unsubscribe(client: ObjectIdentifier, sessionID: String) {
        subscriptions.removeValue(forKey: Key(client: client, sessionID: sessionID))?
            .continuation.finish()
        pruneIdleResources()
    }

    /// Drops every subscription a client holds — the connection went away.
    func unsubscribeAll(client: ObjectIdentifier) {
        for key in subscriptions.keys where key.client == client {
            subscriptions.removeValue(forKey: key)?.continuation.finish()
        }
        pruneIdleResources()
    }

    private func session(_ sessionID: String, path: String) -> SessionState {
        if let existing = sessions[sessionID] {
            // A resume can point the same session at a new transcript file;
            // keeping the old offset would read from the wrong place forever.
            if existing.path != path {
                existing.watcher?.cancel()
                existing.watcher = nil
                existing.reset(path: path)
            }
            return existing
        }
        let fresh = SessionState(path: path)
        sessions[sessionID] = fresh
        return fresh
    }

    /// Sends each subscriber only what it has not seen, then advances its own
    /// cursor. Reading the log once and fanning out is what makes two viewers of
    /// one session correct.
    private func deliver(to key: Key? = nil) {
        let targets = key.map { [$0] } ?? Array(subscriptions.keys)
        for target in targets {
            guard var subscription = subscriptions[target],
                let state = sessions[subscription.sessionID]
            else { continue }
            // Kept in log order, which is conversation order — not sorted by
            // `seq`, which is delivery order. The client upserts, so a revised
            // event arriving out of numeric order still lands in its place.
            let pending = state.log.filter { $0.seq > subscription.cursor }
            guard let highest = pending.map(\.seq).max() else { continue }
            subscription.cursor = highest
            subscriptions[target] = subscription
            subscription.continuation.yield(pending)
        }
    }

    // MARK: - Watching

    private func startWatching(_ sessionID: String) {
        guard let state = sessions[sessionID], state.watcher == nil else { return }
        let descriptor = open(state.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename],
            queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [weak self] in
            Task { await self?.transcriptChanged(sessionID) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        state.watcher = source
    }

    private func transcriptChanged(_ sessionID: String) async {
        // Coalesce the burst: an agent flushing a turn produces several writes,
        // and reading the tail once at the end of them is both cheaper and less
        // likely to split a record.
        try? await Task.sleep(nanoseconds: Self.coalesceNanoseconds)
        guard let state = sessions[sessionID] else { return }

        // A replaced file leaves the old descriptor watching an unlinked inode,
        // so re-arm onto the new one before reading.
        if let watcher = state.watcher, watcher.data.contains(.delete) || watcher.data.contains(.rename) {
            watcher.cancel()
            state.watcher = nil
            startWatching(sessionID)
        }
        refresh(state)
        deliver()
    }

    private func startBackstopIfNeeded() {
        guard backstop == nil else { return }
        backstop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.backstopSeconds * 1_000_000_000)
                guard let self else { return }
                await self.refreshAll()
            }
        }
    }

    private func refreshAll() {
        let watched = Set(subscriptions.values.map(\.sessionID))
        for sessionID in watched {
            guard let state = sessions[sessionID] else { continue }
            refresh(state)
        }
        deliver()
    }

    private func pruneIdleResources() {
        guard subscriptions.isEmpty else { return }
        backstop?.cancel()
        backstop = nil
        for state in sessions.values {
            state.watcher?.cancel()
            state.watcher = nil
        }
    }

    // MARK: - Reading

    /// Reads the transcript's unread tail and folds the new rows into the log.
    private func refresh(_ state: SessionState) {
        guard let handle = FileHandle(forReadingAtPath: state.path) else { return }
        defer { try? handle.close() }

        // A transcript that shrank was replaced (a `--resume` that rewrote it, or
        // a cleared session). Start over rather than reading from a stale offset
        // into the middle of a record.
        let size = (try? handle.seekToEnd()) ?? 0
        if size < state.consumedBytes { state.reset(path: state.path) }
        guard size > state.consumedBytes else { return }

        try? handle.seek(toOffset: state.consumedBytes)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        state.consumedBytes = size

        let text = state.pendingLine + (String(data: data, encoding: .utf8) ?? "")
        var lines = text.components(separatedBy: "\n")
        // The last fragment is only a complete record if the read ended on a
        // newline; otherwise hold it back until the rest arrives.
        state.pendingLine = text.hasSuffix("\n") ? "" : (lines.popLast() ?? "")

        for line in lines {
            guard !line.isEmpty, let lineData = line.data(using: .utf8),
                let row = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            for produced in state.normalizer.events(from: row) {
                append(produced, to: state)
            }
        }
    }

    private func append(_ produced: ClaudeTranscriptNormalizer.Produced, to state: SessionState) {
        let event = AgentEvent(
            seq: state.nextSeq, role: produced.role, at: produced.at, turn: produced.turn,
            parent: produced.parent, payload: produced.payload)
        state.nextSeq += 1

        // A revised event keeps its **place** and takes a new `seq`. The place
        // is what a cold subscriber reads as conversation order: a tool card
        // that moved to the end of the log every time it finished would replay
        // below the diff it produced, and a plan would sink under the work it
        // describes. The new `seq` is what a client already holding the old
        // version needs in order to be told about the change at all.
        if let key = event.upsertKey,
            let existing = state.log.firstIndex(where: { $0.upsertKey == key }) {
            state.log[existing] = event
        } else {
            state.log.append(event)
        }

        if state.log.count > Self.maximumLoggedEvents {
            let dropped = state.log.count - Self.maximumLoggedEvents
            state.log.removeFirst(dropped)
            Log.companion.notice(
                "content plane dropped \(dropped, privacy: .public) oldest events past the cap")
        }
    }
}

/// Claude's transcript dialect. One of a closed set — the manifest says *where*
/// an agent's transcript lives, this says *how that shape reads*. Deliberately
/// not a configurable mapping DSL: every product-grade implementation of this
/// (waku, linkcode) writes real code per dialect, and pretending it is data buys
/// a mini-interpreter that is harder to write and harder to test.
///
/// Lenient by construction. The format is a vendor's internal detail, and a real
/// transcript carries a dozen row types that are not conversation at all
/// (`mode`, `attachment`, `file-history-snapshot`, …). Anything unrecognized is
/// skipped, never fatal.
struct ClaudeTranscriptNormalizer {
    struct Produced {
        let role: AgentEvent.Role
        let at: Date?
        let turn: String?
        let parent: String?
        let payload: AgentEvent.Payload

        var upsertKey: String? {
            switch payload {
            case .tool(let call, _, _, _, _, _, _): return "tool:\(call)"
            case .diff(let call, let path, _): return "diff:\(call):\(path)"
            case .plan: return "plan"
            default: return nil
            }
        }
    }

    /// Tool calls seen so far, so a `tool_result` arriving in a later row can
    /// re-emit the original card with its outcome instead of appearing as an
    /// orphaned blob of output.
    private var openTools: [String: Produced] = [:]

    /// The session's task list in creation order. Claude Code writes a plan two
    /// ways depending on its version: `TodoWrite` sends the whole list in one
    /// call, `TaskCreate`/`TaskUpdate` mutate one item at a time. Both fold into
    /// the same plan event, so the phone never learns which CLI wrote the
    /// transcript — and the incremental shape is why the list has to be held
    /// here rather than read off a single row.
    private var tasks: [(id: String, text: String, status: AgentEvent.PlanItem.Status)] = []

    mutating func events(from row: [String: Any]) -> [Produced] {
        let role: AgentEvent.Role
        switch row["type"] as? String {
        case "assistant": role = .agent
        case "user": role = .user
        default: return []
        }

        // A meta row is text the CLI injected into the conversation on the
        // user's behalf — a skill's body, an appended reminder. Rendering it in
        // a user bubble claims the human said it, which is worse than not
        // showing it at all.
        if row["isMeta"] as? Bool == true { return [] }

        guard let message = row["message"] as? [String: Any] else { return [] }
        let at = timestamp(row["timestamp"])
        let turn = row["uuid"] as? String
        // A sidechain is a subagent's transcript interleaved into the parent's.
        // The field is carried even though this build renders it inline, because
        // adding it later means re-keying every stored event.
        let parent = (row["isSidechain"] as? Bool == true) ? row["parentUuid"] as? String : nil

        if let plain = message["content"] as? String {
            guard let text = Self.spoken(plain, by: role) else { return [] }
            return [
                Produced(
                    role: role, at: at, turn: turn, parent: parent,
                    payload: .text(text: text, thinking: false))
            ]
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }

        var produced: [Produced] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = Self.spoken(block["text"] as? String ?? "", by: role) {
                    produced.append(
                        Produced(role: role, at: at, turn: turn, parent: parent, payload: .text(text: text, thinking: false)))
                }
            case "thinking":
                let text = block["thinking"] as? String ?? ""
                if !text.isEmpty {
                    produced.append(
                        Produced(role: role, at: at, turn: turn, parent: parent, payload: .text(text: text, thinking: true)))
                }
            case "tool_use":
                produced.append(contentsOf: toolUse(block, role: role, at: at, turn: turn, parent: parent))
            case "tool_result":
                if let updated = toolResult(block) { produced.append(updated) }
            default:
                break
            }
        }
        return produced
    }

    /// Claude stamps every row `"2026-08-13T12:04:11.312Z"`. Both formatters
    /// are kept because the fractional part is not guaranteed, and a missing
    /// timestamp is not worth dropping an event over — it only costs that
    /// message its clock. Instance-held rather than static: a formatter is not
    /// `Sendable`, and one per normalizer is still one per session.
    private let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let isoPlain = ISO8601DateFormatter()

    private func timestamp(_ raw: Any?) -> Date? {
        guard let text = raw as? String, !text.isEmpty else { return nil }
        return isoFractional.date(from: text) ?? isoPlain.date(from: text)
    }

    /// What a turn actually said, or nil when it said nothing a reader should
    /// see. Only user rows are filtered: the CLI writes its own plumbing into
    /// the user side of the transcript — a slash command arrives as a
    /// `<command-name>` envelope and its output as `<local-command-stdout>` —
    /// and a phone showing those as things the human typed reads as nonsense.
    /// A slash command is a real turn, so it survives as the command itself.
    private static func spoken(_ text: String, by role: AgentEvent.Role) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard role == .user else { return text }

        if let name = tagged("command-name", in: trimmed) {
            let arguments = tagged("command-args", in: trimmed) ?? ""
            return arguments.isEmpty ? name : "\(name) \(arguments)"
        }
        if trimmed.hasPrefix("<local-command-stdout>") { return nil }
        return text
    }

    private static func tagged(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
            let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private mutating func toolUse(
        _ block: [String: Any], role: AgentEvent.Role, at: Date?, turn: String?, parent: String?
    ) -> [Produced] {
        guard let call = block["id"] as? String, let name = block["name"] as? String else {
            return []
        }
        let input = block["input"] as? [String: Any] ?? [:]

        // TodoWrite is a plan, not a tool card. Promoting it is one of the four
        // things the chat lens can do that the terminal cannot.
        if name == "TodoWrite", let todos = input["todos"] as? [[String: Any]] {
            let items = todos.compactMap { todo -> AgentEvent.PlanItem? in
                guard let text = (todo["content"] ?? todo["activeForm"]) as? String else { return nil }
                return AgentEvent.PlanItem(
                    text: text, status: Self.planStatus(todo["status"] as? String ?? ""))
            }
            return [Produced(role: role, at: at, turn: turn, parent: parent, payload: .plan(items: items))]
        }

        // The newer shape of the same thing: one task per call, so the list is
        // accumulated here and the whole plan re-emitted. An update naming a
        // task this reader never saw (a transcript joined mid-session) falls
        // through to a plain tool card rather than inventing a checklist item.
        if name == "TaskCreate" || name == "TaskUpdate", let items = applyTaskCall(name, input: input) {
            return [Produced(role: role, at: at, turn: turn, parent: parent, payload: .plan(items: items))]
        }

        let card = Produced(
            role: role, at: at, turn: turn, parent: parent,
            payload: .tool(
                call: call, name: name, kind: Self.kind(of: name),
                title: Self.title(of: name, input: input),
                subtitle: Self.subtitle(of: name, input: input), status: .running,
                locations: Self.locations(of: name, input: input)))
        openTools[call] = card

        var produced = [card]
        // An edit tool carries the before and after inline, so the diff needs no
        // git round-trip and works for a file that was never committed.
        if let path = input["file_path"] as? String {
            if let old = input["old_string"] as? String, let new = input["new_string"] as? String {
                produced.append(
                    Produced(
                        role: role, at: at, turn: turn, parent: parent,
                        payload: .diff(
                            call: call, path: path,
                            unified: UnifiedDiff.between(old: old, new: new, path: path))))
            } else if name == "Write", let content = input["content"] as? String {
                produced.append(
                    Produced(
                        role: role, at: at, turn: turn, parent: parent,
                        payload: .diff(
                            call: call, path: path,
                            unified: UnifiedDiff.between(old: "", new: content, path: path))))
            }
        }
        return produced
    }

    /// Folds one `TaskCreate` / `TaskUpdate` into the running task list and
    /// returns the whole plan, or nil when the call says nothing about a task
    /// this reader is tracking.
    ///
    /// Ids are the creation ordinal, which is what the tool's own reply
    /// ("Task #2 created successfully") numbers them by — the create call
    /// itself never carries the id, and the reply is a sentence rather than a
    /// field, so the ordinal is the more reliable of the two.
    private mutating func applyTaskCall(_ name: String, input: [String: Any])
        -> [AgentEvent.PlanItem]?
    {
        if name == "TaskCreate" {
            guard let subject = (input["subject"] ?? input["activeForm"]) as? String,
                !subject.isEmpty
            else { return nil }
            tasks.append((id: String(tasks.count + 1), text: subject, status: .pending))
        } else {
            guard let taskID = taskIdentifier(in: input),
                let index = tasks.firstIndex(where: { $0.id == taskID })
            else { return nil }
            if let subject = input["subject"] as? String, !subject.isEmpty {
                tasks[index].text = subject
            }
            if let status = input["status"] as? String {
                tasks[index].status = Self.planStatus(status)
            }
        }
        return tasks.map { AgentEvent.PlanItem(text: $0.text, status: $0.status) }
    }

    /// The id arrives as a string in every transcript seen so far, but a JSON
    /// number is the obvious way for it to change, and a plan silently
    /// stopping is worse than the two lines it costs to accept both.
    private func taskIdentifier(in input: [String: Any]) -> String? {
        if let text = input["taskId"] as? String { return text }
        if let number = input["taskId"] as? Int { return String(number) }
        return nil
    }

    private static func planStatus(_ raw: String) -> AgentEvent.PlanItem.Status {
        switch raw {
        case "completed": return .completed
        case "in_progress": return .inProgress
        default: return .pending
        }
    }

    private mutating func toolResult(_ block: [String: Any]) -> Produced? {
        guard let call = block["tool_use_id"] as? String, let open = openTools[call],
            case .tool(_, let name, let kind, let title, let subtitle, _, let locations) = open.payload
        else { return nil }
        let failed = block["is_error"] as? Bool ?? false
        let updated = Produced(
            role: open.role, at: open.at, turn: open.turn, parent: open.parent,
            payload: .tool(
                call: call, name: name, kind: kind, title: title, subtitle: subtitle,
                status: failed ? .error : .done, locations: locations))
        openTools[call] = updated
        return updated
    }

    /// Maps a tool name onto ACP's closed vocabulary. An unknown tool lands on
    /// `.other` and still renders — the client never has to know this list.
    static func kind(of name: String) -> AgentEvent.ToolKind {
        switch name {
        case "Read", "NotebookRead": return .read
        case "Edit", "Write", "NotebookEdit": return .edit
        case "Bash", "BashOutput", "KillShell": return .execute
        case "Grep", "Glob", "ToolSearch": return .search
        case "Task", "TodoWrite": return .think
        case "WebFetch", "WebSearch": return .fetch
        default: return .other
        }
    }

    private static func title(of name: String, input: [String: Any]) -> String {
        if let path = input["file_path"] as? String {
            return (path as NSString).lastPathComponent
        }
        if let command = input["command"] as? String { return shortened(command) }
        if let pattern = input["pattern"] as? String { return pattern }
        if let query = input["query"] as? String { return query }
        if let url = input["url"] as? String { return url }
        if let prompt = input["prompt"] as? String { return prompt }
        return name
    }

    private static func subtitle(of name: String, input: [String: Any]) -> String? {
        if let description = input["description"] as? String { return description }
        if let path = input["file_path"] as? String {
            let directory = (path as NSString).deletingLastPathComponent
            return directory.isEmpty ? nil : abbreviatingHome(directory)
        }
        return nil
    }

    private static func locations(of name: String, input: [String: Any]) -> [String] {
        if let path = input["file_path"] as? String { return [path] }
        if let path = input["path"] as? String { return [path] }
        return []
    }

    /// Makes a command legible in two lines on a phone. Agents habitually prefix
    /// a `cd` into an absolute worktree path, which on a 390pt screen spends the
    /// whole card on the prefix and truncates the part that says what ran.
    private static func shortened(_ command: String) -> String {
        var text = command
        // Both separators appear in practice, and the path may be quoted.
        for separator in [" && ", "; "] where text.hasPrefix("cd ") {
            if let range = text.range(of: separator) {
                text = String(text[range.upperBound...])
                break
            }
        }
        return abbreviatingHome(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func abbreviatingHome(_ text: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }
}

/// Builds unified-diff text from an edit tool's before and after strings, so the
/// phone can render it with the same `DiffParser` the git pane already uses
/// rather than learning a second diff shape.
enum UnifiedDiff {
    static func between(old: String, new: String, path: String) -> String {
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
        let common = longestCommonSubsequence(oldLines, newLines)

        var body: [String] = []
        var oldIndex = 0
        var newIndex = 0
        for anchor in common {
            while oldIndex < oldLines.count, oldLines[oldIndex] != anchor {
                body.append("-" + oldLines[oldIndex])
                oldIndex += 1
            }
            while newIndex < newLines.count, newLines[newIndex] != anchor {
                body.append("+" + newLines[newIndex])
                newIndex += 1
            }
            body.append(" " + anchor)
            oldIndex += 1
            newIndex += 1
        }
        while oldIndex < oldLines.count {
            body.append("-" + oldLines[oldIndex])
            oldIndex += 1
        }
        while newIndex < newLines.count {
            body.append("+" + newLines[newIndex])
            newIndex += 1
        }

        let name = (path as NSString).lastPathComponent
        let header = [
            "--- a/\(name)", "+++ b/\(name)",
            "@@ -1,\(oldLines.count) +1,\(newLines.count) @@",
        ]
        return (header + body).joined(separator: "\n")
    }

    /// Classic dynamic-programming LCS. Edit payloads are the changed region of
    /// a file rather than the whole file, so the quadratic table stays small;
    /// the guard below keeps a pathological payload from stalling the host.
    private static func longestCommonSubsequence(_ old: [String], _ new: [String]) -> [String] {
        guard !old.isEmpty, !new.isEmpty else { return [] }
        guard old.count * new.count <= 1_000_000 else { return [] }

        var table = [[Int]](repeating: [Int](repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                table[i][j] =
                    old[i] == new[j]
                    ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var result: [String] = []
        var i = 0
        var j = 0
        while i < old.count, j < new.count {
            if old[i] == new[j] {
                result.append(old[i])
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }
}
