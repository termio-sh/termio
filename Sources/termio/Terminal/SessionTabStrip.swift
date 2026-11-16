import AppKit
import SwiftUI
import TermioShared

/// The horizontal layout's tabs: the selected group's sessions in a row above the cards, as
/// Safari shows a tab group's tabs. A tab is a split group or a lone session; its mark carries the
/// same status the sidebar row would — working, waiting on you, finished — so an agent that needs
/// you is visible from any tab.
///
/// The strip takes the window's top row, centred on the traffic lights' line. With the sidebar
/// collapsed it also carries the navigator toggle and a menu of the groups, so every group stays
/// one click away.
struct SessionTabStrip: View {
    @EnvironmentObject var store: TermioStore
    /// The tab pressed, from mouse-down to mouse-up, whether or not it is ever dragged.
    @State private var press: TabDrag?
    /// The tab under the pointer while it is dragged along the strip.
    @State private var drag: TabDrag?
    /// A dropped tab's distance from its new slot, eased to zero after the drop.
    @State private var settle: TabSettle?
    /// The tab under the pointer, as the strip's tracker reports it.
    @State private var hoveredIndex: Int?

    /// Fixed at the press: which tab, from where, in which group. The roster can change under a
    /// drag (a session closes, the workspace switches), and the drop checks it still holds.
    private struct TabDrag {
        let ids: [Session.ID]
        let origin: Int
        let count: Int
        let group: TabGroup
        var translation: CGFloat
    }

    private struct TabSettle {
        let ids: [Session.ID]
        var offset: CGFloat
    }

    /// How fast the other tabs make room, and the dropped tab settles: Safari's is short and
    /// does not overshoot, so neither does this.
    private static let reflow = Animation.smooth(duration: 0.2)

