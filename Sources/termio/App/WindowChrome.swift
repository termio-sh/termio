import AppKit
import Combine
import SwiftUI

/// The window has no toolbar. The traffic lights float over the content, and every control that
/// used to ride the toolbar band sits in a row belonging to what it acts on: the sidebar's
/// toggle, workspace, sort and `+` above the sidebar list, and each pane's own buttons — plus, on
/// the focused card, the inspector's panes — in its card header. All of them centre on the
/// traffic lights' line, so the top of the window reads as one row.
///
/// A toolbar band could not hold that row. It sits over the content and takes every click there,
/// so a card header under it was dead; and in fullscreen macOS 26 paints it as an opaque light band
/// over a dark terminal.
enum WindowChrome {
    /// The one margin: around the pane area, between two cards, and above each control row.
    /// One value, so the gap between cards is never wider than the gap at the window's edge.
    static let inset: CGFloat = 6

    /// A control row's height. Each row starts `inset` below the window's top edge, so every row
    /// — and the traffic lights, which `TrafficLights` moves onto it — centres on `rowCenter`.
    static let rowHeight: CGFloat = 32
    static var rowCenter: CGFloat { inset + rowHeight / 2 }

    /// The close button's leading edge: the same left margin the sidebar's rows use.
    static let trafficLightsLeading: CGFloat = 19

    /// Where the traffic lights end, in window coordinates. The span comes from the live window,
    /// since the spacing between the buttons is the system's to change. The start does not:
    /// AppKit puts the buttons back at its own x on a titlebar layout until `TrafficLights` moves
    /// them again, and a row reading that x jumps 12pt on every workspace switch.
    @MainActor
    static var trafficLightsEnd: CGFloat {
        guard let window = AppDelegate.mainWindow,
              let close = window.standardWindowButton(.closeButton),
              let zoom = window.standardWindowButton(.zoomButton)
        else { return 79 }
        return trafficLightsLeading + zoom.frame.maxX - close.frame.minX
    }

    /// The gap between the last traffic light and the first control after it. Wider than the
    /// lights' own spacing, so the toggle reads as the row's first control, not a fourth light.
    static let trafficLightsGap: CGFloat = 16

    /// The leading inset of a row whose column starts at `columnMinX` in the window: clear of the
    /// traffic lights while they are drawn, and a plain margin in fullscreen, where they only appear
    /// with the titlebar the pointer summons — and then over the content, not beside it.
    @MainActor
    static func leadingInset(isFullScreen: Bool, columnMinX: CGFloat) -> CGFloat {
        isFullScreen ? 10 : max(10, trafficLightsEnd + trafficLightsGap - columnMinX)
    }

    /// Where the window's own controls — the traffic lights and the navigator toggle — end, in
    /// window coordinates. Nothing else draws to the leading side of this on the top row.
    @MainActor
    static func controlsEnd(isFullScreen: Bool) -> CGFloat {
        leadingInset(isFullScreen: isFullScreen, columnMinX: 0) + ChromeGlyph.prominentFrame.width
    }
}

/// Where the sidebar's slide has things right now, published on every frame of it.
///
/// The traffic lights and the navigator toggle stand still while the column and the cards move
/// under them. Anything that has to keep clear of them is placed from this live geometry, never
/// from where the slide will end: a margin computed for the end position and eased over on its own
/// clock put the card's title under the traffic lights at the start of an expand, and slid the
/// sidebar's row under the toggle on a collapse.
@MainActor
final class NavigatorGeometry: ObservableObject {
    /// The pane area's leading edge in window coordinates: past the column while the sidebar is
    /// open, 0 once it is gone. Unknown until the pane is first laid out, which reads as far away.
    @Published var paneMinX: CGFloat = .greatestFiniteMagnitude
    /// How far the sidebar's content has slid out past the window's leading edge.
    @Published var sidebarTravel: CGFloat = 0
    /// Where `paneMinX` starts and ends while the navigator toggle's slide runs; `nil` at rest.
    @Published var slide: Slide?

