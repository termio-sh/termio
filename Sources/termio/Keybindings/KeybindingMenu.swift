import AppKit

/// Bridges the command catalog to AppKit menus so a menu item's key equivalent
/// is never hardcoded — it is resolved from `KeybindingStore` by command id.
/// `buildMainMenu` runs again on `.termioKeybindingsChanged`, so re-reading the
/// store here is all that's needed to reflect a user's rebinding.
@MainActor
extension NSMenu {
    /// Add an item whose key equivalent comes from the resolved binding for `id`.
    @discardableResult
    func addItem(withTitle title: String, action: Selector, command id: KeyCommandID) -> NSMenuItem {
        let item = addItem(withTitle: title, action: action, keyEquivalent: "")
        item.applyShortcut(for: id)
        return item
    }
}

@MainActor
extension NSMenuItem {
    /// Apply the currently-effective shortcut for `id` (or clear it if unbound).
    func applyShortcut(for id: KeyCommandID) {
        if let shortcut = KeybindingStore.shared.shortcut(for: id) {
            keyEquivalent = shortcut.keyEquivalent
            keyEquivalentModifierMask = shortcut.keyEquivalentModifierMask
        } else {
            keyEquivalent = ""
            keyEquivalentModifierMask = []
        }
    }
}
