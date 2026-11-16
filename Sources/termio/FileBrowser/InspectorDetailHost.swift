import SwiftUI
import AppKit

/// The right inspector's content: its list (file tree / search / changes / issues) beside any open
/// detail — a file editor or preview, a git diff, or a PR/issue. Every one of these
/// is a natural master–detail pair (tree ‖ editor, issue list ‖ conversation, changes ‖ diff), so
/// the list stays put in a narrow leading column and clicking an item only swaps the detail — no
/// drill-in / back round-trip. Details used to cover the terminal; they live here now, so the
/// terminal stays live while you read. Below `twoColumnMinWidth` the split would leave the detail
/// too cramped, so it degrades to detail-only (the list one tab-switch away), Mail-style. The
/// detail itself is not rendered here: `DockedDetailSlot` reserves its space and adopts the one
/// shared `DetailHost`, which the app delegate borrows while `store.inspectorMaximized`.
struct InspectorRoot: View {
    @EnvironmentObject var store: TermioStore
    let list: AnyView

    /// The leading list column's width once the detail sits beside it — a comfortable browse strip
    /// (Mail's message-list / VS Code's explorer proportions), not so wide it starves the detail.
    /// Persisted, so the drag-to-resize width survives relaunch, and shared across inspector panes.
    @AppStorage("inspectorListColumnWidth") private var listColumnWidth: Double = 240
    @State private var columnDividerHovered = false
    /// The list column's width when the divider drag began; nil when no drag is in flight.
    @State private var columnDragAnchor: Double?

    /// The default browse width a double-click on the divider snaps back to.
    private static let defaultListWidth: CGFloat = 240
    /// Drag bounds for the list column: wide enough to read a path, never so wide the detail starves.
    private static let minListWidth: CGFloat = 180
    private static let maxListWidth: CGFloat = 460
    /// Below this the list ‖ detail split leaves the detail too narrow, so the detail takes the whole
    /// panel and the list hides until the inspector is widened (or a tab switch brings it back).
    /// Read by the detail's list toggle too — it widens the panel to this rather than flipping a flag
    /// that a narrow inspector would swallow.
    static let twoColumnMinWidth: CGFloat = 600

    var body: some View {
        GeometryReader { geo in
            // Stays true while maximized: the slot keeps its place (empty, since the delegate is
            // holding the shared host over the whole content area) so restoring is a single
            // re-parent back into a view that is already laid out, with nothing to re-create.
            let showDetail = store.isDetailPresented
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
                    DockedDetailSlot()
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
            // The detail's header lives in its own hosting view and can't see this geometry, so the
            // store carries the one bit it needs. Only the threshold crossing is published, not the
            // width, so a divider drag doesn't wake every store observer on each frame.
            .onChange(of: geo.size.width >= Self.twoColumnMinWidth, initial: true) { _, fits in
                store.noteInspectorFitsTwoColumns(fits)
            }
            // Opening and closing a detail cross-fades over the list. Maximizing does not touch
            // this: the slot stays mounted through it, so there is nothing here to animate.
            .animation(.easeOut(duration: 0.12), value: store.isDetailPresented)
            .animation(.easeOut(duration: 0.12), value: twoColumn)
        }
    }

    /// The draggable seam between the list and the detail. A hairline `Divider` under a wider,
    /// invisible grab strip: the pointer flips to the resize cursor on hover, the drag retunes the
    /// column width (clamped so neither side starves), and a double-click snaps back to the default.
    private func columnDivider(maxAllowed: CGFloat) -> some View {
        Divider()
            .overlay {
                SashGrip(axis: .vertical, isActive: columnDividerHovered || columnDragAnchor != nil)
                    .overlay {
                        SashHandle(
                            axis: .vertical,
                            onHover: { columnDividerHovered = $0 },
                            onBegin: { columnDragAnchor = listColumnWidth },
                            onChange: { delta in
                                guard let start = columnDragAnchor else { return }
                                listColumnWidth = Double(max(Self.minListWidth,
                                                             min(CGFloat(start) + delta, maxAllowed)))
                            },
                            onEnd: { columnDragAnchor = nil },
                            onDoubleClick: { listColumnWidth = Double(Self.defaultListWidth) })
                    }
                    .frame(width: 10)
            }
    }
}

/// The one `NSHostingView` that renders whichever detail is open, moved between two parents rather
/// than built twice: the inspector's `DockedDetailSlot` and the app delegate's full-window position
/// while `store.inspectorMaximized`.
///
/// Two hosts would mean two SwiftUI trees, and maximizing would drop one and build the other from
/// nothing — which is what made the transition flash: the file was re-read behind a blank frame,
/// the Markdown reader built a fresh `WKWebView` and landed back at the top, the mode and find bar
/// reset, and the copy being dropped fired its `onDisappear` save flush. Re-parenting one `NSView`
/// inside one window keeps its view graph, so every `@State` and the live web view survive.
@MainActor
final class DetailHost {
    static let shared = DetailHost()
    private init() {}