    struct Slide {
        let from: CGFloat
        let to: CGFloat
    }
}

/// Moves the traffic lights onto the control rows' line. Without a toolbar AppKit centres them in
/// a 32pt strip at the window's top edge, which puts them half a row above the sidebar panel's
/// first row. AppKit redoes its layout on resize, key changes and fullscreen, so each button's own
/// frame change re-applies the placement, and the window delegate re-applies it on a resize.
@MainActor
final class TrafficLights {
    private weak var window: NSWindow?
    // Held for the window's lifetime, which is the app's; the blocks hold `self` weakly.
    private var observers: [NSObjectProtocol] = []
    private var isPlacing = false
    private var placeScheduled = false

    init(window: NSWindow) {
        self.window = window
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type) else { continue }
            button.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: button, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedulePlace() }
            })
        }
        // The titlebar is laid out after the window first shows.
        DispatchQueue.main.async { [weak self] in self?.place() }
    }

    /// A frame change from AppKit re-places on the next turn, once however many arrive. Placing
    /// from inside the notification recursed: moving a button posts the same notification, and
    /// AppKit moving it back during that call posted another, until the stack ran out.
    private func schedulePlace() {
        guard !placeScheduled, !isPlacing else { return }
        placeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.placeScheduled = false
            self.place()
        }
    }

    /// Idempotent: a frame already in place is left alone, and a call made while placing is
    /// ignored, so the notifications its own moves post cannot loop. Fullscreen is left to AppKit, which shows the buttons only in the titlebar the
    /// pointer summons.
    ///
    /// The buttons are moved down by growing the titlebar container rather than by moving them
    /// inside it: AppKit re-places them on every layout at a fixed distance above the container's
    /// bottom edge, so a taller container is the one placement it keeps. Electron's
    /// `trafficLightPosition` does the same.
    func place() {
        guard !isPlacing else { return }
        isPlacing = true
        defer { isPlacing = false }
        guard let window, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let mini = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let container = close.superview?.superview,
              let frameView = container.superview
        else { return }
        // The buttons' distance above the container's bottom edge is AppKit's; the container's
        // height is what puts their centre on `rowCenter`.
        let height = WindowChrome.rowCenter + close.frame.minY + close.frame.height / 2
        let containerFrame = NSRect(x: container.frame.minX,
                                    y: frameView.isFlipped ? 0 : frameView.bounds.height - height,
                                    width: container.frame.width, height: height)
        if container.frame != containerFrame { container.frame = containerFrame }
        let spacing = mini.frame.minX - close.frame.minX
        guard spacing > 0 else { return }
        for (index, button) in [close, mini, zoom].enumerated() {
            let x = WindowChrome.trafficLightsLeading + CGFloat(index) * spacing
            if button.frame.minX != x { button.setFrameOrigin(NSPoint(x: x, y: button.frame.minY)) }
        }
    }
}

/// One size for every clickable glyph in the window's top row and the cards' headers: the same
/// icon family (Hugeicons), the same glyph size, the same hit area and hover chip. Mixed sizes
/// read as mixed importance, and two families side by side never share an optical weight.
enum ChromeGlyph {
    /// Sized against the traffic lights beside the first of them: a Hugeicons glyph draws
    /// lighter than its point size, so at 13 the row read small next to the 14pt buttons.
    static let size: CGFloat = 15
    static let frame = CGSize(width: 24, height: 22)
    /// The app's core actions — the sidebar toggle, sort, `+` — a step larger, in full ink, on
    /// the system's Liquid Glass, so they stand out from the per-card and per-panel controls.
    static let prominentSize: CGFloat = 20
    static let prominentFrame = CGSize(width: 32, height: 28)

