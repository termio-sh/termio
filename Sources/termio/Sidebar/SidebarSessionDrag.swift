import AppKit
import SwiftUI
import TermioShared

/// A session dragged over a sidebar row. The row's top and bottom thirds ask
/// `sessionRowDropAnswer` whether the gap moves there, a group is joined there, or
/// the pointer is resting on the row; resting for `groupDwell` stacks onto it and
/// groups the two. The gap is always where a release lands (`sidebarOrder` draws it).
///
/// Thirds rather than quarters because a session row is short: at the row heights
/// the interface padding produces, a quarter band is a few points tall.
///
/// A `DropDelegate` rather than a `dropDestination`, for the reason the panes' one
/// is: only `dropUpdated` carries the pointer, and `isTargeted:` is a Bool.
private struct SessionRowDropDelegate: DropDelegate {
    let session: Session.ID
    /// Which appearance of the session this is, for the floating copy to stack onto.
    let place: UUID
    let height: CGFloat
    let store: TermioStore

    /// Every row takes a dragged session, including one from another project or
    /// worktree: refused there, the drop fell through to the sidebar's own target and
    /// committed the gap left in the drag's own list. Over such a row the preview is
    /// withdrawn instead (`track`), so a release there changes nothing.
    func validateDrop(info: DropInfo) -> Bool {
        store.resolveDraggedSession() != nil
    }

    func dropEntered(info: DropInfo) {
        store.resolveDraggedSession()
        track(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        track(info)
        return DropProposal(operation: .move)
    }

    /// Leaving a row keeps the gap where it is: the pointer is crossing into the
    /// next row, and snapping the rows back between the two would make them jitter.
    /// A hold that has not armed ends; one that has stays, because arming moves the
    /// gap under the pointer and so moves the pointer off this row by itself.
    func dropExited(info: DropInfo) {
        if store.sessionGroupDwell?.row == session {
            store.cancelSessionGroupDwell(keepingTarget: true)
        }
        // Off its own slot, a snapped row lets go even where no other row reports in.
        if store.draggingSessionID == session { store.leaveOwnSlot() }
    }

    func performDrop(info: DropInfo) -> Bool {
        store.commitSessionRowDrop()
    }

    private func track(_ info: DropInfo) {
        guard let moved = store.draggingSessionID, height > 0 else { return }
        // Over the gap itself: nothing to move, and a group that armed stays armed.
        guard moved != session else {
            store.cancelSessionGroupDwell(keepingTarget: true)
            store.restOnOwnSlot()
            return
        }
        store.leaveOwnSlot()
        guard store.canReorder(moved, relativeTo: session) else {
            store.withdrawSessionRowPreview()
            return
        }
        let third = height / 3
        let edge: TermioStore.RowInsertion? = info.location.y < third ? .above
            : info.location.y > height - third ? .below : nil
        if let edge {
            let drop = TermioStore.SessionRowDrop(row: session, insert: edge)
            switch store.sessionRowDropAnswer(drop) {
            case .move:
                store.previewSessionRowDrop(drop)
                return
            case .join:
                store.previewSessionRowJoin(drop, place: place)
                return
            case .rest:
                break
            }
        }
        if store.canGroup(moved, with: session), !store.sharesSplitGroup(moved, session) {
            store.beginSessionGroupDwell(on: session, place: place)
        } else {
            // Resting on a row it cannot group with: any group armed elsewhere is off.
            store.cancelSessionGroupDwell()
        }
    }
}

/// The whole sidebar's drop target, behind the rows': what a session dragged over
/// anything that is not a session row answers to. It keeps the gap where the rows
/// last opened it, and a release there commits it.
struct SidebarListDropDelegate: DropDelegate {
    let store: TermioStore