    private(set) var view: NSHostingView<AnyView>?

    /// The inspector's slot, while one is mounted. The delegate hands the host back to it on
    /// restore; a weak reference because SwiftUI, not this object, decides when it goes away.
    weak var dockedSlot: NSView?

    /// The host, built on first use. Both parents ask for it through here, so whichever one needs
    /// it first creates it and the other finds the same instance.
    func view(store: TermioStore, settings: AppSettings, window: NSWindow?) -> NSHostingView<AnyView> {
        if let view { return view }
        // Measure the traffic lights rather than assuming their layout: a maximized detail's header
        // runs up into the titlebar, and where the buttons end is where its title may start.
        let buttonsEnd = window?.standardWindowButton(.zoomButton)?.frame.maxX ?? 70
        let host = NSHostingView(rootView: AnyView(
            DetailHostRoot(trafficLightsInset: buttonsEnd)
                .environmentObject(store)
                .environmentObject(settings)
        ))
        // No SwiftUI-derived sizing constraints: the host is sized by whichever parent holds it,
        // and the default `.standardBounds` options let auto layout satisfy the root view's ideal
        // size by resizing the *window* — which once crushed the whole window to a ~90pt strip.
        host.sizingOptions = []
        view = host
        return host
    }

    /// Puts the host in the inspector's slot, filling it. Re-parenting from the maximized position
    /// is this same single `addSubview`: the view is never left without a superview, so it never
    /// leaves the window and nothing inside it is torn down.
    func dock(in slot: NSView) {
        guard let view, view.superview !== slot else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
            view.topAnchor.constraint(equalTo: slot.topAnchor),
            view.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
        ])
    }

    /// Drops the host once no detail is open. The next open builds a fresh one, which is right —
    /// there is no document left for it to hold.
    func discard() {
        view?.removeFromSuperview()
        view = nil
    }
}

/// The shared host's root view: the same content the inspector docks, plus the two things that
/// differ once it fills the window. There is no band above it, so the detail's own header *is* the
/// window's top bar; and when the sidebar is collapsed the host
/// reaches the window's leading edge, so the header takes an inset that clears the traffic lights.
/// Both read the store, so one long-lived view covers docked and maximized alike.
struct DetailHostRoot: View {
    @EnvironmentObject var store: TermioStore
    /// Leading room the traffic lights need, measured from the live window — the buttons' geometry
    /// is the system's to change, so it is never hardcoded here.
    let trafficLightsInset: CGFloat

    var body: some View {
        InspectorDetailContent()
            .environment(\.detailHeaderLeadingInset, needsTrafficLightsRoom ? trafficLightsInset : 0)
            // Up into the titlebar strip only when it is maximized with the sidebar collapsed — then
            // its header is the window's top row and sits beside the traffic lights, so it takes
            // the top margin every other row does and centres on the same line (`WindowChrome`).
            .padding(.top, ridesTitlebar ? WindowChrome.inset : 0)
            .ignoresSafeArea(.container, edges: ridesTitlebar ? .top : [])
    }

    private var ridesTitlebar: Bool { store.inspectorMaximized && !store.sidebarVisible }

    /// Only when the buttons are actually sitting on this header. Docked, or with the sidebar open,
    /// they land elsewhere; in fullscreen they are hidden until the pointer summons the titlebar —
    /// which then slides in *over* the content, so holding a gap for them all along only pushes the
    /// title inward for nothing.
    private var needsTrafficLightsRoom: Bool { ridesTitlebar && !store.windowIsFullScreen }
}

/// The inspector's slot for the shared detail host. It holds no content of its own — it adopts
/// `DetailHost.shared` — and stands empty while the detail is maximized, keeping the place the host
/// comes back to laid out and ready.
struct DockedDetailSlot: NSViewRepresentable {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ slot: NSView, context: Context) {
        DetailHost.shared.dockedSlot = slot
        // While maximized the delegate is holding the host over the whole content area; taking it
        // back here would yank it out from under the user mid-mode.
        guard !store.inspectorMaximized else { return }
        _ = DetailHost.shared.view(store: store, settings: settings, window: slot.window)
        DetailHost.shared.dock(in: slot)
    }

    static func dismantleNSView(_ slot: NSView, coordinator: ()) {
        MainActor.assumeIsolated {
            if DetailHost.shared.dockedSlot === slot { DetailHost.shared.dockedSlot = nil }
        }
    }
}

/// Extra leading room a detail's header takes so its title clears the window's traffic lights.
/// Non-zero only while the detail is maximized with the sidebar collapsed; docked in the inspector
/// the header is nowhere near them.
private struct DetailHeaderLeadingInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var detailHeaderLeadingInset: CGFloat {
        get { self[DetailHeaderLeadingInsetKey.self] }
        set { self[DetailHeaderLeadingInsetKey.self] = newValue }
    }
}