    var body: some View {
        let group = store.selectedSessionID.flatMap(store.group(of:))
        HStack(spacing: 4) {
            if !store.sidebarVisible {
                ChromeMenuButton(icon: .cardStack, help: localized("Groups"), makeMenu: groupMenu)
            }
            if let group {
                // Safari's sizing: the tabs share the strip's width equally, so one or two fill it.
                // Past the point where a share drops under `SessionTab.minimumWidth` they stop
                // shrinking and scroll instead, the selected one kept in view.
                let tabs = store.tabs(in: group)
                let activeIndex = tabs.firstIndex { store.selectedSessionID.map($0.contains) ?? false }
                GeometryReader { geometry in
                    let tabWidth = SessionTab.width(sharing: geometry.size.width, count: tabs.count)
                    // A tab and the divider after it: the distance a neighbour moves to make room.
                    let slot = tabWidth + 1
                    ScrollViewReader { scroller in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 0) {
                                ForEach(Array(tabs.enumerated()), id: \.element) { index, ids in
                                    if index > 0 {
                                        // No divider beside the selected pill: its own edge parts it.
                                        // None at all mid-drag: they stay put while the tabs move.
                                        TabDivider(hidden: drag != nil
                                                   || activeIndex == index || activeIndex == index - 1)
                                    }
                                    let isDragged = drag?.ids == ids
                                    SessionTab(ids: ids, width: tabWidth, isLifted: isDragged,
                                               isHovering: drag == nil && hoveredIndex == index)
                                        .id(ids.first)
                                        .offset(x: offset(of: index, ids: ids, count: tabs.count, slot: slot))
                                        .zIndex(isDragged ? 1 : 0)
                                        // The dragged tab is under the pointer, 1:1; only its
                                        // neighbours animate as they make room.
                                        .transaction { if isDragged { $0.animation = nil } }
                                }
                            }
                            .padding(.vertical, 2)
                            .padding(.horizontal, 3)
                            // One container behind the whole row takes the pointer for every tab.
                            // It never moves and is never rebuilt while a tab is dragged, which a
                            // tab of its own is: the press stays with the view it began on.
                            .background(TabStripTracker(
                                titles: tabs.map { $0.first.flatMap(store.session).map(store.displayTitle(for:)) ?? "" },
                                slot: slot, leading: 3,
                                onHover: { hoveredIndex = $0 },
                                menu: { index in
                                    tabs.indices.contains(index) ? sidebarMenu(tabMenuItems(for: tabs[index])) : nil
                                },
                                onPress: { index in
                                    guard tabs.indices.contains(index) else { return }
                                    settle = nil
                                    press = TabDrag(ids: tabs[index], origin: index, count: tabs.count,
                                                    group: group, translation: 0)
                                },
                                onDrag: { travel in
                                    dragMoved(travel: travel, count: tabs.count, slot: slot, group: group)
                                },
                                onRelease: { dragged in
                                    if dragged {
                                        dropped(count: tabs.count, slot: slot, group: group)
                                    } else if let pressed = press,
                                              isCurrent(pressed, count: tabs.count, group: group),
                                              let first = pressed.ids.first,
                                              !(store.selectedSessionID.map(pressed.ids.contains) ?? false) {
                                        // Opens the tab on its first card.
                                        store.selectedSessionID = first
                                    }
                                    press = nil
                                }))
                        }
                        // Scrolled-off tabs end at the strip's own rounded edge instead of drawing
                        // on past it, under the controls beside it.
                        .clipShape(Capsule(style: .continuous))
                        .background(TabTrackGlass().allowsHitTesting(false))
                        .onChange(of: store.selectedSessionID, initial: true) { _, selected in
                            guard let tab = tabs.first(where: { selected.map($0.contains) ?? false }) else { return }
                            scroller.scrollTo(tab.first)
                        }
                    }
                }
                .frame(height: SessionTab.height + 4)
            }
            ChromeIconButton(icon: .add, help: localized("New Terminal"), prominence: .glass) {
                store.addTerminalHere()
            }
            if group == nil { Spacer(minLength: 0) }
        }
        .frame(height: WindowChrome.rowHeight)
        .background(WindowDragArea())
    }

    /// Safari's tab drag: past a few points of travel the tab leaves its slot and follows the
    /// pointer along the strip. Once its centre crosses a neighbour's, that neighbour slides
    /// into the slot it left. `travel` is measured by the strip's tracker in its own space, which
    /// neither the tab's offset nor a scroll of the strip can pull out from under the pointer.
    /// The pressed tab is not selected: selecting scrolls it into view, mid-drag.
    private func dragMoved(travel: CGFloat, count: Int, slot: CGFloat, group: TabGroup) {
        guard var next = drag ?? press else { return }
        // The first move checks the press still describes the row: a tab that closed while the
        // button was held would leave the pressed index pointing at a different tab.
        if drag == nil, !isCurrent(next, count: count, group: group) {
            press = nil
            return
        }
        let previous = drag.map { target(of: $0, count: count, slot: slot) }
        next.translation = travel
        if previous != target(of: next, count: count, slot: slot) {
            withAnimation(Self.reflow) { drag = next }
        } else {
            drag = next
        }
    }

    /// Whether `snapshot`, taken at the press, still names the same tab in the same row.
    private func isCurrent(_ snapshot: TabDrag, count: Int, group: TabGroup) -> Bool {
        snapshot.group == group && snapshot.count == count
            && store.tabs(in: group).firstIndex(of: snapshot.ids) == snapshot.origin
    }

    /// On release the order is committed and the tab eases from where it was let go into its
    /// new slot.
    private func dropped(count: Int, slot: CGFloat, group: TabGroup) {
        guard let ended = drag else { return }
        // The row the drag began on is gone (a session came or went, or the workspace changed):
        // committing an index into it would move some other tab, so the drag is dropped instead.
        guard isCurrent(ended, count: count, group: group) else {
            withAnimation(Self.reflow) { drag = nil }
            return
        }
        let destination = target(of: ended, count: count, slot: slot)
        let residual = clamped(ended, count: count, slot: slot)
            - CGFloat(destination - ended.origin) * slot
        // One frame with no animation: the roster changes, the neighbours' make-room offsets
        // drop to zero, and the tab sits in its new slot still at the release point. Nothing on
        // screen moves in that frame.
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            store.moveTab(at: ended.origin, to: destination, in: group)
            drag = nil
            settle = TabSettle(ids: ended.ids, offset: residual)
        }
        DispatchQueue.main.async {
            withAnimation(Self.reflow) {
                settle?.offset = 0
            } completion: {
                if settle?.offset == 0 { settle = nil }
            }
        }
    }

    /// The dragged tab's travel, kept within the strip's ends.
    private func clamped(_ drag: TabDrag, count: Int, slot: CGFloat) -> CGFloat {
        let lowest = -CGFloat(drag.origin) * slot
        let highest = CGFloat(count - 1 - drag.origin) * slot
        return min(max(drag.translation, lowest), highest)
    }

    /// The slot the dragged tab would drop into: the nearest one to its centre.
    private func target(of drag: TabDrag, count: Int, slot: CGFloat) -> Int {
        guard slot > 0 else { return drag.origin }
        let moved = Int((clamped(drag, count: count, slot: slot) / slot).rounded())
        return min(max(drag.origin + moved, 0), count - 1)
    }

    /// Where the tab at `index` is drawn relative to its slot: under the pointer while dragged,
    /// one slot over while it makes room, easing home after a drop.
    private func offset(of index: Int, ids: [Session.ID], count: Int, slot: CGFloat) -> CGFloat {
        if let drag {
            if drag.ids == ids { return clamped(drag, count: count, slot: slot) }
            let destination = target(of: drag, count: count, slot: slot)
            if drag.origin < index, index <= destination { return -slot }
            if destination <= index, index < drag.origin { return slot }
            return 0
        }
        if let settle, settle.ids == ids { return settle.offset }
        return 0
    }

    /// A tab's right-click menu: its session's sidebar menu. A split group's tab acts on its first
    /// session, the one whose title and icon the tab shows.
    private func tabMenuItems(for tab: [Session.ID]) -> [SidebarMenuItem] {
        tab.first.flatMap(store.session).map { sessionMenuItems(store: store, session: $0) } ?? []
    }

    /// Every group, the current one checked — the collapsed sidebar's list, as a menu.
    private func groupMenu() -> NSMenu {
        let menu = NSMenu()
        let current = store.selectedSessionID.flatMap(store.group(of:))
        for group in store.sessionGroups {
            let item = ClosureMenuItem(title: store.title(of: group)) { store.open(group) }
            item.state = group == current ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
}

/// A thin rule between two tabs, hidden beside the selected one.
private struct TabDivider: View {
    let hidden: Bool

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(width: 1, height: 14)
            .opacity(hidden ? 0 : 1)
    }
}