    /// The point size that makes `icon` look `size`. Equal point sizes are not equal glyphs: a
    /// diagonal that runs corner to corner (✕, the zoom arrows), a funnel, a plus, or a pencil and an eye fill
    /// their box, where the outlined panels and boxes keep a margin inside it, so at one point
    /// size those read visibly bigger. Each is scaled to the outlined glyphs' apparent size.
    static func size(for icon: HugeIcon, base: CGFloat = size) -> CGFloat {
        switch icon {
        case .close: base * 0.8
        case .filter, .add: base * 0.85
        case .expand, .collapse: base * 0.87
        case .edit, .view, .bookOpen, .network: base * 0.9
        default: base
        }
    }

    /// The stroke an icon drawn at `base` carries. Passed with every optically scaled glyph: the
    /// glyph's stroke otherwise follows its point size, so the scale that evens a ✕ or a `+` with
    /// its neighbours' size also drew its lines thinner than theirs.
    static func lineWidth(base: CGFloat = size) -> CGFloat {
        max(1.1, base * 1.5 / 24)
    }
    static let chipRadius: CGFloat = 5
}

/// The glass of whatever is "this one": the selected tab, a selected session row, the row in your
/// hand and the row a drag is held over. A face a step lighter than the ground, a hairline, and
/// `GlassRim`; no drop shadow, which reads as a raised button rather than a pane of glass.
struct SelectionGlass<S: InsettableShape>: View {
    let shape: S
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        shape.fill(Color.white.opacity(dark ? 0.09 : 0.55))
            .overlay(shape.strokeBorder(Color.primary.opacity(dark ? 0.10 : 0.07), lineWidth: 0.5))
            .overlay(GlassRim(shape: shape))
    }
}

/// Liquid Glass's specular edge, drawn by hand for a fill that is not system glass: a sheen down
/// the face and a rim lit from the top leading corner, with a weaker reflection at the bottom
/// trailing one.
struct GlassRim<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        ZStack {
            shape.fill(LinearGradient(colors: [.white.opacity(0.07), .clear],
                                      startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.38), location: 0),
                        .init(color: .white.opacity(0.03), location: 0.5),
                        .init(color: .white.opacity(0.16), location: 1),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1)
        }
    }
}

/// A close button's hover cue, as Safari gives the ✕ on a tab: a faint disc behind the glyph while
/// the pointer is on it, in the row's own ink rather than an accent, painted the frame the pointer
/// arrives. Shared by the sidebar's rows and the horizontal tabs so the two read as one control.
struct CloseHoverDisc: View {
    let isHovering: Bool
    var ink: Color = .primary
    var diameter: CGFloat = 20

    var body: some View {
        Circle()
            .fill(ink.opacity(isHovering ? 0.12 : 0))
            .frame(width: diameter, height: diameter)
    }
}

/// A borderless glyph button with a neutral chip under the pointer. The chip paints the frame the
/// pointer arrives, with no fade.
struct ChromeIconButton: View {
    let icon: HugeIcon
    let help: String
    var isOn = false
    var prominence: Prominence = .plain
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.controlActiveState) private var controlActive

    /// How a button sits in the chrome.
    enum Prominence {
        /// A per-card or per-panel control: the small glyph, a hover chip.
        case plain
        /// A core action: the larger glyph, on a glass capsule while the pointer is on it.
        case glass
    }

    private var prominent: Bool { prominence != .plain }

    var body: some View {
        Button(action: action) {
            let frame = prominent ? ChromeGlyph.prominentFrame : ChromeGlyph.frame
            let base = prominent ? ChromeGlyph.prominentSize : ChromeGlyph.size
            let glyph = HugeIconView(icon: icon,
                                     size: ChromeGlyph.size(for: icon, base: base),
                                     color: color,
                                     lineWidthOverride: ChromeGlyph.lineWidth(base: base))
                .frame(width: frame.width, height: frame.height)
                .contentShape(Rectangle())
            switch prominence {
            case .plain: glyph.background(ChromeHoverChip(isHovering: isHovering, isOn: isOn))
            case .glass: glyph.modifier(ChromeGlass(isVisible: isHovering))
            }
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { isHovering = $0 }
    }

    private var color: Color {
        if controlActive == .inactive { return Color(nsColor: .disabledControlTextColor) }
        return isOn || prominent ? .primary : .secondary
    }
}

