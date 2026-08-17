import XCTest
@testable import termio

/// The keyboard is split in two layers, and both halves have a failure mode.
///
/// Keys the *host* claims must be unbound inside the surface: ghostty consumes a
/// bound key before the menu bar sees it, and the embedding drops the actions it
/// cannot perform, so a collision kills the menu command outright (issue #203 —
/// ⌘D and ⌘⇧D did nothing). Keys the *terminal* owns must never be unbound: they
/// are ghostty's own text and buffer verbs, and taking them costs line motion
/// and copy/paste inside the shell.
///
/// Both sides are checked against ghostty's shipped defaults, so a new command
/// landing on a terminal key — or a libghostty bump that binds a key we claim —
/// fails here instead of in a user's hands.
@MainActor
final class KeybindingSurfaceTests: XCTestCase {
    private func shortcut(_ modifiers: NSEvent.ModifierFlags, _ key: Shortcut.Key) -> Shortcut {
        Shortcut(modifiers: modifiers, key: key)
    }

    // MARK: - Trigger spelling

    func testGhosttyTriggerSpelling() {
        XCTAssertEqual(shortcut([.command], .char("d")).ghosttyTrigger, "super+d")
        XCTAssertEqual(shortcut([.command, .shift], .char("d")).ghosttyTrigger, "super+shift+d")
        XCTAssertEqual(shortcut([.command, .option], .left).ghosttyTrigger, "super+alt+arrow_left")
        XCTAssertEqual(shortcut([.command, .shift], .return).ghosttyTrigger, "super+shift+enter")
        XCTAssertEqual(shortcut([.command, .control], .char("f")).ghosttyTrigger, "super+ctrl+f")
        XCTAssertEqual(shortcut([.command], .char(",")).ghosttyTrigger, "super+,")
        XCTAssertEqual(shortcut([.command, .shift], .char("]")).ghosttyTrigger, "super+shift+]")
    }

    // MARK: - Host layer

    /// Every shipped command's key, plus the app-layer keys with no catalog entry,
    /// has to reach the unbind set — that set is what stops the surface from
    /// eating the shortcut.
    func testEveryHostShortcutIsUnbound() {
        let triggers = Set(KeybindingStore.shared.surfaceUnbindTriggers)
        for info in KeyCommandCatalog.all {
            guard let shortcut = info.defaultShortcut else { continue }
            XCTAssertTrue(
                triggers.contains(shortcut.ghosttyTrigger),
                "\(info.title) (\(shortcut.display)) can be swallowed by the surface"
            )
        }
        for reserved in KeybindingStore.hostReserved {
            XCTAssertTrue(
                triggers.contains(reserved.shortcut.ghosttyTrigger),
                "\(reserved.label) (\(reserved.shortcut.display)) can be swallowed by the surface"
            )
        }
    }

    /// The collisions that were live when #203 was filed, pinned so they cannot
    /// come back one at a time.
    func testKnownGhosttyCollisionsAreUnbound() {
        let triggers = Set(KeybindingStore.shared.surfaceUnbindTriggers)
        for trigger in [
            "super+d",              // new_split:right      → Split Right
            "super+shift+d",        // new_split:down       → Split Down
            "super+alt+arrow_left", // goto_split:left      → Focus Pane Left
            "super+n",              // new_window           → New Chat
            "super+w",              // close_surface        → Ungroup
            "super+shift+w",        // close_window         → Close Window
            "super+t",              // new_tab              → New Terminal
            "super+,",              // open_config          → Settings…
            "super+q",              // quit                 → Quit Termio
            "super+ctrl+f",         // toggle_fullscreen    → Enter Full Screen
        ] {
            XCTAssertTrue(triggers.contains(trigger), "\(trigger) is still handled by the surface")
        }
    }

    // MARK: - Terminal layer

    /// Ghostty defaults that act on the terminal's own text or buffer. Taken from
    /// `ghostty +list-keybinds --default` (Ghostty 1.3.1); the app layer must
    /// never claim one of these, or the shell loses line motion, selection, or
    /// copy/paste — the mirror-image bug of #203.
    private static let terminalLayerTriggers: Set<String> = [
        "super+c", "super+v", "super+shift+v", "super+a",   // copy / paste / select all
        "super+k",                                          // clear_screen
        "super+home", "super+end", "super+page_up", "super+page_down", "super+j",
        "super+arrow_up", "super+arrow_down",               // jump_to_prompt
        "super+shift+arrow_up", "super+shift+arrow_down",   // jump_to_prompt
        "super+arrow_left", "super+arrow_right",            // text:\x01 / \x05 (line start/end)
        "super+backspace",                                  // text:\x15 (kill line)
        "alt+arrow_left", "alt+arrow_right",                // esc:b / esc:f (word motion)
        "shift+arrow_left", "shift+arrow_right", "shift+arrow_up", "shift+arrow_down",
        "shift+page_up", "shift+page_down", "shift+home", "shift+end",
        "super+f", "super+e", "super+shift+f", "super+g", "super+shift+g",  // search
    ]

    func testTerminalLayerIsLeftAlone() {
        let claimed = Set(KeybindingStore.shared.surfaceUnbindTriggers)
        let stolen = claimed.intersection(Self.terminalLayerTriggers).sorted()
        XCTAssertTrue(
            stolen.isEmpty,
            "the app layer is unbinding terminal keys: \(stolen.joined(separator: ", "))"
        )
    }
}
