import Foundation

/// The ordering ledger for one device resource watch, whatever it watches.
///
/// A subscribe handshake resolves on two paths: the ack — carrying the gap →
/// reset-the-baseline decision, and the cursor the subscription starts at —
/// comes back through the async call, while the first batches arrive through
/// the subscription handler, which the channel arms *before* the request goes
/// out. So a batch can be delivered while the caller is still awaiting the ack,
/// against state the ack has not installed yet: on the `git:` plane that
/// applied a batch before the gap reset that would erase it, rendering a
/// changed checkout clean; on `fs:` it delivered a batch before the
/// subscription — and so before the canonical resource id the tree translates
/// paths by — leaving a root reached through a symlink matching nothing and a
/// tree that never re-lists.
///
/// The ledger holds batches until the baseline decision has landed, and stamps
/// every attempt with a generation so a watch that was stopped — or restarted —
/// while its handshake was in flight can neither install its subscription nor
/// apply its batches.
///
/// Generic over the batch because the planes carry different payloads and
/// nothing else about the ordering differs. A second copy of this reasoning is
/// how the `fs:` half came to be missing it — which is why this now lives in
/// `Shared/` rather than in the Mac app: the phone's `status:` subscription is
/// the third plane to need it, and a third copy is how it would go wrong again.
///
/// The host has the matching half. `Registry::attach` queues a subscriber's
/// replay and installs the subscriber inside one critical section, so a live
/// batch cannot be handed out ahead of the replay it is owed; this holds the
/// client's end of the same order.
public struct DeviceWatchLedger<Batch> {
    public init() {}

    /// Where an arriving batch goes.
    private enum Phase: Equatable {
        /// The ack has not landed: hold everything.
        case awaitingBaseline
        /// The ack landed and the queue is being handed back. Arrivals keep
        /// queueing — behind what is already held, never ahead of it.
        case draining
        /// Nothing is waiting; a batch applies as it arrives.
        case settled
    }

    public private(set) var generation = 0
    private var phase = Phase.settled
    private var held: [Batch] = []
    private var restartRequested = false

    /// A new subscribe attempt begins; everything older is dead.
    public mutating func begin() -> Int {
        generation += 1
        phase = .awaitingBaseline
        held = []
        return generation
    }

    /// The watch was stopped; an in-flight attempt must not land.
    public mutating func stop() {
        generation += 1
        phase = .settled
        held = []
        restartRequested = false
    }

    /// A newer visible pane wants a watch while an older handshake is still
    /// pending. The old acknowledgement must not install, but its cleanup is
    /// responsible for starting the replacement once it has released the
    /// in-flight slot.
    public mutating func requestRestart() {
        generation += 1
        phase = .settled
        held = []
        restartRequested = true
    }

    /// Returns whether the caller's generation still owns the watch.
    public func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation
    }

    /// Takes the one deferred replacement request after its predecessor has
    /// completed its handshake.
    public mutating func consumeRestartRequest() -> Bool {
        defer { restartRequested = false }
        return restartRequested
    }

    /// Admits one arriving batch: returns it when the batch may apply now, or
    /// nil when it was queued for `releaseNext` or belongs to a dead generation.
    ///
    /// A batch arriving *during* the drain queues too. Letting it through would
    /// let it overtake one already waiting, and the cursor moves with whatever
    /// applies first: batch 8 held, batch 9 let past, cursor at 9, and 8 then
    /// discarded as old news. If 8 named a directory 9 did not, that directory
    /// is stale for good.
    public mutating func admit(_ batch: Batch, generation: Int) -> Batch? {
        guard generation == self.generation else { return nil }
        switch phase {
        case .awaitingBaseline, .draining:
            held.append(batch)
            return nil
        case .settled:
            return batch
        }
    }

    /// The ack landed and the caller is about to make the baseline decision.
    /// `false` when the attempt is stale and must be abandoned.
    ///
    /// Leaves the ledger *draining*: the batches that raced the ack come back
    /// one at a time from `releaseNext`, and anything arriving meanwhile queues
    /// behind them. Handing the whole queue over as an array instead would put
    /// the release outside whatever lock guards the ledger, which is the window
    /// a live batch overtook it in.
    public mutating func settle(generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        phase = .draining
        return true
    }

    /// The next batch to hand over, in arrival order, or nil once the queue is
    /// empty — at which point the ledger settles and later arrivals apply as
    /// they come.
    ///
    /// Called under the same lock `admit` takes, one batch at a time, so a
    /// batch arriving mid-drain is either already in the queue or lands behind
    /// what is left of it. There is no bound on the loop by design: each turn
    /// removes one, and the host debounces its batches (`resource.rs`
    /// `DEBOUNCE`), so "drain until empty" terminates for the same reason the
    /// pane is worth updating at all.
    public mutating func releaseNext(generation: Int) -> Batch? {
        guard generation == self.generation, phase == .draining else { return nil }
        guard !held.isEmpty else {
            phase = .settled
            return nil
        }
        return held.removeFirst()
    }
}