/// The system's Liquid Glass capsule under a core action while the pointer is on it — the
/// material macOS 26 toolbar items wear, interactive so a press answers the way the system's do.
/// At rest the glyph stands alone. Before macOS 26, a flat capsule fill in its place.
struct ChromeGlass: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        if !isVisible {
            content
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(Capsule(style: .continuous).fill(Color.primary.opacity(0.1)))
        }
    }
}

/// The hover chip under a chrome glyph; an `isOn` control keeps it.
struct ChromeHoverChip: View {
    let isHovering: Bool
    var isOn = false

    var body: some View {
        RoundedRectangle(cornerRadius: ChromeGlyph.chipRadius, style: .continuous)
            .fill(Color.primary.opacity(isOn ? 0.12 : isHovering ? 0.1 : 0))
    }
}

/// A chrome glyph that pops an `NSMenu` below itself. A real `NSMenu` rather than a SwiftUI
/// `Menu`, because the `+` menu is reshaped by its delegate on every open (a second machine grows
/// the terminal row into a device submenu), and only an `NSMenu` runs that.
struct ChromeMenuButton: View {
    let icon: HugeIcon
    let help: String
    var prominence: ChromeIconButton.Prominence = .glass
    let makeMenu: @MainActor () -> NSMenu
    @State private var anchor = MenuAnchor()

    var body: some View {
        ChromeIconButton(icon: icon, help: help, prominence: prominence) {
            guard let view = anchor.view else { return }
            makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        }
        .background(MenuAnchorView(anchor: anchor))
    }
}

/// The sidebar's own controls, in the titlebar strip above its list: the navigator toggle beside
/// the traffic lights, the workspace name, then sort and `+` at the trailing edge.
struct SidebarControlRow: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var geometry: NavigatorGeometry

    var body: some View {
        HStack(spacing: 2) {
            NavigatorToggleButton.slot
            WorkspaceSwitcherToolbarView()
                .padding(.leading, 6)
            Spacer(minLength: 4)
            ChromeMenuButton(icon: .filter, help: localized("Choose how projects are ordered"),
                             makeMenu: { ProjectSortMenu.make(settings: settings) })
            ChromeMenuButton(icon: .add, help: localized("New terminal or project"),
                             makeMenu: makeNewSessionMenu)
        }
        .padding(.leading, WindowChrome.leadingInset(isFullScreen: store.windowIsFullScreen,
                                                     columnMinX: 0))
        .padding(.trailing, 8)
        .frame(height: WindowChrome.rowHeight)
        .background(WindowDragArea())
        .mask(alignment: .leading) { clearOfWindowControls }
        // Flush with the window's top edge, like the inspector.
        .padding(.top, WindowChrome.inset)
    }

    /// While the column slides, the row passes the toggle and the traffic lights, which stay put.
    /// It goes under a soft edge at the toggle's trailing side instead of under them. At rest the
    /// edge sits in the row's empty slot and hides nothing.
    private var clearOfWindowControls: some View {
        let feather: CGFloat = 6
        let edge = WindowChrome.controlsEnd(isFullScreen: store.windowIsFullScreen) + geometry.sidebarTravel
        return HStack(spacing: 0) {
            Color.clear.frame(width: max(0, edge - feather))
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: feather)
            Color.black
        }
    }
}