/// The track the tabs sit in, as Terminal's tab bar has one: a translucent face a step fainter
/// than the selected tab's, so the row reads as one control. No edge of its own: the selected
/// pill carries the strip's only hairline and rim, and a second outline around it read as clutter.
private struct TabTrackGlass: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Capsule(style: .continuous)
            .fill(Color.white.opacity(colorScheme == .dark ? 0.035 : 0.28))
    }
}

/// The selected tab's pill, the brightest glass in the strip: the other tabs sit on the track.
/// `SelectionGlass` rather than the system `glassEffect`, which floats its capsule on a drop
/// shadow that read as a raised button rather than a pane of glass.
private struct SelectedTabGlass: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.background(SelectionGlass(shape: Capsule(style: .continuous)))
        } else {
            content
        }
    }
}

/// A session's mark in a rounded tile — the tab's icon. A split group fans its members' tiles out
/// behind the first, like a hand of cards, so a tab that opens several cards says so at a glance.
private struct TabIconStack: View {
    @EnvironmentObject var store: TermioStore
    let ids: [Session.ID]
    let status: SessionStatus

    private static let tile: CGFloat = 20
    /// Each tile behind the first sits this much further right and turns this much further,
    /// pivoting on its bottom edge.
    private static let fanOffset: CGFloat = 5
    private static let fanAngle: Double = 10

    /// One fanned tile: which session, and how far back in the fan it sits (0 is the front).
    private struct Fanned: Identifiable {
        let id: Session.ID
        let depth: Int
    }

    /// Back to front, so the first session's tile is drawn last — on top, upright.
    private var fanned: [Fanned] {
        let shown = Array(ids.prefix(3))
        return shown.indices.reversed().map { Fanned(id: shown[$0], depth: $0) }
    }

