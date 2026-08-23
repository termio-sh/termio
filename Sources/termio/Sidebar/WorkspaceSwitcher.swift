import AppKit
import SwiftUI
import TermioShared

/// The workspace rows, in the order every surface shows them: one item per
/// workspace, the one on screen checked, the first nine carrying ⌘1…9.
///
/// One builder for both menus that draw them — the sidebar switcher and File ▸
/// Workspace — because the digit is positional. Two menus numbering their own
/// rows could disagree about which workspace ⌘2 reaches, and a number that lies
/// is worse than no number at all.
enum WorkspaceMenu {
    /// `representedObject` carries the workspace's uuid string, which is what
    /// `action` reads back — the one thing both callers' handlers share.
    ///
    /// The key equivalents are live only in the menu bar's copy: AppKit matches a
    /// keystroke against the main menu, so the same items in a pull-down draw the
    /// glyphs without claiming ⌘1…9 a second time.
    @MainActor
    static func rows(in store: TermioStore, target: AnyObject, action: Selector) -> [NSMenuItem] {
        let shortcuts = KeybindingStore.workspaceShortcuts
        // The menu is AppKit and has no SwiftUI environment to read the
        // appearance from, so it asks the window that is showing it.
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let chrome = store.settings.chromeTheme(for: dark ? .dark : .light)
        return store.orderedWorkspaces.enumerated().map { index, workspace in
            let item = NSMenuItem(title: workspace.name, action: action, keyEquivalent: "")
            if index < shortcuts.count {
                item.keyEquivalent = shortcuts[index].keyEquivalent
                item.keyEquivalentModifierMask = shortcuts[index].keyEquivalentModifierMask
            }
            item.target = target
            item.representedObject = workspace.id.uuidString
            item.state = workspace.id == store.currentWorkspaceID ? .on : .off
            // The scope's own colour. This is the one place every workspace is
            // visible at once, which is the only place a colour can be read
            // without having been memorised — the menu is its own legend. Drawn
            // nowhere else: inside a workspace every row belongs to it, so the
            // same hue repeated down the sidebar would say nothing.
            item.image = WorkspaceSwatch.image(for: workspace, chrome: chrome)
            // Which machine, in words, and only when the name does not already
            // say it — an auto-created workspace *is* named after its alias.
            // Words rather than a second mark: the row has one image slot and the
            // colour has it, and a machine's name is the thing a person types.
            if let alias = workspace.deviceAlias,
               !workspace.name.localizedCaseInsensitiveContains(alias) {
                item.attributedTitle = titled(workspace.name, on: alias)
            }
            return item
        }
    }

    /// A verb below the rows — New Workspace…, Workspace Settings… — carrying the
    /// glyph that keeps it on the rows' leading edge.
    ///
    /// `NSMenuItem` draws a title with no image in the image column, so a bare verb
    /// under rows that wear a colour starts further left than every name above it.
    /// The glyph is what puts them back on one edge, which is why it is decided here
    /// beside the rows rather than by each menu that adds a verb: the marks are
    /// conditional on a terminal theme being selected, and under unmarked rows the
    /// glyph is the thing that would break the alignment.
    @MainActor
    static func verb(_ title: String, symbol: String, alignedWith rows: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if rows.contains(where: { $0.image != nil }) {
            // Stepped down from the menu default, which draws a symbol heavier than
            // the dot it shares a column with: the glyph is here to hold the leading
            // edge, so it should not out-weigh the marks it is aligning to.
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        }
        return item
    }

    /// The row's title with the machine trailing it in the secondary colour, so
    /// the name still reads as the name.
    @MainActor
    private static func titled(_ name: String, on alias: String) -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: name,
            attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.labelColor])
        title.append(NSAttributedString(
            string: "  " + alias,
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        return title
    }
}

/// The dot a workspace wears in the switcher, rendered once per colour and kept.
///
/// Menus are rebuilt on every open (`menuNeedsUpdate`), so a swatch drawn per row
/// per open is the same handful of images made over and over. The cache is keyed
/// by the colour it drew, not by the workspace, because two scopes sharing a hue
/// share the picture — and because a key that *is* the colour needs no
/// invalidation when the theme changes: the same index resolves to a different
/// colour, which is a different key.
@MainActor
enum WorkspaceSwatch {
    private static let cache = NSCache<NSString, NSImage>()
    /// Sized to the cap height of the menu font rather than to some fraction of the
    /// row: the dot sits beside a name and reads as a mark on it, so it is balanced
    /// against the letters, not against the row's height.
    private static let size = NSSize(width: 12, height: 12)

