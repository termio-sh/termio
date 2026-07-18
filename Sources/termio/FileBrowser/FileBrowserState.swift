import AppKit
import Combine
import Foundation

/// The current selection in the file tree, shared between the SwiftUI view (which
/// writes it) and the hosting controller (which reads it to feed Quick Look). Held
/// as its own object so the controller can answer `QLPreviewPanel`'s data-source
/// callbacks without reaching into SwiftUI's view state.
@MainActor
final class FileBrowserState: NSObject, ObservableObject {
    @Published var selection: URL?
    /// URLs of folders currently expanded in the outline view — drives the
    /// closed/open folder icon toggle. Updated by AppKit notifications and read by
    /// each `FileRow`.
    @Published var expandedFolderURLs: Set<URL> = []
    /// The `NSOutlineView` backing the tree, captured by `FileTreeList` so
    /// `FileBrowserView` can expand a folder on the click that selected it. Not
    /// `@Published` — it's an AppKit escape hatch, not view state.
    weak var outlineView: NSOutlineView?

    /// SwiftUI's `List(children:)` gives the outline view private wrapper objects,
    /// not the `FileNode` held by a row. Register each visible row's wrapper identity
    /// with its URL so expand/collapse notifications can be translated reliably.
    private var urlsByOutlineItem: [ObjectIdentifier: URL] = [:]
    private weak var observedOutline: NSOutlineView?

    /// Called from a representable mounted inside every row, where both the enclosing
    /// outline view and that row's private outline item are reachable.
    func register(outline: NSOutlineView?, item: NSObject?, url: URL) {
        guard let outline else { return }
        outlineView = outline
        if observedOutline !== outline {
            detachExpansionObserver()
            expandedFolderURLs.removeAll()
            observedOutline = outline
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(itemDidExpand(_:)),
                name: NSOutlineView.itemDidExpandNotification,
                object: outline
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(itemDidCollapse(_:)),
                name: NSOutlineView.itemDidCollapseNotification,
                object: outline
            )
        }
        if let item { urlsByOutlineItem[ObjectIdentifier(item)] = url }
    }

    private func detachExpansionObserver() {
        guard let observedOutline else { return }
        NotificationCenter.default.removeObserver(
            self, name: NSOutlineView.itemDidExpandNotification, object: observedOutline)
        NotificationCenter.default.removeObserver(
            self, name: NSOutlineView.itemDidCollapseNotification, object: observedOutline)
        self.observedOutline = nil
        urlsByOutlineItem.removeAll()
    }

    @objc private func itemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? NSObject,
              let url = urlsByOutlineItem[ObjectIdentifier(item)]
        else { return }
        expandedFolderURLs.insert(url)
    }

    @objc private func itemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? NSObject,
              let url = urlsByOutlineItem[ObjectIdentifier(item)]
        else { return }
        expandedFolderURLs.remove(url)
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
