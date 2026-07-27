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
                store.issuesModel = model
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
        HStack(spacing: 0) {
            if model.capabilities?.pullRequests == true { kindSwitch }
            Spacer(minLength: 0)
            filterMenu
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: GitChangesView.topBarHeight)
    }

    private var kindSwitch: some View {
        CapsuleSwitch(
            segments: [("Issues", IssueKind.issue), ("Pull Requests", .pullRequest)],
            selection: Binding(get: { model.query.kind }, set: { model.query.kind = $0 })
        )
    }

    private var filterMenu: some View {
        Menu {
            Toggle("Open Only", isOn: Binding(
                get: { model.query.openOnly },
                set: { model.query.openOnly = $0 }
            ))
            Toggle("Assigned to Me", isOn: Binding(
                get: { model.query.assignedToMe },
                set: { model.query.assignedToMe = $0 }
            ))
            // Label filter, GitHub's own semantics (multi-select = AND). The
            // repo's full label set, checkmarked from the current query.
            if !model.availableLabels.isEmpty {
                Divider()
                Section("Labels") {
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
            // views — so the label is only a clear hit-area, and the funnel is
            // painted behind it (see .background below).
            Color.clear
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background {
            // The funnel takes the accent color while any label filter narrows
            // the list, so a filtered view can't be mistaken for the full one.
            HugeIconView(
                icon: .filter, size: 13,
                color: model.query.labels.isEmpty ? .secondary : .accentColor,
                lineWidthOverride: 1.5
            )
            .allowsHitTesting(false)
        }
        .help("Filter")
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
        } else if let error = model.errorMessage {
            ContentUnavailableView(
                "Couldn’t Load",
                huge: .github,
                description: Text(error)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

// MARK: - Detail (center overlay)

/// The item detail, shown over the terminal in the center (by `TerminalPane`,
/// driven by `store.openIssueDetail`) — the editor/diff pattern, not the narrow
/// inspector. A native header (back, identifier, checkout for PRs, open-in-browser)
/// over the content: an issue shows the conversation (body + comments through
/// `MarkdownHTML` in a themed web view); a pull request adds the Conversation |
/// Files switch — files diff natively in the `GitDiffView` overlay (which stacks
/// on top of this one) against the fetched PR refs, JetBrains-style, no checkout needed.
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
        .task(id: item.number) { await model.loadDetail(for: item) }
        .onExitCommand(perform: onBack)
        .alert(
            "Couldn’t Check Out",
            isPresented: Binding(
                get: { model.checkoutError != nil },
                set: { if !$0 { model.checkoutError = nil } }
            )
        ) {
            Button("OK") { model.checkoutError = nil }
        } message: {
            Text(model.checkoutError ?? "")
        }
    }

    /// Back on the left; the item identity in the middle; actions on the right —
    /// all buttons are `TreeHeaderButton`s (the explorer header's quiet hover
    /// style), so they share the 22pt hit target and hover fill of every other
    /// pane header instead of bare 11pt glyphs.
    private var header: some View {
        HStack(spacing: 6) {
            TreeHeaderButton(huge: .chevronLeft, help: "Back", action: onBack)
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
            Spacer(minLength: 6)
            if item.kind == .pullRequest, model.prInfo != nil {
                if model.isCheckingOut {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 22, height: 22)
                } else {
                    TreeHeaderButton(
                        huge: .gitPullRequest,
                        help: "Check Out \(model.prInfo?.headRef ?? "Branch")"
                    ) {
                        Task { await model.checkout() }
                    }
                }
            }
            if let url = item.url {
                TreeHeaderButton(huge: .squareArrowUpRight, help: "Open on GitHub") {
                    NSWorkspace.shared.open(url)
                }
            }
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
        } else if model.detail == nil, model.detailError == nil {
            // The file list arrives with the detail; show a spinner until it lands.
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

    @ViewBuilder
    private var selectionPill: some View {
        if #available(macOS 26.0, *) {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: .capsule)
                .matchedGeometryEffect(id: selection, in: pillNamespace, isSource: false)
        } else {
            Capsule(style: .continuous)
                .fill(Color(nsColor: .controlColor))
                .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
                .matchedGeometryEffect(id: selection, in: pillNamespace, isSource: false)
        }
    }

    @ViewBuilder
    private var trackBackground: some View {
        if #available(macOS 26.0, *) {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.tint(Color.white.opacity(0.12)), in: .capsule)
        } else {
            Capsule(style: .continuous).fill(Color.primary.opacity(0.06))
        }
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
        return """
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
        let view = WKWebView()
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
