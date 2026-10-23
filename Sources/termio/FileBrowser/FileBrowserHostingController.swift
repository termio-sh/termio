import AppKit
import Quartz
import SwiftUI

/// Hosts `FileBrowserView` in the focused card's panel and drives the shared Quick
/// Look panel for it. `QLPreviewPanel` finds its controller by walking the
/// responder chain from the key window's first responder; because this view
/// controller sits in that chain (above the SwiftUI tree it hosts), it is the
/// natural owner of the panel while the inspector is focused.
@MainActor
// @preconcurrency: `panel.dataSource = self` needs a conformance usable from a
// nonisolated context; Quick Look delivers its data-source calls on the main
// thread, which the dynamic check this buys enforces.
final class FileBrowserHostingController: NSHostingController<AnyView>, @preconcurrency QLPreviewPanelDataSource {
    private let state: FileBrowserState
    /// A file opened from somewhere other than the tree — a cmd-clicked video in the terminal.
    /// While set, the shared panel previews this instead of the tree selection, so a click on a
    /// movie doesn't depend on that file happening to be the selected row.
    private var quickLookURL: URL?

    init(store: TermioStore, settings: AppSettings) {
        let state = FileBrowserState()
        self.state = state
        super.init(rootView: AnyView(
            // The inspector shows its list (tree / search / changes / issues) with any open detail
            // — editor, diff, PR/issue — layered on top of it (see `InspectorRoot`), so a
            // click opens the file *here*, beside the terminal, rather than covering the terminal.
            InspectorRoot(list: AnyView(
                FileBrowserView(
                    onQuickLook: { FileBrowserHostingController.toggleQuickLook() },
                    // A single click opens the file in the inspector (driven by `store.openFileURL`):
                    // a previewable file (image, PDF, HTML) in the read-only preview, everything else
                    // in the editor. `InspectorDetailContent` picks which based on the file kind.
                    // (Spacebar still pops Quick Look for a quick peek without leaving the tree.)
                    onActivate: { url in
                        store.openFileInEditor(url)
                    }
                )
            ))
            .environmentObject(store)
            .environmentObject(settings)
            .environmentObject(state)
        ))
        // This controller is meant to *fill* the trailing split pane, not to size itself to its
        // content. `NSHostingController` defaults `sizingOptions` to `.preferredContentSize`, which
        // makes it publish the SwiftUI tree's *ideal* size as `preferredContentSize`; the enclosing
        // `NSSplitViewController` propagates that up to the window. So when the inspector shows a
        // compact view — the "No Changes" empty state when the working tree is clean — the window
        // collapsed its height to fit (observed shrinking to ~260pt, below `contentMinSize`).
        // Clearing the options lets the pane stretch to the split view's bounds and never drive the
        // window frame.
        self.sizingOptions = []
    }

    @available(*, unavailable)
    required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the Quick Look panel for the current selection, or hides it if it is
    /// already up — Finder's spacebar toggle.
    private static func toggleQuickLook() {
        InspectorPanelHost.shared.controller?.presentQuickLook(nil, toggle: true)
    }

    /// Pops the shared panel on `url`, or toggles the selection's preview when `url` is nil.
    /// A URL that is already showing is closed instead, matching the spacebar toggle.
    fileprivate func presentQuickLook(_ url: URL?, toggle: Bool) {
        guard let panel = QLPreviewPanel.shared() else { return }
        let sameFile = url != nil && quickLookURL == url
        quickLookURL = url
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible, toggle || sameFile {
            panel.orderOut(nil)
            return
        }
        // The panel asks the key window's responder chain who owns it. The inspector
        // controller only gets that question while it is first responder, so claim it
        // before ordering the panel front — otherwise the click previews nothing.
        view.window?.makeFirstResponder(self)
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as? NSURL
    }

    /// The file the panel is showing: an explicitly opened one wins over the tree selection,
    /// which is what spacebar has always previewed.
    private var previewURL: URL? { quickLookURL ?? state.selectedLocalURL }
}

/// The one live inspector. It is mounted in the focused card's panel (see `TerminalPane`); a card
/// that loses focus keeps a picture of it (`TermioStore.panelSnapshots`).
@MainActor
final class InspectorPanelHost {
    static let shared = InspectorPanelHost()

    var controller: FileBrowserHostingController?

    /// Opens `url` in the shared Quick Look panel — the preview a cmd-clicked video, audio file,
    /// or office document gets, since the in-app preview only renders images and PDFs.
    func quickLook(_ url: URL) {
        controller?.presentQuickLook(url, toggle: false)
    }

    /// Whether a point (window coordinates) is on the live panel while it is open. The terminal's
    /// own pointer handlers resolve their pane by geometry, and a panel laid over a narrow card's
    /// terminal sits inside that geometry; they ask this first, so the panel gets its own right-
    /// click menu, presses and drops instead of the terminal underneath.
    func contains(_ point: NSPoint, in window: NSWindow, store: TermioStore) -> Bool {
        guard store.inspectorVisible, let view = controller?.view, view.window === window else { return false }
        return view.convert(view.bounds, to: nil).contains(point)
    }

    /// A still of the panel as it is on screen now, or nil when it is not on screen. Web and
    /// Metal-backed content (a Markdown preview, a PDF) may come out blank — the picture is
    /// a reminder of where the card was, and focusing the card brings the real one back.
    func snapshot() -> NSImage? {
        guard let view = controller?.view, view.window != nil,
              view.bounds.width > 1, view.bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

/// Mounts the live inspector inside a card. Only ever one on screen: the inspector is a single
/// view controller, moved to whichever card has focus.
///
/// While no card shows it, it stays mounted — so the file tree keeps its expanded folders and
/// scroll — but *hidden*, not merely transparent: a transparent view still takes Finder drops
/// over the terminal it sits on, and an editor inside it keeps the keyboard and keeps saving
/// what is typed. A hidden view takes neither, and hiding it hands its first responder on.
struct InspectorPanelView: NSViewControllerRepresentable {
    let isShown: Bool

    func makeNSViewController(context: Context) -> NSViewController {
        if let controller = InspectorPanelHost.shared.controller { return controller }
        let empty = NSViewController()
        empty.view = NSView()
        return empty
    }

    func updateNSViewController(_ controller: NSViewController, context: Context) {
        let view = controller.view
        guard view.isHidden == isShown else { return }
        if !isShown, let window = view.window,
           let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) {
            window.makeFirstResponder(nil)
        }
        view.isHidden = !isShown
    }
}
