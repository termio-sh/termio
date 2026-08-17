import SwiftUI

/// A session's live activity. The four states follow the desktop model
/// (see the main app's `Models.swift`): a finished turn is `done`, *not*
/// "needs you" — `needsAttention` is reserved for an agent actually blocked
/// on the user, keeping "ready for you" (calm) distinct from "waiting on
/// you" (urgent).
public enum SessionStatus: Hashable, Sendable {
    /// Nothing pending, or the user is already looking at the session.
    case idle
    /// The agent is actively processing a turn (shown as the spinning icon).
    case working
    /// The agent finished its turn while the user was elsewhere — a calm
    /// "ready for you" cue, not a demand.
    case done
    /// The agent is blocked waiting on the user (permission prompt, or a
    /// bell / desktop notification it raised).
    case needsAttention

    /// Sort rank for mobile lists: attention first, then working.
    public var rank: Int {
        switch self {
        case .needsAttention: 0
        case .working: 1
        case .idle: 2
        case .done: 3
        }
    }
}

/// A small coloured dot trailing a session title: hidden when idle/working
/// (working is shown by the leading spinner instead), green when done,
/// orange when the session needs the user.
public struct StatusDot: View {
    let status: SessionStatus

    public init(status: SessionStatus) {
        self.status = status
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(status == .done || status == .needsAttention ? 1 : 0)
    }

    private var color: Color {
        status == .needsAttention ? .orange : .green
    }
}

/// The "agent is working" mark: a 3×3 grid of dots with a bright comet that
/// orbits the eight perimeter cells, so the small nine-square grid reads as
/// rotating. Sits in place of the session's brand icon while a turn is in
/// flight. The caller supplies the tint — the agent's brand color on iOS, and
/// monochrome ink in the Mac sidebar, where the vibrancy material would wash a
/// brand tint to grey.
public struct WorkingIndicator: View {
    let tint: Color

    /// When nil the comet self-animates via `TimelineView`; supplying a phase
    /// (0...1) renders one still frame instead, so a caller can drive the
    /// rotation with its own timer where `TimelineView` never ticks — e.g.
    /// inside an open `NSMenu`, which runs a modal event-tracking loop.
    let phase: Double?

    public init(tint: Color = .secondary, phase: Double? = nil) {
        self.tint = tint
        self.phase = phase
    }

    /// The eight perimeter cells of the 3×3 grid in clockwise order, as
    /// `(column, row)` with the center at `(1, 1)`. The comet travels this ring.
    private static let ring: [(Int, Int)] = [
        (0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1),
    ]
    // Dots this small read lighter than their nominal opacity, so the size and
    // the opacity ramp are tuned together: 2.5pt with a 0.5 tail floor sits at
    // the same perceived weight as the neighboring 15pt glyphs.
    private let dotSize: CGFloat = 2.5
    private let spacing: CGFloat = 3.6
    private let period: Double = 1.1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        if let phase {
            grid(phase: phase)
        } else if reduceMotion {
            // Reduce Motion: hold one frame — the mark still reads as "working"
            // from its shape, and the timeline (and its per-tick cost) is gone.
            grid(phase: 0)
        } else {
            // 30Hz, not every display frame: at 13pt with a 1.1s period the
            // comet is visually identical at 30Hz, and an uncapped timeline
            // ran this body at 120Hz per working row on ProMotion — enough to
            // saturate the main thread once a few sessions worked at once.
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let p = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period
                grid(phase: p)
            }
        }
    }

    private func grid(phase: Double) -> some View {
        ZStack {
            // A steady center anchors the spinning ring, matching the tail so
            // the grid reads as one solid mark with a swell running around it.
            dot(opacity: 0.5, scale: 1)
            ForEach(Array(Self.ring.enumerated()), id: \.offset) { index, cell in
                let distance = ringDistance(at: index, phase: phase)
                dot(opacity: opacity(distance: distance), scale: scale(distance: distance))
                    .offset(
                        x: CGFloat(cell.0 - 1) * spacing,
                        y: CGFloat(cell.1 - 1) * spacing
                    )
            }
        }
        .frame(width: 13, height: 13)
    }

    private func dot(opacity: Double, scale: Double) -> some View {
        // scaleEffect, not a phase-dependent frame: a .frame change is a
        // layout invalidation, which cascaded through the hosting view into
        // a full AppKit constraint pass on every animation tick. scaleEffect
        // stays in the render pass and keeps the swell layout-free.
        Circle()
            .fill(tint)
            .frame(width: dotSize, height: dotSize)
            .scaleEffect(scale)
            .opacity(opacity)
    }

    /// A perimeter cell's distance from the comet's head, measured the shorter
    /// way around the ring so the tail wraps.
    private func ringDistance(at index: Int, phase: Double) -> Double {
        let count = Double(Self.ring.count)
        let head = phase * count
        let raw = abs(Double(index) - head)
        return min(raw, count - raw)
    }

    /// The rotation is carried by two signals so neither has to be extreme: a
    /// brightness wave AND a size swell at the comet's head. Opacity alone
    /// needed a near-invisible tail to read as motion, which left the whole mark
    /// far paler than the full-ink glyphs beside it; with the swell doing half
    /// the work the tail floor stays at half ink and the grid keeps real weight.
    private func opacity(distance: Double) -> Double {
        max(0.5, 1 - distance / 4)
    }

    /// Size factor for a cell: the head swells a fifth and the swell dies out
    /// over the next two cells.
    private func scale(distance: Double) -> Double {
        1 + 0.2 * max(0, 1 - distance / 2)
    }
}