    func validateDrop(info: DropInfo) -> Bool {
        store.resolveDraggedSession() != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        store.leaveOwnSlot()
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        store.commitSessionRowDrop()
    }
}

/// The drag and drop a session row carries: lift the whole row to reorder or
/// group it, and accept another row landing on it.
///
/// A modifier rather than a stretch of `SessionRow`'s chain because a row has two
/// bodies — the live one and `EndedSessionRow` — and only the live one used to
/// carry this. A session the device buried still holds its slot in the roster and
/// still opens when clicked, so it stayed reorderable in the context menu while
/// silently refusing every drag: the gesture went missing with the view swap, which
/// nobody decided. One modifier is what keeps the two bodies from drifting again.
struct SessionRowDragAndDrop: ViewModifier {
    @EnvironmentObject var store: TermioStore
    let session: Session
    /// The row content's leading inset, handed to the floating copy of the row.
    let leading: CGFloat
    /// Measured, not assumed: the drop zones are fractions of the row, and row
    /// height follows the interface row padding.
    @State private var rowHeight: CGFloat = 0
    /// This appearance of the session, which a pinned worktree can show twice.
    @State private var place = UUID()

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            // Drag the whole row to reorder it within its bucket (no handle). Uses
            // `.onDrag` (AppKit's drag session) rather than `.draggable` (SwiftUI's): a
            // SwiftUI drag settles its preview over ~0.3s on release, while an AppKit drag
            // image just vanishes on a successful drop — so the row moves crisply. The
            // drag only carries the session id; nothing reorders until the drop commits
            // it (see the drop below). It starts at all only because selection rides a
            // *simultaneous* tap (in the row) — an exclusive `.onTapGesture` kills the drag.
            .onDrag {
                store.sessionDragLeading = leading
                store.sessionDragSource = place
                store.draggingSessionID = session.id
                // The payload is the session's canonical deep link, not a private
                // token: a drag carries plain text, so any text target — a terminal,
                // an editor, a text field — will accept it. Shipping the link means a
                // stray drop pastes something that works (`termio://session/<uuid>`,
                // what `termio session` takes) instead of leaking an internal id.
                // A pane recognises one of these rows by parsing that link back off the
                // drag pasteboard (see `TermioStore.resolveDraggedSession`), so plain
                // text is the whole payload: SwiftUI rebuilds the item provider on the
                // receiving side, and a private type registered here would not survive
                // the trip.
                return NSItemProvider(object: store.sessionLink(for: session) as NSString)
            } preview: {
                // Nothing: the system draws a drag image at its own scale, translucent and
                // blurred, so the row in your hand is drawn by the sidebar instead
                // (`SidebarDragOverlay`), at the row's own size and in its glass. Over the
                // cards the pane's drop wash is what says where it lands.
                Color.clear.frame(width: 1, height: 1)
            }
            // A row answers a dragged session two ways: its far third moves the gap past
            // it, and resting on the rest of it groups the two (`SessionRowDropDelegate`).
            // One gesture does both without a modifier.
            //
            // The height comes off the row itself because the zones are fractions of it;
            // rows grow with the interface row padding, so a fixed band would drift.
            //
            // `onGeometryChange`, not a `GeometryReader` background: the reader wrote
            // the row height from `onAppear`/`onChange` *inside* the layout pass, and a
            // column of rows mounting at once turned that into reentrant NSTableView
            // layout — AppKit warns, and a cold switch into a large workspace spent
            // seconds re-laying the List (docs/bug/main-thread-beachball-sidebar-layout.md).
            // `onGeometryChange` delivers the same height with the write deferred out
            // of the update.
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                // A row's window frame changes every frame the rows slide; its height does not,
                // and an unchanged write would still re-render the row.
                if rowHeight != frame.height { rowHeight = frame.height }
                store.sessionRowFrames[place] = frame
            }
            .onDisappear { store.sessionRowFrames[place] = nil }
            .onDrop(of: [.text], delegate: SessionRowDropDelegate(
                session: session.id, place: place, height: rowHeight, store: store))
    }
}

