import Foundation

/// One event on a session's **content plane** — the structured projection of an
/// agent's conversation, derived from the transcript the agent writes to disk.
///
/// The byte plane (raw PTY frames) and this plane describe the same session and
/// ride the same connection on different channels. They differ in durability:
/// bytes die with the process, events live as long as the transcript file, which
/// is why a dormant session still has a readable conversation and a blank
/// terminal.
///
/// Two properties the wire depends on, both consequences of the source being a
/// **file** rather than a live stream:
///
/// - **`seq` is dense and monotonic per session.** A client that reconnects
///   asks for everything after the highest `seq` it holds. Same mechanism as
///   the PTY ring buffer's catch-up, so there is one reconnect story, not one
///   per plane.
/// - **Tool events are upserts keyed by `call`.** Re-reading a transcript,
///   resuming, or forking makes the same tool record appear again; replaying it
///   must converge rather than duplicate. A start/end event *pair* would not —
///   which is why this is a single mutable event and not two.
public struct AgentEvent: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable, Equatable {
        case user, agent, system
    }

    /// ACP's tool vocabulary. Deliberately a small closed set: the client picks
    /// an icon and an affordance from it, and an unrecognized tool degrades to
    /// `.other` rather than going unrendered.
    public enum ToolKind: String, Codable, Sendable, Equatable {
        case read, edit, execute, search, think, fetch, other
    }

    public enum ToolStatus: String, Codable, Sendable, Equatable {
        case pending, running, done, error
    }

    public enum TurnStatus: String, Codable, Sendable, Equatable {
        case completed, failed, cancelled
    }

    /// Whether the session has a live process behind it. `dormant` is not an
    /// error state: it is the case the content plane exists to serve.
    public enum LiveState: String, Codable, Sendable, Equatable {
        case live, dormant
    }

    public struct PlanItem: Codable, Sendable, Equatable {
        public enum Status: String, Codable, Sendable, Equatable {
            case pending, inProgress, completed
        }
        public let text: String
        public let status: Status

        public init(text: String, status: Status) {
            self.text = text
            self.status = status
        }
    }

    public enum Payload: Codable, Sendable, Equatable {
        case turnStart
        case turnEnd(status: TurnStatus)
        /// Assistant or user prose. `thinking` marks reasoning the client
        /// renders collapsed — it is content, not a separate channel.
        case text(text: String, thinking: Bool)
        case tool(
            call: String, name: String, kind: ToolKind, title: String,
            subtitle: String?, status: ToolStatus, locations: [String])
        /// An edit tool's content, already unified so the client never has to
        /// know how a given agent spells "old text" and "new text".
        case diff(call: String, path: String, unified: String)
        case plan(items: [PlanItem])
        case usage(tokens: Int, cost: Double?, contextLeft: Int?)
        case sessionInfo(title: String, model: String?, state: LiveState)
    }

    public let seq: Int
    public let role: Role
    /// When the agent wrote this, from the transcript's own clock — not when
    /// the phone received it. A conversation read days later still groups by
    /// the day it happened, and a replay after a reconnect cannot restamp
    /// itself to "now".
    public let at: Date?
    /// The turn this event belongs to, when the transcript says so.
    public let turn: String?
    /// The parent tool call for a subagent's events. Present from day one
    /// because retrofitting it means re-keying every stored event: a sidechain
    /// can arrive before the parent tool call that spawned it, and the host
    /// buffers those orphans so the client stays dumb.
    public let parent: String?
    public let payload: Payload

    public init(
        seq: Int, role: Role, at: Date? = nil, turn: String? = nil, parent: String? = nil,
        payload: Payload
    ) {
        self.seq = seq
        self.role = role
        self.at = at
        self.turn = turn
        self.parent = parent
        self.payload = payload
    }

    /// The upsert key: the identity a replayed event collapses onto. Prose is
    /// append-only and has none; tools, diffs and the plan do.
    ///
    /// The plan's key is constant because an agent has one task list per
    /// session: every revision of it lands on the same row, which is the
    /// difference between a checklist and a dozen stale copies of a TUI box
    /// scrolling past.
    public var upsertKey: String? {
        switch payload {
        case .tool(let call, _, _, _, _, _, _): return "tool:\(call)"
        case .diff(let call, let path, _): return "diff:\(call):\(path)"
        case .plan: return "plan"
        default: return nil
        }
    }
}

