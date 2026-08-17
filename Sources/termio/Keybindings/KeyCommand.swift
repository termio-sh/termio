import Foundation

/// Stable identifier for every rebindable app command. The raw string is the key
/// used both in `keybindings.json` and to look a shortcut up from the menu and
/// the palette, so these values are API — don't rename them once shipped.
enum KeyCommandID: String, CaseIterable, Identifiable {
    // File
    case newTerminal = "file.new-terminal"
    case newTerminalAtHome = "file.new-terminal-at-home"
    case newChat = "file.new-chat"
    case openProject = "file.open-project"
    // Navigation
    case openQuickly = "nav.open-quickly"
    case commandPalette = "nav.command-palette"
    // Session
    case nextSession = "session.next"
    case previousSession = "session.previous"
    // Branch
    case newWorktree = "branch.new-worktree"
    case newPullRequest = "branch.new-pull-request"
    // Panes
    case splitRight = "pane.split-right"
    case splitLeft = "pane.split-left"
    case splitDown = "pane.split-down"
    case splitUp = "pane.split-up"
    case splitZoom = "pane.zoom"
    // Raw value predates the Ungroup rename — kept so saved keybindings resolve.
    case ungroup = "pane.close"
    case focusPaneLeft = "pane.focus-left"
    case focusPaneRight = "pane.focus-right"
    case focusPaneUp = "pane.focus-up"
    case focusPaneDown = "pane.focus-down"
    // Font
    case increaseFontSize = "font.increase"
    case decreaseFontSize = "font.decrease"
    case resetFontSize = "font.reset"
    // Window
    case closeWindow = "window.close"
    // Interface
    case toggleProjectFiles = "ui.toggle-project-files"

    var id: String { rawValue }
}

/// One row in the command catalog: everything the menu, the palette, and the
/// Settings ▸ Keyboard list need to *describe* a command, independent of how it
/// is invoked (menus keep their `#selector`s; the palette keeps its closures).
/// Bindings live here; invocation stays at the call sites. That split is why the
/// catalog can be a plain value table.
struct KeyCommandInfo: Identifiable {
    let id: KeyCommandID
    /// Grouping header in the Settings list (e.g. "Panes").
    let category: String
    /// Human title, matching the menu item wording.
    let title: String
    /// The shipped shortcut, before any user override. `nil` = no default binding.
    let defaultShortcut: Shortcut?
}

