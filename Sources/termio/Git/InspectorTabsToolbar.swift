import SwiftUI

// MARK: - Inspector pane switch

/// The inspector's pane switch (Files / Search / Changes / Info). It sits at the *left* edge of
/// the inspector in the toolbar — pinned there by an inspector tracking separator (see
/// `MainToolbarDelegate`) — while the collapse button sits at the far right.
///
/// ## Why this is hand-drawn, not a native segmented control
///
/// On macOS 26 the system stopped drawing an *enclosing track* for segmented controls: in Liquid
/// Glass the "track" is simply the shared toolbar glass background, and the control only owns the
/// selected-segment pill. termio's toolbar is deliberately transparent over the terminal, so that
/// shared glass is suppressed — a native `Picker(.segmented)` / `NSSegmentedControl` /
/// `NSToolbarItemGroup(.selectOne)` therefore has nothing to sit on and renders as detached,
/// track-less floating glyphs with no visible selection. (We tried the native group; that's exactly
/// what happened.) So we draw the switch ourselves: our own always-visible track holding the
/// segments, with a selected pill that slides between them via `matchedGeometryEffect` — the pill
/// is ours, so it never depends on the system deciding to paint shared glass.
///
/// The active glyph is lifted to `.primary` while the rest stay `.secondary`, so the selected pane
/// reads unambiguously even where the glass pill is subtle.
struct InspectorTabsToolbar: View {
    @EnvironmentObject var store: TermioStore
    /// Slides the selection pill from the old segment to the new one.
    @Namespace private var pillNamespace
    /// Drives the fade-in that syncs the cluster with the inspector pane's slide. The toolbar item
    /// is inserted with NSToolbar animation OFF (its pop runs on an independent clock — see
    /// `setInspectorSwitchVisible`), so without this the cluster snapped in while the pane was still
    /// sliding. A fresh hosting view is built per insertion, so `onAppear` fires on every open.
    @State private var appeared = false

    /// Outer height of the glass track, matched to the taller macOS 26 (Tahoe) bordered toolbar
    /// buttons flanking it (the collapse / + / inspector items) so all the toolbar backgrounds line
    /// up — the old 30 sat visibly short. 36 matches the native single-button outer frame exactly
    /// (per PR #3). The glyph area derives from this as `controlHeight - 2 * trackPadding`.
    static let controlHeight: CGFloat = 36
    private static let trackPadding: CGFloat = 3
    private static var glyphHeight: CGFloat { controlHeight - 2 * trackPadding }
    /// Equal per-segment width. Each glyph sits centered in its own slot, so this doubles as the
    /// center-to-center spacing between icons — wide enough that they breathe (28 read cramped),
    /// still tighter than the loose 34pt of the very first pass. Equal widths keep that spacing
    /// uniform regardless of how wide each SF Symbol happens to draw.
    private static let segmentWidth: CGFloat = 34

    private let segments: [(tab: InspectorTab, icon: HugeIcon, help: String)] = [
        (.files, .listBullet, "Project Files"),
        (.search, .search, "Search Files"),
        (.changes, .gitBranch, "Changes"),
        (.info, .infoCircle, "Info"),
    ]

    var body: some View {
        segmentedTrack
            // Clamp the hosting view to a fixed height matching the native bordered toolbar buttons
            // flanking it, so every toolbar background reads at one consistent height. An
            // unconstrained control can also report a tall intrinsic height that grows the unified
            // toolbar when the item is inserted, so the clamp stays.
            .frame(height: Self.controlHeight)
            .fixedSize()
            // Fade in over the ~0.25s the split view takes to slide the inspector open, so the
            // cluster and the pane read as one motion instead of a snap followed by a slide.
            .opacity(appeared ? 1 : 0)
            .onAppear { withAnimation(.easeOut(duration: 0.25)) { appeared = true } }
    }

    /// The row of segments with the sliding selection pill behind the active one, all inside our own
    /// track. Same structure on every OS; only the pill + track *materials* differ (Liquid Glass on
    /// macOS 26, flat capsule fills on macOS 15 / earlier).
    private var segmentedTrack: some View {
        HStack(spacing: 0) {
            ForEach(segments, id: \.tab) { seg in
                let selected = store.inspectorTab == seg.tab
                // Active glyph lifts to full-strength; the rest stay muted — so the selected
                // pane is legible even before you notice the pill.
                HugeIconView(icon: seg.icon, size: 15, color: selected ? .primary : .secondary)
                    .frame(width: Self.segmentWidth, height: Self.glyphHeight)
                    // Each segment is a matched-geometry *source*; the pill (non-source, below)
                    // snaps to whichever one is selected and animates across on change.
                    .matchedGeometryEffect(id: seg.tab, in: pillNamespace)
                    .contentShape(.capsule)
                    // Set the pane WITHOUT `withAnimation`: a global transaction would also animate
                    // the inspector *content* swap, slowly cross-fading the outgoing pane (e.g. the
                    // search field's focus ring lingered for the whole duration). The pill's slide is
                    // animated locally by the `.animation(value:)` below instead, so the content
                    // switches instantly while only the pill glides.
                    .onTapGesture { store.inspectorTab = seg.tab }
                    .help(seg.help)
            }
        }
        // The selection pill rides behind the active segment and slides across on switch.
        .background { selectionPill }
        .padding(Self.trackPadding)
        .background { trackBackground }
        // Scope the slide animation to just this control's subtree, so switching panes doesn't
        // drag the inspector content along with it.
        .animation(.snappy(duration: 0.28), value: store.inspectorTab)
    }

    // MARK: Materials — Liquid Glass on macOS 26, flat fills below

    @ViewBuilder
    private var selectionPill: some View {
        if #available(macOS 26.0, *) {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: .capsule)
                // Non-source: takes the frame + position of the currently selected segment.
                .matchedGeometryEffect(id: store.inspectorTab, in: pillNamespace, isSource: false)
        } else {
            Capsule(style: .continuous)
                .fill(Color(nsColor: .controlColor))
                .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
                .matchedGeometryEffect(id: store.inspectorTab, in: pillNamespace, isSource: false)
        }
    }

    @ViewBuilder
    private var trackBackground: some View {
        if #available(macOS 26.0, *) {
            // A faint, slightly-whitened glass so the track stays lighter than the system collapse
            // button and lets the brighter selected pill read as raised above it.
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.tint(Color.white.opacity(0.12)), in: .capsule)
        } else {
            Capsule(style: .continuous).fill(Color.primary.opacity(0.06))
        }
    }
}
