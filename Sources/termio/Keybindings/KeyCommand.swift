import Foundation

/// Stable identifier for every rebindable app command. The raw string is the key
/// used both in `keybindings.json` and to look a shortcut up from the menu and
/// the palette, so these values are API — don't rename them once shipped.
enum KeyCommandID: String, CaseIterable, Identifiable {
    // File
    case newTerminal = "file.new-terminal"
    case openProject = "file.open-project"
    // Navigation
    case openQuickly = "nav.open-quickly"
    case commandPalette = "nav.command-palette"
    // Panes
    case splitRight = "pane.split-right"
    case splitDown = "pane.split-down"
    case splitZoom = "pane.zoom"
    case closePane = "pane.close"
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
        .init(id: .newTerminal, category: "File", title: "New Terminal",
              defaultShortcut: .init(modifiers: [.command], key: .char("t"))),
        .init(id: .openProject, category: "File", title: "Open Project…",
              defaultShortcut: .init(modifiers: [.command], key: .char("o"))),
        // Navigation
        .init(id: .openQuickly, category: "Navigation", title: "Open Quickly…",
              defaultShortcut: .init(modifiers: [.command, .shift], key: .char("o"))),
        .init(id: .commandPalette, category: "Navigation", title: "Command Palette…",
              defaultShortcut: .init(modifiers: [.command, .shift], key: .char("p"))),
        // Panes
        .init(id: .splitRight, category: "Panes", title: "Split Right",
              defaultShortcut: .init(modifiers: [.command], key: .char("d"))),
        .init(id: .splitDown, category: "Panes", title: "Split Down",
              defaultShortcut: .init(modifiers: [.command, .shift], key: .char("d"))),
        .init(id: .splitZoom, category: "Panes", title: "Zoom Split",
              defaultShortcut: .init(modifiers: [.command, .shift], key: .return)),
        .init(id: .closePane, category: "Panes", title: "Close Pane",
              defaultShortcut: .init(modifiers: [.command], key: .char("w"))),
        .init(id: .focusPaneLeft, category: "Panes", title: "Focus Pane Left",
              defaultShortcut: .init(modifiers: [.command, .option], key: .left)),
        .init(id: .focusPaneRight, category: "Panes", title: "Focus Pane Right",
              defaultShortcut: .init(modifiers: [.command, .option], key: .right)),
        .init(id: .focusPaneUp, category: "Panes", title: "Focus Pane Up",
              defaultShortcut: .init(modifiers: [.command, .option], key: .up)),
        .init(id: .focusPaneDown, category: "Panes", title: "Focus Pane Down",
              defaultShortcut: .init(modifiers: [.command, .option], key: .down)),
        // Font
        .init(id: .increaseFontSize, category: "Font", title: "Increase Font Size",
              defaultShortcut: .init(modifiers: [.command], key: .char("="))),
        .init(id: .decreaseFontSize, category: "Font", title: "Decrease Font Size",
              defaultShortcut: .init(modifiers: [.command], key: .char("-"))),
        .init(id: .resetFontSize, category: "Font", title: "Reset Font Size",
              defaultShortcut: .init(modifiers: [.command], key: .char("0"))),
        // Window
        .init(id: .closeWindow, category: "Window", title: "Close Window",
              defaultShortcut: .init(modifiers: [.command, .shift], key: .char("w"))),
        // Interface
        .init(id: .toggleProjectFiles, category: "Interface", title: "Show Project Files",
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
