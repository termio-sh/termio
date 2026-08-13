import TermioShared
import XCTest

@testable import termio

/// The content plane's live half: a subscriber must be told about a turn the
/// agent appends *after* it subscribed. The cold replay is the easy case and
/// was never the one that broke — a lens that only ever paints its backlog
/// looks like a working chat right up until you send something.
final class AgentEventStoreStreamTests: XCTestCase {
    private func assistantLine(_ text: String, uuid: String) -> String {
        let row: [String: Any] = [
            "type": "assistant", "uuid": uuid,
            "message": ["content": [["type": "text", "text": text]]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: row)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    func testAppendedTurnReachesALiveSubscriber() async throws {
        let path = NSTemporaryDirectory() + "termio-stream-\(UUID().uuidString).jsonl"
        try assistantLine("first", uuid: "a1").write(
            toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let client = ObjectIdentifier(NSObject())
        let sessionID = UUID().uuidString
        let stream = await AgentEventStore.shared.subscribe(
            client: client, sessionID: sessionID, transcriptPath: path, since: 0)

        var iterator = stream.makeAsyncIterator()
        let backlog = await iterator.next()
        XCTAssertEqual(backlog?.count, 1, "cold subscribe should replay the one record")

        // The agent writes another turn while the subscriber is listening.
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(assistantLine("second", uuid: "a2").utf8))
        try handle.close()

        let live = await withTaskGroup(of: [AgentEvent]?.self) { group in
            group.addTask { await iterator.next() ?? nil }
            group.addTask {
                // Generous next to the store's own 5s backstop: this test is
                // asking whether the update arrives at all, not how fast.
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        await AgentEventStore.shared.unsubscribe(client: client, sessionID: sessionID)

        guard let live, case .text(let text, _) = live.first?.payload else {
            return XCTFail("no live batch — the appended turn never reached the subscriber")
        }
        XCTAssertEqual(text, "second")
    }
}
