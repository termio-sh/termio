import Foundation

/// The durable cursor for a resumable resource subscription (`fs:`, `git:`,
/// `status:`), and the one rule that decides what a batch is worth.
///
/// A subscription resumes by naming the last batch it applied. Getting that
/// number wrong is silent in both directions, and both have shipped:
///
/// - **Too high** — the ack's `seq` names the end of a replay the host is
///   *about* to send. Adopting it before the batches arrive means a drop in
///   between resumes past batches nobody applied, and they are never asked for
///   again. On `status:` that is a session stuck reading `working` after its
///   turn ended; on `git:` a baseline missing the deltas that would have
///   cleaned it.
/// - **Too low, in the other sense** — a stale batch applied *after* newer
///   truth rolls the state backwards: a finished agent going back to working, a
///   path resurrected after it was cleaned.
///
/// So the cursor advances only for a batch that actually applied, and only when
/// that batch is the next one. A batch past the next one is a hole: it applies,
/// because the state it names is newer than what is on screen, but the cursor
/// stays put so the next resume replays what this attempt never saw. Leaving
/// the cursor behind costs a re-replay, which is idempotent; moving it ahead
/// loses batches for good.
///
/// A plain value type so the rule is testable without a connection — the same
/// reason `DeviceWatchLedger` and `StallProbe` are one. The ledger orders the
/// *arrival* of batches against the ack; this decides what each one is worth
/// once it has arrived. Both halves are needed, and neither implies the other.
public struct ResourceCursor: Equatable {
    /// What the next `subscribe_resource` sends as `since` — the highest
    /// contiguous batch applied. `nil` until anything has been.
    public private(set) var resumeFrom: UInt64?
    /// The highest seq applied in *this* attempt, which is not the same number
    /// and must not be confused with it. They part only across a hole.
    ///
    /// Reset to `resumeFrom` on every new attempt, because a fresh subscription
    /// replays in order from the cursor — so what looked stale under the old
    /// attempt is exactly what this one has to apply. Without the reset the two
    /// deadlock: the batches spanning a hole are dropped as stale on every
    /// reconnect, and the cursor never moves again.
    private var applied: UInt64?

    public init() {}

    /// What to do with an arriving batch.
    public enum Verdict: Equatable {
        /// Apply it; the cursor moved with it.
        case apply
        /// Apply it, but the cursor stayed — batches are missing, and the next
        /// resume has to ask for them.
        case applyAcrossHole
        /// Already superseded. Applying it would move the state backwards.
        case drop
    }

    /// Begin a subscribe attempt: the replay that follows arrives in order from
    /// `resumeFrom`, so nothing before it counts as stale any more.
    public mutating func beginAttempt() {
        applied = resumeFrom
    }

    /// Adopt a complete baseline at `seq` — a `git:` gap subscriber's
    /// synthesized full state, or an `fs:` listing stamped with the cursor it
    /// was taken at. There is nothing before it to be missing, so the cursor
    /// takes it outright rather than walking to it one batch at a time.
    public mutating func adoptBaseline(_ seq: UInt64) {
        if let resumeFrom, seq <= resumeFrom { return }
        resumeFrom = seq
        applied = seq
    }

    /// Forget everything: a gap with no baseline coming, or a watch that
    /// stopped. The next subscribe starts from scratch.
    public mutating func reset() {
        resumeFrom = nil
        applied = nil
    }

    /// Judge one arriving batch and move the cursor if it earned it.
    public mutating func admit(seq: UInt64) -> Verdict {
        if let applied, seq <= applied { return .drop }
        applied = seq
        if seq == (resumeFrom ?? 0) + 1 {
            resumeFrom = seq
            return .apply
        }
        return .applyAcrossHole
    }
}