    private var width: CGFloat {
        let behind = CGFloat(min(ids.count, 3) - 1)
        return Self.tile + behind * Self.fanOffset + (behind > 0 ? 3 : 0)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(fanned) { tile in
                fannedTile(tile)
            }
        }
        .frame(width: width, height: Self.tile, alignment: .leading)
        .overlay(alignment: .leading) {
            StatusDot(status: status).frame(width: Self.tile, height: Self.tile)
        }
    }

    private func fannedTile(_ fanned: Fanned) -> some View {
        let depth = CGFloat(fanned.depth)
        return tile(for: fanned.id, isLead: fanned.depth == 0)
            .rotationEffect(.degrees(Double(fanned.depth) * Self.fanAngle), anchor: .bottom)
            .offset(x: depth * Self.fanOffset)
    }

    @ViewBuilder
    private func tile(for id: Session.ID, isLead: Bool) -> some View {
        ZStack {
            GlassTile()
            if isLead, status == .working {
                WorkingIndicator(tint: .sidebarWorkingInk)
                    .frame(width: 12, height: 12)
            } else if let session = store.session(id) {
                AgentIconView(agent: store.effectiveAgent(for: session), size: 12)
            }
        }
        .frame(width: Self.tile, height: Self.tile)
    }
}

/// An app-icon tile drawn as glass: an opaque base so fanned tiles hide the ones behind them,
/// a sheen that fades down the face, and a rim lit at the top edge and dark at the bottom.
struct GlassTile: View {
    /// 6 suits the 20pt session tile; a larger tile wants a proportionally rounder
    /// corner or it reads as a square with nicked edges.
    var cornerRadius: CGFloat = 6
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = colorScheme == .dark
        shape
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay(
                shape.fill(LinearGradient(
                    colors: [.white.opacity(dark ? 0.20 : 0.9), .white.opacity(dark ? 0.04 : 0.35)],
                    startPoint: .top, endPoint: .bottom)))
            // The light face falls off toward the bottom, over the sheen. The sheen
            // and the lit rim are white, and on a white base — Settings' sidebar, a
            // light theme's tab strip — they had nothing to be brighter than, so the
            // tile read as a flat paper chip with a hairline. Dark needs no falloff:
            // white already stands off a dark base.
            .overlay(shape.fill(LinearGradient(
                colors: [.black.opacity(0), .black.opacity(dark ? 0 : 0.13)],
                startPoint: .top, endPoint: .bottom)))
            .overlay(
                shape.strokeBorder(LinearGradient(
                    stops: [
                        .init(color: .white.opacity(dark ? 0.55 : 1), location: 0),
                        .init(color: .white.opacity(dark ? 0.10 : 0.5), location: 0.45),
                        .init(color: .white.opacity(dark ? 0.22 : 0.7), location: 1),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75))
            .overlay(shape.strokeBorder(Color.black.opacity(dark ? 0.45 : 0.14), lineWidth: 0.5).padding(-0.5))
            // A hard 1pt drop, not `.shadow`: a blurred shadow costs an offscreen pass per tile,
            // and the sidebar draws dozens of these while it scrolls.
            .background(shape.fill(Color.black.opacity(dark ? 0.35 : 0.12)).offset(y: 1))
    }
}

private struct SessionTab: View {
    @EnvironmentObject var store: TermioStore
    let ids: [Session.ID]
    let width: CGFloat
    /// Being dragged along the strip: it keeps its hover fill, so a tab that is not the selected
    /// pill still reads as a piece being moved rather than a label sliding over the others.
    var isLifted = false
    var isHovering = false
    @State private var isOverClose = false

    static let height: CGFloat = 26
    static let minimumWidth: CGFloat = 120

    /// One tab's share of a strip `available` wide: the strip less its end padding and the 1pt
    /// dividers between tabs, split evenly, but never under `minimumWidth`.
    static func width(sharing available: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return minimumWidth }
        let room = available - 6 - CGFloat(count - 1)
        return max(minimumWidth, (room / CGFloat(count)).rounded(.down))
    }

    private var isActive: Bool { store.selectedSessionID.map(ids.contains) ?? false }

