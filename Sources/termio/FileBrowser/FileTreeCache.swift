import Foundation

/// Realized file trees, kept alive per checkout so returning to one is a handoff
/// rather than a rebuild.
///
/// A `DeviceFileTreeModel` holds the realized nodes, and node identity is the
/// path — which is what lets the outline keep its expansion across a refresh *of
/// the same root*. Change the root — switch workspace, select a session in
/// another project — and the view built a whole new tree instead: every folder
/// the user had opened closed itself, and the outline re-diffed from nothing.
/// Coming back paid it again, plus a round trip per open directory.
///
/// This is the same bargain `TermioStore`'s surface cache already strikes for
/// terminals: the model outlives the view, so switching away and back costs a
/// dictionary read. The view keeps owning *presentation*; only the realized tree
/// lives here.
///
/// A parked model holds no connection: the pane's `stopWarming` releases the
/// channel pin and the `fs:` subscription on the way out, and the next
/// `startWarming` re-arms them. What it costs while parked is memory — a node
/// per listed entry — which is why the cache is capped. The least recently used
/// checkout is dropped once the cap is passed, which costs that tree one rebuild
/// the next time it is opened: the behaviour every tree had before this existed.
@MainActor
final class FileTreeCache {
    /// How many checkouts to keep. A user moves between a handful in a sitting;
    /// past that the tail is cold and worth its rebuild.
    private static let capacity = 8

    private var models: [String: DeviceFileTreeModel] = [:]
    /// Least recently used first, so eviction reads off the front.
    private var order: [String] = []

    /// The tree for this checkout — the one already realized when there is one,
    /// a fresh model otherwise. Touching it marks the checkout as recently used,
    /// so the tree you keep returning to is the last to be evicted.
    func model(for checkout: Checkout, root: String) -> DeviceFileTreeModel {
        let key = Self.key(checkout, root: root)
        if let existing = models[key] {
            touch(key)
            return existing
        }
        let model = DeviceFileTreeModel(checkout: checkout, root: root)
        models[key] = model
        touch(key)
        while order.count > Self.capacity, let oldest = order.first {
            order.removeFirst()
            models[oldest] = nil
        }
        return model
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// The tree already realized for this checkout, or nil. For a caller that
    /// needs to stand one down rather than start it: building a model in order
    /// to stop it would evict a live one for nothing.
    func existing(for checkout: Checkout, root: String) -> DeviceFileTreeModel? {
        models[Self.key(checkout, root: root)]
    }

    /// Keyed by machine and root together: two boxes with a checkout at the same
    /// path are two trees, and the same box reached by two aliases is one.
    private static func key(_ checkout: Checkout, root: String) -> String {
        checkout.deviceIdentity + "\u{1f}" + root
    }
}