/// Carried by every detail header bar, so each one clears the traffic lights when it rides the
/// titlebar. Applied outside the header's own padding, which keeps its docked spacing untouched.
struct DetailHeaderTitlebarInset: ViewModifier {
    @Environment(\.detailHeaderLeadingInset) private var inset

    func body(content: Content) -> some View {
        content.padding(.leading, inset)
            // A maximized detail's header is the window's top row, so it moves the window too.
            .background(WindowDragArea())
    }
}

/// Collapses or restores the inspector's list column. Leads each detail's header, on the side of the
/// column it acts on, the way a sidebar toggle sits at the sidebar's edge. A panel glyph rather than
/// one of the box-split "layout" marks, which the diff's inline / side-by-side toggle owns now: two
/// of those in one header read as one control. Shown only where it can act: while the panel has
/// room for both columns, and never while the detail is maximized and fills the window.
struct DetailListColumnToggle: View {
    @EnvironmentObject var store: TermioStore
    /// How much wider the header's leading padding is than its trailing one. The toggle steps out
    /// by that much, so it sits as far from the leading edge as the close button from the
    /// trailing one.
    var outset: CGFloat = 0

    var body: some View {
        if store.inspectorFitsTwoColumns, !store.inspectorMaximized {
            let showing = store.inspectorListColumnVisible
            DetailChromeButton(
                icon: showing ? .panelLeftCollapse : .panelLeftExpand,
                help: showing ? "Hide the list column" : "Show the list column"
            ) {
                store.setInspectorListColumn(visible: !showing)
            }
            .padding(.leading, -outset)
        }
    }
}

/// The detail's own window controls, drawn at the trailing edge of each detail's header. Both
/// act on the content area, so they live
/// *in* it rather than in the window toolbar — which also sidesteps the flaky
/// `NSTrackingSeparatorToolbarItem` layout the toolbar-hosted versions destabilized. Hugeicons
/// glyphs, matching the inspector's other pane-header buttons.
struct InspectorDetailChromeButtons: View {
    @EnvironmentObject var store: TermioStore

    var body: some View {
        HStack(spacing: 6) {
            DetailChromeButton(
                icon: store.inspectorMaximized ? .collapse : .expand,
                help: store.inspectorMaximized ? "Restore detail to the inspector"
                                               : "Maximize detail to fill the window"
            ) { store.inspectorMaximized.toggle() }
            // The X is optically heavy (two full-width diagonals), so it's drawn a touch smaller to
            // sit even with the others.
            DetailChromeButton(icon: .close, help: "Close (Esc)") {
                NotificationCenter.default.post(name: .termioCloseContentOverlay, object: nil)
            }
        }
    }
}

/// One content-area control, wearing the shared `TreeHeaderChip` so the detail's window controls
/// read as one family with the window's other glyph buttons: one size (`ChromeGlyph`), quiet
/// `.secondary` at rest and brightening to primary over a faint rounded fill on hover.
struct DetailChromeButton: View {
    let icon: HugeIcon
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HugeIconView(icon: icon, size: ChromeGlyph.size(for: icon),
                         color: hovering ? .primary : .secondary,
                         lineWidthOverride: ChromeGlyph.lineWidth())
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
        } else if let opening = store.openingRemoteFile {
            // The click is answered before the network is: the file's chrome goes
            // up now, and the editor replaces it when the bytes land.
            RemoteFileOpeningView(opening: opening, settings: settings)
        } else if let url = store.openFileURL {
            // Content staged from an SSH host is previewed as source, never as live
            // web content: HTML and SVG from a remote box would otherwise run in
            // WebKit with the file's own origin. An HTML page goes to the editor,
            // which renders it only when `allowsWebPreview` says it may.
            if FileActivation.isPreviewable(url), !FileActivation.isWebPage(url),
               store.openFileAllowsActiveWebContent
                || !FileActivation.isActiveWebContent(url) {
                FilePreviewView(url: url, settings: settings,
                                displayName: store.openFileDisplayName,
                                allowsWebFallback: store.openFileAllowsActiveWebContent,
                                addToChat: { selection in
                                    if let selection {
                                        _ = store.addSnippetToSelectedSessionPrompt(selection)
                                    } else {
                                        _ = store.addPathToSelectedSessionPrompt(url)
                                    }
                                },
                                // A passage goes to the agent beside the document. With the
                                // reader filling the window there is no session beside it, so
                                // the verb is gone rather than aimed at a terminal you can't see.
                                canAddToChat: {
                                    store.selectedSessionRunsAgent && !store.inspectorMaximized
                                },
                                onClose: close)
                    .id(url)
            } else {
                FileEditorView(url: url, settings: settings,
                               readOnly: store.openFileReadOnly,
                               jumpLine: store.openFileLine,
                               displayName: store.openFileDisplayName,
                               remote: store.openFileRemote,
                               onRemoteSave: { store.openFileRemote = $0 },
                               allowsWebPreview: store.openFileAllowsActiveWebContent,
                               onDirtyChange: { store.openFileDirty = $0 },
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
        }
    }
}
