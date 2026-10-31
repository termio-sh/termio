import AppKit
import SwiftUI
import TermioShared

/// The workspace a machine reopens on, across launches.
enum MachineMemory {
    private static let key = "lastWorkspaceByMachine"

    static func remember(_ id: Workspace.ID, on device: WorkspaceDevice) {
        var known = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        known[device.alias ?? ""] = id.uuidString
        UserDefaults.standard.set(known, forKey: key)
    }

    static func workspace(on device: WorkspaceDevice) -> Workspace.ID? {
        let known = UserDefaults.standard.dictionary(forKey: key) as? [String: String]
        return known?[device.alias ?? ""].flatMap(UUID.init(uuidString:))
    }
}

extension TermioStore {
    /// This Mac first, then every machine with a workspace or a recorded handshake.
    /// The registry half keeps a machine listed after its empty workspace is pruned.
    var switcherMachines: [WorkspaceDevice] {
        var aliases = Set(DeviceRoster.known(in: self).compactMap(\.alias))
        aliases.formUnion(workspaces.compactMap(\.deviceAlias))
        return [.thisMac] + aliases.sorted().map { .ssh(alias: $0) }
    }

    func workspaces(on device: WorkspaceDevice) -> [Workspace] {
        orderedWorkspaces.filter { $0.device == device }
    }

    func lastWorkspace(on device: WorkspaceDevice) -> Workspace? {
        let own = workspaces(on: device)
        guard let remembered = MachineMemory.workspace(on: device) else { return own.first }
        return own.first { $0.id == remembered } ?? own.first
    }

    func enterMachine(_ device: WorkspaceDevice) {
        if let workspace = lastWorkspace(on: device) {
            switchToWorkspace(workspace.id)
        } else if let alias = device.alias {
            switchToWorkspace(deviceWorkspace(for: alias))
        } else {
            // This Mac can lose its last workspace. There is nothing to enter, so make one.
            // After the panel has gone: the name panel is modal.
            DispatchQueue.main.async { self.presentNewWorkspacePanel(on: device) }
        }
    }
}

