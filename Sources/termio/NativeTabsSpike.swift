import AppKit
import SwiftUI

// MARK: - SPIKE: native NSWindow tabbing (Ghostty's model)
//
// Branch: spike/native-window-tabs. Purpose: let us *feel* Route A — one real NSWindow per tab,
// grouped with `addTabbedWindow` so macOS draws its own native tab bar (the same widget Ghostty
// relocates into its titlebar). This is throwaway exploration, not a merge candidate.
//
// WHAT THIS DEMONSTRATES (honestly):
//   • The native tab bar chrome: the system `+`, drag-to-reorder, compression when the window
//     narrows, the overflow menu, ⌃⇥ cycling, ⌘⇧\ to show all tabs — all free from AppKit.
//   • The unavoidable consequence: every tab is a whole window, so each carries its OWN sidebar.
//     Collapse the sidebar in one tab and the other tab keeps its own — proof they're separate.
//
// WHAT THIS FAKES (the part that would be the real rewrite):
//   • Content follows the store's single GLOBAL `selectedSessionID`, so every tab shows the same
//     session. Real per-tab content needs selection to become per-window — that refactor (plus
//     the fact native tabs can't nest into Safari tab-groups) is exactly what this spike prices.

extension AppDelegate {
    private static let sessionTabbingIdentifier = NSWindow.TabbingIdentifier("termio.session")

    /// Opt the main window into native tabbing so new windows with the same tabbing identifier
    /// merge into one native tab group instead of opening standalone.
    func enableNativeSessionTabbing() {
        guard let window else { return }
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.sessionTabbingIdentifier
    }

    /// AppKit's hook for the tab bar's `+` button and our repointed ⌘T. Creates a fresh session
    /// window and tabs it into the sender window's group.
    @objc func newWindowForTab(_ sender: Any?) {
        let parent = (sender as? NSWindow)
            ?? NSApp.keyWindow
            ?? NSApp.mainWindow
        let newWindow = makeSpikeSessionWindow()
        if let parent, parent.tabbingIdentifier == Self.sessionTabbingIdentifier {
            parent.addTabbedWindow(newWindow, ordered: .above)
        }
        newWindow.makeKeyAndOrderFront(nil)
    }

    /// Builds a window that mirrors the main window's chrome — same style mask, transparent
    /// terminal-tinted titlebar, full-height sidebar, and a real toolbar (branch picker) bound to
    /// this window's own split. Retained in `spikeWindows` / `spikeToolbarDelegates`.
    private func makeSpikeSessionWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "Termio"
        w.contentMinSize = NSSize(width: 640, height: 420)
        w.titleVisibility = .hidden
        w.titlebarSeparatorStyle = .automatic
        w.tabbingMode = .preferred
        w.tabbingIdentifier = Self.sessionTabbingIdentifier
        w.isReleasedWhenClosed = false

        let split = makeSpikeContentSplit()
        w.contentViewController = split

        // A real toolbar bound to THIS window's split, so the branch picker + sidebar toggle work
        // per tab exactly like the main window.
        let delegate = MainToolbarDelegate(store: store, settings: settings, splitViewController: split)
        spikeToolbarDelegates.append(delegate)
        let toolbar = NSToolbar(identifier: "TermioSpikeToolbar")
        toolbar.delegate = delegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        if #available(macOS 26, *) {
            w.toolbarStyle = .automatic
        } else {
            w.toolbarStyle = .unifiedCompact
        }
        w.toolbar = toolbar

        // Match the main window's transparent, terminal-tinted titlebar (statically resolved).
        let translucent = settings.backgroundOpacity < 1.0 || settings.backgroundBlur > 0
        w.isOpaque = !translucent
        w.backgroundColor = translucent ? .clear : resolvedTerminalBackground()
        w.titlebarAppearsTransparent = !w.styleMask.contains(.fullScreen)

        spikeWindows.append(w)
        return w
    }

    /// A standalone copy of the main content split ([sidebar | terminal]) bound to the shared
    /// store. Mirrors `makeContentSplitViewController` but touches no `AppDelegate` singleton state
    /// so it can be built once per window.
    private func makeSpikeContentSplit() -> NSSplitViewController {
        let sidebar = NSHostingController(rootView: SidebarView()
            .environmentObject(store)
            .environmentObject(settings))
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 240
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true
        if #unavailable(macOS 26) {
            sidebarItem.titlebarSeparatorStyle = .none
        }

        let detail = NSHostingController(rootView: TerminalPane()
            .environmentObject(store)
            .environmentObject(settings))
        detail.sizingOptions = []
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 280
        detailItem.titlebarSeparatorStyle = .line

        let split = NSSplitViewController()
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)
        return split
    }
}
