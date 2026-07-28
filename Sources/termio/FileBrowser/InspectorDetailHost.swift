import SwiftUI

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
    private static let listColumnWidth: CGFloat = 240
    /// Below this the list ‖ detail split leaves the detail too narrow, so the detail takes the whole
    /// panel and the list hides until the inspector is widened (or a tab switch brings it back).
    private static let twoColumnMinWidth: CGFloat = 600

    var body: some View {
        GeometryReader { geo in
            let showDetail = store.isDetailPresented && !store.inspectorMaximized
            // Two-column when there's room AND the user hasn't collapsed the list to focus the detail.
            let twoColumn = showDetail && geo.size.width >= Self.twoColumnMinWidth && !store.inspectorListCollapsed
            // List hides only in the narrow, detail-only fallback; otherwise it's the full panel
            // (no detail) or the leading column (two-column).
            let showList = !showDetail || twoColumn
            HStack(spacing: 0) {
                if showList {
                    list
                        .frame(maxWidth: twoColumn ? Self.listColumnWidth : .infinity)
                    if twoColumn { Divider() }
                }
                if showDetail {
                    InspectorDetailContent()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeOut(duration: 0.12), value: showDetail)
            .animation(.easeOut(duration: 0.12), value: twoColumn)
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
            if FileActivation.isPreviewable(url) {
                FilePreviewView(url: url, settings: settings, onClose: close)
                    .id(url)
            } else {
                FileEditorView(url: url, settings: settings,
                               readOnly: store.openFileReadOnly,
                               jumpLine: store.openFileLine, onClose: close)
                    .id(url)
            }
        } else if let request = store.openTrace {
            TraceView(request: request, settings: settings, onClose: close)
                .id(request)
        }
    }
}