/// The workspace rows for File ▸ Workspace: the current machine's first, carrying
/// ⌘1…9, then the other machines' rows with no digit.
///
/// The digit is positional within the current machine, and `MachineSwitcherPanel`
/// numbers its rows the same way, so both surfaces agree about what ⌘2 reaches.
enum WorkspaceMenu {
    /// `representedObject` carries the workspace's uuid string, which is what
    /// `action` reads back.
    @MainActor
    static func rows(in store: TermioStore, target: AnyObject, action: Selector) -> [NSMenuItem] {
        let shortcuts = KeybindingStore.workspaceShortcuts
        let device = store.currentWorkspace.device
        let ordered = store.workspaces(on: device) + store.orderedWorkspaces.filter { $0.device != device }
        let localCount = store.workspaces(on: device).count
        return ordered.enumerated().map { index, workspace in
            let item = NSMenuItem(title: workspace.name, action: action, keyEquivalent: "")
            if index < localCount, index < shortcuts.count {
                item.keyEquivalent = shortcuts[index].keyEquivalent
                item.keyEquivalentModifierMask = shortcuts[index].keyEquivalentModifierMask
            }
            item.target = target
            item.representedObject = workspace.id.uuidString
            item.state = workspace.id == store.currentWorkspaceID ? .on : .off
            // Which machine, in words, and only when the name does not already
            // say it — an auto-created workspace *is* named after its alias.
            // In words rather than as a mark: a machine's name is the thing a
            // person types, and the row has the room for it.
            if let alias = workspace.deviceAlias,
               !workspace.name.localizedCaseInsensitiveContains(alias) {
                item.attributedTitle = titled(workspace.name, on: alias)
            }
            return item
        }
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

    /// Whether the pointer is over the name, or its menu is open. Reported by the
    /// AppKit overlay below, which is the view the pointer actually lands on.
    @State private var isHighlighted = false

    /// What the hover chip puts around the name. Real padding, not a background
    /// drawn outside the label's bounds: the toolbar item is only as large as this
    /// view asks to be, so anything painted past that edge is at the mercy of the
    /// hosting view's clip — and a chip clipped on one side looks like a bug rather
    /// than a control.
    ///
    /// The leading half is given back as negative padding on the whole box (see
    /// `body`), so the name still starts at the x the toggle beside it was spaced
    /// for.
    private static let chipInset: CGFloat = 8

    var body: some View {
        let current = store.currentWorkspace
        let machineIcon: HugeIcon = current.device.isThisMac ? .laptop : .network
        // One machine and one workspace: the icon alone, still the way to add either.
        if !store.hasMultipleWorkspaces && store.switcherMachines.count == 1 {
            HugeIconView(icon: machineIcon,
                             size: ChromeGlyph.size(for: machineIcon, base: ChromeGlyph.prominentSize),
                             color: color,
                             lineWidthOverride: ChromeGlyph.lineWidth(base: ChromeGlyph.prominentSize))
                .padding(.horizontal, Self.chipInset)
                .frame(height: ChromeGlyph.prominentFrame.height)
                .modifier(ChromeGlass(isVisible: true))
                .overlay(Capsule(style: .continuous).fill(Color.primary.opacity(isHighlighted ? 0.08 : 0)))
                .padding(.leading, -Self.chipInset)
                .overlay(WorkspaceMenuPopper(store: store, highlighted: $isHighlighted))
                .accessibilityHidden(true)
        } else {
            // One button: the capsule hugs the icon and the name. The spacer beside it
            // takes the slack, so a long name truncates before it can reach sort or `+`.
            HStack(spacing: 4) {
                HugeIconView(icon: machineIcon,
                             size: ChromeGlyph.size(for: machineIcon, base: ChromeGlyph.prominentSize),
                             color: color,
                             lineWidthOverride: ChromeGlyph.lineWidth(base: ChromeGlyph.prominentSize))
                Text(current.name)
                    // The very font the sidebar's rows and section headers use — not a copy of its
                    // definition, which is what this was and what let the two drift on paper. The band
                    // and the column below it share an x-height and read as one thing: this names that
                    // column, and a size step would separate it from what it names. Rank comes from
                    // weight instead — a label larger than the window title beside it is what makes a
                    // titlebar look mis-scaled.
                    .font(settings.interfaceFont)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
                .foregroundStyle(color)
                .padding(.horizontal, Self.chipInset)
                .frame(height: ChromeGlyph.prominentFrame.height)
                // Always on: this is the one thing that says the word is a control.
                .modifier(ChromeGlass(isVisible: true))
                .overlay(Capsule(style: .continuous).fill(Color.primary.opacity(isHighlighted ? 0.08 : 0)))
                // The leading inset given back, so the capsule fills the gap beside the toggle
                // rather than pushing the name away from it: the two read as one band.
                .padding(.leading, -Self.chipInset)
                // The overlay owns the press, the hover, the tooltip, and the
                // accessibility of this control — it is the view under the pointer, so a
                // `.help()` here would be shadowed by it and a SwiftUI accessibility
                // element here would hide it. See `WorkspaceMenuHost`.
                .overlay(WorkspaceMenuPopper(store: store, highlighted: $isHighlighted))
                .accessibilityHidden(true)
        }
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
    /// Driven by the host below: the pointer entering or leaving, and the menu
    /// being up. Hover is answered here rather than by a SwiftUI `.onHover` on the
    /// label, for the same reason the tooltip is — this view is the one the pointer
    /// hits, so the label underneath never learns the pointer arrived.
    @Binding var highlighted: Bool

    /// The name as well as the sentence, because the label above has only the row's slack
    /// and a name too long for it is middle-truncated with nowhere else to be read in place.
    private static func toolTip(for store: TermioStore) -> String {
        "\(store.currentWorkspace.name) — \(localized("The sidebar shows this workspace"))"
    }

    func makeNSView(context: Context) -> WorkspaceMenuHost {
        let view = WorkspaceMenuHost()
        view.store = store
        view.onHighlight = { highlighted = $0 }
        view.toolTip = Self.toolTip(for: store)
        return view
    }

    func updateNSView(_ nsView: WorkspaceMenuHost, context: Context) {
        nsView.store = store
        // Rebound every update: the closure captures this struct's binding, and a
        // stale one writes to a view tree that has been replaced.
        nsView.onHighlight = { highlighted = $0 }
        // Set here too: the scope changes far more often than this view is made.
        nsView.toolTip = Self.toolTip(for: store)
    }
}

/// The click target, and the target of the menu it pops. One class rather than a
/// view plus a coordinator: the menu is built when it opens, out of the store this
/// view already holds, so there is no second place for its contents to live.
private final class WorkspaceMenuHost: NSView {
    weak var store: TermioStore?
    private var lastClose: TimeInterval = 0
    private var panel: SwitcherPanel?
    private var resignObserver: NSObjectProtocol?

    /// Reports the pointer cue back to the view drawing it. See `highlight`.
    var onHighlight: ((Bool) -> Void)?

    private var hoverTracking: NSTrackingArea?

    /// Flipped so the anchor below reads in the direction the menu opens, rather
    /// than depending on whichever convention the hosting view happens to use.
    override var isFlipped: Bool { true }

    /// A click in a background window opens the menu rather than only raising the
    /// window — the switcher is often the reason the window is being reached for.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        showMenu()
    }

    // MARK: - Hover
    //
    // Only while the app is active: hovering a background window highlights
    // nothing on macOS, and the name is drawn in the disabled colour there anyway.

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHighlight?(true) }

    override func mouseExited(with event: NSEvent) {
        if panel == nil { onHighlight?(false) }
    }

    /// A panel outliving the control it hangs from would float with nothing under it.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { closePanel() }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Whether the pointer is over this view right now, asked rather than
    /// remembered — the tracking area is silent while a menu holds the event loop,
    /// so this is how the cue is settled once the menu has gone.
    private var isUnderPointer: Bool {
        guard let location = window?.mouseLocationOutsideOfEventStream else { return false }
        return bounds.contains(convert(location, from: nil))
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

    /// A key child panel, the way the command palette floats, rather than an
    /// `NSPopover`: dismissal is then only ever this view's own decision, and there
    /// is no arrow under the toolbar control.
    private func showMenu() {
        guard let store, let window, panel == nil else { return }
        // Clicking the control resigns the panel on the mouse-down that lands here,
        // so that click would otherwise reopen what it just dismissed.
        if ProcessInfo.processInfo.systemUptime - lastClose < 0.2 { return }
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let bottom = window.screen?.visibleFrame.minY ?? window.frame.minY
        let hosting = NSHostingView(rootView: MachineSwitcherPanel(
            store: store,
            maxHeight: anchor.minY - 6 - bottom - 8,
            unusedAliases: DeviceRoster.unusedAliases(known: DeviceRoster.known(in: store)),
            dismiss: { [weak self] in self?.closePanel() }))
        let size = hosting.fittingSize
        let panel = SwitcherPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.contentView = AppDelegate.paletteBackdrop(around: hosting)
        panel.onCancel = { [weak self] in self?.closePanel() }
        panel.setFrameOrigin(NSPoint(
            x: max(anchor.minX, window.frame.minX + 8),
            // A window low on the screen: over the control, rather than off the bottom.
            y: max(bottom + 8, anchor.minY - 6 - size.height)))
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        // The shadow shape is computed before the backdrop's first frame.
        DispatchQueue.main.async { panel.invalidateShadow() }
        self.panel = panel
        onHighlight?(true)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    private func closePanel() {
        guard let panel else { return }
        self.panel = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        // Key goes back only if the panel still holds it. A click on another window
        // has already made that window key, and taking it back would undo the click.
        let hadKey = panel.isKeyWindow
        window?.removeChildWindow(panel)
        panel.orderOut(nil)
        if hadKey { window?.makeKey() }
        lastClose = ProcessInfo.processInfo.systemUptime
        onHighlight?(isUnderPointer)
    }
}

private final class SwitcherPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// Any shortcut closes the panel and goes on to the menu bar, so a command that
    /// leaves the scope as it was still hands the keyboard back to the terminal.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onCancel?()
        return false
    }
}

/// The switcher's panel: every machine, the current one's workspaces under it, and
/// the actions that are not about any one row. Every row shares one grid: a glyph
/// column, a text column, and a trailing column that the new-workspace buttons, the
/// shortcuts and the chevron all end on.
private struct MachineSwitcherPanel: View {
    @ObservedObject var store: TermioStore
    /// The room below the control. A long list scrolls inside it, keeping the actions on screen.
    let maxHeight: CGFloat
    let unusedAliases: [String]
    let dismiss: () -> Void

