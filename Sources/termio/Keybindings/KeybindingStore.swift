import AppKit
import Combine

extension Notification.Name {
    /// Posted whenever an effective binding changes so `AppDelegate` can rebuild
    /// the main menu (menu items cache their key equivalents at build time).
    static let termioKeybindingsChanged = Notification.Name("termioKeybindingsChanged")
}

/// The effective keybinding table: catalog defaults with a thin layer of user
/// overrides on top. Only the *diffs* are persisted, to
/// `~/.termio[-dev]/keybindings.json` (`{ "pane.split-down": "cmd+shift+k" }`),
/// mirroring how Xcode stores a user set as deltas over the built-in defaults.
///
/// A singleton so the menu builder, the palette, and the Settings pane all read
/// one source of truth; an `ObservableObject` so the Settings UI re-renders on
/// edit.
@MainActor
final class KeybindingStore: ObservableObject {
    static let shared = KeybindingStore()

    /// id → user override. Absent id = use the catalog default.
    @Published private(set) var overrides: [KeyCommandID: Shortcut] = [:]

    private let fileURL = AppChannel.homeConfigDirectory
        .appendingPathComponent("keybindings.json", isDirectory: false)

    private init() {
        load()
    }

    // MARK: - Lookup

    /// The effective shortcut for a command: override if present, else the
    /// shipped default (which may itself be nil = unbound).
    func shortcut(for id: KeyCommandID) -> Shortcut? {
        if let override = overrides[id] { return override }
        return KeyCommandCatalog.info(id).defaultShortcut
    }

    /// Convenience for the palette's display strings (`⌥⌘←`).
    func display(for id: KeyCommandID) -> String? { shortcut(for: id)?.display }

    /// True when the command currently differs from its shipped default.
    func isCustomized(_ id: KeyCommandID) -> Bool { overrides[id] != nil }

    // MARK: - Editing

    /// Bind `id` to `shortcut`, or clear the override (revert to default) with
    /// `nil`. Persists and broadcasts so menu + palette pick it up.
    func setShortcut(_ shortcut: Shortcut?, for id: KeyCommandID) {
        if let shortcut, shortcut != KeyCommandCatalog.info(id).defaultShortcut {
            overrides[id] = shortcut
        } else {
            // Matching the default is stored as "no override" so the JSON stays
            // minimal and a later default change still reaches the user.
            overrides.removeValue(forKey: id)
        }
        save()
        NotificationCenter.default.post(name: .termioKeybindingsChanged, object: nil)
    }

    /// Revert a single command to its shipped default.
    func reset(_ id: KeyCommandID) { setShortcut(nil, for: id) }

    /// Revert every command to its shipped default.
    func resetAll() {
        guard !overrides.isEmpty else { return }
        overrides.removeAll()
        save()
        NotificationCenter.default.post(name: .termioKeybindingsChanged, object: nil)
    }

    // MARK: - Validation

    /// Why a candidate shortcut can't be assigned, or nil if it's fine. Two
    /// rules: it must not collide with another command (or a reserved system
    /// shortcut), and it must include ⌘ so it can never shadow a key an agent
    /// TUI or the shell wants (those live in Ctrl / plain-key space).
    func rejection(for shortcut: Shortcut, assigning id: KeyCommandID) -> String? {
        guard shortcut.modifiers.contains(.command) else {
            return "Add ⌘ — shortcuts without Command would collide with the terminal."
        }
        if let other = conflict(for: shortcut, excluding: id) {
            return "Already used by \(other)."
        }
        return nil
    }

    /// The human label of whatever already owns `shortcut`, or nil if it's free.
    /// Checks both the rebindable catalog and the fixed system shortcuts.
    func conflict(for shortcut: Shortcut, excluding id: KeyCommandID?) -> String? {
        for info in KeyCommandCatalog.all where info.id != id {
            if self.shortcut(for: info.id) == shortcut { return info.title }
        }
        for reserved in Self.reserved where reserved.shortcut == shortcut {
            return reserved.label
        }
        return nil
    }

    /// Fixed shortcuts termio does not expose for rebinding but must still guard
    /// against, so the recorder can warn instead of silently double-binding.
    private static let reserved: [(label: String, shortcut: Shortcut)] = [
        ("Settings…", .init(modifiers: [.command], key: .char(","))),
        ("Quit Termio", .init(modifiers: [.command], key: .char("q"))),
        ("Copy", .init(modifiers: [.command], key: .char("c"))),
        ("Paste", .init(modifiers: [.command], key: .char("v"))),
        ("Select All", .init(modifiers: [.command], key: .char("a"))),
    ]

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }  // absent = all defaults
        guard let raw = try? JSONDecoder().decode([String: String].self, from: data) else {
            Log.app.error("keybindings: could not decode \(self.fileURL.path, privacy: .public); using defaults")
            return
        }
        for (key, token) in raw {
            guard let id = KeyCommandID(rawValue: key), let sc = Shortcut(encoded: token) else { continue }
            overrides[id] = sc
        }
    }

    private func save() {
        let raw = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value.encoded) })
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.sortedPretty.encode(raw)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("keybindings: failed to write \(self.fileURL.path): \(error.localizedDescription)")
        }
    }
}

private extension JSONEncoder {
    /// Stable key order + pretty printing so the file reads cleanly and diffs
    /// don't churn when overrides are added or removed.
    static var sortedPretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
