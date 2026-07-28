import Foundation

/// Parses ConEmu-style `OSC 9;4` progress reports out of a terminal byte stream
/// and maps them to an agent activity — an in-band busy/idle signal on the same
/// unbreakable channel as the OSC title, but more precise: an agent that reports
/// progress says "I am working" without termio having to recognise a spinner glyph.
///
/// The sequence is the ConEmu / Windows Terminal progress protocol that libghostty
/// forwards but does not surface: `ESC ] 9 ; 4 ; <state> ; <progress> (BEL | ST)`,
/// where
/// - state `0` = clear → **idle**,
/// - state `1` (normal) and `3` (indeterminate) → **working**,
/// - state `2` (error) and `4` (paused) → ignored (neither a clean busy nor idle
///   transition; leaving the last signal in place beats guessing).
///
/// Grok emits `9;4;1;-1` natively while a turn runs and `9;4;0;` when it finishes;
/// Claude Code emits the same shape once `terminalProgressBarEnabled` is set. This is
/// fed every raw read chunk from the PTY (sequences split across reads are tolerated)
/// and returns each busy/idle flip in order — a stream of identical `9;4;1`
/// keepalives collapses to nothing, but a chunk that carries a whole `busy … idle`
/// turn yields both transitions rather than only the last (which the arbitration,
/// keyed on the previous *delivered* state, would otherwise silently drop).
///
/// It reads only OSC 9 *progress* (`9;4;<state>;<progress>`); the neighbouring OSC 9
/// notification (`9;<text>`), OSC 9;9 cwd, and OSC 4 palette forms all fall through —
/// the grammar is validated end to end (state numeric, at most one numeric-or-empty
/// progress field) and an overrun payload is rejected, so a notification whose body
/// merely starts `4;…` can't be mistaken for progress.
struct OSCProgressScanner {
    private enum State { case ground, esc, osc, oscEsc }
    private var state: State = .ground
    private var payload: [UInt8] = []
    /// Set when a payload exceeds `maxPayload`: it is then too long to be a progress
    /// report, so it is rejected outright rather than classified from its prefix.
    private var overflowed = false
    private var lastActivity: AgentStatusRules.Activity?
    /// Progress payloads are a handful of bytes (`9;4;1;-1`); anything longer is some
    /// other, longer OSC (a title, a notification) and cannot be a progress report.
    private static let maxPayload = 24

    /// Scans a raw chunk, returning every busy/idle flip it completes, in order.
    /// Empty in the common case (no progress, or only repeats of the current state).
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
                    if let t = finish() { transitions.append(t) }
                    state = .ground
                case 0x1B: // possible ST (ESC \) terminator
                    state = .oscEsc
                default:
                    if payload.count < Self.maxPayload { payload.append(byte) } else { overflowed = true }
                }
            case .oscEsc:
                if byte == UInt8(ascii: "\\") { // ST terminator
                    if let t = finish() { transitions.append(t) }
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

    /// Classifies the buffered payload and reports it only on a state change.
    private mutating func finish() -> AgentStatusRules.Activity? {
        defer { payload.removeAll(keepingCapacity: true); overflowed = false }
        guard !overflowed, let activity = Self.classify(payload), activity != lastActivity else { return nil }
        lastActivity = activity
        return activity
    }

    /// Maps an OSC 9 payload to an activity. Fast-rejects everything that isn't a
    /// `9;4;<state>` progress report before allocating, so the common OSC 0/2 title
    /// spinner (one OSC per frame) never pays for a `String`, then validates the whole
    /// grammar so a longer OSC 9 notification that happens to begin `4;…` is not
    /// misread as progress.
    static func classify(_ payload: [UInt8]) -> AgentStatusRules.Activity? {
        guard payload.count >= 3,
              payload[0] == UInt8(ascii: "9"),
              payload[1] == UInt8(ascii: ";"),
              payload[2] == UInt8(ascii: "4") else { return nil }
        let parts = String(decoding: payload, as: UTF8.self)
            .split(separator: ";", omittingEmptySubsequences: false)
        // `9 ; 4 ; <state>` with an optional trailing `<progress>` — nothing more.
        guard parts.count == 3 || parts.count == 4,
              parts[0] == "9", parts[1] == "4",
              let stateDigit = Int(parts[2]) else { return nil }
        if parts.count == 4 {
            // The progress field is a percentage; Grok reports `-1` for its
            // indeterminate bar and an empty value on clear. Anything else (a
            // notification body, stray text) means this wasn't a progress report.
            let progress = parts[3]
            guard progress.isEmpty || Int(progress) != nil else { return nil }
        }
        switch stateDigit {
        case 0: return .idle
        case 1, 3: return .working
        default: return nil // 2 = error, 4 = paused — not a clean transition
        }
    }
}
