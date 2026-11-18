import AppKit
import SwiftUI

/// A zero-size helper that finds the `NSTableView`/`NSOutlineView` backing a List
/// (by walking up from its own placement inside a row) and corrects two AppKit-layer
/// details SwiftUI gets wrong for our lists. Re-applied on every update because each
/// row mounts one, so any list rebuild reasserts both. Shared by the left sidebar,
/// the Settings sidebar, and the Issues / PR-files / git-changes lists.
///
/// - `selectionHighlightStyle = .none` strips the source list's blue accent fill
///   while leaving selection itself intact — the List keeps native, drag-friendly
///   selection and `SidebarRowHighlight` is the only thing that paints it.
/// - `verticalLineScroll = 24` restores mouse-wheel scrolling. These lists all set
///   `defaultMinListRowHeight` to 1 so rows self-size, but SwiftUI writes that
///   minimum into `NSTableView.rowHeight`, and AppKit mirrors `rowHeight` into the
///   enclosing scroll view's `verticalLineScroll` — the per-line increment every
///   non-precise (physical wheel) scroll event is multiplied by. At 1pt a wheel
///   notch barely moves the list; 24 is what a default-height List gets, so wheels
///   feel like every other Mac list. Trackpads send precise pixel deltas and never
///   consult it.
struct OutlineViewFixups: NSViewRepresentable {
    /// Overrides the table's style. Left `nil` everywhere the source list's own
    /// metrics are wanted; the settings sidebar passes `.fullWidth` because
    /// `.sourceList` reserves a leading strip for a disclosure column that a flat
    /// list never uses, and that strip is not reachable from `listRowInsets` —
    /// it lands *outside* them, so the rows can only ever start further right
    /// than the traffic lights they should line up under.
    var style: NSTableView.Style?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.apply(from: view, style: style) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(from: nsView, style: style) }
    }

    private static func apply(from view: NSView, style: NSTableView.Style?) {
        var ancestor = view.superview
        while let current = ancestor {
            // NSOutlineView is an NSTableView subclass, so this catches the tree.
            if let table = current as? NSTableView {
                if table.selectionHighlightStyle != .none {
                    table.selectionHighlightStyle = .none
                }
                if let style, table.style != style {
                    table.style = style
                    // The other half of the same strip: an outline indents every
                    // row by one level's worth even when nothing is nested.
                    (table as? NSOutlineView)?.indentationPerLevel = 0
                }
                if let scroll = table.enclosingScrollView {
                    if scroll.verticalLineScroll != 24 {
                        scroll.verticalLineScroll = 24
                    }
                    enforce(scroll)
                }
                return
            }
            ancestor = current.superview
        }
    }

    /// SwiftUI re-configures the List's scroll view on some structural updates
    /// (covering the pane with another tab's overlay is one), resetting
    /// `verticalLineScroll` back to the 1pt it mirrors from `rowHeight` — and a
    /// property-less representable gets no `updateNSView` afterward to re-run
    /// `apply`, so a one-shot write stays clobbered on an always-mounted list.
    /// This observer watches the clip view's bounds (they change on every scroll)
    /// and re-asserts the increment the moment a reset scroll view first moves, so
    /// a wheel is never slow for more than its first notch. One observer per
    /// scroll view; the token dies with the scroll view it's associated to.
    private static func enforce(_ scroll: NSScrollView) {
        guard objc_getAssociatedObject(scroll, &enforcementKey) == nil else { return }
        scroll.contentView.postsBoundsChangedNotifications = true
        let token = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: nil
        ) { [weak scroll] _ in
            // `queue: nil` delivers on the posting thread, and AppKit posts a clip
            // view's bounds change on main — the isolation the scroll view's own
            // properties require.
            MainActor.assumeIsolated {
                guard let scroll, scroll.verticalLineScroll != 24 else { return }
                scroll.verticalLineScroll = 24
            }
        }
        objc_setAssociatedObject(scroll, &enforcementKey, token, .OBJC_ASSOCIATION_RETAIN)
    }
}

/// Unique address keying the enforcement token onto its scroll view. Only its
/// address is ever taken; the value itself is never read or written.
nonisolated(unsafe) private var enforcementKey: UInt8 = 0