/// Shows or hides the navigator. Drawn once, by `NavigatorToggleOverlay`, beside the traffic lights.
struct NavigatorToggleButton: View {
    var body: some View {
        ChromeIconButton(icon: .sidebarLeft, help: localized("Hide or show the navigator"), prominence: .glass) {
            NSApp.sendAction(#selector(AppDelegate.toggleNavigator(_:)), to: nil, from: nil)
        }
    }

    /// The room a row beside the traffic lights keeps for the toggle, which floats over it.
    static var slot: some View {
        Color.clear.frame(width: ChromeGlyph.prominentFrame.width, height: ChromeGlyph.prominentFrame.height)
    }
}

/// Holds the navigator toggle still while the sidebar slides. The toggle belongs to the window, not
/// to the sidebar's row or the top-left card: when either row carried it, collapsing slid the
/// sidebar's copy away with the column and the card's copy appeared beside the traffic lights, so
/// the button jumped. Rex keeps a single toggle on its window container the same way. The rows
/// that pass under it keep an empty `NavigatorToggleButton.slot` instead.
@MainActor
final class NavigatorToggleOverlay {
    private let host: NSHostingView<NavigatorToggleButton>
    private let leading: NSLayoutConstraint
    // Held for the window's lifetime, which is the app's.
    private var observers: Set<AnyCancellable> = []

    init(over container: NSView, store: TermioStore) {
        let host = NSHostingView(rootView: NavigatorToggleButton())
        host.sizingOptions = []
        // The host sits inside the titlebar strip, and SwiftUI otherwise insets its content by the
        // titlebar's safe area: the glyph drew below the traffic lights' line, by however tall
        // AppKit had laid the titlebar out at that moment.
        host.safeAreaRegions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host, positioned: .above, relativeTo: nil)
        let size = ChromeGlyph.prominentFrame
        leading = host.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        NSLayoutConstraint.activate([
            leading,
            host.topAnchor.constraint(equalTo: container.topAnchor,
                                      constant: WindowChrome.rowCenter - size.height / 2),
            host.widthAnchor.constraint(equalToConstant: size.width),
            host.heightAnchor.constraint(equalToConstant: size.height),
        ])
        self.host = host
        // `@Published` sends before the store changes, so each sink takes the new value it is
        // handed rather than reading the store back.
        store.$windowIsFullScreen
            .sink { [weak self] isFullScreen in self?.place(isFullScreen: isFullScreen) }
            .store(in: &observers)
        // A maximized detail fills the window and has no slot for the toggle — unless the
        // sidebar has been brought back over it, whose row keeps one.
        store.$inspectorMaximized.combineLatest(store.$sidebarVisible)
            .sink { [weak host] maximized, sidebarVisible in host?.isHidden = maximized && !sidebarVisible }
            .store(in: &observers)
        // The traffic lights take their place after the window first shows (`TrafficLights`).
        DispatchQueue.main.async { [weak self, weak store] in
            guard let store else { return }
            self?.place(isFullScreen: store.windowIsFullScreen)
        }
    }

    /// Follows the traffic lights, which `TrafficLights` moves after the window first shows and
    /// again whenever AppKit lays them out anew: placed only once, the toggle read their position
    /// from before the first move and sat too far left of the slot the rows keep for it.
    func follow(_ window: NSWindow, store: TermioStore) {
        guard let zoom = window.standardWindowButton(.zoomButton) else { return }
        zoom.postsFrameChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: zoom)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak store] _ in
                guard let store else { return }
                self?.place(isFullScreen: store.windowIsFullScreen)
            }
            .store(in: &observers)
    }

    private func place(isFullScreen: Bool) {
        leading.constant = WindowChrome.leadingInset(isFullScreen: isFullScreen, columnMinX: 0)
    }
}

/// One backdrop behind the whole window: one fixed color under the sidebar, the gaps between the
/// cards and the window's edges alike — the theme's panel color (`panelBackgroundColor`). Only
/// the cards paint a surface of their own, so every section sits on the same ground.
///
/// A plain color, not a vibrancy material: a material follows the window's key state, so the
/// whole ground flipped between the wallpaper-tinted material and flat grey whenever Settings or
/// a sheet took key — and its tint came from the wallpaper rather than the theme.
final class WindowBackdrop: NSView {
    static func install(under container: NSView) -> WindowBackdrop {
        let backdrop = WindowBackdrop(frame: container.bounds)
        backdrop.wantsLayer = true
        backdrop.autoresizingMask = [.width, .height]
        container.addSubview(backdrop, positioned: .below, relativeTo: nil)
        return backdrop
    }

