import AppKit
import GhosttyTerminal

/// Ghostty-style right-click menu over the terminal surfaces: Copy/Paste plus
/// the split-pane actions the ⌘⇧P palette offers, so a mouse-first user can
/// split without learning the palette.
///
/// The libghostty wrapper's own `rightMouseDown` either pops a Copy-only menu
/// (over a selection) or forwards the click to the terminal program — the app
/// never gets a say, and the wrapper instantiates its view class itself so a
/// subclass override can't be injected. So the menu is added one level up: a
/// local `rightMouseDown` monitor that spots clicks landing on a terminal
/// surface in the main window and consumes them with termio's menu instead
/// (Ghostty likewise claims right-click for its menu).
@MainActor
final class TerminalContextMenu: NSObject {
    private weak var store: TermioStore?
    /// The ⌘V interceptor, so the menu's Paste answers the image-at-a-remote-
    /// session case the same way the key does instead of restating the rule.
    private weak var imagePaste: TermiodImagePaste?
    // Held for the app's lifetime; never removed.
    private var monitor: Any?
    /// The surface the open menu acts on, resolved at click time.
    private weak var clickedView: TerminalView?
    /// The web link under the pointer at click time (ghostty's hover-link report,
    /// the same state the cmd+click interceptor reads), or nil off-link. Captured
    /// when the menu opens so the actions don't chase a moved mouse.
    private var clickedLinkURL: URL?

