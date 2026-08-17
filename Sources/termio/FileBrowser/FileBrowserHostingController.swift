import AppKit
import Quartz
import SwiftUI

/// Hosts `FileBrowserView` in the trailing inspector and drives the shared Quick
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

    init(store: TermioStore, settings: AppSettings) {
        let state = FileBrowserState()
        self.state = state
        super.init(rootView: AnyView(
            // The inspector shows its list (tree / search / changes / issues) with any open detail
            // — editor, diff, PR/issue, trace — layered on top of it (see `InspectorRoot`), so a
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
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        state.selection == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        state.selection as? NSURL
    }
}
