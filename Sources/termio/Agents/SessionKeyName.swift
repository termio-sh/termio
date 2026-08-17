import Foundation

/// A key named on `termio sessions send --key <name>`, resolved into the fields of
/// one libghostty key event.
///
/// A key's bytes are not a property of the key — they are a property of the key
/// *and the mode the program negotiated*. Up is `ESC [ A` in normal cursor mode and
/// `ESC O A` in application mode; ctrl-c is `0x03` in legacy mode and `CSI 99;5u`
/// under the kitty keyboard protocol every coding agent turns on. A caller who
/// hand-writes `$'\e[A'` into `send` is guessing at one of those, and is right only
/// by luck. So `--key` never produces bytes: it produces a key *event*, and
/// Ghostty's own encoder decides the bytes from the live mode.
///
/// This is the exact mirror of the rule for text. Text must go into the PTY raw
/// (`writeRaw`), untouched by the input encoder, or the ESC of a hand-written
/// `ESC [ 200 ~` gets re-encoded as an Escape *keypress*. Keys must go *through*
/// that encoder for the same reason. Two payloads, two paths, one principle: the
/// encoder owns keys and nothing else.
///
/// The vocabulary is kitty's and tmux's, not a third dialect — both spellings of
/// every modifier are accepted (`c-c` and `ctrl-c`, `s-tab` and `shift-tab`,
/// `m-b` and `alt-b`) so a caller never has to guess which one this CLI speaks.
struct SessionKeyPress: Equatable {
    struct Modifiers: OptionSet, Equatable {
        let rawValue: UInt8
        init(rawValue: UInt8) { self.rawValue = rawValue }

        static let shift = Modifiers(rawValue: 1 << 0)
        static let control = Modifiers(rawValue: 1 << 1)
        static let option = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)

