import Foundation

/// Parses ConEmu-style `OSC 9;4` progress out of a terminal byte stream as an agent
/// busy/idle signal — the same unbreakable channel as the OSC title, but more precise
/// (the agent says "I’m working" without termio having to recognise a spinner glyph).
/// libghostty forwards the sequence but surfaces only titles (OSC 0/2) and cwd (OSC 7).
///
/// The protocol is `ESC ] 9 ; 4 ; <state> ; <progress> (BEL | ST)`: state `0` = clear
/// → idle, `1`/`3` (normal/indeterminate) → working, `2`/`4` (error/paused) ignored.
/// Grok emits `9;4;1;-1` while a turn runs and `9;4;0;` when it ends.
///
/// Fed every raw read chunk (sequences split across reads are tolerated), it returns
/// each completed report in byte order — both edges when one read carries a whole
/// `busy … idle` turn. It keeps NO cross-chunk state: duplicates collapse within a
/// chunk, but dedup across reads is the store's job (`lastProgressActivity`, under the
/// live-agent gate), exactly like the title channel. That is deliberate — a scanner
/// that privately deduped a pre-promotion `working` (which the gate rejects) would then
/// swallow the keepalives a row just promoted to Grok needs.
///
/// Only `9;4` progress is read; OSC 9 notifications (`9;<text>`), OSC 9;9 cwd and OSC 4
/// palette fall through — the grammar is validated whole (numeric state; busy carries a
/// `0…100` percentage, Grok's `-1`, or empty) and overruns rejected, so a notification
/// body starting `4;…` can't be misread as progress.
struct OSCProgressScanner {
    private enum State { case ground, esc, osc, oscEsc }
    private var state: State = .ground
    private var payload: [UInt8] = []
    /// Set when a payload exceeds `maxPayload`: it is then too long to be a progress
    /// report, so it is rejected outright rather than classified from its prefix.
    private var overflowed = false
    /// Progress payloads are a handful of bytes (`9;4;1;-1`); anything longer is some
    /// other, longer OSC (a title, a notification) and cannot be a progress report.
    private static let maxPayload = 24

    /// Scans a raw chunk, returning every completed report in it, in byte order,
    /// with consecutive duplicates collapsed. Empty in the common case (no progress).
    mutating func scan(_ data: Data) -> [AgentStatusRules.Activity] {
        var transitions: [AgentStatusRules.Activity] = []
        for byte in data {
            switch state {
            case .ground:
                if byte == 0x1B { state = .esc }
            case .esc:
                if byte == UInt8(ascii: "]") {
                    beginPayload()
                } else if byte == 0x1B {
                    state = .esc
                } else {
                    state = .ground
                }
            case .osc:
                switch byte {
                case 0x07: // BEL terminator
                    emit(into: &transitions)
                    state = .ground
                case 0x1B: // possible ST (ESC \) terminator
                    state = .oscEsc
                default:
                    if payload.count < Self.maxPayload { payload.append(byte) } else { overflowed = true }
                }
            case .oscEsc:
                if byte == UInt8(ascii: "\\") { // ST terminator
                    emit(into: &transitions)
                    state = .ground
                } else if byte == 0x1B {
                    state = .oscEsc
                } else {
                    // A bare ESC mid-payload aborts this OSC.
                    state = .ground
                }
            }
        }
        return transitions
    }

    private mutating func beginPayload() {
        state = .osc
        payload.removeAll(keepingCapacity: true)
        overflowed = false
    }

    /// Classifies the buffered payload and appends it unless it repeats the previous
    /// report in this same chunk. No state survives the call.
    private mutating func emit(into transitions: inout [AgentStatusRules.Activity]) {
        defer { payload.removeAll(keepingCapacity: true); overflowed = false }
        guard !overflowed, let activity = Self.classify(payload) else { return }
        if transitions.last != activity { transitions.append(activity) }
    }

    /// Maps an OSC 9 payload to an activity. Fast-rejects everything that isn't a
    /// `9;4;<state>` progress report before allocating, so the common OSC 0/2 title
    /// spinner (one OSC per frame) never pays for a `String`, then validates the whole
    /// grammar — a numeric state and, for the busy states, a progress field in the
    /// documented `0…100` range (plus Grok's indeterminate `-1`, and an empty value) —
    /// so a longer OSC 9 notification that happens to begin `4;…` is not misread.
    static func classify(_ payload: [UInt8]) -> AgentStatusRules.Activity? {
        guard payload.count >= 3,
              payload[0] == UInt8(ascii: "9"),
              payload[1] == UInt8(ascii: ";"),
              payload[2] == UInt8(ascii: "4") else { return nil }
        let parts = String(decoding: payload, as: UTF8.self)
            .split(separator: ";", omittingEmptySubsequences: false)
        // `9 ; 4 ; <state>` with an optional trailing `<progress>` — nothing more. The
        // byte prefix already pinned `parts[0] == "9"`, but `4` may have been a longer
        // run (`9;41;…`), so the second field is re-checked exactly.
        guard parts.count == 3 || parts.count == 4,
              parts[1] == "4",
              let stateDigit = Int(parts[2]) else { return nil }
        switch stateDigit {
        case 0:
            return .idle // clear; any progress value is ignored
        case 1, 3:
            // Busy states carry a progress field. It is a percentage (`0…100`),
            // Grok's indeterminate `-1`, or empty. A missing field, a stray value, or
            // an out-of-range number means this wasn't a progress report.
            guard parts.count == 4 else { return nil }
            let progress = parts[3]
            if progress.isEmpty { return .working }
            guard let value = Int(progress), value == -1 || (0 ... 100).contains(value) else { return nil }
            return .working
        default:
            return nil // 2 = error, 4 = paused — not a clean transition
        }
    }
}
