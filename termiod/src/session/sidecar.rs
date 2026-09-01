//! The VT sidecar's side of a session: what it is asked to do, what it hands
//! back, and the budget that keeps a slow parse from costing unbounded memory.
//!
//! The sidecar is deliberately off the byte path — bytes reach clients whether
//! or not it keeps up, which is the anti-100x invariant. This module owns the
//! machinery that makes "whether or not" safe: a queue that refuses work rather
//! than growing, so falling behind degrades the snapshot and never the stream.

use bytes::Bytes;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc as std_mpsc;
use std::sync::Arc;

/// PTY bytes allowed to sit unparsed in the sidecar's command FIFO. The
/// per-client budget stops a slow socket from buying unbounded memory; this
/// stops a slow *parse* from doing the same one hop upstream.
const SIDECAR_QUEUE_CAP: usize = 16 * 1024 * 1024;

/// The budget in the words a staleness notice uses. Asked for rather than
/// restated, so the number and the sentence explaining it cannot drift.
/// The budget itself, for tests that need to fill it exactly.
#[cfg(test)]
pub(crate) const CAP_FOR_TESTS: usize = SIDECAR_QUEUE_CAP;

pub(crate) fn cap_description() -> String {
    format!("{} MiB", SIDECAR_QUEUE_CAP / (1024 * 1024))
}

use crate::protocol::GridDiff;
use crate::id::ClientId;

/// Counts PTY bytes queued for the VT sidecar but not yet parsed.
pub(crate) struct SidecarQueue {
    outstanding: AtomicUsize,
}

impl SidecarQueue {
    pub(crate) fn new() -> Self {
        Self {
            outstanding: AtomicUsize::new(0),
        }
    }

    pub(crate) fn try_reserve(&self, bytes: usize) -> bool {
        self.outstanding
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |outstanding| {
                outstanding
                    .checked_add(bytes)
                    .filter(|total| *total <= SIDECAR_QUEUE_CAP)
            })
            .is_ok()
    }

    /// Whether every byte charged to the queue has been credited back. A
    /// healthy session ends here; anything else means the budget ratchets shut.
    pub(crate) fn is_drained(&self) -> bool {
        self.outstanding.load(Ordering::Relaxed) == 0
    }

    pub(crate) fn release(&self, bytes: usize) {
        let _ =
            self.outstanding
                .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |outstanding| {
                    Some(outstanding.saturating_sub(bytes))
                });
    }
}

/// How often the sidecar samples the screen for the status engine. The Swift
/// tap throttled to the same second, for the same reason: the promotion streak
/// counts ticks, and a quiet terminal is the "turn ended" signal at roughly
/// this granularity.
pub(crate) const STATUS_TICK: std::time::Duration = std::time::Duration::from_secs(1);

/// One second of a session's own output, as the status engine reads it.
pub(crate) struct ScreenTick {
    /// Whether the live screen differs from the previous tick's. The primary
    /// liveness key: a finished agent still dribbles output at an idle prompt,
    /// which the byte stream alone reads as activity.
    pub(crate) changed: bool,
    /// Bytes the VT was fed since the last tick — the secondary signal, and the
    /// stall suppressor's numerator.
    pub(crate) bytes: u64,
    /// The screen itself, carried only when the session's agent declared screen
    /// rules. A row nobody matches against is a string nobody needs.
    pub(crate) text: Option<String>,
}

pub(crate) enum SidecarCommand {
    Write(Bytes),
    /// What the status engine wants sampled. `screen` off stops the once-a-second
    /// grid walk entirely, which is what a plain shell costs.
    SetStatusWatch {
        screen: bool,
        text: bool,
    },
    Resize {
        rows: u16,
        cols: u16,
    },
    Snapshot {
        client_id: ClientId,
        request_id: u64,
        scrollback: bool,
    },
    SetGridDiff(bool),
    Shutdown,
}

/// Snapshot replies and live grid updates share this single FIFO channel.
/// Separate channels could let a post-boundary G overtake its S and regress
/// rows after the client applies the newer snapshot.
pub(crate) enum SidecarResult {
    Snapshot {
        client_id: ClientId,
        request_id: u64,
        result: Result<SidecarCapture, String>,
    },
    Grid(GridDiff),
    Keyframe(termiod_vt::Snapshot),
    /// The two in-band status channels, as they arrive. Not throttled: a turn
    /// boundary is an edge, not something to sample once a second.
    Osc(Vec<crate::session::status::OscSignal>),
    Screen(ScreenTick),
}