    /// `color` must be already resolved for the window's appearance: a layer keeps the
    /// `CGColor` it was handed and never re-resolves it.
    func paint(_ color: NSColor) {
        layer?.backgroundColor = color.cgColor
    }
}

/// The window's split controller, with a divider that is easy to grab. The divider is a 1pt line
/// that draws nothing (see `SeamlessSplitView`), and AppKit's grab area for a thin divider is
/// barely wider than that. It reaches into the gap beside the cards instead, which is empty
/// ground anyway.
final class CardsSplitViewController: NSSplitViewController {
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        let rect = super.splitView(splitView, effectiveRect: proposedEffectiveRect,
                                   forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        return rect.insetBy(dx: -WindowChrome.inset, dy: 0)
    }

    /// No divider beside a collapsed sidebar. It is the gap between the sidebar and the cards, so
    /// with the sidebar gone it would stand alone at the window's edge, beside the cards' own
    /// margin — twice the gap every other edge has.
    override func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        if dividerIndex == 0, splitViewItems.first?.isCollapsed == true { return true }
        return super.splitView(splitView, shouldHideDividerAt: dividerIndex)
    }
}

/// The window's split view. Its one divider is the gap between the sidebar and the cards — as
/// wide as every other gap — and draws the same grip every divider does (`SashGrip`): a line
/// along it while the pointer is on it or dragging it, and nothing at rest.
final class SeamlessSplitView: NSSplitView {
    private var isHovering = false { didSet { if isHovering != oldValue { needsDisplay = true } } }
    private var isDragging = false { didSet { if isDragging != oldValue { needsDisplay = true } } }
    private var hoverArea: NSTrackingArea?
    private var hoverReveal: DispatchWorkItem?

    /// The divider and the gap beside it that also grabs it (see `CardsSplitViewController`).
    private var dividerArea: NSRect? {
        guard arrangedSubviews.count > 1, !arrangedSubviews[0].isHidden else { return nil }
        return NSRect(x: arrangedSubviews[0].frame.maxX - WindowChrome.inset, y: 0,
                      width: dividerThickness + 2 * WindowChrome.inset, height: bounds.height)
    }

    override var dividerThickness: CGFloat { WindowChrome.inset }

