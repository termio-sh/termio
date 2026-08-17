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
    @EnvironmentObject var settings: AppSettings
    /// Light vs dark decides the track + chip materials: a white glass track with a soft grey
    /// selected chip in light mode (the macOS 26 Finder segmented control), a faint light track
    /// with a brighter overlay chip in dark.
    @Environment(\.colorScheme) private var colorScheme
    /// Whether the current project's origin remote points at github.com — probed
    /// async per selection change; gates the Issues segment together with the
    /// General "GitHub" setting.
    @State private var hasGitHubRemote = false
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
        (.issues, .github, "Issues"),
        (.info, .infoCircle, "Info"),
    ]

    /// Issues only exists for a project that actually lives on GitHub (and with the
    /// integration left on in General) — for anything else the segment disappears
    /// rather than leading to a dead pane.
    private var visibleSegments: [(tab: InspectorTab, icon: HugeIcon, help: String)] {
        segments.filter { $0.tab != .issues || (settings.githubIntegrationEnabled && hasGitHubRemote) }
    }

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
            // Re-probe when the selection moves or the General switch flips; keyed so
            // the check doesn't rerun on unrelated store churn.
            .task(id: "\(settings.githubIntegrationEnabled)|\(store.inspectorProjectPath ?? "")") {
                if let path = store.inspectorProjectPath, settings.githubIntegrationEnabled {
                    hasGitHubRemote = await GitService.gitHubRepoSlug(in: path) != nil
                } else {
                    hasGitHubRemote = false
                }
                // The pane someone was on can vanish out from under them (setting
                // turned off, selection moved to a non-GitHub project) — land on Files.
                if store.inspectorTab == .issues,
                   !(settings.githubIntegrationEnabled && hasGitHubRemote) {
                    store.inspectorTab = .files
                }
            }
    }

    /// The row of segments with the sliding selection pill behind the active one, all inside our own
    /// track. Same structure on every OS; only the pill + track *materials* differ (Liquid Glass on
    /// macOS 26, flat capsule fills on macOS 15 / earlier).
    private var segmentedTrack: some View {
        HStack(spacing: 0) {
            ForEach(visibleSegments, id: \.tab) { seg in
                let selected = store.inspectorTab == seg.tab
                // Active glyph lifts to full-strength; the rest stay muted — so the selected
                // pane is legible even before you notice the pill.
                // Heavier than the size-derived 1.1pt default: at 15pt the Hugeicons stroke
                // reads hairline next to the SF Symbol toolbar buttons flanking the track,
                // so match their optical weight instead.
                HugeIconView(icon: seg.icon, size: 15, color: selected ? .primary : .secondary,
                             lineWidthOverride: 1.5)
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
        // drag the inspector content along with it. Fast and bounce-free: the pane itself
        // switches instantly, and the pill is the motion cue the eye tracks — at 0.28s it
        // arrived visibly after the content and made every switch read slow. A tab switch
        // is a dozens-of-times-a-day micro-interaction, and the eye finishes tracking a
        // hop this small in under ~80ms, so 0.1s is the floor that still shows *which way*
        // the selection moved without ever being waited on.
        .animation(.snappy(duration: 0.1, extraBounce: 0), value: store.inspectorTab)
    }

    // MARK: Materials — macOS 26 (Tahoe) Finder segmented control

    // The track is the raised white *glass* panel; the selected segment is a soft **grey** chip
    // recessed into it — the macOS 26 Finder / toolbar segmented look. (This inverts the earlier
    // pass, where the track was grey and the chip white.) In dark mode the same relationship holds
    // with light-on-dark values. The chip itself stays a flat fill, never `.glassEffect` — the
    // glass pill's soft shadow read as stray chrome riding *inside* the track.
    private var selectionPill: some View {
        Capsule(style: .continuous)
            .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.07))
            // Non-source: takes the frame + position of the currently selected segment.
            .matchedGeometryEffect(id: store.inspectorTab, in: pillNamespace, isSource: false)
    }

    // The track is real Liquid Glass on macOS 26 — the same `.regular` material as the native
    // bordered toolbar buttons flanking it (collapse / +), so the whole toolbar row reads as one
    // family of glass capsules instead of a painted white slab next to translucent buttons.
    // Pre-26 there is no glass, so fall back to the flat fills.
    @ViewBuilder
    private var trackBackground: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: .capsule)
        } else {
            Capsule(style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white)
        }
    }
}