    var body: some View {
        let lead = ids.first.flatMap(store.session)
        let title = lead.map(store.displayTitle(for:)) ?? ""
        // Only a lone session closes from its tab: a split group's tab holds several, and which
        // one an × meant would be a guess.
        let closable = ids.count == 1 ? lead : nil
        HStack(spacing: 8) {
            TabIconStack(ids: ids, status: store.combinedStatus(of: ids))
            Text(title)
                .font(.system(size: 13, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if closable != nil {
                Color.clear.frame(width: 18, height: 18)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .frame(width: width, height: Self.height)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(!isActive && (isHovering || isLifted) ? 0.06 : 0)))
        .modifier(SelectedTabGlass(isActive: isActive))
        // Picture only: the strip's tracker behind the row takes every press but the ×'s.
        .allowsHitTesting(false)
        .overlay(alignment: .trailing) {
            if let closable {
                Button { store.requestCloseSession(closable.id) } label: {
                    HugeIconView(icon: .close, size: 10, color: .secondary)
                        .frame(width: 18, height: 18)
                        .background(CloseHoverDisc(isHovering: isOverClose, diameter: 18))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isOverClose = $0 }
                .help(localized("Close Session"))
                .opacity(isHovering ? 1 : 0)
                .padding(.trailing, 6)
            }
        }
    }
}

/// The tab row's mouse handling, for every tab at once: hover, click and drag. The strip sits on
/// the titlebar row, where a press the window receives becomes a window move, so the press is
/// taken before the window sees it, by local event monitors, the way the cards' grab handle takes
/// its own (`PaneDragRearrange`). Which tab a press is on is plain arithmetic on the row: the tabs
/// are `slot` apart from `leading`.
private struct TabStripTracker: NSViewRepresentable {
    /// Each tab's title, in order: the count of tabs, and the tooltip over each.
    let titles: [String]
    let slot: CGFloat
    let leading: CGFloat
    let onHover: (Int?) -> Void
    /// The right-click menu of the tab at an index.
    let menu: (Int) -> NSMenu?
    let onPress: (Int) -> Void
    let onDrag: (CGFloat) -> Void
    /// Whether the press became a drag.
    let onRelease: (Bool) -> Void

    func makeNSView(context: Context) -> TrackerView { TrackerView() }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.titles = titles
        view.slot = slot
        view.leading = leading
        view.onHover = onHover
        view.tabMenu = menu
        view.onPress = onPress
        view.onDrag = onDrag
        view.onRelease = onRelease
    }

    final class TrackerView: NSView, NSViewToolTipOwner {
        var titles: [String] = [] { didSet { if titles != oldValue { needsLayout = true } } }
        var slot: CGFloat = 0 { didSet { if slot != oldValue { needsLayout = true } } }
        var leading: CGFloat = 0
        var onHover: (Int?) -> Void = { _ in }
        var tabMenu: (Int) -> NSMenu? = { _ in nil }
        var onPress: (Int) -> Void = { _ in }
        var onDrag: (CGFloat) -> Void = { _ in }
        var onRelease: (Bool) -> Void = { _ in }
        private var press: (index: Int, at: NSPoint)?
        private var isDragging = false
        private var hoverArea: NSTrackingArea?

        /// How far the pointer travels before a press stops being a click.
        private static let dragThreshold: CGFloat = 4
        private static var monitors: [Any] = []
        /// The strip the pointer last moved over, which a scroll resamples even when the pointer
        /// sits on a tab's ×, where the press hit test finds the button instead.
        private static weak var hovering: TrackerView?
        private static weak var active: TrackerView?

        override var mouseDownCanMoveWindow: Bool { false }

        /// The row's claim on the titlebar strip. Under a transparent titlebar AppKit decides a
        /// window move from this private hook, not from `mouseDownCanMoveWindow`: without it the
        /// window server moved the window for a press on a tab while the tab got the same drag.
        /// `NSButton` claims its rect the same way, as do Chromium's tabs (`tab_view.mm`) and
        /// Firefox's; if a release drops the hook, this is never called and nothing breaks.
        @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect { bounds }

        /// The tab under `point`, in window coordinates.
        func index(at point: NSPoint) -> Int? {
            let x = convert(point, from: nil).x - leading
            guard slot > 0, x >= 0, bounds.contains(convert(point, from: nil)) else { return nil }
            let index = Int(x / slot)
            return index < titles.count ? index : nil
        }

        /// The tabs' tooltips, which the tabs cannot carry themselves: they take no pointer events.
        override func layout() {
            super.layout()
            removeAllToolTips()
            for (index, title) in titles.enumerated() where !title.isEmpty {
                let rect = NSRect(x: leading + CGFloat(index) * slot, y: 0, width: slot, height: bounds.height)
                addToolTip(rect.intersection(bounds), owner: self, userData: nil)
            }
        }

        // `addToolTip` keeps no reference to its owner, so the tracker answers for every tab
        // rather than handing over a string nothing holds.
        func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                  userData data: UnsafeMutableRawPointer?) -> String {
            index(at: convert(point, to: nil)).map { titles[$0] } ?? ""
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverArea { removeTrackingArea(hoverArea) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self)
            addTrackingArea(area)
            hoverArea = area
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            visibleIndex(at: event.locationInWindow).flatMap(tabMenu)
        }

        override func mouseEntered(with event: NSEvent) { hovered(event) }
        override func mouseMoved(with event: NSEvent) { hovered(event) }

        override func mouseExited(with event: NSEvent) {
            // Mid-drag the tab follows the pointer wherever it goes; hover resumes on release.
            if press == nil { onHover(nil) }
        }

        private func hovered(_ event: NSEvent) {
            Self.hovering = self
            if press == nil { onHover(visibleIndex(at: event.locationInWindow)) }
        }

        /// The tab under `point` only where the strip shows it: a scrolled-off tab is still in
        /// the tracker's bounds, but nobody is pointing at it.
        private func visibleIndex(at point: NSPoint) -> Int? {
            visibleRect.contains(convert(point, from: nil)) ? index(at: point) : nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, Self.monitors.isEmpty else { return }
            func monitor(_ mask: NSEvent.EventTypeMask, _ handler: @escaping @MainActor (NSEvent) -> Bool) {
                let installed = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
                    nonisolated(unsafe) let event = event
                    let consumed = MainActor.assumeIsolated { handler(event) }
                    return consumed ? nil : event
                }
                if let installed { Self.monitors.append(installed) }
            }
            monitor(.leftMouseDown) { event in
                guard let tracker = Self.tracker(under: event),
                      let index = tracker.index(at: event.locationInWindow) else { return false }
                // A control-click is a right-click: the menu, not a press.
                if event.modifierFlags.contains(.control) {
                    if let menu = tracker.tabMenu(index) {
                        NSMenu.popUpContextMenu(menu, with: event, for: tracker)
                    }
                    return true
                }
                Self.active = tracker
                tracker.pressed(index, event)
                return true
            }
            monitor(.leftMouseDragged) { event in
                guard let tracker = Self.active else { return false }
                tracker.moved(event)
                return true
            }
            // A scroll moves the strip under a still pointer; read the pointer again once the
            // scroll has landed, so a dragged tab stays under it and hover follows the tab now
            // there. Momentum arrives as scroll events too.
            monitor(.scrollWheel) { event in
                guard let tracker = Self.active ?? Self.tracker(under: event) ?? Self.hovering,
                      tracker.window === event.window else { return false }
                DispatchQueue.main.async { tracker.resample() }
                return false
            }
            monitor(.leftMouseUp) { event in
                guard let tracker = Self.active else { return false }
                Self.active = nil
                tracker.released(event)
                return true
            }
        }

