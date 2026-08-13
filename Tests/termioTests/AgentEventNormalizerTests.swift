import TermioShared
import XCTest

@testable import termio

/// Pins the Claude transcript dialect and the wire round-trip behind it: the
/// block types that become events, the row types that must be skipped without
/// throwing, the upsert that makes a re-read converge instead of duplicating,
/// the promotion of TodoWrite into a plan, the unified diff built from an edit
/// tool's before/after, and a batch surviving an encode/decode hop.
final class AgentEventNormalizerTests: XCTestCase {
    private func normalize(_ rows: [[String: Any]]) -> [ClaudeTranscriptNormalizer.Produced] {
        var normalizer = ClaudeTranscriptNormalizer()
        return rows.flatMap { normalizer.events(from: $0) }
    }

    private func assistant(_ blocks: [[String: Any]], uuid: String = "u1") -> [String: Any] {
        ["type": "assistant", "uuid": uuid, "message": ["content": blocks]]
    }

    func testTextAndThinkingBecomeSeparateEvents() {
        let events = normalize([
            assistant([
                ["type": "thinking", "thinking": "weighing options"],
                ["type": "text", "text": "Here is the plan."],
            ])
        ])
        XCTAssertEqual(events.count, 2)
        guard case .text(let reasoning, let isThinking) = events[0].payload,
            case .text(let prose, let isProse) = events[1].payload
        else { return XCTFail("expected two text events") }
        XCTAssertEqual(reasoning, "weighing options")
        XCTAssertTrue(isThinking)
        XCTAssertEqual(prose, "Here is the plan.")
        XCTAssertFalse(isProse)
    }

    /// A real transcript is mostly rows that are not conversation. None of them
    /// may produce an event, and none may throw.
    func testNonConversationRowsAreSkipped() {
        let noise: [[String: Any]] = [
            ["type": "mode", "mode": "plan"],
            ["type": "attachment", "id": "a1"],
            ["type": "file-history-snapshot", "snapshot": [:]],
            ["type": "ai-title", "title": "something"],
            ["type": "summary"],
            ["type": "assistant"],
            ["type": "user", "message": ["content": []]],
        ]
        XCTAssertTrue(normalize(noise).isEmpty)
    }