pub(crate) struct SidecarCapture {
    pub(crate) snapshot: termiod_vt::Snapshot,
    /// The same screen serialised back to VT sequences. `None` only if the
    /// formatter failed, in which case delivery falls back to packed cells.
    pub(crate) vt: Option<Vec<u8>>,
    pub(crate) scrollback: Option<Result<termiod_vt::Scrollback, String>>,
}

/// What a snapshot request is refused with when the sidecar is simply not
/// there — it never started, its sender is gone, or its answers stopped
/// arriving. A VT that went *stale* refuses with the reason it went stale.
pub(crate) const UNAVAILABLE: &str = "VT sidecar is unavailable";

/// A session's VT, and whether it still has one.
///
/// These were three fields held in agreement by hand: a command sender, its
/// byte budget, and a `vt_stale: Option<String>`. A stale reason alongside a
/// live sender was not a state this host would run, and every question about
/// the VT had to be asked twice to find out which kind of "no" it was.
pub(crate) enum Vt {
    /// The sidecar thread is parsing. `queue` is the budget that keeps it off
    /// the byte path: the producer stops feeding the VT rather than blocking on
    /// it or letting a slow parse buy unbounded memory.
    Live {
        commands: std_mpsc::Sender<SidecarCommand>,
        queue: Arc<SidecarQueue>,
    },
    /// Nothing more will reach the VT. The screen it held no longer describes
    /// any boundary in the output stream, so it can never answer a snapshot
    /// again — attach and resync fall back to ring replay, and `reason` is what
    /// they are told.
    Down { reason: String },
}

impl Vt {
    pub(crate) fn live(commands: std_mpsc::Sender<SidecarCommand>, queue: Arc<SidecarQueue>) -> Vt {
        Vt::Live { commands, queue }
    }

    pub(crate) fn down(reason: impl Into<String>) -> Vt {
        Vt::Down {
            reason: reason.into(),
        }
    }

    pub(crate) fn is_live(&self) -> bool {
        matches!(self, Vt::Live { .. })
    }

    /// Why the VT cannot answer a snapshot, or `None` while it still can.
    pub(crate) fn refusal(&self) -> Option<&str> {
        match self {
            Vt::Live { .. } => None,
            Vt::Down { reason } => Some(reason),
        }
    }

    /// Charge `bytes` of PTY output to the VT's budget. `false` means the parse
    /// has fallen far enough behind that the only legal degrade is to stop
    /// feeding it and say so.
    pub(crate) fn try_reserve(&self, bytes: usize) -> bool {
        match self {
            Vt::Live { queue, .. } => queue.try_reserve(bytes),
            Vt::Down { .. } => false,
        }
    }

    /// Credit back bytes the VT will never parse.
    pub(crate) fn release(&self, bytes: usize) {
        if let Vt::Live { queue, .. } = self {
            queue.release(bytes);
        }
    }

    /// Hand the sidecar a command. `false` if it did not arrive, which also
    /// takes the VT down: a sender that will not take a command has no thread
    /// behind it, and the session is finding that out here.
    pub(crate) fn send(&mut self, command: SidecarCommand) -> bool {
        let Vt::Live { commands, .. } = self else {
            return false;
        };
        if commands.send(command).is_ok() {
            return true;
        }
        *self = Vt::down(UNAVAILABLE);
        false
    }

    /// Ask the sidecar thread to stop and stop expecting answers from it.
    /// Failure earns no word here: this runs on the way out.
    pub(crate) fn shut_down(&mut self) {
        if let Vt::Live { commands, .. } = self {
            let _ = commands.send(SidecarCommand::Shutdown);
        }
        *self = Vt::down(UNAVAILABLE);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sidecar_queue_stops_admitting_bytes_past_its_budget() {
        let queue = SidecarQueue::new();

        assert!(queue.try_reserve(SIDECAR_QUEUE_CAP));
        assert!(!queue.try_reserve(1));

        queue.release(SIDECAR_QUEUE_CAP);
        assert!(queue.try_reserve(1));
        queue.release(1);
        // Releasing more than was reserved is a bug, not a panic: the VT thread
        // and the session actor account independently.
        queue.release(SIDECAR_QUEUE_CAP);
        assert!(queue.try_reserve(SIDECAR_QUEUE_CAP));
    }
}