        /// The tracker the window would deliver this press to. A press on a tab's × lands on the
        /// button above the tracker, so it is left alone.
        private static func tracker(under event: NSEvent) -> TrackerView? {
            guard let frameView = event.window?.contentView?.superview else { return nil }
            return frameView.hitTest(frameView.convert(event.locationInWindow, from: nil)) as? TrackerView
        }

        private func pressed(_ index: Int, _ event: NSEvent) {
            press = (index, convert(event.locationInWindow, from: nil))
            isDragging = false
            onPress(index)
        }

        private func resample() {
            guard let window else { return }
            let pointer = window.mouseLocationOutsideOfEventStream
            if let press {
                if isDragging { onDrag(convert(pointer, from: nil).x - press.at.x) }
            } else {
                onHover(visibleIndex(at: pointer))
            }
        }

        private func moved(_ event: NSEvent) {
            guard let press else { return }
            // The tracker's own space: it sits still under the tabs (its own would chase the
            // pointer) and scrolls with them, so a strip that scrolls mid-drag is counted too.
            let point = convert(event.locationInWindow, from: nil)
            if !isDragging {
                guard abs(point.x - press.at.x) >= Self.dragThreshold
                    || abs(point.y - press.at.y) >= Self.dragThreshold else { return }
                isDragging = true
            }
            onDrag(point.x - press.at.x)
        }

        private func released(_ event: NSEvent) {
            guard let press else { return }
            // The drop is placed from where the pointer is now, in case the strip scrolled since
            // the last move.
            if isDragging { onDrag(convert(event.locationInWindow, from: nil).x - press.at.x) }
            self.press = nil
            let dragged = isDragging
            isDragging = false
            onRelease(dragged)
            onHover(visibleIndex(at: event.locationInWindow))
        }
    }
}