    @State private var hovered: String?

    private static let rowHeight: CGFloat = 28
    private static let iconSize: CGFloat = 16
    private static let iconColumn: CGFloat = 25
    private static let leadingInset: CGFloat = 8
    private static let trailingInset: CGFloat = 8
    private static let addButtonSize: CGFloat = 23

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(store.switcherMachines, id: \.self, content: machineGroup)
                }
                .padding(6)
            }
            .frame(height: listHeight)
            Divider().padding(.horizontal, 14)
            VStack(spacing: 1) {
                if !unusedAliases.isEmpty {
                    actionRow(localized("Connect to…"), icon: .network, opensMenu: true, action: showConnectMenu)
                }
                actionRow(localized("Workspace Settings…"), icon: .settings) {
                    dismiss()
                    NSApp.sendAction(#selector(AppDelegate.openWorkspaceSettings(_:)), to: nil, from: nil)
                }
            }
            .padding(6)
        }
        .frame(width: 264)
        .font(.system(size: 13))
        // ⌘1…9 reach the menu bar while this is open, and a panel left key would keep
        // typing from the terminal the switch just brought up.
        .onChange(of: store.currentWorkspaceID) { dismiss() }
    }

    /// Worked out rather than measured: a `ScrollView` has no fitting height to report.
    private var listHeight: CGFloat {
        let current = store.workspaces(on: store.currentWorkspace.device).count
        let rows = store.switcherMachines.count + (current > 1 ? current : 0)
        let actions = CGFloat(unusedAliases.isEmpty ? 1 : 2) * (Self.rowHeight + 1) + 13
        let full = CGFloat(rows) * (Self.rowHeight + 1) - 1 + 12
        return min(full, max(Self.rowHeight * 3, maxHeight - actions))
    }

    @ViewBuilder
    private func machineGroup(_ device: WorkspaceDevice) -> some View {
        let isCurrent = store.currentWorkspace.device == device
        let own = store.workspaces(on: device)
        let expanded = isCurrent && own.count > 1
        machineRow(device, isCurrent: isCurrent, own: own, expanded: expanded)
        if expanded {
            ForEach(Array(own.enumerated()), id: \.element.id) { index, workspace in
                workspaceRow(workspace, index: index)
            }
        }
    }

    private func machineRow(
        _ device: WorkspaceDevice, isCurrent: Bool, own: [Workspace], expanded: Bool
    ) -> some View {
        let key = "machine-" + device.displayName
        let isOffline: Bool = {
            guard isCurrent, case .failed = store.deviceSessions else { return false }
            return true
        }()
        return HStack(spacing: 0) {
            Button {
                dismiss()
                store.enterMachine(device)
            } label: {
                HStack(spacing: 0) {
                    panelIcon(device.isThisMac ? .laptop : .network, color: isOffline ? .secondary : .primary)
                        .frame(width: Self.iconColumn, alignment: .leading)
                    Text(device.displayName)
                        .fontWeight(.medium)
                        .foregroundStyle(isOffline ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 10)
                    Text(machineDetail(device, isCurrent: isCurrent, own: own, isOffline: isOffline))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, Self.leadingInset)
                .padding(.trailing, 6)
                .frame(height: Self.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                dismiss()
                // After the panel has gone: the name panel is modal.
                DispatchQueue.main.async { store.presentNewWorkspacePanel(on: device) }
            } label: {
                panelIcon(.dashboardSquareAdd, color: hovered == key + "+" ? .primary : .secondary)
                    .frame(width: Self.addButtonSize, height: Self.addButtonSize)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(hovered == key + "+" ? 0.13 : 0)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(device.alias.map { localized("New Workspace on \($0)") } ?? localized("New Workspace"))
            .onHover { hovered = $0 ? key + "+" : key }
            // The glyph, not its hit box, ends on the trailing column.
            .padding(.trailing, Self.trailingInset - (Self.addButtonSize - Self.iconSize) / 2)
        }
        .background(rowFill(isSelected: isCurrent && !expanded, isHovered: hovered == key || hovered == key + "+"))
        .onHover { inside in
            if inside { hovered = key } else if hovered == key { hovered = nil }
        }
    }

    private func machineDetail(
        _ device: WorkspaceDevice, isCurrent: Bool, own: [Workspace], isOffline: Bool
    ) -> String {
        if isOffline { return localized("Offline") }
        guard !isCurrent, own.count > 1 else { return "" }
        return store.lastWorkspace(on: device)?.name ?? ""
    }

    private func workspaceRow(_ workspace: Workspace, index: Int) -> some View {
        let key = "workspace-" + workspace.id.uuidString
        return Button {
            dismiss()
            store.switchToWorkspace(workspace.id)
        } label: {
            HStack(spacing: 0) {
                Text(workspace.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 10)
                if index < KeybindingStore.workspaceShortcuts.count {
                    Text(verbatim: "⌘\(index + 1)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, Self.leadingInset + Self.iconColumn)
            .padding(.trailing, Self.trailingInset)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowFill(isSelected: workspace.id == store.currentWorkspaceID, isHovered: hovered == key))
        .onHover { hovered = $0 ? key : nil }
    }

    private func actionRow(
        _ title: String, icon: HugeIcon, opensMenu: Bool = false, action: @escaping () -> Void
    ) -> some View {
        let key = "action-" + title
        return Button(action: action) {
            HStack(spacing: 0) {
                panelIcon(icon, color: .primary)
                    .frame(width: Self.iconColumn, alignment: .leading)
                Text(title)
                Spacer(minLength: 10)
                if opensMenu {
                    HugeIconView(icon: .chevronRight, size: 7.5, color: .secondary, lineWidthOverride: 1.75)
                }
            }
            .padding(.leading, Self.leadingInset)
            .padding(.trailing, Self.trailingInset)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowFill(isSelected: false, isHovered: hovered == key))
        .onHover { hovered = $0 ? key : nil }
    }

    /// Evened by `ChromeGlyph` rather than by point size: the globe fills its box where
    /// the others keep a margin, so at one point size it reads larger than they do.
    private func panelIcon(_ icon: HugeIcon, color: Color) -> some View {
        HugeIconView(icon: icon,
                     size: ChromeGlyph.size(for: icon, base: Self.iconSize),
                     color: color,
                     lineWidthOverride: ChromeGlyph.lineWidth(base: Self.iconSize))
    }

    private func rowFill(isSelected: Bool, isHovered: Bool) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.primary.opacity(isSelected ? 0.13 : (isHovered ? 0.07 : 0)))
    }

    /// The same action the File menu's Connect to… rows send.
    private func showConnectMenu() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        let menu = NSMenu()
        for alias in unusedAliases {
            let item = NSMenuItem(
                title: alias, action: #selector(AppDelegate.connectToDevice(_:)), keyEquivalent: "")
            item.target = delegate
            item.representedObject = alias
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        dismiss()
    }
}