    static func image(for workspace: Workspace, chrome: ChromeTheme?) -> NSImage? {
        guard let color = resolved(workspace, chrome: chrome) else { return nil }
        let key = NSString(string: color.description)
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        cache.setObject(image, forKey: key)
        return image
    }

    /// The colour a workspace wears, for the surfaces that draw it themselves
    /// rather than handing an image to AppKit.
    ///
    /// Wrapped rather than clamped: the index is stored against a palette whose
    /// size is the theme's business, and a theme with fewer tints must still draw
    /// every workspace rather than collapsing the tail onto one colour.
    static func color(for workspace: Workspace, chrome: ChromeTheme?) -> Color? {
        guard let tints = chrome?.workspaceTints, !tints.isEmpty else { return nil }
        return tints[(workspace.color ?? 0) % tints.count]
    }

    private static func resolved(_ workspace: Workspace, chrome: ChromeTheme?) -> NSColor? {
        color(for: workspace, chrome: chrome).map(NSColor.init)
    }
}

/// The workspace switcher, in the sidebar's own toolbar region: which scope you
/// are in, and the control that changes it. It sits in the strip above the list
/// rather than in a row of its own, next to the navigator toggle and the
/// sidebar's other actions — the band belongs to the column below it, and a first
/// row that is not a session is a row the tree has to explain.
///
/// Quiet by design — it names the workspace and nothing else — and absent
/// entirely while there is only one, so a user who never makes a second never
/// sees it.
struct WorkspaceSwitcherToolbarView: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.controlActiveState) private var controlActive

    /// Long names truncate rather than push the sort and `+` buttons toward
    /// NSToolbar's `»` overflow: the sidebar region has only the room the
    /// navigator's minimum thickness gives it.
    private static let nameWidthCeiling: CGFloat = 130

    var body: some View {
        // The single-workspace collapse. Not "hidden but present": with one scope
        // there is no switch to make, and a control that always reads the same
        // word is a label for a decision the user never took.
        if store.hasMultipleWorkspaces {
            let current = store.currentWorkspace
            // The name and nothing else. No device mark — the rows below already say
            // which machine they are on — and no menu chevron: the toolbar band is
            // three glyphs wide, and every point this control spends on decoration is
            // a point the name truncates at.
            Text(current.name)
                .font(nameFont)
                .fontWeight(.medium)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: Self.nameWidthCeiling)
                .fixedSize()
                // The overlay owns the press, the tooltip, and the accessibility of
                // this control — it is the view under the pointer, so a `.help()` here
                // would be shadowed by it and a SwiftUI accessibility element here would
                // hide it. See `WorkspaceMenuHost`.
                .overlay(WorkspaceMenuPopper(store: store))
                .accessibilityHidden(true)
        }
    }

    /// The sidebar's own row size, so the band and the column below it share an
    /// x-height and read as one thing — this names that column, and a size step
    /// would separate it from what it names. The rank comes from weight instead:
    /// a label larger than the 13pt window title beside it is what makes a titlebar
    /// look mis-scaled. Derived from the interface size rather than fixed, so it
    /// still follows the density preference the rows below it follow.
    private var nameFont: Font {
        let size = settings.interfaceFontSize
        return settings.interfaceFontFamily.isEmpty
            ? .system(size: size)
            : .custom(settings.interfaceFontFamily, size: size)
    }

    // Matched to the sidebar toolbar's native glyphs (the `+` new-terminal item, the
    // sort pull-down): those are bordered `NSToolbarItem`s, which tint their template
    // symbol at full-strength `labelColor`, so the name sits at `.primary` to read as
    // one control band with them rather than a dimmer `.secondary` label.
    private var color: Color {
        controlActive == .inactive ? Color(nsColor: .disabledControlTextColor) : .primary
    }
}

