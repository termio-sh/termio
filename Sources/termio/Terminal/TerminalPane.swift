import AppKit
import SwiftUI
import GhosttyTerminal

extension Notification.Name {
    /// Posted by the toolbar's close button to dismiss whichever content overlay (file editor,
    /// diff, or preview) covers the terminal. `TerminalPane` handles it, running the same teardown
    /// — clear the store, hand focus back to the terminal — the overlays' own Esc / close use, so
    /// the toolbar and in-overlay close paths stay identical.
    static let termioCloseContentOverlay = Notification.Name("termio.closeContentOverlay")

    /// Dev-only fault injector for the hollow-cursor focus race. The selected terminal is
    /// made first responder, then deliberately resigned while the main window stays key.
    /// Fired from the command palette's "Debug: Orphan Terminal Focus".
    static let termioDebugOrphanFocus = Notification.Name("termio.debugOrphanFocus")
}

/// Right column. Every session that has been opened stays *mounted* here for the
/// app's lifetime; switching sessions only flips opacity and keyboard focus.
///
/// The earlier design swapped the visible terminal with `.id(session.id)`, which
/// made SwiftUI destroy the old surface view and build a fresh one on every
/// switch. A fresh `TerminalView` lays out from a zero frame, so libghostty calls
/// `ghostty_surface_set_size` — a SIGWINCH the shell answers by repainting its
/// prompt. That resize-on-every-switch was the visible flicker. Keeping each
/// surface mounted and only toggling visibility means the view is never
/// reparented or resized, so the shell never repaints and switching is instant.
struct TerminalPane: View {
    /// The pane area's named coordinate space — the fixed frame the split
    /// dividers' drags are measured in (see the ZStack's `coordinateSpace`).
    static let splitCoordinateSpace = "termio.splitPane"
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var focusDriver = TerminalFocusDriver()
    @State private var activated: [Session.ID] = []
    @State private var isDropTargeted = false

    /// The wash painted over the terminal while a file is dragged onto it. The old fill was a flat
    /// `accentColor.opacity(0.18)`, which read as a heavy, saturated blue. This is a much softer,
    /// desaturated blue-grey: barely-there in light mode, a touch stronger in dark so it still
    /// registers over a dark terminal without looking like a solid panel.
    private var dropTint: Color {
        colorScheme == .dark
            ? Color(.sRGB, red: 0.62, green: 0.70, blue: 0.82, opacity: 0.10)
            : Color(.sRGB, red: 0.40, green: 0.52, blue: 0.68, opacity: 0.09)
    }

