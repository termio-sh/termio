import XCTest
@testable import termio

/// The trajectory ledger's projection step: three transcript schemas folded into rows.
/// What is pinned here is what the page would silently get wrong — a tool call and its
/// result landing as two rows instead of one timed step, a turn boundary in the wrong
/// place, or a failure that stops being visible.
final class SessionTrajectoryTests: XCTestCase {
    private func render(_ lines: [String], name: String = "transcript.jsonl") throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(name).path
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try SessionTraceRenderer.html(jsonlPath: path, title: "t",
                                             theme: .builtin(dark: true), includeHeader: false)
    }

    /// Rows are counted by their kind marker, which is also what the filter bar selects on —
    /// inside the ledger only, since the stylesheet names the same markers.
    private func rows(_ html: String, kind: String) -> Int {
        guard let ledger = html.components(separatedBy: "<section class=\"ledger\">").last
        else { return 0 }
        return ledger.components(separatedBy: "data-kind=\"\(kind)\"").count - 1
    }

    func testClaudeToolCallAndResultAreOneTimedStep() throws {
        let html = try render([
            #"{"type":"user","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"go"}}"#,
            #"{"type":"assistant","timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"assistant","model":"claude-opus-5","content":[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"git status"}}]}}"#,
            #"{"type":"user","timestamp":"2026-01-01T00:00:03.500Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_1","content":"clean"}]}}"#,
        ])
        XCTAssertEqual(rows(html, kind: "tool"), 1)
        XCTAssertEqual(rows(html, kind: "user"), 1)
        // The call → result interval is the step's own duration, not the row's arrival time.
        XCTAssertTrue(html.contains(">2.5s<"), "expected the paired call to carry its 2.5s")
        XCTAssertTrue(html.contains("git status"), "the row previews the argument that names the work")
        XCTAssertTrue(html.contains("clean"), "the result belongs to the call's own row")
    }

    func testClaudeFailedToolStaysVisibleToTheErrorFilter() throws {
        let html = try render([
            #"{"type":"assistant","timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"false"}}]}}"#,
            #"{"type":"user","timestamp":"2026-01-01T00:00:02.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_1","is_error":true,"content":"boom"}]}}"#,
        ])
        XCTAssertTrue(html.contains("data-err=\"1\""))
        XCTAssertTrue(html.contains("failed"))
    }

    func testEachUserMessageOpensATurn() throws {
        let html = try render([
            #"{"type":"user","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"first"}}"#,
            #"{"type":"assistant","timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}"#,
            #"{"type":"user","timestamp":"2026-01-01T00:00:02.000Z","message":{"role":"user","content":"second"}}"#,
        ])
        XCTAssertTrue(html.contains("Turn 1"))
        XCTAssertTrue(html.contains("Turn 2"))
        XCTAssertFalse(html.contains("Turn 3"))
    }

    /// Harness-injected context is a note, not a turn the human took — it must not split
    /// the ledger into a turn per reminder.
    func testInjectedContextIsNotATurn() throws {
        let html = try render([
            #"{"type":"user","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"go"}}"#,
            #"{"type":"user","isMeta":true,"timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"user","content":"<system-reminder>x</system-reminder>"}}"#,
        ])
        XCTAssertEqual(rows(html, kind: "note"), 1)
        XCTAssertFalse(html.contains("Turn 2"))
    }

    /// Code mode dispatches through `custom_tool_call`; before it was read, a whole Codex
    /// session rendered with no tool activity at all.
    func testCodexCodeModeToolCallsRender() throws {
        let html = try render([
            #"{"timestamp":"2026-01-01T00:00:00.000Z","type":"session_meta","payload":{"cwd":"/tmp","cli_version":"1"}}"#,
            #"{"timestamp":"2026-01-01T00:00:00.500Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            #"{"timestamp":"2026-01-01T00:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"go"}}"#,
            #"{"timestamp":"2026-01-01T00:00:02.000Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"c1","name":"exec","input":"tools.exec_command()"}}"#,
            #"{"timestamp":"2026-01-01T00:00:03.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":[{"type":"input_text","text":"done"}]}}"#,
            #"{"timestamp":"2026-01-01T00:00:04.000Z","type":"event_msg","payload":{"type":"agent_message","message":"finished"}}"#,
        ])
        XCTAssertEqual(rows(html, kind: "tool"), 1)
        XCTAssertTrue(html.contains(">1.0s<"), "the call → output interval is the step's duration")
        XCTAssertTrue(html.contains("done"), "the array-shaped output is read, not dropped")
        XCTAssertTrue(html.contains("gpt-5.6-sol"), "the turn's model names the assistant row")
    }

    func testGrokPairsToolResultsByCallID() throws {
        let html = try render([
            #"{"type":"user","content":[{"type":"text","text":"<user_query>go</user_query>"}]}"#,
            #"{"type":"assistant","model_id":"grok-4.5","content":"on it","tool_calls":[{"id":"c1","name":"web_fetch","arguments":"{\"url\":\"https://example.com\"}"}]}"#,
            #"{"type":"tool_result","tool_call_id":"c1","content":"Error: nope"}"#,
        ], name: "chat_history.jsonl")
        XCTAssertEqual(rows(html, kind: "tool"), 1)
        XCTAssertTrue(html.contains("https://example.com"), "the row previews the argument, not the JSON blob")
        XCTAssertTrue(html.contains("data-err=\"1\""), "Grok marks failures in the content itself")
        // No timestamps anywhere in a Grok transcript, so no fabricated geometry.
        XCTAssertFalse(html.contains("class=\"histogram\""))
    }

    /// A transcript with timestamps gets the histogram; every column has to address a row
    /// that exists, or the jump lands nowhere.
    func testHistogramColumnsAddressRealRows() throws {
        let html = try render([
            #"{"type":"user","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"go"}}"#,
            #"{"type":"assistant","timestamp":"2026-01-01T00:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}"#,
        ])
        XCTAssertTrue(html.contains("class=\"histogram\""))
        XCTAssertTrue(html.contains("href=\"#r1\""))
        XCTAssertTrue(html.contains("id=\"r1\""))
        XCTAssertTrue(html.contains("href=\"#r2\""))
        XCTAssertTrue(html.contains("id=\"r2\""))
    }

    func testMissingTranscriptRendersTheNewConversationPage() throws {
        let html = try SessionTraceRenderer.html(
            jsonlPath: "/nonexistent/session.jsonl", title: "t",
            theme: .builtin(dark: false), includeHeader: false)
        XCTAssertTrue(html.contains("New conversation"))
    }
}