/// The single source of truth for command metadata + default shortcuts. Both the
/// AppKit menu (`buildMainMenu`) and the command palette read their shortcuts
/// from here via `KeybindingStore`, so a binding is written in exactly one place.
enum KeyCommandCatalog {
    /// Order here is the display order in the Settings list.
    static let all: [KeyCommandInfo] = [
        // File
        .init(id: .newTerminal, category: localized("File"), title: localized("New Terminal"),
              defaultShortcut: .init(modifiers: [.command], key: .char("t"))),
        // Unbound, the way Split Left and Split Up are: a shell at `~` is the rare
        // direction, and the key it would take — ⌘⇧T — is "reopen closed tab" muscle
        // memory everywhere else on the Mac.
        .init(id: .newTerminalAtHome, category: localized("File"), title: localized("New Terminal at Home"),
              defaultShortcut: nil),
        .init(id: .newChat, category: localized("File"), title: localized("New Chat"),
              defaultShortcut: .init(modifiers: [.command], key: .char("n"))),
        .init(id: .openProject, category: localized("File"), title: localized("Open Project…"),
              defaultShortcut: .init(modifiers: [.command], key: .char("o"))),
        // Navigation
        .init(id: .openQuickly, category: localized("Navigation"), title: localized("Open Quickly…"),
              defaultShortcut: .init(modifiers: [.command, .shift], key: .char("o"))),
        .init(id: .commandPalette, category: localized("Navigation"), title: localized("Command Palette…"),
              defaultShortcut: .init(modifiers: [.command, .shift], key: .char("p"))),
        // Session — cycling follows the sidebar's visual order (see
        // `selectAdjacentSession`). ⌘⇧]/⌘⇧[ is the iTerm2/Chrome tab-cycling
        // convention; ghostty's own next/previous_tab on the same keys are
        // unbound in the surface config (see `applyAppearance`) so they reach
        // the menu.
        .init(id: .nextSession, category: localized("Session"), title: localized("Next Session"),
              defaultShortcut: .init(modifiers: [.command, .shift], key: .char("]"))),
        .init(id: .previousSession, category: localized("Session"), title: localized("Previous Session"),
              defaultShortcut: .init(modifiers: [.command, .shift], key: .char("["))),
        // Branch — GitHub Desktop's Branch-menu bindings verbatim: New Branch
        // is ⌘⇧N there, and termio's branch-creation verb is the worktree.
        .init(id: .newWorktree, category: localized("Branch"), title: localized("New Worktree…"),
              defaultShortcut: .init(modifiers: [.command, .shift], key: .char("n"))),
        .init(id: .newPullRequest, category: localized("Branch"), title: localized("New Pull Request"),
              defaultShortcut: .init(modifiers: [.command], key: .char("r"))),
        // Panes
        .init(id: .splitRight, category: localized("Panes"), title: localized("Split Right"),
              defaultShortcut: .init(modifiers: [.command], key: .char("d"))),
        // Left and Up ship unbound, the way ghostty ships them: the two directions
        // people reach for constantly earn the keys, the mirrored pair stays a
        // menu verb until a user decides otherwise in Settings ▸ Keyboard.
        .init(id: .splitLeft, category: localized("Panes"), title: localized("Split Left"), defaultShortcut: nil),
        .init(id: .splitDown, category: localized("Panes"), title: localized("Split Down"),
              defaultShortcut: .init(modifiers: [.command, .shift], key: .char("d"))),
        .init(id: .splitUp, category: localized("Panes"), title: localized("Split Up"), defaultShortcut: nil),
        .init(id: .splitZoom, category: localized("Panes"), title: localized("Zoom Split"),
              defaultShortcut: .init(modifiers: [.command, .shift], key: .return)),
        .init(id: .ungroup, category: localized("Panes"), title: localized("Ungroup"),
              defaultShortcut: .init(modifiers: [.command], key: .char("w"))),
        .init(id: .focusPaneLeft, category: localized("Panes"), title: localized("Focus Pane Left"),
              defaultShortcut: .init(modifiers: [.command, .option], key: .left)),
        .init(id: .focusPaneRight, category: localized("Panes"), title: localized("Focus Pane Right"),
              defaultShortcut: .init(modifiers: [.command, .option], key: .right)),
        .init(id: .focusPaneUp, category: localized("Panes"), title: localized("Focus Pane Up"),
              defaultShortcut: .init(modifiers: [.command, .option], key: .up)),
        .init(id: .focusPaneDown, category: localized("Panes"), title: localized("Focus Pane Down"),
              defaultShortcut: .init(modifiers: [.command, .option], key: .down)),
        // Font
        .init(id: .increaseFontSize, category: localized("Font"), title: localized("Increase Font Size"),
              defaultShortcut: .init(modifiers: [.command], key: .char("="))),
        .init(id: .decreaseFontSize, category: localized("Font"), title: localized("Decrease Font Size"),
              defaultShortcut: .init(modifiers: [.command], key: .char("-"))),
        .init(id: .resetFontSize, category: localized("Font"), title: localized("Reset Font Size"),
              defaultShortcut: .init(modifiers: [.command], key: .char("0"))),
        // Window
        .init(id: .closeWindow, category: localized("Window"), title: localized("Close Window"),
              defaultShortcut: .init(modifiers: [.command, .shift], key: .char("w"))),
        // Interface
        .init(id: .toggleProjectFiles, category: localized("Interface"), title: localized("Show Project Files"),
              defaultShortcut: .init(modifiers: [.command, .option], key: .char("0"))),
    ]

    static let byID: [KeyCommandID: KeyCommandInfo] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func info(_ id: KeyCommandID) -> KeyCommandInfo { byID[id]! }

    /// Category headers in display order, de-duplicated.
    static var categories: [String] {
        var seen = Set<String>()
        return all.compactMap { seen.insert($0.category).inserted ? $0.category : nil }
    }
}