/// The row in your hand, drawn over the sidebar: the row's own size, icon and title on the
/// selection's glass, following the pointer up and down the column 1:1. On a drop it eases
/// into the slot the rows made for it, and the real row shows once it lands.
///
/// Drawn here rather than as the system drag image, which macOS scales down, fades and blurs.
/// It reads the pointer each frame of the drag (`TimelineView`) rather than through the store,
/// because a store write at pointer rate redraws every view observing it.
struct SidebarDragOverlay: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject private var sidebarDrag: SidebarDragState
    @State private var pointer = PointerAnchor.Box()
    @State private var frame: CGRect = .zero
    /// Where a settling row eases to, in the overlay's space; set once the slot is laid out.
    @State private var settleTop: CGFloat?

    /// A stacked tile's place on the target's icon: the tab strip's fan (`TabIconStack`).
    private static let fanOffset: CGFloat = 5
    private static let fanAngle: Double = 10

    var body: some View {
        let lifted = store.draggingSessionID ?? sidebarDrag.settling
        ZStack(alignment: .topLeading) {
            PointerAnchor(box: pointer)
            if let lifted, let session = store.session(lifted) {
                TimelineView(.animation(paused: store.draggingSessionID == nil)) { _ in
                    let _ = store.noticeSessionDragFrame()
                    floatingRow(session)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { newFrame in
            frame = newFrame
        }
        // A drag of the same row later takes its own grab, not this one's.
        .onChange(of: lifted == nil) { _, ended in
            if ended { pointer.release() }
        }
        .onChange(of: sidebarDrag.settling) { _, settling in
            guard let settling else {
                settleTop = nil
                return
            }
            // The next turn: the roster changed with the drop, and the slot's frame is
            // written when the rows have laid out.
            DispatchQueue.main.async {
                guard let source = store.sessionDragSource, let slot = store.sessionRowFrames[source] else {
                    sidebarDrag.settling = nil
                    return
                }
                withAnimation(TermioStore.rowReflow) {
                    settleTop = slot.minY - frame.minY
                } completion: {
                    if sidebarDrag.settling == settling { sidebarDrag.settling = nil }
                }
            }
        }
    }

    /// Out of the column, over the cards or past its top or bottom, a group armed or a snap
    /// made in the sidebar is off: a card is advertising its own drop, and the bracket and
    /// stacked icon would contradict it. No drop delegate says the pointer left the column,
    /// so the frame that draws the row does. Deferred: this runs while the view draws.
    private func leaveGroupOutsideColumn(_ location: CGPoint) {
        guard !(0...frame.width).contains(location.x) || !(0...frame.height).contains(location.y),
              sidebarDrag.groupTarget != nil || sidebarDrag.arming != nil
                || sidebarDrag.snapped || store.slotRest != nil
        else { return }
        DispatchQueue.main.async {
            store.cancelSessionGroupDwell()
            store.leaveOwnSlot()
        }
    }

    /// The row a hold stacks the dragged row onto, while one is arming or armed. A group
    /// joined through a gap between its rows stacks onto nothing: the gap is the place.
    private var stackedPlace: UUID? {
        if sidebarDrag.arming != nil { return store.sessionGroupDwell?.place }
        guard sidebarDrag.groupTarget != nil, !sidebarDrag.joinsInPlace else { return nil }
        return store.sessionGroupTargetPlace
    }

    /// A stack holds only while the pointer rests on its target. Moving off it, up or down,
    /// lets the row go back to following the pointer; without this, a target with no row
    /// past it (the last in a list) left nothing to report the move, and the row stayed stuck.
    private func leaveGroupOffTarget(_ location: CGPoint) {
        guard let place = stackedPlace, let target = store.sessionRowFrames[place] else { return }
        let y = location.y + frame.minY
        guard y < target.minY || y > target.maxY else { return }
        DispatchQueue.main.async { store.cancelSessionGroupDwell() }
    }

    @ViewBuilder
    private func floatingRow(_ session: Session) -> some View {
        if let source = store.sessionDragSource, let slot = store.sessionRowFrames[source],
           let location = pointer.location() {
            let row = slot.offsetBy(dx: -frame.minX, dy: -frame.minY)
            let grab = pointer.grab(for: session.id, default: location.y - row.minY)
            let _ = leaveGroupOutsideColumn(location)
            let _ = leaveGroupOffTarget(location)
            // Resting on a row it could group with, the dragged row stacks onto it: the
            // title goes, and its icon fans onto the target's the way a split group's
            // tiles fan in its tab (`TabIconStack`), so the target stays readable and
            // the stack is the group a release will make.
            let joining = store.draggingSessionID == nil ? nil : stackedPlace
            let target = joining.flatMap { store.sessionRowFrames[$0] }?
                .offsetBy(dx: -frame.minX, dy: -frame.minY)
            let stacked = target != nil
            // Resting on its own slot, it snaps in (`restOnOwnSlot`).
            let snapped = sidebarDrag.snapped && store.draggingSessionID != nil
            let top = settleTop ?? target?.minY ?? (snapped ? row.minY : nil)
                ?? min(max(location.y - grab, 0), max(frame.height - row.height, 0))
            // Out over the cards nothing is in the column to draw; the pane's wash takes over.
            let inColumn = sidebarDrag.settling != nil || stacked
                || (0...frame.width).contains(location.x)
            ZStack(alignment: .leading) {
                SelectionGlass(shape: Capsule(style: .continuous))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .frame(width: frame.width, height: row.height)
                    .opacity(stacked ? 0 : 1)
                HStack(spacing: 6) {
                    AgentIconView(agent: store.effectiveAgent(for: session), size: 15)
                        .frame(width: 16)
                        .rotationEffect(.degrees(stacked ? Self.fanAngle : 0), anchor: .bottom)
                        .offset(x: stacked ? (target?.minX ?? row.minX) - row.minX + Self.fanOffset : 0)
                    Text(store.displayTitle(for: session))
                        .font(settings.interfaceFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .opacity(stacked ? 0 : 1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, store.sessionDragLeading)
                .frame(width: row.width, height: row.height)
                .offset(x: row.minX)
            }
            .offset(y: top)
            .opacity(inColumn ? 1 : 0)
            .animation(TermioStore.rowReflow, value: stacked)
            .animation(TermioStore.rowReflow, value: snapped)
        }
    }
}

/// The pointer, in the sidebar overlay's own space, read from AppKit: a drag holds the mouse
/// in AppKit's drag loop, where no SwiftUI gesture sees it move.
private struct PointerAnchor: NSViewRepresentable {
    @MainActor
    final class Box {
        fileprivate weak var view: NSView?
        /// Where in the row the pointer took it, fixed for the drag so the row does not
        /// jump to centre itself under the pointer.
        private var held: (id: Session.ID, grab: CGFloat)?
        func location() -> CGPoint? {
            guard let view, let window = view.window else { return nil }
            let point = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            return CGPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
        }

        func grab(for id: Session.ID, default fresh: CGFloat) -> CGFloat {
            if let held, held.id == id { return held.grab }
            held = (id, fresh)
            return fresh
        }

        func release() { held = nil }
    }

    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }

    /// Never the hit view: a drop over the column belongs to the rows under it.
    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
