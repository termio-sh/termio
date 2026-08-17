import SwiftUI
import AppKit

/// The right inspector's content: its list (file tree / search / changes / issues) beside any open
/// detail — a file editor or preview, a git diff, a PR/issue, or an agent trace. Every one of these
/// is a natural master–detail pair (tree ‖ editor, issue list ‖ conversation, changes ‖ diff), so
/// the list stays put in a narrow leading column and clicking an item only swaps the detail — no
/// drill-in / back round-trip. Details used to cover the terminal; they live here now, so the
/// terminal stays live while you read. Below `twoColumnMinWidth` the split would leave the detail
/// too cramped, so it degrades to detail-only (the list one tab-switch away), Mail-style. When
/// `store.inspectorMaximized` the detail is hoisted to the app delegate's full-window host, so
/// `InspectorDetailContent` renders in exactly one place.
struct InspectorRoot: View {
    @EnvironmentObject var store: TermioStore
    let list: AnyView

    /// The leading list column's width once the detail sits beside it — a comfortable browse strip
    /// (Mail's message-list / VS Code's explorer proportions), not so wide it starves the detail.
    /// Persisted, so the drag-to-resize width survives relaunch, and shared across inspector panes.
    @AppStorage("inspectorListColumnWidth") private var listColumnWidth: Double = 240

    /// The default browse width a double-click on the divider snaps back to.
    private static let defaultListWidth: CGFloat = 240
    /// Drag bounds for the list column: wide enough to read a path, never so wide the detail starves.
    private static let minListWidth: CGFloat = 180
    private static let maxListWidth: CGFloat = 460
    /// Below this the list ‖ detail split leaves the detail too narrow, so the detail takes the whole
    /// panel and the list hides until the inspector is widened (or a tab switch brings it back).
    private static let twoColumnMinWidth: CGFloat = 600
    /// The named space the resize drag reads its pointer x in — the list column's leading edge is its
    /// origin, so the pointer's x *is* the target column width.
    private static let dragSpace = "inspectorList"

    var body: some View {
        GeometryReader { geo in
            let showDetail = store.isDetailPresented && !store.inspectorMaximized
            // Two-column when there's room AND the user hasn't collapsed the list to focus the detail.
            let twoColumn = showDetail && geo.size.width >= Self.twoColumnMinWidth && !store.inspectorListCollapsed
            // Never let the column eat the detail on a narrow inspector: cap it to leave the detail at
            // least a readable strip, then clamp the persisted width into the drag bounds.
            let maxAllowed = max(Self.minListWidth, min(Self.maxListWidth, geo.size.width - 260))
            let width = max(Self.minListWidth, min(CGFloat(listColumnWidth), maxAllowed))
            // Whether the always-mounted list is fully hidden under the detail (narrow or
            // list-collapsed fallback) — inert to clicks and assistive tech, but still alive.
            let listCovered = showDetail && !twoColumn
            ZStack(alignment: .topLeading) {
                // The list is ALWAYS mounted at real size. `List(children:)` holds the file tree's
                // disclosure state inside the view, and both unmounting the list (the old narrow
                // detail-only branch) and squeezing it to zero width tear down its backing outline
                // view — the tree came back fully collapsed after closing a file. So the hidden
                // states keep the list laid out full-width and let the opaque detail cover it.
                // The frames are a single structural branch (nil = no-op) for the same reason: an
                // if/else between fixed-width and flexible would give the list two SwiftUI
                // identities, resetting the tree on the two-column ↔ full transition.
                HStack(spacing: 0) {
                    list
                        .frame(width: twoColumn ? width : nil)
                        .frame(maxWidth: twoColumn ? nil : .infinity)
                        .allowsHitTesting(!listCovered)
                        .accessibilityHidden(listCovered)
                    Spacer(minLength: 0)
                }
                // The detail overlays everything right of the list column (`InspectorDetailContent`
                // is opaque): beside the list in two-column, covering the whole panel — list still
                // alive beneath — in the narrow or list-collapsed fallbacks.
                if showDetail {
                    InspectorDetailContent()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.leading, twoColumn ? width + 1 : 0)
                        .transition(.opacity)
                }
                // The divider rides ABOVE the detail: it straddles the seam at `width`, and the
                // detail layer starts at `width + 1`, which would otherwise swallow the trailing
                // half of its 10pt grab strip — dragging from the detail side would miss.
                if twoColumn {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: width).allowsHitTesting(false)
                        columnDivider(maxAllowed: maxAllowed)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(.named(Self.dragSpace))
            .animation(.easeOut(duration: 0.12), value: showDetail)
            .animation(.easeOut(duration: 0.12), value: twoColumn)
        }
    }

    /// The draggable seam between the list and the detail. A hairline `Divider` under a wider,
    /// invisible grab strip: the pointer flips to the resize cursor on hover, the drag retunes the
    /// column width (clamped so neither side starves), and a double-click snaps back to the default.
    private func columnDivider(maxAllowed: CGFloat) -> some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(coordinateSpace: .named(Self.dragSpace))
                            .onChanged { value in
                                listColumnWidth = Double(max(Self.minListWidth, min(value.location.x, maxAllowed)))
                            }
                    )
                    .onTapGesture(count: 2) { listColumnWidth = Double(Self.defaultListWidth) }
            }
    }
}

