import AppKit

/// Where ⌘W and ⌘⇧W land, resolved as a pure decision.
///
/// Menu actions hang off the app delegate rather than a window, so the close keys
/// have to work out their own target — the app's one hand-rolled substitute for the
/// context tree Zed and VS Code resolve bindings against
/// (`docs/design/keyboard-command-design.md`). Two branches don't justify a context
/// engine, but they do justify keeping the decision in one readable, testable place:
/// this routing regresses silently, which is why cmux guards the same key with a CI
/// lint. `CloseCommandTests` is termio's version of that guard.
enum CloseCommand {
    /// What holds the key window when a close key arrives.
    enum Frontmost: Equatable {
        /// Nothing on screen — the main window is closed and the app runs on.
        case nothing
        case mainWindow
        /// The ⌘⇧P / ⌘⇧O panel. Borderless, so `performClose` would only beep;
        /// it dismisses through the store flag that owns its presentation.
        case palette
        /// Settings, or any other window the app puts up.
        case auxiliaryWindow(closable: Bool)
    }

    enum Action: Equatable {
        case nothing
        case dismissPalette
        case closeKeyWindow
        case ungroupPane
        case closeMainWindow
    }

    /// - Parameter ungroupingSplit: whether this key peels a pane off a split before
    ///   it will consider the window — true for ⌘W with a split on screen, false for
    ///   ⌘⇧W, which closes the window whatever the layout.
    static func action(for frontmost: Frontmost, ungroupingSplit: Bool) -> Action {
        switch frontmost {
        case .nothing:
            // Nothing is on screen, so there is nothing to close. Acting on the
            // main window here would mutate a layout the user cannot see.
            return .nothing
        case .palette:
            return .dismissPalette
        case .auxiliaryWindow(let closable):
            // A window with no close button can't be closed by AppKit; beeping at
            // the user is worse than leaving the key inert.
            return closable ? .closeKeyWindow : .nothing
        case .mainWindow:
            return ungroupingSplit ? .ungroupPane : .closeMainWindow
        }
    }

    /// Classifies the live key window. Split from `action(for:ungroupingSplit:)` so
    /// the decision itself stays free of AppKit state and can be tested.
    @MainActor
    static func frontmost(mainWindow: NSWindow?, palettePanel: NSWindow?) -> Frontmost {
        guard let keyWindow = NSApp.keyWindow else { return .nothing }
        if let palettePanel, keyWindow === palettePanel { return .palette }
        if let mainWindow, keyWindow === mainWindow { return .mainWindow }
        return .auxiliaryWindow(closable: keyWindow.styleMask.contains(.closable))
    }
}
