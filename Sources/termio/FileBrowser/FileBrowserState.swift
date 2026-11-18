import Foundation

/// The current selection in the file tree, shared between the SwiftUI view (which
/// writes it) and the hosting controller (which reads it to feed Quick Look). Held
/// as its own object so the controller can answer `QLPreviewPanel`'s data-source
/// callbacks without reaching into SwiftUI's view state.
@MainActor
final class FileBrowserState: ObservableObject {
    /// The selected row, as the path on whichever device the checkout lives on.
    /// A path rather than a URL because the tree is the device's: only a
    /// checkout on this Mac has a `URL` that addresses anything.
    @Published var selection: String?
    /// The selection as a file on *this* Mac, or nil for a checkout on another
    /// device. Quick Look previews a local file or nothing.
    @Published var selectedLocalURL: URL?
    /// The page drawing the tree, registered by `FileTreeWebView` so
    /// `FileBrowserView` can collapse it and reveal a path in it. Not
    /// `@Published`: it is a handle, not view state.
    weak var tree: FileTreeBridge?
}