/// The detail's own window controls, drawn at the trailing edge of each detail's header (and as a
/// top-trailing overlay on the header-less trace). All three act on the content area, so they live
/// *in* it rather than in the window toolbar — which also sidesteps the flaky
/// `NSTrackingSeparatorToolbarItem` layout the toolbar-hosted versions destabilized. Hugeicons
/// glyphs, matching the inspector's other pane-header buttons.
struct InspectorDetailChromeButtons: View {
    @EnvironmentObject var store: TermioStore

    var body: some View {
        HStack(spacing: 6) {
            // Collapse the leading list column so the detail fills the inspector. A two-pane
            // "layout columns" glyph depicts the list ‖ content split it toggles — bolder and clearer
            // at this size than the busy sidebar-rail mark. Meaningless once the detail already
            // fills the whole window, so it's dropped while maximized.
            if !store.inspectorMaximized {
                DetailChromeButton(
                    icon: .layoutColumns, size: 15,
                    help: store.inspectorListCollapsed ? "Show the list column" : "Hide the list column"
                ) { store.inspectorListCollapsed.toggle() }
            }
            DetailChromeButton(
                icon: store.inspectorMaximized ? .collapse : .expand, size: 14,
                help: store.inspectorMaximized ? "Restore detail to the inspector"
                                               : "Maximize detail to fill the window"
            ) { store.inspectorMaximized.toggle() }
            // The X is optically heavy (two full-width diagonals), so it's drawn a touch smaller to
            // sit even with the others.
            DetailChromeButton(icon: .close, size: 12, help: "Close (Esc)") {
                NotificationCenter.default.post(name: .termioCloseContentOverlay, object: nil)
            }
        }
    }
}

/// One content-area control, wearing the shared `TreeHeaderChip` so the detail's window controls
/// read as one family with the refresh / filter / ↗ buttons in the same header — a 22×22 Hugeicons
/// glyph, quiet `.secondary` at rest and brightening to primary over a faint rounded fill on hover.
/// `size` varies per glyph so each sits at the same optical weight (the diagonal-heavy ✕ shrinks).
private struct DetailChromeButton: View {
    let icon: HugeIcon
    var size: CGFloat = 14
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HugeIconView(icon: icon, size: size,
                         color: hovering ? .primary : .secondary,
                         lineWidthOverride: 1.0)
                .modifier(TreeHeaderChip(hovering: $hovering))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The detail itself, chosen from the store's four detail slots. A PR's file diff (`openDiff`)
/// deliberately stacks on top of its `openIssueDetail`, so closing the diff returns to the PR
/// rather than the list — hence `openDiff` is checked first. Every close routes through the same
/// `.termioCloseContentOverlay` teardown the toolbar button uses (clear the store, return focus
/// to the terminal), so the toolbar and in-place close paths stay identical. Shared verbatim by
/// the inspector and the full-window maximize host.
struct InspectorDetailContent: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings

    private func close() {
        NotificationCenter.default.post(name: .termioCloseContentOverlay, object: nil)
    }

    var body: some View {
        detail
            // Opaque so the inspector's list (a transparent tree over the sidebar material) never
            // shows through the detail beneath it.
            .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var detail: some View {
        if let request = store.openDiff {
            GitDiffView(request: request, settings: settings, onClose: close,
                        onNavigate: { store.openDiff = $0 })
                .id(request)
        } else if let item = store.openIssueDetail, let model = store.issuesModel {
            IssueDetailView(item: item, model: model, settings: settings, onBack: close)
                .id(item.number)
        } else if let url = store.openFileURL {
            // Content staged from an SSH host is previewed as source, never as live
            // web content: HTML and SVG from a remote box would otherwise run in
            // WebKit with the file's own origin.
            if FileActivation.isPreviewable(url),
               store.openFileAllowsActiveWebContent
                || !FileActivation.isActiveWebContent(url) {
                FilePreviewView(url: url, settings: settings,
                                displayName: store.openFileDisplayName,
                                allowsWebFallback: store.openFileAllowsActiveWebContent,
                                onClose: close)
                    .id(url)
            } else {
                FileEditorView(url: url, settings: settings,
                               readOnly: store.openFileReadOnly,
                               jumpLine: store.openFileLine,
                               displayName: store.openFileDisplayName,
                               addToChat: { selection in
                                   if let selection {
                                       _ = store.addSnippetToSelectedSessionPrompt(selection)
                                   } else {
                                       _ = store.addPathToSelectedSessionPrompt(url)
                                   }
                               },
                               canAddToChat: { store.selectedSessionRunsAgent },
                               onClose: close)
                    .id(url)
            }
        } else if let request = store.openTrace {
            TraceView(request: request, settings: settings, onClose: close)
                .id(request)
        }
    }
}
