import AppKit
import SwiftUI
import WebKit

// MARK: - Issues pane

/// The inspector's Issues pane: the bound GitHub repo's issues and pull
/// requests. Top bar carries the kind switch (Issues / Pull Requests — drawn
/// like the git pane's Changes / History miniature track) and a light filter;
/// rows are one-line (state dot, monospace identifier, title, label chips);
/// clicking a row pushes in the detail (body + comments as rendered markdown).
/// Connect and binding zero states cover the ladder before any of that exists.
struct IssuesView: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    let repoRoot: String

    @StateObject private var model: IssuesPanelModel
    @State private var selection: Int?
    @State private var filterHovering = false

    init(repoRoot: String) {
        self.repoRoot = repoRoot
        self._model = StateObject(wrappedValue: IssuesPanelModel(repoRoot: repoRoot))
    }

    private var chrome: ChromeTheme? { settings.chromeTheme(for: colorScheme) }

    var body: some View {
        // List only — the detail opens in the center over the terminal (like the file
        // editor and diff), driven by `store.openIssueDetail`, not pushed in here.
        listPane
            .task(id: repoRoot) {
                store.registerIssuesModel(model)
                await model.start()
            }
            // Selection IS the open gesture; route it to the center overlay. Follow the
            // overlay back: when it closes, release the selection so the same row reopens.
            .onChange(of: selection) { _, selected in
                guard let selected,
                      let item = model.items.first(where: { $0.number == selected })
                else { return }
                store.openIssueDetail = item
            }
            .onChange(of: store.openIssueDetail) { _, item in
                if item == nil { selection = nil }
            }
    }

    // MARK: List pane

    private var listPane: some View {
        VStack(spacing: 0) {
            if model.phase == .ready { topBar }
            content
        }
    }

    /// The kind switch (only when the provider has PRs at all) and the filter
    /// menu, at the git pane's shared 34pt top-bar height. Trailing padding is
    /// deeper than leading so the funnel's right edge lines up under the
    /// toolbar's collapse button instead of hugging the pane edge.
    private var topBar: some View {
        HStack(spacing: 2) {
            if model.capabilities?.pullRequests == true { kindSwitch }
            Spacer(minLength: 0)
            refreshButton
                // Breathing room so refresh and filter don't read as one two-icon cluster.
                .padding(.trailing, 8)
            filterMenu
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: GitChangesView.topBarHeight)
    }

    /// Manual reload of the current query — the GitHub Desktop refresh affordance.
    /// The list is otherwise fetch-on-interaction, so this is the "prove it's
    /// current" escape hatch when something changed on GitHub out of band.
    private var refreshButton: some View {
        // VS Code codicon refresh — the two-arrow ring reads more refined than the Hugeicons
        // single-arrow one, and matches the File Explorer header's four codicon actions.
        TreeHeaderButton(codicon: .refresh, help: "Refresh") {
            Task { await model.loadList() }
        }
    }

    private var kindSwitch: some View {
        CapsuleSwitch(
            segments: [("Issues", IssueKind.issue), ("Pull Requests", .pullRequest)],
            selection: Binding(get: { model.query.kind }, set: { model.query.kind = $0 })
        )
    }

    private var filterMenu: some View {
        Menu {
            // Each axis is its own submenu so the top level reads as the list of
            // things you can filter by, not a flat pile of toggles. State and
            // assignee are single-select (inline Picker = radio); labels stay
            // multi-select with GitHub's AND semantics.
            Menu("State") {
                Picker("State", selection: Binding(
                    get: { model.query.openOnly },
                    set: { model.query.openOnly = $0 }
                )) {
                    Text("Open").tag(true)
                    Text("All").tag(false)
                }
                .pickerStyle(.inline)
            }
            Menu("Assignee") {
                Picker("Assignee", selection: Binding(
                    get: { model.query.assignedToMe },
                    set: { model.query.assignedToMe = $0 }
                )) {
                    Text("Anyone").tag(false)
                    Text("Assigned to Me").tag(true)
                }
                .pickerStyle(.inline)
            }
            // The repo's full label set, checkmarked from the current query —
            // only when the repo actually has labels to offer.
            if !model.availableLabels.isEmpty {
                Menu("Labels") {
                    ForEach(model.availableLabels, id: \.name) { label in
                        Toggle(label.name, isOn: Binding(
                            get: { model.query.labels.contains(label.name) },
                            set: { _ in model.toggleLabelFilter(label.name) }
                        ))
                    }
                }
            }
        } label: {
            // macOS flattens a Menu label to Text/Image and drops shape-drawn
            // views — so the label is only a clear hit-area, and the chip + funnel
            // are painted behind it (see .background below).
            Color.clear
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background {
            // The shared `TreeHeaderChip` fill (drawn here, not in the label, because the
            // Menu drops shape-drawn label views) so the funnel hovers exactly like the
            // refresh codicon beside it. On top of the chip:
            // the funnel takes the accent color while any filter narrows the list (non-default
            // state, an assignee, or a label), so a filtered view can't be mistaken for the full
            // one — and only otherwise follows the secondary→primary hover of every header glyph.
            // 1.0pt: the shared inspector-header Hugeicon weight, so the funnel matches the
            // detail's window controls and the ↗ exactly and sits at the codicon refresh's weight.
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(filterHovering ? 0.08 : 0))
                    .frame(width: 22, height: 22)
                HugeIconView(
                    icon: .filter, size: 13,
                    color: isFiltered ? .accentColor : (filterHovering ? .primary : .secondary),
                    lineWidthOverride: 1.0
                )
            }
            .allowsHitTesting(false)
        }
        .onHover { filterHovering = $0 }
        .help("Filter")
    }

    /// Any axis narrowing the list away from its default (all open items, anyone,
    /// no labels) — drives the funnel's accent tint.
    private var isFiltered: Bool {
        !model.query.openOnly || model.query.assignedToMe || !model.query.labels.isEmpty
    }

    // MARK: Content per phase

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .disconnected:
            zeroState(
                title: "GitHub Issues",
                message: "Connect your GitHub account to read this project’s issues and pull requests here."
            ) {
                Button("Connect GitHub") { Task { await model.connect() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        case .connecting(let userCode):
            zeroState(
                title: "Enter Code on GitHub",
                message: "Type this code at github.com/login/device to approve termio. Waiting for approval…"
            ) {
                Text(userCode)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                ProgressView().controlSize(.small)
            }
        case .unbound:
            zeroState(
                title: "No GitHub Repository",
                message: "This project’s origin remote doesn’t point at github.com, so there is no issue tracker to show."
            ) {
                Button("Disconnect GitHub") { model.disconnect() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        case .ready:
            listBody
        }
    }

    private func zeroState<Actions: View>(
        title: String, message: String, @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 10) {
            HugeIconView(icon: .github, size: 34, color: .secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            actions()
            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var listBody: some View {
        if model.isLoading, model.items.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.errorMessage != nil {
            // The recovery the model classified drives which actions we offer — reconnecting can
            // only fix an access 403, not a rate limit / 404 / 5xx / network error. `zeroState`
            // paints `model.errorMessage` in red beneath the actions.
            switch model.recovery {
            case .reauthorize:
                // A valid token with no rights to *this* repo (403) — usually an org that hasn't
                // authorized termio. Switch account, or grant org access.
                zeroState(
                    title: "Couldn’t Load",
                    message: "Reconnect to sign in with a different account, or grant termio access to the organization that owns this repository."
                ) {
                    Button("Reconnect") { Task { await model.reconnect() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    Button("Grant Org Access…") { model.openConnectionSettings() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            case .retry, .none:
                // Rate limit, 404, 5xx, network, decode — reconnecting won't help; just retry.
                zeroState(
                    title: "Couldn’t Load",
                    message: "Something went wrong loading this repository. Try again in a moment."
                ) {
                    Button("Try Again") { Task { await model.loadList() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                }
            }
        } else if model.items.isEmpty {
            ContentUnavailableView(
                model.query.kind == .issue ? "No Issues" : "No Pull Requests",
                huge: .checkCircle,
                description: Text(emptyMessage)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Native `List` selection as the click handler, like the changes list —
            // a selected row opens its detail in the center (see `body`'s onChange).
            List(model.items, selection: $selection) { item in
                IssueRow(
                    item: item,
                    font: settings.interfaceFont,
                    chrome: chrome,
                    isSelected: selection == item.number
                )
                // Drag a row out as its GitHub URL — the terminal pane catches the
                // drop and inserts the full link at the prompt (see
                // `TerminalPane.dropToken`), so you can hand an agent "look at #123"
                // without leaving the keyboard-mouse flow. The custom preview names
                // the item so the lift reads as "this issue", not a bare link chip —
                // and doubles as the affordance that the row is draggable at all.
                .draggableIssueLink(item)
                // Right-click menu via an AppKit `NSMenu`, NOT SwiftUI's
                // `.contextMenu` — the latter rings the targeted row with an
                // un-styleable accent border (the file tree learned the same, see
                // `FileTreeList.RowContextMenu`). A secondary-click recognizer on the
                // row's own view pops the menu, so nothing emphasizes the row.
                .background(IssueRowContextMenu(url: item.url))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
        }
    }

    private var emptyMessage: String {
        let noun = model.query.kind == .issue ? "issues" : "pull requests"
        return model.query.openOnly ? "No open \(noun) right now." : "No \(noun) found."
    }
}

// MARK: - Row

/// One list row: state icon, monospace identifier, title (the flexible element).
/// The icon is shape-distinct per state (GitHub's octicon convention), so the
/// resting row reads without hover and without leaning on hue alone. The trailing
/// metadata — label chips and the updated age — still appears on hover (the
/// GitChangeRow pattern), so the resting row stays clean and the hover answers
/// "what labels, how fresh".
private struct IssueRow: View {
    let item: IssueSummary
    let font: Font
    let chrome: ChromeTheme?
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            OcticonView(
                icon: item.state.octicon(for: item.kind),
                size: 13,
                color: item.state.tint(for: item.kind)
            )
            .frame(width: 14)
            .help(item.state.label)
            // Never wraps or compresses — without this, a narrow pane stacks the
            // identifier one character per line and the row balloons.
            Text(item.identifier)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Text(item.title)
                .font(font)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 6)
            if isHovering {
                HStack(spacing: 4) {
                    ForEach(item.labels.prefix(3), id: \.name) { label in
                        HStack(spacing: 3) {
                            Circle()
                                .fill(label.color)
                                .frame(width: 5, height: 5)
                            Text(label.name)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                    Text(item.updatedAt.issueRowAge)
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(OutlineSelectionStyleStripper())
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(
            SidebarRowHighlight(isSelected: isSelected, isHovering: isHovering, chrome: chrome)
                .animation(.easeInOut(duration: 0.12), value: isSelected)
                .animation(.easeInOut(duration: 0.12), value: isHovering)
        )
        .onHover { isHovering = $0 }
        .help(item.title)
    }
}

private extension View {
    /// Makes a row draggable as its GitHub URL, with a labelled lift preview.
    /// A no-op when the item has no URL (nothing meaningful to carry). Applied at
    /// the `List` row rather than inside `IssueRow` so the drag composes with the
    /// list's native `selection:` binding — a SwiftUI tap gesture on the row would
    /// swallow the drag, the native selection does not.
    @ViewBuilder
    func draggableIssueLink(_ item: IssueSummary) -> some View {
        if let url = item.url {
            draggable(url) {
                HStack(spacing: 6) {
                    OcticonView(
                        icon: item.state.octicon(for: item.kind),
                        size: 12,
                        color: item.state.tint(for: item.kind)
                    )
                    Text(item.identifier)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(item.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
        } else {
            self
        }
    }
}

/// The per-row right-click menu, via AppKit `NSMenu` rather than SwiftUI's
/// `.contextMenu` — the latter rings the targeted row with an un-styleable accent
/// border. A secondary-click recognizer on the row's own view pops the menu up, so
/// nothing emphasizes the row. Both items act on the item's GitHub URL, so the whole
/// menu is suppressed when there is none (mirrors `FileTreeList.RowContextMenu`).
private struct IssueRowContextMenu: NSViewRepresentable {
    let url: URL?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.owner = view
        context.coordinator.url = url
        context.coordinator.attach()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.url = url
        context.coordinator.attach()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var owner: NSView?
        var url: URL?
        private weak var hostView: NSView?
        private var recognizer: NSClickGestureRecognizer?

        func attach() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let owner = self.owner else { return }
                guard let host = Self.rowView(above: owner) else { return }
                if hostView === host, recognizer != nil { return }
                detach()
                let recognizer = NSClickGestureRecognizer(target: self, action: #selector(self.showMenu(_:)))
                recognizer.buttonMask = 0x2 // secondary (right) mouse button
                host.addGestureRecognizer(recognizer)
                self.recognizer = recognizer
                self.hostView = host
            }
        }

        func detach() {
            if let recognizer, let hostView { hostView.removeGestureRecognizer(recognizer) }
            recognizer = nil
            hostView = nil
        }

        @objc private func showMenu(_ recognizer: NSClickGestureRecognizer) {
            guard let hostView, url != nil else { return }
            let menu = NSMenu()
            menu.addItem(menuItem("Copy Link", #selector(copyLink)))
            menu.addItem(menuItem("Open in Browser", #selector(openInBrowser)))
            menu.popUp(positioning: nil, at: recognizer.location(in: hostView), in: hostView)
        }

        private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        @objc private func copyLink() {
            guard let url else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(url.absoluteString, forType: .string)
        }

        @objc private func openInBrowser() {
            guard let url else { return }
            NSWorkspace.shared.open(url)
        }

        private static func rowView(above view: NSView) -> NSView? {
            var ancestor = view.superview
            while let current = ancestor {
                if current is NSTableRowView { return current }
                ancestor = current.superview
            }
            return nil
        }
    }
}

// MARK: - Detail (center overlay)

/// The item detail, shown over the terminal in the center (by `TerminalPane`,
/// driven by `store.openIssueDetail`) — the editor/diff pattern, not the narrow
/// inspector. A native header (identifier, open-in-browser)
/// over the content: an issue shows the conversation (body + comments through
/// `MarkdownHTML` in a themed web view); a pull request adds the Conversation |
/// Files switch — files diff natively in the `GitDiffView` overlay (which stacks
/// on top of this one) against the fetched PR refs, JetBrains-style, no checkout needed.
/// Identity for the detail's load `.task`: the open item *and* the model driving it, so a
/// model swap (session switch to another repo) re-triggers the load even at the same issue number.
private struct DetailTaskKey: Hashable {
    let number: Int
    let model: ObjectIdentifier
}

struct IssueDetailView: View {
    let item: IssueSummary
    @ObservedObject var model: IssuesPanelModel
    @ObservedObject var settings: AppSettings
    let onBack: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private enum Tab: Hashable { case conversation, files }
    @State private var tab: Tab = .conversation

    var body: some View {
        VStack(spacing: 0) {
            header
            if item.kind == .pullRequest { prTabBar }
            switch tab {
            case .conversation: conversationBody
            case .files: filesBody
            }
        }
        // Match the diff/editor detail overlays: paint the whole view (header and
        // tab bar included) with the terminal background so the header doesn't fall
        // through to the host's `windowBackgroundColor` and seam against the body.
        .background(Color(nsColor: settings.terminalBackgroundColor))
        // Key on the model instance too: a session switch can swap in a different repo's model
        // while `item.number` is unchanged, and without re-firing here that fresh model would sit
        // on a spinner (its `loadDetail` never called). Re-firing costs nothing on a cache hit.
        .task(id: DetailTaskKey(number: item.number, model: ObjectIdentifier(model))) {
            await model.loadDetail(for: item)
        }
        .onExitCommand(perform: onBack)
    }

    /// The item identity on the left; actions on the right — all buttons are
    /// `TreeHeaderButton`s (the explorer header's quiet hover style), so they
    /// share the 22pt hit target and hover fill of every other pane header
    /// instead of bare 11pt glyphs. Dismissal is the toolbar's overlay-close
    /// button (and Esc), matching the editor/diff overlays — no in-header back.
    private var header: some View {
        HStack(spacing: 6) {
            OcticonView(
                icon: item.state.octicon(for: item.kind),
                size: 14,
                color: item.state.tint(for: item.kind)
            )
            .frame(width: 15)
            Text(item.identifier)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            // The title fills the bar so the open item reads from the header alone,
            // not only from the body's H1 — truncating at the tail when the pane is
            // narrow (the row's own treatment).
            Text(item.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if let url = item.url {
                TreeHeaderButton(huge: .squareArrowUpRight, help: "Open on GitHub") {
                    NSWorkspace.shared.open(url)
                }
            }
            // The content-area window controls (hide list / maximize / close) ride the header's
            // trailing edge, after the open-on-GitHub button.
            InspectorDetailChromeButtons()
        }
        .padding(.horizontal, 8)
        .frame(height: GitChangesView.topBarHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    /// The PR's inner switch, in the pane's shared miniature-track style. The
    /// trailing count previews how many files the Files tab holds.
    private var prTabBar: some View {
        HStack(spacing: 0) {
            CapsuleSwitch(
                segments: [("Conversation", Tab.conversation), ("Files", .files)],
                selection: $tab
            )
            Spacer(minLength: 0)
            if !model.prFiles.isEmpty {
                Text("\(model.prFiles.count)")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: GitChangesView.topBarHeight)
    }

    @ViewBuilder
    private var conversationBody: some View {
        if let detail = model.detail {
            IssueWebView(
                html: IssueDetailHTML.page(
                    detail,
                    theme: TraceTheme.resolve(settings: settings, colorScheme: colorScheme)
                ),
                background: settings.terminalBackgroundColor
            )
            // Fill like the error/progress branches below: without this, SwiftUI can size the
            // representable from the WKWebView's intrinsic (near-zero while it's mid-load), which
            // collapses the detail to a sliver — and the empty area paints the window background
            // (reads as a black window, most visibly across a minimize/restore relayout).
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.detailError {
            ContentUnavailableView("Couldn’t Load", huge: .github, description: Text(error))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var filesBody: some View {
        if !model.prFiles.isEmpty {
            // GitHub Desktop's "Files changed": file list on the left, the selected file's
            // diff on the right, rendered from the API's inline patches (no fetch, no git).
            PRFilesSplitView(
                files: model.prFiles, patches: model.prFilePatches,
                repoRoot: model.repoRoot, settings: settings, onClose: onBack
            )
        } else if model.prFilesLoading || (model.detail == nil && model.detailError == nil) {
            // The file list streams in behind the conversation (see `loadDetail`); show a
            // spinner while it's still in flight, so an early tap on Files isn't a wrong "No Files".
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No Files", huge: .fileDoc,
                description: Text("This pull request changes no files.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The pane's miniature capsule segmented switch — the git pane's Changes /
/// History track generalized over any value: our own always-visible track with
/// a Liquid Glass selection pill sliding between text segments.
private struct CapsuleSwitch<Value: Hashable>: View {
    let segments: [(title: String, value: Value)]
    @Binding var selection: Value

    @Namespace private var pillNamespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments, id: \.value) { seg in
                let active = selection == seg.value
                Text(seg.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 10)
                    .frame(height: 21)
                    .matchedGeometryEffect(id: seg.value, in: pillNamespace)
                    .contentShape(.capsule)
                    .onTapGesture { selection = seg.value }
            }
        }
        .background { selectionPill }
        .padding(2.5)
        .background { trackBackground }
        .animation(.snappy(duration: 0.28), value: selection)
    }

    // Flat track + pill on every OS: macOS 26's `.glassEffect` casts an ambient
    // drop shadow beneath the switch that reads as a stray shadow against the
    // detail's pale body, so both the pill and its track use plain capsule fills
    // with no shadow.
    private var selectionPill: some View {
        Capsule(style: .continuous)
            .fill(Color(nsColor: .controlColor))
            .matchedGeometryEffect(id: selection, in: pillNamespace, isSource: false)
    }

    private var trackBackground: some View {
        Capsule(style: .continuous).fill(Color.primary.opacity(0.06))
    }
}

// MARK: - Detail HTML

/// Assembles the self-contained detail page: title + meta header, the body,
/// then each comment as a panel — all markdown through `MarkdownHTML` in
/// `documentMode`, so raw HTML (bot comments, `<picture>`/`<img>`/tables) renders
/// through the GitHub-mirroring `HTMLSanitizer` whitelist the way GitHub itself
/// does, colored from the live `TraceTheme`.
private enum IssueDetailHTML {
    static func page(_ detail: IssueDetail, theme: TraceTheme) -> String {
        let s = detail.summary
        let labels = s.labels.map {
            "<span class=\"label\" style=\"border-color:#\($0.colorHex.isEmpty ? "888888" : $0.colorHex)\">\(escape($0.name))</span>"
        }.joined()
        let body = detail.bodyMarkdown.isEmpty
            ? "<p class=\"empty\">No description provided.</p>"
            : MarkdownHTML.html(detail.bodyMarkdown, documentMode: true)
        let comments = detail.comments.map { comment in
            """
            <section class="comment">
            <div class="who">\(avatar(comment.avatarURL))<b>\(escape(comment.author))</b> · \(relative(comment.createdAt))</div>
            \(MarkdownHTML.html(comment.bodyMarkdown, documentMode: true))
            </section>
            """
        }.joined()
        let page = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>\(css(theme))</style></head><body>
        <header>
        <h1>\(escape(s.title))</h1>
        <div class="meta">\(escape(s.identifier)) · <span class="state">\(s.state.label)</span> · \(avatar(detail.authorAvatarURL))\(escape(s.author)) opened \(relative(detail.createdAt))</div>
        \(labels.isEmpty ? "" : "<div class=\"labels\">\(labels)</div>")
        </header>
        <article class="body">\(body)</article>
        \(comments)
        </body></html>
        """
        return routeImages(page)
    }

    /// Point every `<img>`/`<source>` at the token-authenticating loader so a private
    /// repo's attachments resolve — the raw `<img src>` GitHub embeds targets
    /// `github.com/user-attachments/…`, which 404s anonymously and only returns bytes
    /// with the connect token attached (see `GitHubAssetSchemeHandler`). Only `src`/
    /// `srcset` are rewritten, so `href` links still open in the browser as before.
    private static func routeImages(_ html: String) -> String {
        let scheme = GitHubAssetSchemeHandler.scheme
        return html
            .replacingOccurrences(of: "src=\"https://", with: "src=\"\(scheme)://")
            .replacingOccurrences(of: "srcset=\"https://", with: "srcset=\"\(scheme)://")
    }

    private static func avatar(_ url: URL?) -> String {
        guard let url, url.scheme == "https" else { return "" }
        return "<img class=\"avatar\" src=\"\(escape(url.absoluteString))\" alt=\"\">"
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return escape(formatter.localizedString(for: date, relativeTo: Date()))
    }

    private static func css(_ theme: TraceTheme) -> String {
        """
        :root { color-scheme: \(theme.isDark ? "dark" : "light"); }
        body { margin: 0; padding: 14px 16px 24px; background: \(theme.background);
               color: \(theme.foreground); font: 13px/1.55 -apple-system, sans-serif;
               word-wrap: break-word; }
        header h1 { font-size: 16px; line-height: 1.35; margin: 0 0 6px; }
        .meta { color: \(theme.secondary); font-size: 11.5px; }
        .meta .state { font-weight: 600; }
        .labels { margin-top: 8px; }
        .label { display: inline-block; border: 1px solid; border-radius: 9px;
                 padding: 1px 8px; margin: 0 4px 4px 0; font-size: 10.5px; }
        .avatar { width: 16px; height: 16px; border-radius: 50%; vertical-align: -3px;
                  margin-right: 4px; }
        .body, .comment { background: \(theme.panel); border-radius: 8px;
                          padding: 10px 12px; margin-top: 12px; }
        .comment .who { color: \(theme.secondary); font-size: 11.5px; margin-bottom: 6px; }
        .comment .who b { color: \(theme.foreground); font-weight: 600; }
        .empty { color: \(theme.secondary); font-style: italic; }
        a { color: \(theme.accent); text-decoration: none; }
        a:hover { text-decoration: underline; }
        p, ul, ol, blockquote, pre, table { margin: 0 0 10px; }
        *:last-child { margin-bottom: 0; }
        code { font: 11.5px ui-monospace, monospace; background: rgba(128,128,128,.16);
               border-radius: 4px; padding: 1px 4px; }
        pre { background: rgba(128,128,128,.12); border-radius: 6px; padding: 8px 10px;
              overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { border-left: 3px solid \(theme.secondary); margin-left: 0;
                     padding-left: 10px; color: \(theme.secondary); }
        img { max-width: 100%; }
        table { border-collapse: collapse; }
        td, th { border: 1px solid rgba(128,128,128,.3); padding: 3px 8px; }
        h1, h2, h3, h4 { font-size: 13.5px; margin: 12px 0 6px; }
        hr { border: none; border-top: 1px solid rgba(128,128,128,.3); }
        li.task { list-style: none; margin-left: -18px; }
        .task-box { vertical-align: -3px; margin-right: 4px; color: \(theme.secondary); }
        .task-box.checked { color: \(theme.accent); }
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// The trace's minimal `WKWebView` host, re-declared privately for the detail
/// page: transparent while loading, links open in the browser.
private struct IssueWebView: NSViewRepresentable {
    let html: String
    let background: NSColor

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Attachments in a private repo need the connect token; route their <img> loads
        // through the handler so it can attach the bearer WebKit can't add itself.
        config.setURLSchemeHandler(context.coordinator.assetHandler,
                                   forURLScheme: GitHubAssetSchemeHandler.scheme)
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(html, baseURL: nil)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(lastHTML: html) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String
        let assetHandler = GitHubAssetSchemeHandler()
        init(lastHTML: String) { self.lastHTML = lastHTML }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

/// Loads the detail page's images with the connect token so a *private* repo's
/// attachments resolve. GitHub embeds them as `github.com/user-attachments/…`,
/// which 404s anonymously and only returns the bytes with a bearer attached — but
/// WebKit can't add an `Authorization` header to sub-resource loads. `IssueDetailHTML`
/// rewrites image URLs to this custom scheme; the handler restores `https`, adds the
/// bearer for GitHub hosts, and streams the result back. (URLSession drops the header
/// on the cross-origin redirect to the signed CDN URL, matching `curl -L`'s default,
/// so the presigned download isn't rejected.)
final class GitHubAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "x-termio-ghasset"

    private var live = Set<ObjectIdentifier>()
    private let lock = NSLock()

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        lock.lock(); live.insert(id); lock.unlock()

        // Only feed a task that hasn't been stopped — calling back into a stopped
        // `WKURLSchemeTask` traps. `stop` removes the id, so `settle` no-ops after it.
        func settle(_ body: (any WKURLSchemeTask) -> Void) {
            lock.lock(); let ok = live.remove(id) != nil; lock.unlock()
            if ok { body(task) }
        }

        guard let raw = task.request.url?.absoluteString,
              let url = URL(string: raw.replacingOccurrences(
                  of: "\(Self.scheme)://", with: "https://")) else {
            settle { $0.didFailWithError(URLError(.badURL)) }
            return
        }

        var request = URLRequest(url: url)
        if let host = url.host,
           host == "github.com" || host.hasSuffix(".githubusercontent.com"),
           let token = GitHubIssueAuth.storedToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    settle { $0.didFailWithError(error) }
                } else if let data, let response {
                    settle {
                        // Frame the payload under the request's own custom-scheme URL so
                        // WebKit doesn't reject a response that arrived over https.
                        let framed = URLResponse(
                            url: $0.request.url ?? url, mimeType: response.mimeType,
                            expectedContentLength: data.count, textEncodingName: nil)
                        $0.didReceive(framed)
                        $0.didReceive(data)
                        $0.didFinish()
                    }
                } else {
                    settle { $0.didFailWithError(URLError(.badServerResponse)) }
                }
            }
        }.resume()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        lock.lock(); live.remove(ObjectIdentifier(task)); lock.unlock()
    }
}

private extension Date {
    /// Compact age for the row's hover metadata — "5m", "3h", "2d", "6w".
    var issueRowAge: String {
        let seconds = max(0, -timeIntervalSinceNow)
        switch seconds {
        case ..<3600: return "\(max(1, Int(seconds / 60)))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(86_400 * 28): return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / (86_400 * 7)))w"
        }
    }
}
