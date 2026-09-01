import AppKit
import Combine
import Foundation

/// The current selection in the file tree, shared between the SwiftUI view (which
/// writes it) and the hosting controller (which reads it to feed Quick Look). Held
/// as its own object so the controller can answer `QLPreviewPanel`'s data-source
/// callbacks without reaching into SwiftUI's view state.
///
/// An `NSObject` so it can also be the outline view's action target — see `rowClicked`.
@MainActor
final class FileBrowserState: NSObject, ObservableObject {
    /// The selected row, as the path on whichever device the checkout lives on.
    /// A path rather than a URL because the tree is the device's: only a
    /// checkout on this Mac has a `URL` that addresses anything.
    @Published var selection: String?
    /// The selection as a file on *this* Mac, or nil for a checkout on another
    /// device. Quick Look previews a local file or nothing.
    @Published var selectedLocalURL: URL?
    /// The `NSOutlineView` backing the tree, captured by `FileTreeList` so
    /// `FileBrowserView` can expand a folder on the click that selected it. Not
    /// `@Published` — it's an AppKit escape hatch, not view state.
    weak var outlineView: NSOutlineView?

    /// Every primary click on a row, including one landing on the row already selected.
    /// That click publishes nothing through the `selection` binding — nothing changed —
    /// yet it is the one a tree must honour: VS Code and Zed leave a row selected after
    /// its editor closes and re-open the file when you click it again.
    ///
    /// The outline view's own action is the only way to see it; a click recognizer on the
    /// row never gets the event, because `NSOutlineView` runs a tracking loop in
    /// `mouseDown`. That is also why selection has been serving as the tree's click handler.
    let rowClicked = PassthroughSubject<Void, Never>()

    /// Points `outline`'s action at this object, re-asserted on every row update (see
    /// `FileBrowserView`'s `captureOutline`) so a rebuilt list is wired the turn it appears.
    func observeClicks(on outline: NSOutlineView) {
        guard outline.target !== self else { return }
        outline.target = self
        outline.action = #selector(outlineViewClicked)
    }

    @objc private func outlineViewClicked() {
        rowClicked.send()
    }
}