    init(store: TermioStore, imagePaste: TermiodImagePaste?) {
        self.store = store
        self.imagePaste = imagePaste
        super.init()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            // Local event monitors are always called on the main thread; the
            // annotation just can't say so (and `NSEvent` isn't `Sendable`, so
            // only the Bool verdict crosses the `assumeIsolated` boundary).
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { self.intercept(event) }
            return consumed ? nil : event
        }
    }

    /// Returns whether the click was consumed by showing the menu; `false`
    /// lets right-clicks outside the terminal behave as before.
    private func intercept(_ event: NSEvent) -> Bool {
        guard let store,
              let window = event.window,
              window.frameAutosaveName == AppDelegate.mainWindowFrameAutosaveName,
              let contentView = window.contentView,
              // Details (editor, diff, trace, PR/issue) open in the right inspector now, so the
              // terminal is always fully visible and owns its right-clicks — except when a detail
              // is maximized to a full-window overlay covering everything; then it owns them.
              !(store.isDetailPresented && store.inspectorMaximized)
        else { return false }

        // Resolve the pane by geometry rather than `hitTest`: every activated
        // session stays mounted, hidden ones included (see `TerminalPane`), and
        // raw AppKit hit-testing doesn't honor SwiftUI's `allowsHitTesting(false)`
        // on those, so the topmost view under the cursor may be a hidden sibling.
        // Visible panes tile without overlapping, so "contains the point and is
        // visible" is unambiguous.
        let point = event.locationInWindow
        let target = terminalViews(in: contentView).first { view in
            guard view.window === window,
                  view.convert(view.bounds, to: nil).contains(point),
                  let id = sessionID(for: view) else { return false }
            return store.visiblePaneIDs.contains(id)
        }
        guard let target else { return false }

        // Focus follows the right-click (the wrapper's own `rightMouseDown`
        // does the same), and the selection is moved synchronously so the
        // split actions below operate on the clicked pane, not a stale one.
        window.makeFirstResponder(target)
        if let id = sessionID(for: target), store.selectedSessionID != id {
            store.selectedSessionID = id
        }
        clickedView = target
        clickedLinkURL = TerminalLinkState.hoveredURL
            .flatMap(URL.init(string:))
            .flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        // popUp — not popUpContextMenu(_:with:for:) — presents exactly the menu we
        // built. Passing the surface as the `for:` view makes AppKit merge in the
        // system's automatic text-input extras (the "AutoFill" submenu, Services)
        // because the ghostty surface is an NSTextInputClient; those are meaningless
        // over a terminal, so we position the menu ourselves and skip the augmentation.
        makeMenu().popUp(positioning: nil,
                         at: target.convert(event.locationInWindow, from: nil),
                         in: target)
        return true
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        // Right-clicking a web link offers it externally up top (the Browser
        // Right/Down items below pick the same link up for an in-app split).
        // This is also the path that always works — a TUI with mouse reporting
        // (Claude Code) swallows cmd+click, but never the right-click.
        if clickedLinkURL != nil {
            menu.addItem(storeItem(localized("Open Link"), action: #selector(openLink), symbol: "safari"))
            menu.addItem(.separator())
        }
        // Copy targets the surface's own responder action, and is a no-op
        // without a selection. Paste goes through `paste(_:)` below, which ends
        // up at the same responder action for everything except the one case
        // that cannot work there.
        menu.addItem(surfaceItem(localized("Copy"), action: "copy:", symbol: "doc.on.doc"))
        menu.addItem(storeItem(localized("Paste"), action: #selector(paste), symbol: "doc.on.clipboard"))
        // The session's deep link (`termio://session/<uuid>`) — the canonical
        // address every `termio sessions` command takes and the form that stays
        // self-describing when pasted into an agent prompt, so wiring one agent
        // to drive another is a right-click instead of a `list` round-trip.
        if clickedSessionID != nil {
            menu.addItem(storeItem(localized("Copy Session Link"), action: #selector(copyLink), symbol: "link"))
        }
        menu.addItem(.separator())
        // Ghostty's own split glyphs and order (Right, Left, Down, Up): the filled
        // half of the rectangle is where the new pane lands, which reads at a
        // glance in a way "rectangle.split.2x1" never did once there were four.
        menu.addItem(storeItem(localized("Split Right"), action: #selector(splitRight),
                               symbol: "rectangle.righthalf.inset.filled"))
        menu.addItem(storeItem(localized("Split Left"), action: #selector(splitLeft),
                               symbol: "rectangle.leadinghalf.inset.filled"))
        menu.addItem(storeItem(localized("Split Down"), action: #selector(splitDown),
                               symbol: "rectangle.bottomhalf.inset.filled"))
        menu.addItem(storeItem(localized("Split Up"), action: #selector(splitUp),
                               symbol: "rectangle.tophalf.inset.filled"))
        // "Ungroup" is the layout half: the pane leaves the split group but its
        // session stays alive in the sidebar — the same action the sidebar row
        // names "Ungroup" (the inverse of "Group with"). Its glyph is Split
        // Right's with a slash through it: un-split. "Close Session" is the
        // destructive half and is always offered; closing a split session
        // prunes its pane on the way out, so the layout needs no separate
        // cleanup.
        if store?.splitRoot != nil {
            menu.addItem(storeItem(localized("Ungroup"), action: #selector(ungroup),
                                   symbol: "rectangle.split.2x1.slash"))
        }
        if clickedSessionID != nil {
            menu.addItem(storeItem(localized("Close Session"), action: #selector(closeSession), symbol: "xmark"))
        }
        return menu
    }

    private func surfaceItem(_ title: String, action: String, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: "")
        item.target = clickedView
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private func storeItem(_ title: String, action: Selector, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    /// The session under the clicked surface, resolved live from `clickedView`.
    private var clickedSessionID: Session.ID? {
        clickedView.flatMap(sessionID(for:))
    }

    @objc private func copyLink() {
        guard let store, let session = clickedSessionID.flatMap(store.session(_:))
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.sessionLink(for: session), forType: .string)
    }

    @objc private func splitRight() { store?.splitSelectedPane(.horizontal) }
    @objc private func splitLeft() { store?.splitSelectedPane(.horizontal, slot: .first) }
    @objc private func splitDown() { store?.splitSelectedPane(.vertical) }
    @objc private func splitUp() { store?.splitSelectedPane(.vertical, slot: .first) }
    @objc private func ungroup() { store?.ungroupSelectedPane() }
    @objc private func closeSession() {
        guard let id = clickedSessionID else { return }
        store?.requestCloseSession(id)
    }

    /// An image aimed at a session on another device crosses the boundary and
    /// pastes the path it landed at; everything else is the surface's own
    /// paste, which routes through ghostty's `paste_from_clipboard` binding so
    /// bracketed paste is preserved.
    @objc private func paste() {
        if imagePaste?.pasteImageFromMenu(sessionID: clickedSessionID) == true { return }
        clickedView?.perform(NSSelectorFromString("paste:"), with: nil)
    }

    @objc private func openLink() {
        guard let url = clickedLinkURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// All terminal surface views under `root`, in tree order.
    private func terminalViews(in root: NSView) -> [TerminalView] {
        var found: [TerminalView] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let terminal = view as? TerminalView { found.append(terminal) }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    /// Maps a surface view back to its session through the store's surface
    /// cache — the view and its cached `TerminalViewState` share a controller.
    private func sessionID(for view: TerminalView) -> Session.ID? {
        store?.surfaces.first { $0.value.controller === view.controller }?.key
    }
}