/// Opens the switcher's menu on click, over the label above it.
///
/// AppKit rather than SwiftUI's `Menu` because only `NSMenuItem` draws both halves
/// a row needs at once: a checkmark in the state column for the workspace on
/// screen, and the ⌘-digit that reaches it, right-aligned in the column macOS puts
/// shortcuts in. SwiftUI offers one or the other — an inline `Picker` checkmarks,
/// a `Button` takes `.keyboardShortcut` — and `.keyboardShortcut` would also
/// *claim* ⌘1…9 for as long as this view is mounted, a second live binding racing
/// File ▸ Workspace for the same keystroke.
private struct WorkspaceMenuPopper: NSViewRepresentable {
    let store: TermioStore

    func makeNSView(context: Context) -> WorkspaceMenuHost {
        let view = WorkspaceMenuHost()
        view.store = store
        view.toolTip = localized("The sidebar shows this workspace")
        return view
    }

    func updateNSView(_ nsView: WorkspaceMenuHost, context: Context) {
        nsView.store = store
    }
}

/// The click target, and the target of the menu it pops. One class rather than a
/// view plus a coordinator: the menu is built when it opens, out of the store this
/// view already holds, so there is no second place for its contents to live.
private final class WorkspaceMenuHost: NSView {
    weak var store: TermioStore?

    /// Flipped so the anchor below reads in the direction the menu opens, rather
    /// than depending on whichever convention the hosting view happens to use.
    override var isFlipped: Bool { true }

    /// A click in a background window opens the menu rather than only raising the
    /// window — the switcher is often the reason the window is being reached for.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        showMenu()
    }

    // MARK: - Accessibility
    //
    // The element is this view rather than the `Text` beneath it. A SwiftUI
    // `.accessibilityAddTraits(.isButton)` only sets a trait — nothing there answers
    // a press — so the control announced itself as a button and then did nothing,
    // which the `Menu` it replaced did not do. Answering here gives the press a real
    // implementation and one description that cannot disagree with the label drawn.

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
    override func accessibilityLabel() -> String? { localized("Workspace") }
    override func accessibilityValue() -> Any? { store?.currentWorkspace.name }

    override func accessibilityPerformPress() -> Bool {
        showMenu()
        return true
    }

    private func showMenu() {
        guard let store else { return }
        let menu = NSMenu()
        let rows = WorkspaceMenu.rows(in: store, target: self, action: #selector(switchToWorkspace(_:)))
        for row in rows {
            menu.addItem(row)
        }
        // This Mac, without asking: the device submenu belongs to the menus that
        // already carry one (File ▸ Workspace and the sidebar `+`), and growing a
        // third here would put a machine list in the switcher, which is the "go to
        // a computer" mode the workspace replaced.
        addAction(localized("New Workspace…"), to: menu, #selector(newWorkspace),
                  symbol: "plus", alignedWith: rows)
        menu.addItem(.separator())
        // Renaming and removing are in Settings ▸ Workspaces. Creating stays here
        // because it is the one verb that does not need the user to pick which
        // workspace it acts on — the other two do, and this menu can only ever
        // offer them for the row it already shows checked.
        addAction(localized("Workspace Settings…"), to: menu, #selector(openWorkspaceSettings),
                  symbol: "gearshape", alignedWith: rows)
        // No device verb here, deliberately. A machine you can *go to* is the
        // mode this scope replaced: it made the sidebar answer "which computer"
        // when the question is "which work". A device is a place a new thing is
        // put — New Terminal on it, Clone to it, File ▸ Connect to… for a box
        // never reached — never a place the window travels to.

        // Anchored under the label the way a pull-down opens, rather than at the
        // pointer the way a context menu does.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    private func addAction(
        _ title: String, to menu: NSMenu, _ action: Selector,
        symbol: String, alignedWith rows: [NSMenuItem]
    ) {
        let item = WorkspaceMenu.verb(title, symbol: symbol, alignedWith: rows)
        item.action = action
        item.target = self
        menu.addItem(item)
    }

    @objc private func switchToWorkspace(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        store?.switchToWorkspace(id)
    }

    @objc private func newWorkspace() {
        store?.presentNewWorkspacePanel(on: .thisMac)
    }

    @objc private func openWorkspaceSettings() {
        NSApp.sendAction(#selector(AppDelegate.openWorkspaceSettings(_:)), to: nil, from: nil)
    }
}