    override func drawDivider(in rect: NSRect) {
        guard isDragging || (isHovering && pointerIsOnDivider) else { return }
        NSColor.labelColor.withAlphaComponent(SashGrip.lineAlpha).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.midX - SashGrip.lineWidth / 2, y: rect.minY,
                                         width: SashGrip.lineWidth, height: rect.height),
                     xRadius: 1, yRadius: 1).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard let divider = dividerArea else { return endHover() }
        let area = NSTrackingArea(rect: divider, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
        // A rebuilt area sends no exit for a pointer it never saw leave — a relayout while the
        // line was up (a click on a card moves focus and relays out) left it lit for good.
        if let window, !divider.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            endHover()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hoverReveal?.cancel()
        // Checked again when the delay ends: AppKit can report an entry the pointer never made
        // (a rebuilt tracking area as the app activates — a `sessions focus` switch did it), and
        // no exit ever follows one, so the line stayed up with the pointer nowhere near it.
        let reveal = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isHovering = self.pointerIsOnDivider
        }
        hoverReveal = reveal
        DispatchQueue.main.asyncAfter(deadline: .now() + SashGrip.hoverDelay, execute: reveal)
    }

    override func mouseExited(with event: NSEvent) { endHover() }

    private var pointerIsOnDivider: Bool {
        guard let window, let divider = dividerArea else { return false }
        return divider.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func endHover() {
        hoverReveal?.cancel()
        hoverReveal = nil
        isHovering = false
    }

    /// AppKit tracks the divider drag inside `mouseDown`, so the line stays up for its length.
    /// Only a press on the divider is a drag: a click nothing inside claimed also bubbles up
    /// here, and lighting the line for it flashed it on every such click.
    override func mouseDown(with event: NSEvent) {
        guard let divider = dividerArea, divider.contains(convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        hoverReveal?.cancel()
        isDragging = true
        super.mouseDown(with: event)
        isDragging = false
        updateTrackingAreas()
    }
}

/// The look every draggable divider shares, after VS Code's sash: nothing at rest, and once the
/// pointer has rested on it (`hoverDelay`) or while dragging it, a line of bright ink along its
/// length. Ink, not an accent hue —
/// Termio marks state in ink. Drawing only: the caller owns the hit area, the cursor and the drag.
struct SashGrip: View {
    enum Axis { case vertical, horizontal }

    static let lineWidth: CGFloat = 2
    static let lineAlpha: CGFloat = 0.5
    /// How long the pointer rests on a divider before its line shows — VS Code's sash delay.
    /// A pointer passing over shows nothing; a drag shows the line at once.
    static let hoverDelay: TimeInterval = 0.3

    /// `.vertical`: the line runs top to bottom, between side-by-side panes.
    let axis: Axis
    let isActive: Bool

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(Self.lineAlpha))
            .frame(width: axis == .vertical ? Self.lineWidth : nil,
                   height: axis == .vertical ? nil : Self.lineWidth)
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(false)
    }
}

/// A divider's hit area, cursor and drag, in AppKit. The resize cursor is a cursor rect, which
/// nothing else in the window can overwrite while the pointer is inside it, and the drag re-sets
/// it on every move. A SwiftUI `onHover` push lost to the terminal and to SwiftUI itself, which
/// reset the cursor on every mouse move — the arrow flickered back on hover and mid-drag, once the
/// pointer ran ahead of the divider onto the terminal and the hover reported itself over.
///
/// `onChange` gets the distance along the drag axis since mouse-down: rightward for a vertical
/// divider, downward for a horizontal one.
struct SashHandle: NSViewRepresentable {
    let axis: SashGrip.Axis
    var onHover: (Bool) -> Void = { _ in }
    var onBegin: () -> Void = {}
    let onChange: (CGFloat) -> Void
    var onEnd: () -> Void = {}
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        if view.axis != axis {
            view.axis = axis
            view.window?.invalidateCursorRects(for: view)
        }
        view.onHover = onHover
        view.onBegin = onBegin
        view.onChange = onChange
        view.onEnd = onEnd
        view.onDoubleClick = onDoubleClick
    }

    final class HandleView: NSView {
        var axis: SashGrip.Axis = .vertical
        var onHover: (Bool) -> Void = { _ in }
        var onBegin: () -> Void = {}
        var onChange: (CGFloat) -> Void = { _ in }
        var onEnd: () -> Void = {}
        var onDoubleClick: (() -> Void)?
        private var dragStart: NSPoint?
        private var hoverArea: NSTrackingArea?
        private var hoverReveal: DispatchWorkItem?

        private var cursor: NSCursor { axis == .vertical ? .resizeLeftRight : .resizeUpDown }

        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverArea { removeTrackingArea(hoverArea) }
            let area = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self)
            addTrackingArea(area)
            hoverArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            hoverReveal?.cancel()
            // Only if the pointer is really here when the delay ends: an entry AppKit reports
            // for a rebuilt tracking area is never followed by an exit.
            let reveal = DispatchWorkItem { [weak self] in
                guard let self, let window = self.window else { return }
                if self.bounds.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                    self.onHover(true)
                }
            }
            hoverReveal = reveal
            DispatchQueue.main.asyncAfter(deadline: .now() + SashGrip.hoverDelay, execute: reveal)
        }

        override func mouseExited(with event: NSEvent) {
            hoverReveal?.cancel()
            hoverReveal = nil
            // Mid-drag the pointer leaves freely; the grip stays lit until the release.
            if dragStart == nil { onHover(false) }
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2, let onDoubleClick {
                onDoubleClick()
                return
            }
            hoverReveal?.cancel()
            dragStart = event.locationInWindow
            cursor.set()
            onBegin()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStart else { return }
            cursor.set()
            let point = event.locationInWindow
            // Window coordinates run bottom-up; a horizontal divider dragged down is positive.
            onChange(axis == .vertical ? point.x - start.x : start.y - point.y)
        }

        override func mouseUp(with event: NSEvent) {
            guard dragStart != nil else { return }
            dragStart = nil
            onEnd()
            if !bounds.contains(convert(event.locationInWindow, from: nil)) { onHover(false) }
        }
    }
}