extension AgentEvent {
    /// Hand-rolled JSON in the same style as `CompanionControl`: both ends read
    /// plain dictionaries, so an older peer skips a field it doesn't know
    /// instead of failing the whole batch.
    public var jsonObject: [String: Any] {
        var object: [String: Any] = ["seq": seq, "role": role.rawValue]
        // Milliseconds since the epoch: an integer both ends already agree on,
        // where a formatted date would drag a parser and a locale into the wire.
        if let at { object["at"] = Int(at.timeIntervalSince1970 * 1000) }
        if let turn { object["turn"] = turn }
        if let parent { object["parent"] = parent }

        switch payload {
        case .turnStart:
            object["ev"] = ["t": "turn-start"]
        case .turnEnd(let status):
            object["ev"] = ["t": "turn-end", "status": status.rawValue]
        case .text(let text, let thinking):
            var event: [String: Any] = ["t": "text", "text": text]
            if thinking { event["thinking"] = true }
            object["ev"] = event
        case .tool(let call, let name, let kind, let title, let subtitle, let status, let locations):
            var event: [String: Any] = [
                "t": "tool", "call": call, "name": name, "kind": kind.rawValue,
                "title": title, "status": status.rawValue,
            ]
            if let subtitle { event["subtitle"] = subtitle }
            if !locations.isEmpty { event["locations"] = locations }
            object["ev"] = event
        case .diff(let call, let path, let unified):
            object["ev"] = ["t": "diff", "call": call, "path": path, "unified": unified]
        case .plan(let items):
            object["ev"] = [
                "t": "plan",
                "items": items.map { ["text": $0.text, "status": $0.status.rawValue] },
            ]
        case .usage(let tokens, let cost, let contextLeft):
            var event: [String: Any] = ["t": "usage", "tokens": tokens]
            if let cost { event["cost"] = cost }
            if let contextLeft { event["contextLeft"] = contextLeft }
            object["ev"] = event
        case .sessionInfo(let title, let model, let state):
            var event: [String: Any] = ["t": "session-info", "title": title, "state": state.rawValue]
            if let model { event["model"] = model }
            object["ev"] = event
        }
        return object
    }

    /// Returns nil for an event this build has no case for, so a newer Mac can
    /// add an event type without a older phone dropping the batch around it.
    public init?(json object: [String: Any]) {
        guard let seq = object["seq"] as? Int,
            let roleName = object["role"] as? String,
            let role = Role(rawValue: roleName),
            let event = object["ev"] as? [String: Any],
            let type = event["t"] as? String
        else { return nil }

        let payload: Payload
        switch type {
        case "turn-start":
            payload = .turnStart
        case "turn-end":
            let status = (event["status"] as? String).flatMap(TurnStatus.init(rawValue:))
            payload = .turnEnd(status: status ?? .completed)
        case "text":
            guard let text = event["text"] as? String else { return nil }
            payload = .text(text: text, thinking: event["thinking"] as? Bool ?? false)
        case "tool":
            guard let call = event["call"] as? String, let name = event["name"] as? String
            else { return nil }
            payload = .tool(
                call: call, name: name,
                kind: (event["kind"] as? String).flatMap(ToolKind.init(rawValue:)) ?? .other,
                title: event["title"] as? String ?? name,
                subtitle: event["subtitle"] as? String,
                status: (event["status"] as? String).flatMap(ToolStatus.init(rawValue:)) ?? .done,
                locations: event["locations"] as? [String] ?? [])
        case "diff":
            guard let call = event["call"] as? String, let path = event["path"] as? String,
                let unified = event["unified"] as? String
            else { return nil }
            payload = .diff(call: call, path: path, unified: unified)
        case "plan":
            let raw = event["items"] as? [[String: Any]] ?? []
            payload = .plan(
                items: raw.compactMap { item in
                    guard let text = item["text"] as? String else { return nil }
                    let status = (item["status"] as? String).flatMap(PlanItem.Status.init(rawValue:))
                    return PlanItem(text: text, status: status ?? .pending)
                })
        case "usage":
            payload = .usage(
                tokens: event["tokens"] as? Int ?? 0, cost: event["cost"] as? Double,
                contextLeft: event["contextLeft"] as? Int)
        case "session-info":
            payload = .sessionInfo(
                title: event["title"] as? String ?? "",
                model: event["model"] as? String,
                state: (event["state"] as? String).flatMap(LiveState.init(rawValue:)) ?? .dormant)
        default:
            return nil
        }

        let at = (object["at"] as? Int).map {
            Date(timeIntervalSince1970: Double($0) / 1000)
        }
        self.init(
            seq: seq, role: role, at: at, turn: object["turn"] as? String,
            parent: object["parent"] as? String, payload: payload)
    }
}