    var body: some View {
        GeometryReader { geo in
            // A file open next to the terminal reserves the right slice of the pane; the
            // terminal group is laid out into what's left. `previewSlice` is 0 when no file
            // is open, so the single-terminal path (and every split-tree measurement below)
            // is unchanged for users who never open a preview.
            let previewSlice = previewColumnWidth(totalWidth: geo.size.width)
            let dividerWidth: CGFloat = previewSlice > 0 ? 6 : 0
            let termWidth = max(0, geo.size.width - previewSlice - dividerWidth)
            let bounds = CGRect(origin: .zero, size: CGSize(width: termWidth, height: geo.size.height))
            let layout = store.splitRoot?.layout(in: bounds)
            let zoomed = store.isPaneZoomed && layout != nil
            HStack(spacing: 0) {
                terminalGroup(bounds: bounds, layout: layout, zoomed: zoomed)
                    .frame(width: termWidth, height: geo.size.height)
                    .coordinateSpace(name: Self.splitCoordinateSpace)
                if previewSlice > 0, let url = store.openFileURL {
                    PreviewSplitDivider(
                        totalWidth: geo.size.width,
                        currentRatio: store.previewSplitRatio,
                        setRatio: { store.previewSplitRatio = $0 }
                    )
                    .frame(width: dividerWidth, height: geo.size.height)
                    previewColumn(url: url)
                        .frame(width: previewSlice, height: geo.size.height)
                        .id(url)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // Paint the terminal's own background behind the pane, extending up under the toolbar so
        // the system toolbar material picks up a terminal tint instead of a flat grey band.
        .background(paneBackground.ignoresSafeArea(.container, edges: .top))
        // A VSCode-style drop overlay: just a translucent accent wash over the whole
        // terminal while a file is dragged over it (their `terminal-dropBackground`) —
        // no border, only the background tint, fading in and out.
        .overlay {
            if isDropTargeted {
                dropTint
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        // Double-clicking / clicking a file in the sidebar covers the terminal pane with it (the
        // surface keeps running underneath): an image/PDF/HTML in a read-only preview, anything
        // else in the editor. Skipped when the user chose "Open to the Side" — that path renders
        // the same content in the right split column instead of over the terminal.
        .overlay {
            if let url = store.openFileURL, !store.openFileInSidePanel {
                let onClose = {
                    store.openFileURL = nil
                    requestSelectedTerminalFocus(reason: .overlayClosed)
                }
                Group {
                    if FileActivation.isPreviewable(url) {
                        FilePreviewView(url: url, settings: settings, onClose: onClose)
                    } else {
                        FileEditorView(url: url, settings: settings,
                                       readOnly: store.openFileReadOnly,
                                       jumpLine: store.openFileLine, onClose: onClose)
                    }
                }
                .id(url)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: store.openFileURL != nil)
        // Clicking a row in the inspector's Issues pane covers the terminal with that item's
        // detail — the conversation (and, for a PR, its Files), opened in the center like the
        // editor and diff rather than cramped in the narrow inspector. Ordered BEFORE the diff
        // overlay below so a PR's file diff stacks on top: closing the diff returns here, not to
        // the terminal. Escape or the back button clears it.
        .overlay {
            if let item = store.openIssueDetail, let model = store.issuesModel {
                IssueDetailView(item: item, model: model, settings: settings) {
                    store.openIssueDetail = nil
                    requestSelectedTerminalFocus(reason: .overlayClosed)
                }
                .background(paneBackground)
                .id(item.number)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: store.openIssueDetail != nil)
        // Clicking a row in the inspector's Changes pane covers the terminal with that file's
        // unified diff (the surface keeps running underneath), the git counterpart of the editor
        // overlay above. Escape or the close button clears it.
        .overlay {
            if let request = store.openDiff {
                GitDiffView(request: request, settings: settings, onClose: {
                    store.openDiff = nil
                    requestSelectedTerminalFocus(reason: .overlayClosed)
                }, onNavigate: { store.openDiff = $0 })
                .id(request)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: store.openDiff != nil)
        // The Info pane's "View Trace" covers the terminal with the session's rendered agent trace
        // (dashboard + collapsible conversation), themed to match termio. Escape or the close button
        // clears it, like the editor and diff overlays.
        .overlay {
            if let request = store.openTrace {
                TraceView(request: request, settings: settings, onClose: {
                    store.openTrace = nil
                    requestSelectedTerminalFocus(reason: .overlayClosed)
                })
                .id(request)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: store.openTrace != nil)
        // The ⌘⇧O/⌘⇧P palette lives in its own floating NSPanel (owned by
        // the app delegate — a SwiftUI overlay would render *under* the NSView
        // terminal surfaces); this only hands focus back to the terminal when
        // it closes.
        .onChange(of: store.paletteMode) { _, mode in
            if mode == nil { requestSelectedTerminalFocus(reason: .paletteClosed) }
        }
        // Dropping a file (dragged from the file-tree inspector or the Finder) inserts
        // its shell-quoted path at the prompt — the prebuilt libghostty surface does not
        // register for file drops itself, so the pane catches them and feeds the path to
        // the selected session's surface. No trailing return, so the path is inserted for
        // the user (or the agent) to act on rather than run.
        .dropDestination(for: URL.self) { urls, _ in
            sendPaths(urls)
        } isTargeted: { isDropTargeted = $0 }
        // Every visible pane must be mounted — with splits that is all the
        // tree's leaves, not just the selection.
        .onChange(of: store.visiblePaneIDs, initial: true) { _, ids in
            for id in ids where !activated.contains(id) {
                activated.append(id)
            }
        }
        // A background-driven session (a sibling spawn, a `send` to a pane never
        // shown) mounts invisibly so its surface attaches without the selection
        // moving; the focus paths all gate on visibility, so it stays silent.
        .onChange(of: store.backgroundActivationIDs, initial: true) { _, ids in
            for id in ids where !activated.contains(id) {
                activated.append(id)
            }
        }
        .onChange(of: store.selectedSessionID, initial: true) { _, id in
            if let id, !activated.contains(id) {
                activated.append(id)
            }
            // Switching sessions returns to the terminal: dismiss any open file editor so the
            // newly selected session's surface is what's shown (the overlay's `.onDisappear`
            // flushes any pending auto-save first). The diff overlay is dismissed for the same reason.
            store.openFileURL = nil
            store.openDiff = nil
            store.openTrace = nil
            store.openIssueDetail = nil
            requestSelectedTerminalFocus(reason: .selectionChanged)
        }
        // The toolbar's close button posts this; tear the overlay down the same way the overlay's
        // own Esc / close does (clear the store, return focus to the selected session's terminal).
        .onReceive(NotificationCenter.default.publisher(for: .termioCloseContentOverlay)) { _ in
            // Tear down top-down: a stacked PR file diff closes first, revealing the detail;
            // a second press then closes the detail (matching the overlay's own Esc handling).
            if store.openDiff != nil {
                store.openDiff = nil
            } else {
                store.openFileURL = nil
                store.openTrace = nil
                store.openIssueDetail = nil
            }
            requestSelectedTerminalFocus(reason: .overlayClosed)
        }
        // Dev-only: perform the real AppKit failure while the main window stays key.
        // The driver focuses the selected TerminalView, resigns it to nil on the next
        // runloop, then uses the same orphan repair as a sibling-driven surface update.
        .onReceive(NotificationCenter.default.publisher(for: .termioDebugOrphanFocus)) { _ in
            injectTerminalFocusOrphan()
        }
        // Window-key status is separate from surface focus, matching Ghostty. Becoming
        // key asks the driver to repair an orphan; it does not mutate a FocusState.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow,
                  window.frameAutosaveName == AppDelegate.mainWindowFrameAutosaveName
            else { return }
            requestSelectedTerminalFocus(reason: .windowBecameKey)
        }
    }

    /// The terminal-side ZStack: the flat mount for every terminal surface plus the split-tree
    /// dividers. Extracted from `body` so it can be sized independently when a file preview
    /// occupies the right column.
    @ViewBuilder
    private func terminalGroup(bounds: CGRect, layout: SplitNode.PaneLayout?, zoomed: Bool) -> some View {
        ZStack {
            if mounted.isEmpty {
                WelcomeView()
            }
            ForEach(mounted, id: \.session.id) { item in
                let id = item.session.id
                let paneFrame = zoomed
                    ? (id == store.selectedSessionID ? bounds : nil)
                    : layout?.frames[id]
                let isVisible = paneFrame != nil
                    || (layout == nil && store.selectedSessionID == id)
                let rect = paneFrame ?? bounds
                ManagedTerminalSurface(
                    id: id,
                    context: store.surface(for: item.session, in: item.project),
                    isSelected: store.selectedSessionID == id,
                    isVisible: isVisible,
                    onFocused: { selectFocusedSurface(id) },
                    requestFocus: { reason in
                        requestTerminalFocus(for: id, reason: reason)
                    }
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .opacity(isVisible ? 1 : 0)
                .allowsHitTesting(isVisible)
            }
            if let layout, !zoomed {
                ForEach(layout.dividers) { divider in
                    SplitDividerHandle(spec: divider) { ratio in
                        store.updateSplitRatio(branchID: divider.id, ratio: ratio)
                    }
                }
            }
        }
    }

    /// The right-hand file preview column. Reuses the existing `FilePreviewView` for opaque
    /// binaries (image/PDF/HTML) and `FileEditorView` for editable text, so a click on any file
    /// in the sidebar opens the same reader it would have as a full-window overlay — just now
    /// beside the terminal instead of covering it.
    @ViewBuilder
    private func previewColumn(url: URL) -> some View {
        let onClose = {
            store.openFileURL = nil
            requestSelectedTerminalFocus(reason: .overlayClosed)
        }
        if FileActivation.isPreviewable(url) {
            FilePreviewView(url: url, settings: settings, onClose: onClose)
        } else {
            FileEditorView(url: url, settings: settings,
                           readOnly: store.openFileReadOnly,
                           jumpLine: store.openFileLine, onClose: onClose)
        }
    }

    /// Fraction of the pane width taken by the preview column when a file is open. Clamped to
    /// keep both the terminal and preview usable — the divider drag writes into the same range.
    static let previewMinRatio: CGFloat = 0.2
    static let previewMaxRatio: CGFloat = 0.8

    private func previewColumnWidth(totalWidth: CGFloat) -> CGFloat {
        guard store.openFileURL != nil, store.openFileInSidePanel, totalWidth > 0 else { return 0 }
        let clamped = min(max(store.previewSplitRatio, Self.previewMinRatio), Self.previewMaxRatio)
        return totalWidth * clamped
    }

    /// A surface becoming first responder is the source of truth for split selection.
    /// Each mounted surface owns an independent Boolean FocusState, so one surface
    /// resigning can no longer clear the focus intent of every sibling.
    private func selectFocusedSurface(_ id: Session.ID) {
        guard id != store.selectedSessionID,
              store.visiblePaneIDs.contains(id) else { return }
        store.selectedSessionID = id
    }

    private func requestSelectedTerminalFocus(reason: TerminalFocusReason) {
        guard let id = store.selectedSessionID else { return }
        requestTerminalFocus(for: id, reason: reason)
    }

    /// Mirrors Ghostty's `moveFocus`: resolve the selected AppTerminalView by its
    /// TerminalViewState delegate, retry with capped exponential backoff until it is
    /// windowed, and explicitly resign the previously focused surface before moving.
    private func requestTerminalFocus(for id: Session.ID, reason: TerminalFocusReason) {
        guard let session = store.session(id),
              let project = store.project(for: id) else { return }
        let state = store.surface(for: session, in: project)
        focusDriver.moveFocus(
            to: state,
            sessionID: id,
            reason: reason,
            canFocus: { [weak store] in
                guard let store else { return false }
                return store.selectedSessionID == id
                    && store.visiblePaneIDs.contains(id)
                    && store.openFileURL == nil
                    && store.openDiff == nil
                    && store.openTrace == nil
                    && store.paletteMode == nil
            }
        )
    }

    private func injectTerminalFocusOrphan() {
        guard AppChannel.isDev,
              let id = store.selectedSessionID,
              let session = store.session(id),
              let project = store.project(for: id) else { return }
        let state = store.surface(for: session, in: project)
        focusDriver.injectOrphan(
            in: state,
            sessionID: id,
            canFocus: { [weak store] in
                guard let store else { return false }
                return store.selectedSessionID == id
                    && store.visiblePaneIDs.contains(id)
                    && store.openFileURL == nil
                    && store.openDiff == nil
                    && store.openTrace == nil
                    && store.paletteMode == nil
            },
            repair: { requestTerminalFocus(for: id, reason: .faultInjector) }
        )
    }

    /// Inserts the dropped files' paths into the selected session's terminal,
    /// space-separated and each shell-quoted so spaces and other special characters
    /// survive. Focuses the session first (VSCode's focus-on-drop), and if its shell
    /// isn't attached yet, activates the session so its surface mounts and retries
    /// once it has come up. Returns whether a drop was accepted at all.
    private func sendPaths(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty,
              let id = store.selectedSessionID,
              let session = store.session(id),
              let project = store.project(for: id) else { return false }
        requestTerminalFocus(for: id, reason: .fileDrop)
        let text = urls.map { Self.dropToken(for: $0) }.joined(separator: " ") + " "
        if store.surface(for: session, in: project).send(text) { return true }

        // The shell may not be attached yet (a freshly opened session whose surface
        // hasn't mounted). Activating it mounts the surface; retry a moment later, once.
        store.selectedSessionID = id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if !store.surface(for: session, in: project).send(text) {
                Log.pty.error("dropped path could not be sent — \(session.title, privacy: .public) has no live terminal")
            }
        }
        return true
    }

    /// The shell-quoted token to insert for a dropped URL. A `file://` URL becomes
    /// its local path (the file-tree/Finder case, so the prompt gets a usable path);
    /// any other scheme — an https GitHub issue/PR dragged from the Issues pane —
    /// keeps its full `absoluteString`, since stripping to `.path` would drop the
    /// scheme and host and leave a meaningless `/owner/repo/issues/123` fragment.
    private static func dropToken(for url: URL) -> String {
        shellQuoted(url.isFileURL ? url.path : url.absoluteString)
    }

    /// Single-quotes a path for the shell, escaping any embedded single quote the
    /// POSIX way (`'\''`), so a dropped path is always one safe token.
    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct MountedSession {
        let project: Project
        let session: Session
    }

    /// The sessions to keep on screen: every activated id that still resolves to a
    /// live session (closed sessions drop out, which unmounts their surface).
    private var mounted: [MountedSession] {
        activated.compactMap { id in
            guard let session = store.session(id), let project = store.project(for: id) else { return nil }
            return MountedSession(project: project, session: session)
        }
    }

    /// True when the user has dialed the background below full opacity or enabled
    /// blur, so the surface, window, and title bar must stay see-through.
    private var isTranslucent: Bool {
        settings.backgroundOpacity < 1.0 || settings.backgroundBlur > 0
    }

    /// The terminal background fill, or clear when translucent — then the surface and
    /// window stay see-through.
    private var paneBackground: Color {
        isTranslucent ? .clear : Color(nsColor: settings.terminalBackgroundColor)
    }
}

// MARK: - Terminal focus

/// Why a focus request is being made. Explicit navigation may replace another
/// responder; background reconciliation and window activation may only repair the
/// narrow orphan shape (the main window itself, or nil, is first responder).
private enum TerminalFocusReason {
    case surfaceMounted
    case selectionChanged
    case surfaceUpdated
    case windowBecameKey
    case paletteClosed
    case overlayClosed
    case fileDrop
    case faultInjector

    var replacesCurrentResponder: Bool {
        switch self {
        case .surfaceMounted, .selectionChanged, .paletteClosed, .overlayClosed, .fileDrop:
            true
        case .surfaceUpdated, .windowBecameKey, .faultInjector:
            false
        }
    }

    var label: String {
        switch self {
        case .surfaceMounted: "surface-mounted"
        case .selectionChanged: "selection-changed"
        case .surfaceUpdated: "surface-updated"
        case .windowBecameKey: "window-became-key"
        case .paletteClosed: "palette-closed"
        case .overlayClosed: "overlay-closed"
        case .fileDrop: "file-drop"
        case .faultInjector: "fault-injector"
        }
    }
}

/// One focus state per terminal, matching Ghostty's SurfaceView model. The Boolean
/// binding is retained only to report a clicked split pane back to the store; moving
/// focus is handled from AppKit by TerminalFocusDriver, never by waiting for this value
/// to transition through nil.
private struct ManagedTerminalSurface: View {
    let id: Session.ID
    let context: TerminalViewState
    let isSelected: Bool
    let isVisible: Bool
    let onFocused: () -> Void
    let requestFocus: (TerminalFocusReason) -> Void

    @FocusState private var surfaceFocus: Bool

    var body: some View {
        TerminalSurfaceView(context: context)
            .terminalFocused($surfaceFocus)
            .background {
                // NSViewRepresentable.updateNSView runs after a parent/store-driven
                // reconciliation. Re-check first responder on the following runloop,
                // after any transient detach/resign has settled.
                TerminalFocusRepairProbe {
                    guard isSelected, isVisible else { return }
                    requestFocus(.surfaceUpdated)
                }
            }
            .onAppear {
                guard isSelected else { return }
                surfaceFocus = true
                requestFocus(.surfaceMounted)
            }
            .onChange(of: isSelected, initial: true) { _, selected in
                surfaceFocus = selected
                if selected { requestFocus(.selectionChanged) }
            }
            .onChange(of: surfaceFocus) { _, focused in
                if focused { onFocused() }
            }
            // A relaunched session gets a fresh TerminalViewState (see
            // `relaunchSession`); keying the mounted view on the state's identity
            // remounts the NSView for the new surface. Without this the
            // representable would only *update* — and its update path deliberately
            // keeps the first-mounted delegate, which is the old, dead state.
            .id(ObjectIdentifier(context))
    }
}

private struct TerminalFocusRepairProbe: NSViewRepresentable {
    let repair: () -> Void

    func makeNSView(context _: Context) -> TerminalFocusProbeView {
        let view = TerminalFocusProbeView(frame: .zero)
        DispatchQueue.main.async { repair() }
        return view
    }

    func updateNSView(_: TerminalFocusProbeView, context _: Context) {
        DispatchQueue.main.async { repair() }
    }
}

private final class TerminalFocusProbeView: NSView {
    override func hitTest(_: NSPoint) -> NSView? { nil }
}

/// App-side equivalent of Ghostty's `moveFocus`. It addresses both wrapper gaps:
/// a focus request is retried until the selected TerminalView is in a window, and
/// the previous terminal is explicitly resigned before the new one is focused.
@MainActor
private final class TerminalFocusDriver {
    private enum Strength {
        case replaceResponder
        case repairOrphan
    }

    private weak var lastFocusedSurface: TerminalView?
    private var replaceGeneration = 0
    private var repairGeneration = 0
    private var injectionGeneration = 0

    func moveFocus(
        to state: TerminalViewState,
        sessionID: Session.ID,
        reason: TerminalFocusReason,
        canFocus: @escaping () -> Bool
    ) {
        let strength: Strength = reason.replacesCurrentResponder
            ? .replaceResponder
            : .repairOrphan
        let generation: Int
        switch strength {
        case .replaceResponder:
            replaceGeneration += 1
            generation = replaceGeneration
        case .repairOrphan:
            repairGeneration += 1
            generation = repairGeneration
        }
        scheduleMove(
            to: state,
            sessionID: sessionID,
            reason: reason,
            strength: strength,
            generation: generation,
            delay: 0,
            canFocus: canFocus
        )
    }

    private func scheduleMove(
        to state: TerminalViewState,
        sessionID: Session.ID,
        reason: TerminalFocusReason,
        strength: Strength,
        generation: Int,
        delay: TimeInterval,
        canFocus: @escaping () -> Bool
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak state] in
            guard let self, let state,
                  isCurrent(strength, generation: generation),
                  canFocus() else { return }

            guard let window = mainWindow() else {
                retryMove(to: state, sessionID: sessionID, reason: reason,
                          strength: strength, generation: generation,
                          after: delay, canFocus: canFocus)
                return
            }
            // Key-window status is deliberately not focus state. Do not move focus
            // in the background; didBecomeKey will issue a fresh repair request.
            guard window.isKeyWindow else { return }
            guard let root = window.contentView,
                  let target = terminalView(matching: state, under: root),
                  target.window === window else {
                retryMove(to: state, sessionID: sessionID, reason: reason,
                          strength: strength, generation: generation,
                          after: delay, canFocus: canFocus)
                return
            }

            let current = window.firstResponder
            if current === target {
                lastFocusedSurface = target
                return
            }
            if strength == .repairOrphan,
               current != nil, current !== window {
                // A field, browser, overlay, or newly-clicked sibling owns focus.
                // A render-driven repair must never steal from a real responder.
                return
            }

            resignPreviousSurface(current: current, target: target)
            if window.makeFirstResponder(target), window.firstResponder === target {
                lastFocusedSurface = target
                if AppChannel.isDev {
                    if current == nil || current === window {
                        Log.focus.info("recovered terminal focus [\(reason.label, privacy: .public)] → \(sessionID.uuidString.prefix(8), privacy: .public)")
                    } else {
                        Log.focus.info("moved terminal focus [\(reason.label, privacy: .public)] → \(sessionID.uuidString.prefix(8), privacy: .public)")
                    }
                }
            } else {
                retryMove(to: state, sessionID: sessionID, reason: reason,
                          strength: strength, generation: generation,
                          after: delay, canFocus: canFocus)
            }
        }
    }

    private func retryMove(
        to state: TerminalViewState,
        sessionID: Session.ID,
        reason: TerminalFocusReason,
        strength: Strength,
        generation: Int,
        after delay: TimeInterval,
        canFocus: @escaping () -> Bool
    ) {
        let nextDelay = delay == 0 ? 0.05 : min(delay * 2, 0.5)
        scheduleMove(to: state, sessionID: sessionID, reason: reason,
                     strength: strength, generation: generation,
                     delay: nextDelay, canFocus: canFocus)
    }

    /// Deterministically reproduce the production failure against the real terminal
    /// responder. This intentionally does not mutate SwiftUI focus state directly.
    func injectOrphan(
        in state: TerminalViewState,
        sessionID: Session.ID,
        canFocus: @escaping () -> Bool,
        repair: @escaping () -> Void
    ) {
        injectionGeneration += 1
        scheduleInjection(in: state, sessionID: sessionID,
                          generation: injectionGeneration, delay: 0,
                          canFocus: canFocus, repair: repair)
    }

    private func scheduleInjection(
        in state: TerminalViewState,
        sessionID: Session.ID,
        generation: Int,
        delay: TimeInterval,
        canFocus: @escaping () -> Bool,
        repair: @escaping () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak state] in
            guard let self, let state,
                  generation == injectionGeneration, canFocus() else { return }
            guard let window = mainWindow(), window.isKeyWindow,
                  let root = window.contentView,
                  let target = terminalView(matching: state, under: root),
                  target.window === window else {
                let nextDelay = delay == 0 ? 0.05 : min(delay * 2, 0.5)
                scheduleInjection(in: state, sessionID: sessionID,
                                  generation: generation, delay: nextDelay,
                                  canFocus: canFocus, repair: repair)
                return
            }

            if window.firstResponder !== target {
                resignPreviousSurface(current: window.firstResponder, target: target)
                guard window.makeFirstResponder(target),
                      window.firstResponder === target else {
                    let nextDelay = delay == 0 ? 0.05 : min(delay * 2, 0.5)
                    scheduleInjection(in: state, sessionID: sessionID,
                                      generation: generation, delay: nextDelay,
                                      canFocus: canFocus, repair: repair)
                    return
                }
            }
            lastFocusedSurface = target

            DispatchQueue.main.async { [weak self, weak window, weak target] in
                guard let self, let window, let target,
                      generation == injectionGeneration,
                      canFocus(), window.isKeyWindow,
                      window.firstResponder === target else { return }
                _ = window.makeFirstResponder(nil)
                guard window.firstResponder !== target else { return }
                Log.focus.info("fault injector: dropped terminal first responder while key=true session=\(sessionID.uuidString.prefix(8), privacy: .public)")
                repair()
            }
        }
    }

    private func isCurrent(_ strength: Strength, generation: Int) -> Bool {
        switch strength {
        case .replaceResponder: generation == replaceGeneration
        case .repairOrphan: generation == repairGeneration
        }
    }

    private func mainWindow() -> NSWindow? {
        AppDelegate.mainWindow
    }

    private func terminalView(
        matching state: TerminalViewState,
        under root: NSView
    ) -> TerminalView? {
        if let terminal = root as? TerminalView,
           let delegate = terminal.delegate as AnyObject?,
           delegate === state {
            return terminal
        }
        for child in root.subviews {
            if let match = terminalView(matching: state, under: child) {
                return match
            }
        }
        return nil
    }

    private func resignPreviousSurface(current: NSResponder?, target: TerminalView) {
        let previous = (current as? TerminalView) ?? lastFocusedSurface
        if let previous, previous !== target {
            // Ghostty does this explicitly too: in practice the normal focus callback
            // is occasionally skipped during SwiftUI/AppKit reconciliation.
            _ = previous.resignFirstResponder()
        }
    }
}

/// The draggable divider between two split panes: a hairline with a wider
/// invisible hit area (muxy's 1pt-line / ~10pt-grab pattern). Dragging writes
/// the branch ratio through `onRatioChange`; the anchor is captured on the
/// first tick so the delta is always relative to where the drag began, not to
/// the live (already-moved) ratio.
private struct SplitDividerHandle: View {
    let spec: SplitNode.DividerSpec
    let onRatioChange: (Double) -> Void
    @State private var anchorRatio: Double?

    /// Whether the divider line runs vertically (panes side by side).
    private var verticalLine: Bool { spec.direction == .horizontal }
    private static let hitThickness: CGFloat = 9

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: verticalLine ? spec.frame.width : nil,
                   height: verticalLine ? nil : spec.frame.height)
            .frame(width: verticalLine ? Self.hitThickness : spec.frame.width,
                   height: verticalLine ? spec.frame.height : Self.hitThickness)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    (verticalLine ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0,
                            coordinateSpace: .named(TerminalPane.splitCoordinateSpace))
                    .onChanged { value in
                        let start = anchorRatio ?? spec.ratio
                        if anchorRatio == nil { anchorRatio = start }
                        guard spec.span > 0 else { return }
                        let delta = verticalLine ? value.translation.width : value.translation.height
                        onRatioChange(start + Double(delta / spec.span))
                    }
                    .onEnded { _ in anchorRatio = nil }
            )
            .position(x: spec.frame.midX, y: spec.frame.midY)
    }
}

/// The vertical divider between the terminal group and the file preview column. Sits in
/// an HStack (not the split tree's ZStack), so it measures its drag in `.global` space and
/// converts pixels into the pane-fraction the ratio store expects.
private struct PreviewSplitDivider: View {
    let totalWidth: CGFloat
    let currentRatio: CGFloat
    let setRatio: (CGFloat) -> Void
    @State private var anchorRatio: CGFloat?
    @State private var anchorX: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 2.5) // widen the hit area without widening the hairline
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        guard totalWidth > 0 else { return }
                        if anchorX == nil { anchorX = value.startLocation.x }
                        let deltaX = value.location.x - (anchorX ?? value.startLocation.x)
                        // Divider drift is relative to the ratio snapshot at gesture start; the
                        // ratio maps the *preview* width, so dragging right (positive delta)
                        // shrinks the preview and drops the ratio.
                        let start = anchorRatio ?? currentRatio
                        if anchorRatio == nil { anchorRatio = start }
                        let next = start - CGFloat(deltaX) / totalWidth
                        setRatio(min(max(next, TerminalPane.previewMinRatio), TerminalPane.previewMaxRatio))
                    }
                    .onEnded { _ in
                        anchorRatio = nil
                        anchorX = nil
                    }
            )
    }
}