/// Moves the window from a stretch of chrome nothing else claims — a card header's empty run, the
/// sidebar's control row — the way a titlebar does: drag to move, double-click to zoom. The
/// window itself is not movable by its background, since that also claimed presses meant for the
/// SwiftUI dividers and started a window drag instead of a resize.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}

/// Holds the sidebar's content at its full width while the column slides, so collapsing and
/// expanding move it as one piece instead of squeezing it frame by frame — re-wrapping every row
/// and pushing the row's buttons along. Pinned to the column's trailing edge and clipped there:
/// the content leaves past the window's leading edge the way a stock sidebar does.
final class SidebarSlideController: NSViewController {
    private let content: NSViewController
    private let onTravel: (CGFloat) -> Void

    var holdsWidth = false {
        didSet { (viewIfLoaded as? SlideView)?.holdsWidth = holdsWidth }
    }

    /// The column's width when it last rested open; 0 if it has not been open yet.
    var restingWidth: CGFloat { (viewIfLoaded as? SlideView)?.restingWidth ?? 0 }

    /// `onTravel` hears how far the content has slid past the column's leading edge, on every
    /// layout of the slide.
    init(content: NSViewController, onTravel: @escaping (CGFloat) -> Void) {
        self.content = content
        self.onTravel = onTravel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let slide = SlideView()
        slide.clipsToBounds = true
        addChild(content)
        slide.addSubview(content.view)
        slide.content = content.view
        slide.onTravel = onTravel
        view = slide
    }

    private final class SlideView: NSView {
        weak var content: NSView?
        var onTravel: ((CGFloat) -> Void)?
        /// The column's width when it last rested open: what the content keeps while it slides.
        private(set) var restingWidth: CGFloat = 0
        var holdsWidth = false { didSet { needsLayout = true } }

        override func layout() {
            super.layout()
            guard let content else { return }
            if !holdsWidth, bounds.width > 0 { restingWidth = bounds.width }
            let width = holdsWidth ? max(restingWidth, bounds.width) : bounds.width
            content.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
            onTravel?(width - bounds.width)
        }
    }
}

/// The sort pull-down: one entry per `ProjectSortOrder`, the active one checked.
@MainActor
enum ProjectSortMenu {
    static func make(settings: AppSettings) -> NSMenu {
        let menu = NSMenu()
        for order in ProjectSortOrder.allCases {
            let item = NSMenuItem(title: order.displayName, action: #selector(Target.choose(_:)), keyEquivalent: "")
            item.target = Target.shared
            item.representedObject = order.rawValue
            item.state = order == settings.projectSortOrder ? .on : .off
            menu.addItem(item)
        }
        Target.shared.settings = settings
        return menu
    }

    @MainActor
    private final class Target: NSObject {
        static let shared = Target()
        weak var settings: AppSettings?

        @objc func choose(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                  let order = ProjectSortOrder(rawValue: raw) else { return }
            settings?.projectSortOrder = order
        }
    }
}