        /// Modifiers that make the keypress a chord rather than typed text. With any
        /// of these the event carries no `text` — Ghostty's encoder derives the
        /// chord's bytes from the physical key and the mode (see `SessionKeyPress`).
        static let chording: Modifiers = [.control, .option, .command]
    }

    /// The native macOS virtual keycode (`kVK_…`), the same number an `NSEvent`
    /// would carry. Ghostty translates it into its own key enum, so it — not a
    /// character — is what identifies the physical key.
    let keycode: UInt32
    let modifiers: Modifiers
    /// The codepoint the key produces with no modifiers applied. Feeds the kitty
    /// protocol's key reporting; zero for keys with no printable form.
    let unshiftedCodepoint: UInt32
    /// The text a real keystroke would have inserted, for an unmodified printable
    /// key. Nil for every special key and every chord, where Ghostty's encoder
    /// produces the bytes itself.
    let text: String?

    /// Return — the submit `send` appends to a prompt, and the key behind `--key enter`.
    static let `return` = SessionKeyPress(
        keycode: 0x24, modifiers: [], unshiftedCodepoint: 0, text: nil)

    /// Whether pressing this actually puts bytes in the PTY — nil when it does,
    /// otherwise why not, and what to press instead.
    ///
    /// Only Ctrl and Shift reach the program. Option is a text-composition modifier
    /// on macOS (option-b types `∫`; it is not Meta+b), and Ghostty adds a real
    /// Alt's ESC prefix only when `macos-option-as-alt` is on, which it is not by
    /// default — so an Option chord composes no text, encodes no sequence, and
    /// evaporates. Command drives the app, not the terminal. Both are refused
    /// rather than pressed, because a `--key` that reports success and delivers
    /// nothing is the exact failure this option exists to remove. Their names still
    /// *parse*, so the caller gets this explanation instead of "unknown key".
    var undeliverableReason: String? {
        if modifiers.contains(.command) {
            return "Command is an app shortcut, not a key the program in the "
                + "terminal ever sees — ⌘C copies in Termio and sends no bytes."
        }
        if modifiers.contains(.option) {
            let key = unshiftedCodepoint == 0
                ? "<key>"
                : String(UnicodeScalar(unshiftedCodepoint) ?? " ")
            return "macOS types a character with Option (option-b is ∫), so Ghostty "
                + "sends nothing for an Option chord unless macos-option-as-alt is "
                + "on. A meta chord is ESC then the key: --key escape --key \(key)"
        }
        return nil
    }

    /// Resolves a name to a keypress, or nil if the name is not in the vocabulary.
    /// Never guesses: an unrecognized name is an error the caller must see, never
    /// text to send instead. Case-insensitive, and `-` and `+` are interchangeable
    /// separators (tmux writes `C-c`, kitty writes `ctrl+c`).
    static func parse(_ name: String) -> SessionKeyPress? {
        let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }

        // Peel modifier prefixes off the front. A separator at the very start, or a
        // head that names no modifier, or an empty tail all end the peel — so `-`,
        // `ctrl--`, and `c-` mean the minus key, ctrl-minus, and (loudly) nothing.
        var modifiers: Modifiers = []
        var rest = Substring(trimmed)
        while let separator = rest.firstIndex(where: { $0 == "-" || $0 == "+" }),
              separator != rest.startIndex
        {
            guard let modifier = modifier(named: String(rest[rest.startIndex ..< separator]))
            else { break }
            let tail = rest[rest.index(after: separator)...]
            guard !tail.isEmpty else { break }
            modifiers.insert(modifier)
            rest = tail
        }

        // `space` is the one printable key with a spelled-out name — nobody can type
        // its character into an argument and see it survive the shell.
        let key = rest == "space" ? " " : String(rest)
        if let keycode = specialKeycodes[key] {
            return SessionKeyPress(
                keycode: keycode, modifiers: modifiers, unshiftedCodepoint: 0, text: nil)
        }
        guard let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1,
              let keycode = printableKeycodes[Character(scalar)]
        else { return nil }
        // A chord carries no text; an unmodified (or merely shifted) printable key
        // carries what a real keystroke would have typed, which is what makes the
        // character appear rather than vanish into an unhandled binding.
        var typed: String?
        if modifiers.isDisjoint(with: .chording) {
            typed = modifiers.contains(.shift) ? key.uppercased() : key
        }
        return SessionKeyPress(
            keycode: keycode, modifiers: modifiers,
            unshiftedCodepoint: scalar.value, text: typed)
    }

    private static func modifier(named head: String) -> Modifiers? {
        switch head {
        case "c", "ctrl", "control": return .control
        case "s", "shift": return .shift
        case "m", "alt", "meta", "opt", "option": return .option
        case "d", "cmd", "command", "super", "win": return .command
        default: return nil
        }
    }

    /// The named keys, for the error a bad name earns. Grouped the way a caller
    /// scans for one, not alphabetically.
    static let vocabulary =
        "enter, escape, tab, space, backspace, delete, insert, up, down, left, right, "
        + "home, end, pageup, pagedown, f1–f12, a–z, 0–9, and punctuation — each "
        + "optionally prefixed with ctrl-/c- or shift-/s- (e.g. ctrl-c, c-c, "
        + "shift-tab). For a meta chord press ESC first: --key escape --key b"

    /// Named keys with no printable form, as macOS virtual keycodes. Aliases cover
    /// both dialects: kitty's `escape`/`backspace`/`pageup` and tmux's
    /// `bspace`/`ppage`/`npage`/`ic`/`dc`.
    private static let specialKeycodes: [String: UInt32] = [
        "enter": 0x24, "return": 0x24, "cr": 0x24,
        "escape": 0x35, "esc": 0x35,
        "tab": 0x30,
        "backspace": 0x33, "bspace": 0x33, "bs": 0x33,
        "delete": 0x75, "del": 0x75, "dc": 0x75,
        "insert": 0x72, "ic": 0x72,
        "up": 0x7E, "down": 0x7D, "left": 0x7B, "right": 0x7C,
        "home": 0x73, "end": 0x77,
        "pageup": 0x74, "pgup": 0x74, "ppage": 0x74,
        "pagedown": 0x79, "pgdn": 0x79, "npage": 0x79,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    ]

    /// Printable keys of the ANSI US layout, as macOS virtual keycodes. Space rides
    /// here rather than with the special keys because it *is* printable: `--key space`
    /// types a space, `--key ctrl-space` is the NUL chord.
    private static let printableKeycodes: [Character: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06,
        "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E,
        "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23,
        "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19,
        "7": 0x1A, "8": 0x1C, "0": 0x1D,
        "=": 0x18, "-": 0x1B, "]": 0x1E, "[": 0x21, "'": 0x27, ";": 0x29, "\\": 0x2A,
        ",": 0x2B, "/": 0x2C, ".": 0x2F, "`": 0x32,
        " ": 0x31,
    ]
}
