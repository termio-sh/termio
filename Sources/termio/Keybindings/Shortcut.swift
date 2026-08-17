import AppKit

/// One keyboard shortcut — a set of modifiers plus a single key — in the one
/// representation the whole app shares. It is the bridge between three worlds
/// that otherwise each spell shortcuts their own way:
///
///  - **AppKit menus** want a `keyEquivalent` string + a `keyEquivalentModifierMask`.
///  - **The command palette** wants a display string like `⌥⌘←`.
///  - **On-disk config** (`~/.termio/keybindings.json`) wants a stable, hand-editable
///    token like `opt+cmd+left`.
///
/// Keeping all three in one value type means a shortcut is defined once (in the
/// command catalog) and every surface renders it consistently. Parsing is
/// lenient on input aliases (`cmd`/`command`/`super`) but `encoded` always emits
/// one canonical form so the JSON stays diff-stable.
struct Shortcut: Equatable {
    /// The non-modifier key. Arrows are special-cased because AppKit encodes them
    /// as private-use function-key scalars, not characters.
    enum Key: Equatable {
        case char(String)   // a single lowercase character or punctuation ("d", ",", "]", "0")
        case left, right, up, down
        case `return`
    }

    var modifiers: NSEvent.ModifierFlags
    var key: Key

    init(modifiers: NSEvent.ModifierFlags, key: Key) {
        // Only the four device-independent modifiers we bind against; strip caps
        // lock / function / numeric-pad noise so equality and conflict checks
        // compare like with like.
        self.modifiers = modifiers.intersection([.command, .option, .control, .shift])
        self.key = key
    }
}

// MARK: - Encoding (config token: "opt+cmd+left")

extension Shortcut {
    /// Canonical order matches how macOS itself renders modifiers: ⌃⌥⇧⌘.
    private static let modifierOrder: [(NSEvent.ModifierFlags, token: String, glyph: String)] = [
        (.control, "ctrl", "⌃"),
        (.option, "opt", "⌥"),
        (.shift, "shift", "⇧"),
        (.command, "cmd", "⌘"),
    ]

    /// The stable token written to `keybindings.json`, e.g. `opt+cmd+left`.
    var encoded: String {
        var parts = Self.modifierOrder.filter { modifiers.contains($0.0) }.map(\.token)
        parts.append(key.token)
        return parts.joined(separator: "+")
    }

    /// Parse a config token. Returns nil on anything unrecognised so a corrupt
    /// file degrades to the default binding rather than crashing.
    init?(encoded: String) {
        var mods: NSEvent.ModifierFlags = []
        var parsedKey: Key?
        for raw in encoded.lowercased().split(separator: "+") {
            let token = raw.trimmingCharacters(in: .whitespaces)
            switch token {
            case "cmd", "command", "super", "meta": mods.insert(.command)
            case "opt", "option", "alt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            case "shift": mods.insert(.shift)
            default:
                guard let k = Key(token: token) else { return nil }
                parsedKey = k
            }
        }
        guard let parsedKey else { return nil }
        self.init(modifiers: mods, key: parsedKey)
    }
}

// MARK: - Ghostty trigger ("super+alt+arrow_left")

extension Shortcut {
    /// The same shortcut in Ghostty's `keybind` trigger syntax, so a key the host
    /// claims can be unbound inside the surface (see `applyAppearance`). Ghostty
    /// spells ⌘ `super` and ⌥ `alt`, and names the arrow and return keys rather
    /// than encoding them as characters.
    var ghosttyTrigger: String {
        // Ghostty's own `+list-keybinds` output orders modifiers super, ctrl,
        // alt, shift; its parser accepts any order, but matching the upstream
        // spelling keeps a config dump readable next to ghostty's.
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("super") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        parts.append(key.ghosttyToken)
        return parts.joined(separator: "+")
    }
}

// MARK: - Display (menu glyphs: "⌥⌘←")

extension Shortcut {
    /// The glyph string shown in menus and the palette.
    var display: String {
        let mods = Self.modifierOrder.filter { modifiers.contains($0.0) }.map(\.glyph).joined()
        return mods + key.displayGlyph
    }
}

// MARK: - AppKit menu bridging

extension Shortcut {
    /// The `NSMenuItem.keyEquivalent` character (lowercase; arrows become their
    /// private-use function-key scalar).
    var keyEquivalent: String { key.keyEquivalent }

    /// The mask for `NSMenuItem.keyEquivalentModifierMask`.
    var keyEquivalentModifierMask: NSEvent.ModifierFlags { modifiers }
}

// MARK: - Live capture from a key event (the recorder)

extension Shortcut {
    /// Build a shortcut from a `keyDown` event as the recorder sees it. Returns
    /// nil for modifier-only presses (nothing to bind yet).
    init?(event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Arrows arrive as key codes, not characters.
        switch event.keyCode {
        case 123: self.init(modifiers: mods, key: .left); return
        case 124: self.init(modifiers: mods, key: .right); return
        case 125: self.init(modifiers: mods, key: .down); return
        case 126: self.init(modifiers: mods, key: .up); return
        case 36, 76: self.init(modifiers: mods, key: .return); return  // return / keypad enter
        default: break
        }
        guard let chars = event.charactersIgnoringModifiers, let first = chars.first else { return nil }
        // Ignore bare modifier / function keys that produce no printable base key.
        guard first.isLetter || first.isNumber || first.isPunctuation || first.isSymbol else { return nil }
        self.init(modifiers: mods, key: .char(String(first).lowercased()))
    }
}

// MARK: - Key token/glyph tables

private extension Shortcut.Key {
    init?(token: String) {
        switch token {
        case "left": self = .left
        case "right": self = .right
        case "up": self = .up
        case "down": self = .down
        case "return", "enter": self = .return
        default:
            guard token.count == 1 else { return nil }
            self = .char(token)
        }
    }

    var token: String {
        switch self {
        case .char(let c): return c
        case .left: return "left"
        case .right: return "right"
        case .up: return "up"
        case .down: return "down"
        case .return: return "return"
        }
    }

    /// Ghostty's own key names. Single characters (including punctuation like
    /// `,` `[` `=`) are spelled literally; everything else is a named key.
    var ghosttyToken: String {
        switch self {
        case .char(let c): return c
        case .left: return "arrow_left"
        case .right: return "arrow_right"
        case .up: return "arrow_up"
        case .down: return "arrow_down"
        case .return: return "enter"
        }
    }

    var displayGlyph: String {
        switch self {
        case .char(let c): return c.uppercased()
        case .left: return "←"
        case .right: return "→"
        case .up: return "↑"
        case .down: return "↓"
        case .return: return "↩"
        }
    }

    var keyEquivalent: String {
        switch self {
        case .char(let c): return c
        case .left: return String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!)
        case .right: return String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)
        case .up: return String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)
        case .down: return String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
        case .return: return "\r"
        }
    }
}
