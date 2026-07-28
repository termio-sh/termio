import Foundation

/// Parses ConEmu-style `OSC 9;4` progress reports out of a terminal byte stream
/// and maps them to an agent activity — an in-band busy/idle signal on the same
/// unbreakable channel as the OSC title, but more precise: an agent that reports
/// progress says "I am working" without termio having to recognise a spinner glyph.
///
/// The sequence is the ConEmu / Windows Terminal progress protocol that libghostty
/// forwards but does not surface: `ESC ] 9 ; 4 ; <state> ; <pct> (BEL | ST)`, where
/// - state `0` = clear → **idle**,
/// - state `1` (normal) and `3` (indeterminate) → **working**,
/// - state `2` (error) and `4` (paused) → ignored (neither a clean busy nor idle
///   transition; leaving the last signal in place beats guessing).
///
/// Grok emits `9;4;1;-1` natively while a turn runs and `9;4;0;` when it finishes;
/// Claude Code emits the same shape once `terminalProgressBarEnabled` is set. This is
/// fed every raw read chunk from the PTY (sequences split across reads are tolerated)
/// and returns a value only when the busy/idle state actually flips — a stream of
/// identical `9;4;1` keepalives collapses to a single `.working`.
///
/// It reads only OSC 9 *progress* (`9;4;…`); the neighbouring OSC 9 notification
/// (`9;<text>`), OSC 9;9 cwd, and OSC 4 palette forms all fall through to `nil`.
struct OSCProgressScanner {
    private enum State { case ground, esc, osc, oscEsc }
    private var state: State = .ground
    private var payload: [UInt8] = []
    private var lastActivity: AgentStatusRules.Activity?
    /// Progress payloads are a handful of bytes (`9;4;1;-1`); anything longer is
    /// some other OSC and can't be a progress report, so it is capped rather than
    /// buffered unboundedly across a pathological unterminated sequence.
    private static let maxPayload = 32

    /// Scans a raw chunk, returning the new activity iff the busy/idle state changed.
    mutating func scan(_ data: Data) -> AgentStatusRules.Activity? {
        var transition: AgentStatusRules.Activity?
        for byte in data {
            switch state {
            case .ground:
                if byte == 0x1B { state = .esc }
            case .esc:
                if byte == UInt8(ascii: "]") {
                    state = .osc
                    payload.removeAll(keepingCapacity: true)
                } else if byte == 0x1B {
                    state = .esc
                } else {
                    state = .ground
                }
            case .osc:
                switch byte {
                case 0x07: // BEL terminator
                    if let t = finish() { transition = t }
                    state = .ground
                case 0x1B: // possible ST (ESC \) terminator
                    state = .oscEsc
                default:
                    if payload.count < Self.maxPayload { payload.append(byte) }
                }
            case .oscEsc:
                if byte == UInt8(ascii: "\\") { // ST terminator
                    if let t = finish() { transition = t }
                    state = .ground
                } else if byte == 0x1B {
                    state = .oscEsc
                } else {
                    // A bare ESC mid-payload aborts this OSC.
                    state = .ground
                }
            }
        }
        return transition
    }

    /// Classifies the buffered payload and reports it only on a state change.
    private mutating func finish() -> AgentStatusRules.Activity? {
        defer { payload.removeAll(keepingCapacity: true) }
        guard let activity = Self.classify(payload), activity != lastActivity else { return nil }
        lastActivity = activity
        return activity
    }

    /// Maps an OSC 9 payload to an activity. Fast-rejects everything that isn't a
    /// `9;4;<state>` progress report before allocating, so the common OSC 0/2 title
    /// spinner (one OSC per frame) never pays for a `String`.
    static func classify(_ payload: [UInt8]) -> AgentStatusRules.Activity? {
        guard payload.count >= 3,
              payload[0] == UInt8(ascii: "9"),
              payload[1] == UInt8(ascii: ";"),
              payload[2] == UInt8(ascii: "4") else { return nil }
        let parts = String(decoding: payload, as: UTF8.self)
            .split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[1] == "4", let stateDigit = Int(parts[2]) else { return nil }
        switch stateDigit {
        case 0: return .idle
        case 1, 3: return .working
        default: return nil // 2 = error, 4 = paused — not a clean transition
        }
    }
}