    func testToolResultUpsertsOntoItsCallRatherThanAddingACard() {
        var normalizer = ClaudeTranscriptNormalizer()
        let started = normalizer.events(
            from: assistant([
                ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "swift build"]]
            ]))
        XCTAssertEqual(started.count, 1)
        guard case .tool(_, _, let kind, let title, _, let running, _) = started[0].payload else {
            return XCTFail("expected a tool event")
        }
        XCTAssertEqual(kind, .execute)
        XCTAssertEqual(title, "swift build")
        XCTAssertEqual(running, .running)

        let finished = normalizer.events(
            from: [
                "type": "user", "uuid": "u2",
                "message": ["content": [["type": "tool_result", "tool_use_id": "t1", "is_error": true]]],
            ])
        XCTAssertEqual(finished.count, 1)
        guard case .tool(let call, _, _, _, _, let status, _) = finished[0].payload else {
            return XCTFail("expected the tool event again")
        }
        XCTAssertEqual(status, .error)
        // Same upsert key both times: the client replaces in place, so a
        // replayed transcript converges instead of growing a second card.
        XCTAssertEqual(started[0].upsertKey, finished[0].upsertKey)
        XCTAssertEqual(call, "t1")
    }

    func testTodoWriteBecomesAPlanNotAToolCard() {
        let events = normalize([
            assistant([
                [
                    "type": "tool_use", "id": "t2", "name": "TodoWrite",
                    "input": [
                        "todos": [
                            ["content": "Write the normalizer", "status": "completed"],
                            ["content": "Render it", "status": "in_progress"],
                            ["content": "Ship", "status": "pending"],
                        ]
                    ],
                ]
            ])
        ])
        XCTAssertEqual(events.count, 1)
        guard case .plan(let items) = events[0].payload else { return XCTFail("expected a plan") }
        XCTAssertEqual(items.map(\.status), [.completed, .inProgress, .pending])
        XCTAssertEqual(items.first?.text, "Write the normalizer")
    }

    /// The user side of a transcript carries the CLI's own plumbing. None of it
    /// may reach the phone as something the human said.
    func testInjectedUserContentIsNotShownAsTheHumanSpeaking() {
        func user(_ text: String, meta: Bool = false) -> [String: Any] {
            var row: [String: Any] = [
                "type": "user", "uuid": "u9", "message": ["content": text],
            ]
            if meta { row["isMeta"] = true }
            return row
        }

        XCTAssertTrue(normalize([user("Base directory for this skill: …", meta: true)]).isEmpty)
        XCTAssertTrue(normalize([user("<local-command-stdout>Login successful</local-command-stdout>")]).isEmpty)

        let command = normalize([
            user(
                "<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>"
            )
        ])
        guard case .text(let spoken, _) = command.first?.payload else {
            return XCTFail("a slash command is still a turn the human took")
        }
        XCTAssertEqual(spoken, "/clear")

        guard case .text(let typed, _) = normalize([user("so should you close it?")]).first?.payload
        else { return XCTFail("expected the human's own words") }
        XCTAssertEqual(typed, "so should you close it?")
    }

    /// The shape current Claude Code writes: one task per call, status changed
    /// later by id. Every call re-emits the whole plan onto the same row, so the
    /// phone shows one checklist rather than a card per mutation.
    func testTaskCallsAccumulateIntoOnePlan() {
        var normalizer = ClaudeTranscriptNormalizer()
        func call(_ name: String, _ input: [String: Any], id: String) -> [ClaudeTranscriptNormalizer
            .Produced]
        {
            normalizer.events(
                from: assistant([["type": "tool_use", "id": id, "name": name, "input": input]]))
        }

        XCTAssertEqual(call("TaskCreate", ["subject": "Read the transcript"], id: "c1").count, 1)
        let created = call("TaskCreate", ["subject": "Render it"], id: "c2")
        guard case .plan(let both) = created[0].payload else { return XCTFail("expected a plan") }
        XCTAssertEqual(both.map(\.text), ["Read the transcript", "Render it"])
        XCTAssertEqual(both.map(\.status), [.pending, .pending])

        let updated = call("TaskUpdate", ["taskId": "1", "status": "completed"], id: "c3")
        guard case .plan(let after) = updated[0].payload else { return XCTFail("expected a plan") }
        XCTAssertEqual(after.map(\.status), [.completed, .pending])
        // One row for the whole plan, whichever call revised it.
        XCTAssertEqual(created[0].upsertKey, updated[0].upsertKey)
        XCTAssertEqual(created[0].upsertKey, "plan")

        // A status change for a task this reader never saw is a tool card, not
        // an invented checklist entry.
        let stray = call("TaskUpdate", ["taskId": "99", "status": "completed"], id: "c4")
        guard case .tool = stray[0].payload else { return XCTFail("expected a tool card") }
    }

    func testEditToolAlsoProducesAUnifiedDiffTheDiffParserCanRead() {
        let events = normalize([
            assistant([
                [
                    "type": "tool_use", "id": "t3", "name": "Edit",
                    "input": [
                        "file_path": "/tmp/Sample.swift",
                        "old_string": "let a = 1\nlet b = 2\nlet c = 3",
                        "new_string": "let a = 1\nlet b = 20\nlet c = 3",
                    ],
                ]
            ])
        ])
        XCTAssertEqual(events.count, 2)
        guard case .diff(_, let path, let unified) = events[1].payload else {
            return XCTFail("expected a diff alongside the tool card")
        }
        XCTAssertEqual(path, "/tmp/Sample.swift")
        // Only the changed line moves; the LCS keeps the neighbours as context.
        XCTAssertTrue(unified.contains("-let b = 2"))
        XCTAssertTrue(unified.contains("+let b = 20"))
        XCTAssertTrue(unified.contains(" let a = 1"))
        XCTAssertFalse(unified.contains("-let a = 1"))

        let parsed = DiffParser.lines(from: unified)
        XCTAssertEqual(parsed.filter { $0.kind == .addition }.count, 1)
        XCTAssertEqual(parsed.filter { $0.kind == .deletion }.count, 1)
    }

    func testWriteToolDiffsAgainstAnEmptyFile() {
        let events = normalize([
            assistant([
                [
                    "type": "tool_use", "id": "t4", "name": "Write",
                    "input": ["file_path": "/tmp/New.swift", "content": "one\ntwo"],
                ]
            ])
        ])
        guard case .diff(_, _, let unified) = events.last?.payload else {
            return XCTFail("expected a diff for a new file")
        }
        XCTAssertTrue(unified.contains("+one"))
        XCTAssertTrue(unified.contains("+two"))
        // A new file is all additions — checked through the parser, since the
        // `--- a/` header legitimately starts with hyphens.
        XCTAssertTrue(DiffParser.lines(from: unified).allSatisfy { $0.kind != .deletion })
    }

    func testUnknownToolStillRendersAsAnOtherCard() {
        let events = normalize([
            assistant([["type": "tool_use", "id": "t5", "name": "SomeFutureTool", "input": [:]]])
        ])
        guard case .tool(_, let name, let kind, _, _, _, _) = events.first?.payload else {
            return XCTFail("expected a tool event")
        }
        XCTAssertEqual(name, "SomeFutureTool")
        XCTAssertEqual(kind, .other)
    }

    /// The batch has to survive the hop the phone actually makes it take.
    func testEventBatchSurvivesTheWireRoundTrip() {
        let events = [
            AgentEvent(seq: 1, role: .agent, payload: .text(text: "hello", thinking: false)),
            AgentEvent(
                seq: 2, role: .agent,
                payload: .tool(
                    call: "t1", name: "Read", kind: .read, title: "App.swift",
                    subtitle: "/tmp", status: .done, locations: ["/tmp/App.swift"])),
            AgentEvent(
                seq: 3, role: .system,
                payload: .sessionInfo(title: "termio", model: nil, state: .dormant)),
        ]
        let encoded = CompanionControl.agentEvents(sessionID: "s1", events: events).encoded()
        guard case .agentEvents(let sessionID, let decoded)? = CompanionControl.decode(encoded) else {
            return XCTFail("batch did not decode")
        }
        XCTAssertEqual(sessionID, "s1")
        XCTAssertEqual(decoded, events)
    }

    /// Two phones on one session must each get the whole conversation. The
    /// first cut shared a single cursor on the session, so whichever client
    /// polled first consumed the new bytes and the second silently received an
    /// empty batch — the exact failure the multi-client rule forbids.
    /// A cold subscribe replays the log, so the log has to be in conversation
    /// order. The trap: a tool's card is revised when its result lands, and a
    /// revision that re-appended would put the finished card *below* the diff
    /// it produced — every edit in the transcript would read backwards.
    func testAFinishedToolKeepsItsPlaceAheadOfItsOwnDiff() async throws {
        let path = NSTemporaryDirectory() + "chat-lens-\(UUID().uuidString).jsonl"
        let rows = """
            {"type":"assistant","uuid":"u1","message":{"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/tmp/A.swift","old_string":"a","new_string":"b"}}]}}
            {"type":"user","uuid":"u2","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}
            {"type":"assistant","uuid":"u3","message":{"content":[{"type":"text","text":"done"}]}}
            """
        try (rows + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = AgentEventStore()
        let client = NSObject()
        var stream = await store.subscribe(
            client: ObjectIdentifier(client), sessionID: "s2", transcriptPath: path, since: 0
        ).makeAsyncIterator()
        guard let batch = await stream.next() else { return XCTFail("no replay") }

        XCTAssertEqual(batch.map(\.upsertKey), ["tool:t1", "diff:t1:/tmp/A.swift", nil])
        guard case .tool(_, _, _, _, _, let status, _) = batch[0].payload else {
            return XCTFail("expected the tool card first")
        }
        // In its original place, but already carrying the result.
        XCTAssertEqual(status, .done)
    }

    func testTwoClientsOnOneSessionEachReceiveEverything() async throws {
        let path = NSTemporaryDirectory() + "chat-lens-\(UUID().uuidString).jsonl"
        let row = """
            {"type":"assistant","uuid":"u1","message":{"content":[{"type":"text","text":"first"}]}}
            """
        try (row + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = AgentEventStore()
        let firstClient = NSObject()
        let secondClient = NSObject()

        var first = await store.subscribe(
            client: ObjectIdentifier(firstClient), sessionID: "s1", transcriptPath: path, since: 0
        ).makeAsyncIterator()
        var second = await store.subscribe(
            client: ObjectIdentifier(secondClient), sessionID: "s1", transcriptPath: path, since: 0
        ).makeAsyncIterator()

        let firstBatch = await first.next()
        let secondBatch = await second.next()
        XCTAssertEqual(firstBatch?.count, 1)
        XCTAssertEqual(secondBatch?.count, 1, "second client was starved by the first")
        XCTAssertEqual(firstBatch, secondBatch)

        // The live path is where the bug actually was: one client's read used to
        // consume the tail for everyone.
        let appended = """
            {"type":"assistant","uuid":"u2","message":{"content":[{"type":"text","text":"second"}]}}
            """
        guard let handle = FileHandle(forWritingAtPath: path) else {
            return XCTFail("cannot append to the transcript")
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((appended + "\n").utf8))
        try handle.close()

        let firstUpdate = await first.next()
        let secondUpdate = await second.next()
        XCTAssertEqual(firstUpdate?.count, 1)
        XCTAssertEqual(secondUpdate?.count, 1, "second client missed the live update")
        XCTAssertEqual(firstUpdate, secondUpdate)
        if case .text(let text, _)? = firstUpdate?.first?.payload {
            XCTAssertEqual(text, "second")
        } else {
            XCTFail("expected the appended text event")
        }
    }

    /// An event type this build predates drops itself out of the batch instead
    /// of voiding the batch around it.
    func testUnknownEventTypeDropsWithoutTakingTheBatchDown() {
        let payload = """
            {"t":"agentEvents","session":"s1","events":[\
            {"seq":1,"role":"agent","ev":{"t":"text","text":"kept"}},\
            {"seq":2,"role":"agent","ev":{"t":"telepathy","mood":"blue"}}]}
            """
        guard case .agentEvents(_, let decoded)? = CompanionControl.decode(payload) else {
            return XCTFail("batch did not decode")
        }
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.seq, 1)
    }
}
