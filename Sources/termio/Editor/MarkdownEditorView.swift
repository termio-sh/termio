import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The rendered face of `FileEditorView` for Markdown: the document drawn as a document,
/// and — unlike the read-only reader it replaces — editable in place.
///
/// It hosts the vendored domd kernel (`Resources/domd`, see the README there) in a
/// `WKWebView`. domd's model *is* the Markdown text, so this face and the Highlightr
/// source face edit the same bytes; there is no conversion layer between them and no
/// third representation to keep in sync.
///
/// **Single writer.** Both faces can now write the buffer, so exactly one owns it at a
/// time and ownership follows the visible face (`isActive`). While this face is up it
/// reports every change back on a short debounce, which is what keeps auto-save and the
/// dirty flag honest; while it is dormant it writes nothing and accepts pushes instead.
/// The flip out of it is ordered by `flush(then:)` — the host pulls the document *before*
/// it changes face, so an edit made in the last few milliseconds cannot be lost to the
/// debounce. Getting that order wrong is how a flip silently eats the edits just made.
struct MarkdownEditorView: NSViewRepresentable {
    let source: String
    let fileURL: URL
    let theme: DocumentTheme
    let fontFamily: String
    /// False mounts the kernel view-only: a device copy or a git revision is shown, never
    /// edited. The page is rebuilt when this changes, so it can never be a live toggle
    /// that leaves a stale `contenteditable` behind.
    let isEditable: Bool
    /// Whether this is the face on screen. A dormant page stays mounted (the ZStack keeps
    /// both faces alive) but must never take focus or report an edit.
    let isActive: Bool
    /// How the host reaches this page to pull the document before flipping away from it.
    let handle: MarkdownEditorHandle
    /// An edit made in this face, already debounced on the page side.
    let onEdit: (String) -> Void
    /// A document handed to the page, paired with the kernel's own serialization of it
    /// before any edit. The host merges an edit against that pair so the file keeps its own
    /// formatting rather than taking the kernel's canonical one — see `MarkdownWriteBack`.
    /// The two travel together because a merge against a mismatched pair is worse than none.
    let onCanonical: (_ document: String, _ canonical: String) -> Void
    /// A page-side failure worth surfacing rather than swallowing.
    let onFailure: (String) -> Void

    /// Serves the vendored page, the shared engines, and the document's own folder.
    /// Nothing else is reachable: the page's CSP allows no network at all, and this
    /// handler is the only other way bytes get in.
    static let scheme = "termio-domd"

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(
            DomdSchemeHandler(documentDirectory: fileURL.deletingLastPathComponent()),
            forURLScheme: Self.scheme)
        config.userContentController.add(context.coordinator, name: "domd")
        // The kernel's own state; a page reload must never inherit the last document's.
        config.websiteDataStore = .nonPersistent()

        let view = DomdWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.isHidden = !isActive
        context.coordinator.configure(
            owner: self, webView: view, appearance: appearance, source: source)
        // The retry: whenever the view gains a window, ask again. Idempotent, so an
        // extra call costs nothing and a missed one is no longer permanent.
        view.onWindowChange = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.claimFocusIfWanted(view)
        }
        handle.coordinator = context.coordinator
        view.load(URLRequest(url: pageURL))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        handle.coordinator = context.coordinator
        context.coordinator.update(owner: self, webView: view, appearance: appearance, source: source)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.detach(from: view)
    }

    private var appearance: Appearance {
        Appearance(theme: theme, fontFamily: fontFamily, isDark: theme.isDark)
    }

    private var pageURL: URL {
        URL(string: "\(Self.scheme):///index.html")
            // Unreachable — the string above is a literal and parses — but the editor
            // must not trap on a URL, so a failure lands on a page that says so.
            ?? URL(fileURLWithPath: "/")
    }

    /// Everything about the page's look that can change without rebuilding it.
    ///
    /// The CJK register is deliberately not here. It is a property of the document, not
    /// of the theme, and this struct is rebuilt on every SwiftUI update — so riding here
    /// it was re-decided on every keystroke to answer a question only a new document can
    /// change. It is decided once per document instead, in `loadDocument`.
    struct Appearance: Equatable {
        let theme: DocumentTheme
        let fontFamily: String
        let isDark: Bool
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private var onEdit: (String) -> Void = { _ in }
        private var onCanonical: (String, String) -> Void = { _, _ in }
        private var onFailure: (String) -> Void = { _ in }
        private var isEditable = false
        private var isActive = false
        private var appearance: Appearance?
        /// The document the page was last given, and the one it last reported. The
        /// buffer is pushed in only when it differs from both, which is what stops a
        /// reported edit from being echoed straight back as a host push.
        private var pushedSource = ""
        private var reportedSource: String?
        private var pageIsReady = false
        /// Whether the document now in the page is set in the CJK register — looser
        /// leading and tracking, no optical negative tracking on headings. Decided once
        /// per document (see `loadDocument`), because deciding it walks every scalar in
        /// the document: about 5ms on an 80KB file, which is not a thing to do on a
        /// keystroke. See `MarkdownReaderRenderer.isCJK`.
        private var pageIsCJK = false
        /// A document pushed before the page could accept it, replayed on `ready`.
        private var pendingLoad: String?
        /// Whether the page's full-screen viewer is up. Escape belongs to it while it is,
        /// and the host has to know because the two claimants are on opposite sides of
        /// the web view: the page's own listener never sees AppKit's `cancelOperation:`.
        private var viewerIsOpen = false
        /// Callers waiting on `flush` — the flip out of this face. Answered by the
        /// page, or by `failWaiters` if it never replies.
        private var flushWaiters: [(String?) -> Void] = []
        private var flushTimeout: Task<Void, Never>?
        private weak var webView: WKWebView?

        func configure(owner: MarkdownEditorView, webView: WKWebView,
                       appearance: Appearance, source: String) {
            self.webView = webView
            onEdit = owner.onEdit
            onCanonical = owner.onCanonical
            onFailure = owner.onFailure
            isEditable = owner.isEditable
            isActive = owner.isActive
            self.appearance = appearance
            pushedSource = source
        }

        func update(owner: MarkdownEditorView, webView: WKWebView,
                    appearance next: Appearance, source: String) {
            onEdit = owner.onEdit
            onCanonical = owner.onCanonical
            onFailure = owner.onFailure
            self.webView = webView

            if webView.isHidden == owner.isActive { webView.isHidden = !owner.isActive }
            let becameActive = owner.isActive && !isActive
            isActive = owner.isActive

            if appearance != next {
                appearance = next
                applyAppearance(next, to: webView)
            }
            if isEditable != owner.isEditable {
                isEditable = owner.isEditable
                configurePage(on: webView)
            }
            // The host is the source of truth for text it authored itself (a load, a
            // revert, the source face's keystrokes). Text this page reported is already
            // in the page, and pushing it back would reset the caret on every keystroke.
            if source != pushedSource, source != reportedSource {
                pushedSource = source
                loadDocument(source, into: webView)
            }
            if becameActive { claimFocusIfWanted(webView) }
        }

        func detach(from webView: WKWebView) {
            flushTimeout?.cancel()
            failWaiters()
            webView.configuration.userContentController
                .removeScriptMessageHandler(forName: "domd")
        }

        /// Claims the Escape keystroke if the page's viewer is up, and gives it up in
        /// the same call.
        ///
        /// Consuming rather than merely reading is what makes the ordering deterministic:
        /// the page closes its overlay on its own Escape and reports "closed", but that
        /// message and AppKit's `cancelOperation:` race. Whichever arrives first, exactly
        /// one Escape is absorbed here, so the overlay closes OR the editor does — never
        /// both on one keypress.
        func consumeViewerEscape() -> Bool {
            guard viewerIsOpen else { return false }
            viewerIsOpen = false
            return true
        }

        /// The document as the page has it *now*, pending debounce included.
        ///
        /// This is the flip out of this face: the caller must wait for the answer
        /// before changing which face is visible, or the last edits are lost. `nil`
        /// means the page could not answer — the caller keeps the buffer it already has
        /// rather than replacing it with a guess.
        func flush(then completion: @escaping (String?) -> Void) {
            guard let webView, pageIsReady else { completion(nil); return }
            flushWaiters.append(completion)
            // A page that never answers must not strand the flip forever.
            flushTimeout?.cancel()
            flushTimeout = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.failWaiters()
            }
            // `callAsyncJavaScript`, not `evaluateJavaScript`: the page's flush awaits
            // the kernel's `flushPendingInput`, so it is a promise. `evaluateJavaScript`
            // would hand back the promise object rather than the document.
            webView.callAsyncJavaScript(
                "return await (window.termioDomd?.flush() ?? null);",
                arguments: [:], in: nil, in: .page
            ) { [weak self] result in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.flushTimeout?.cancel()
                    self.flushTimeout = nil
                    switch result {
                    case .failure(let error):
                        self.onFailure(error.localizedDescription)
                        self.failWaiters()
                    case .success(let value):
                        // `null` is the page saying "nothing changed" — the host keeps
                        // the buffer it has rather than adopting a canonicalized copy.
                        guard let markdown = value as? String else {
                            self.answerWaiters(nil)
                            return
                        }
                        self.reportedSource = markdown
                        self.answerWaiters(markdown)
                    }
                }
            }
        }

        private func answerWaiters(_ markdown: String?) {
            let waiting = flushWaiters
            flushWaiters = []
            for completion in waiting { completion(markdown) }
        }

        private func failWaiters() {
            let waiting = flushWaiters
            flushWaiters = []
            for completion in waiting { completion(nil) }
        }

        // MARK: Page plumbing

        private func loadDocument(_ markdown: String, into webView: WKWebView) {
            // Before the page says `ready` there is nothing to call. The initial state
            // written in `didFinish` normally carries the document, but a push that
            // lands between that write and `ready` would fall between them — so it is
            // held and replayed instead of dropped.
            guard pageIsReady else { pendingLoad = markdown; return }
            guard let encoded = DomdScript.string(markdown) else {
                onFailure(localized("This document could not be handed to the editor."))
                return
            }
            // The register the document is set in, re-decided only because the document
            // itself changed. Pushed before the load so the page is never briefly drawn
            // in the wrong one.
            let isCJK = MarkdownReaderRenderer.isCJK(markdown)
            if isCJK != pageIsCJK {
                pageIsCJK = isCJK
                configurePage(on: webView)
            }
            // The load and the baseline read are one evaluation because `load` is
            // synchronous: what comes back is the kernel's serialization of exactly the
            // document just handed over, with no edit in it. That is the base an edit is
            // merged against — without it a typed character would carry the whole
            // document's canonical formatting into the file (see `MarkdownWriteBack`).
            // A page that did not fully hydrate answers `null` and nothing is merged.
            webView.evaluateJavaScript("""
                window.termioDomd?.load(\(encoded));
                window.termioDomd?.isHydrated() ? window.termioDomd.markdown() : null;
                """) { [weak self] value, error in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let error {
                        self.onFailure(error.localizedDescription)
                        return
                    }
                    guard let canonical = value as? String else { return }
                    self.onCanonical(markdown, canonical)
                }
            }
        }

        private func configurePage(on webView: WKWebView) {
            guard let appearance else { return }
            guard let payload = DomdScript.object([
                "editable": isEditable,
                "appearance": appearance.isDark ? "dark" : "light",
                "cjk": pageIsCJK,
            ]) else { return }
            evaluate("window.termioDomdConfigure?.(\(payload))", on: webView)
        }

        private func applyAppearance(_ appearance: Appearance, to webView: WKWebView) {
            let theme = appearance.theme
            let tokens: [(String, String)] = [
                ("--domd-page-bg", theme.background),
                ("--domd-page-fg", theme.foreground),
                ("--domd-panel", theme.panel),
                ("--domd-accent", theme.accent),
                ("--domd-border", theme.isDark ? "rgba(255,255,255,0.14)" : "rgba(0,0,0,0.12)"),
                // Quattro carries no Han glyphs, so a Chinese run falls through to
                // whatever comes next. The Apple CJK faces are named rather than left to
                // `-apple-system`, exactly as the reader names them: this is the face
                // Chinese prose is set in and it must not depend on stack order.
                ("--font-prose", "\"iA Writer Quattro\", \"PingFang SC\", \"PingFang TC\", "
                    + "\"Hiragino Sans GB\", -apple-system, system-ui, sans-serif"),
                // The terminal face, so code here matches the source face you flipped
                // from and the two read as one document.
                ("--font-mono", MarkdownReaderRenderer.monoStack(appearance.fontFamily)),
            ]
            // The reader's own highlight theme, injected unchanged, so a fence is
            // coloured identically in both faces. Small (about 1KB) and re-sent only
            // when the appearance changes.
            // The reader's own highlight theme, handed over unchanged. The page
            // rewrites its `.hljs-*` selectors to the `.token.*` the kernel emits —
            // the translation lives there, beside the tokenizer that needs the same
            // map, so a colour is still defined in exactly one file.
            if let css = DomdScript.string(MarkdownSkin.highlightTheme(dark: theme.isDark)) {
                evaluate("window.termioDomdSetHighlightTheme?.(\(css))", on: webView)
            }
            let writes = tokens.compactMap { name, value -> String? in
                guard let encodedName = DomdScript.string(name),
                      let encodedValue = DomdScript.string(value) else { return nil }
                return "document.documentElement.style.setProperty(\(encodedName), \(encodedValue));"
            }
            evaluate(writes.joined(), on: webView)
            configurePage(on: webView)
        }

        /// Takes first responder so typing and ⌘C reach the page rather than the terminal
        /// surface beneath the overlay.
        ///
        /// Idempotent and safe to call from anywhere: it re-reads the conditions rather
        /// than trusting the moment it was called. `DomdFocus.shouldClaim` is the rule,
        /// and the `isActive` half of it is what keeps a dormant face — still mounted in
        /// the ZStack beside the source editor — from stealing the caret.
        func claimFocusIfWanted(_ webView: WKWebView) {
            DispatchQueue.main.async { [weak self, weak webView] in
                guard let self, let webView, let window = webView.window else { return }
                guard DomdFocus.shouldClaim(isActive: self.isActive,
                                            isHidden: webView.isHidden,
                                            hasWindow: true) else { return }
                guard window.firstResponder !== webView else { return }   // already ours
                window.makeFirstResponder(webView)
            }
        }

        private func evaluate(_ script: String, on webView: WKWebView) {
            guard !script.isEmpty else { return }
            webView.evaluateJavaScript(script) { [weak self] _, error in
                guard let error else { return }
                MainActor.assumeIsolated { self?.onFailure(error.localizedDescription) }
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let appearance else { return }
            // Colours and fonts only. The document is not handed over here: this runs
            // after the page's own scripts, by which time the editor has already
            // mounted and would never read it. It arrives on `ready` instead.
            applyAppearance(appearance, to: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onFailure(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            onFailure(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if url.fragment != nil, url.path == webView.url?.path {
                decisionHandler(.allow)          // an in-page anchor
            } else if url.scheme == MarkdownEditorView.scheme {
                NSWorkspace.shared.open(URL(fileURLWithPath: url.path))
                decisionHandler(.cancel)
            } else {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            }
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            receive(body)
        }

        /// The page's messages, separated from the `WKScriptMessage` that carries them so
        /// the routing can be exercised without a live web view.
        func receiveForTesting(_ body: [String: Any]) { receive(body) }

        private func receive(_ body: [String: Any]) {
            guard let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                pageIsReady = true
                // The document is delivered HERE, and only here.
                //
                // The page mounts while its own <script> runs, which is before
                // `didFinish` can inject anything — so an initial state written there
                // is read by nobody, and the first `update()` sees `source` already
                // equal to `pushedSource` and loads nothing. The face came up empty.
                // Pushing on the page's own readiness signal removes the ordering
                // assumption entirely: one delivery path, driven by the side that
                // knows when it is ready.
                if let webView {
                    let document = pendingLoad ?? pushedSource
                    pendingLoad = nil
                    loadDocument(document, into: webView)
                    claimFocusIfWanted(webView)
                }
            case "edit":
                // A dormant or view-only page is not the buffer's owner and its word
                // is ignored, whatever it says.
                guard let markdown = body["markdown"] as? String, isEditable, isActive else { return }
                reportedSource = markdown
                pushedSource = markdown
                onEdit(markdown)
            case "viewer":
                viewerIsOpen = (body["state"] as? String) == "open"
            case "diagnostic":
                // The page's own view of a click: whether it arrived, what it landed on,
                // and whether a caret followed. Logged rather than surfaced — it answers
                // "did the click reach the page at all" without a banner.
                Log.markdownFace.debug("\((body["message"] as? String) ?? "", privacy: .public)")
            case "error":
                onFailure((body["message"] as? String)
                    ?? localized("The Markdown editor reported a problem."))
            default:
                break
            }
        }

    }
}

/// Whether the rendered face should be holding first responder right now.
///
/// Pure so the rule can be tested: both faces stay mounted in the ZStack, so a DORMANT
/// rendered face must never take focus from the source editor beside it, and a face
/// that is not yet in a window cannot take it at all. Getting the second wrong is how
/// the face ends up unclickable; getting the first wrong is how the source editor loses
/// the caret out from under the user.
enum DomdFocus {
    static func shouldClaim(isActive: Bool, isHidden: Bool, hasWindow: Bool) -> Bool {
        isActive && !isHidden && hasWindow
    }
}

/// The face's own `WKWebView`.
///
/// Two AppKit behaviours the rendered face needs and the default does not give:
///
/// - `acceptsFirstMouse`: without it AppKit spends the first click activating the view
///   and the page never sees it — the "first click does nothing, the second works"
///   symptom. An editor surface should take the caret on the click that reaches it.
/// - `viewDidMoveToWindow`: focus can only be claimed once there is a window to claim it
///   in. The page's `ready` message is the natural moment to ask, but the view may not be
///   in a window yet, and nothing used to retry — a Markdown file opens straight into the
///   rendered face, so there is no later "became active" transition to catch it either.
final class DomdWebView: WKWebView {
    /// Called when the view lands in a window, so a focus claim that was too early can
    /// be retried. Set by the coordinator.
    var onWindowChange: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}

/// The host's handle on a mounted `MarkdownEditorView`.
///
/// `NSViewRepresentable` gives the parent no way to reach its own coordinator, and the
/// flip out of the rendered face has to reach it — that face owns the buffer, so the
/// document must be pulled from it before the flip, not after. A reference type held as
/// `@State`: it survives view rebuilds, and the weak coordinator means a dismantled page
/// leaves the handle harmlessly empty rather than answering for a view that is gone.
@MainActor
final class MarkdownEditorHandle {
    fileprivate weak var coordinator: MarkdownEditorView.Coordinator?

    /// Whether this Escape belongs to the page's full-screen viewer rather than to the
    /// editor. Consumes the claim, so one keystroke closes one thing.
    func consumeViewerEscape() -> Bool {
        coordinator?.consumeViewerEscape() ?? false
    }

    /// The document as the page has it now, debounced edits included; `nil` when there is
    /// no page to ask. The caller must not change face until this answers.
    func flush(then completion: @escaping (String?) -> Void) {
        guard let coordinator else { completion(nil); return }
        coordinator.flush(then: completion)
    }
}

/// Serves the rendered face's three kinds of bytes and nothing else: the vendored page
/// from `Resources/domd`, the shared KaTeX and mermaid engines from the bundle root, and
/// images from the open document's own folder.
///
/// The page's CSP forbids the network outright, so this handler is the only way anything
/// reaches it. Image requests are confined to the document's directory — a `../` in a
/// Markdown image path resolves before the check, so it cannot walk out of it.
private final class DomdSchemeHandler: NSObject, WKURLSchemeHandler {
    private let documentDirectory: URL

    init(documentDirectory: URL) {
        self.documentDirectory = documentDirectory.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(CocoaError(.fileReadUnknown))
            return
        }
        guard let fileURL = resolve(url) else {
            urlSchemeTask.didFailWithError(CocoaError(.fileReadNoSuchFile))
            return
        }
        guard let data = FileManager.default.contents(atPath: fileURL.path) else {
            urlSchemeTask.didFailWithError(CocoaError(.fileReadNoSuchFile))
            return
        }
        urlSchemeTask.didReceive(URLResponse(
            url: url, mimeType: Self.mimeType(for: fileURL),
            expectedContentLength: data.count, textEncodingName: nil))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    /// Maps a page URL onto a file, or `nil` for anything outside the allowed roots.
    private func resolve(_ url: URL) -> URL? {
        switch DomdResource.classify(path: url.path) {
        case .none:
            return nil
        case .image(let relativePath):
            return DomdResource.imageURL(forRelativePath: relativePath, under: documentDirectory)
        case .engine(let name):
            // Shared with the reader and the Issues pane, so they live at the bundle
            // root rather than in the vendored folder.
            return Bundle.termioResources.url(
                forResource: (name as NSString).deletingPathExtension, withExtension: "js")
        case .font(let name):
            // `.process("Resources/Fonts")` flattens the woff2s to the bundle root.
            return Bundle.termioResources.url(
                forResource: (name as NSString).deletingPathExtension, withExtension: "woff2")
        case .page(let name):
            return Bundle.termioResources.url(
                forResource: (name as NSString).deletingPathExtension,
                withExtension: (name as NSString).pathExtension,
                subdirectory: "domd")
        }
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": return "text/html"
        case "js": return "text/javascript"
        case "css": return "text/css"
        case "woff2": return "font/woff2"
        default:
            return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
        }
    }
}


/// What a URL the rendered face asks for is allowed to mean.
///
/// Split out from the scheme handler because this is the security boundary and it is
/// pure: the page's CSP forbids the network outright, so every byte that reaches it
/// comes through here, and "which paths are reachable" is worth pinning down in a test
/// rather than discovering from a bug report.
enum DomdResource: Equatable {
    /// An image, by its path relative to the open document's folder.
    case image(String)
    /// KaTeX or mermaid, shared with the reader and served from the bundle root.
    case engine(String)
    /// One of the vendored page's own files.
    case page(String)
    /// A prose webfont, served from the bundle root rather than inlined as base64.
    case font(String)

    /// The vendored page's files. An allow-list rather than a directory walk, so a
    /// crafted path can never read the rest of the resource bundle.
    static let pageFiles: Set<String> = ["index.html", "app.js", "app.css", "domd.css"]
    static let engineFiles: Set<String> = [
        "katex.min.js", "mermaid.min.js", "highlight.min.js",
    ]

    /// The bundled iA Writer Quattro V faces (SIL OFL; licence beside the woff2s in
    /// Resources/Fonts). An explicit allow-list for the same reason the others are one:
    /// a name arriving from the page must never be able to walk the resource bundle.
    ///
    /// The reader inlines these as ~135KB of base64 `@font-face` because
    /// `loadHTMLString` gives its WebContent process no read access to the bundle. This
    /// page has a scheme handler, so it fetches them instead — the CSP already allows
    /// `font-src 'self'`, and the bytes are served once and cached rather than rebuilt
    /// into every document.
    static let fontFiles: Set<String> = [
        "iAWriterQuattroV.woff2", "iAWriterQuattroV-Italic.woff2",
    ]

    static func classify(path: String) -> DomdResource? {
        if path.hasPrefix("/img/") {
            let encoded = String(path.dropFirst("/img/".count))
            guard !encoded.isEmpty else { return nil }
            return .image(encoded.removingPercentEncoding ?? encoded)
        }
        // A single path component and nothing else: `/a/../app.js` never resolves to
        // the page, and neither does a nested path into the resource bundle.
        guard path.hasPrefix("/"), !path.dropFirst().contains("/") else { return nil }
        let name = String(path.dropFirst())
        if engineFiles.contains(name) { return .engine(name) }
        if fontFiles.contains(name) { return .font(name) }
        if pageFiles.contains(name) { return .page(name) }
        return nil
    }

    /// An image path resolved against the open document's folder, or `nil` when it
    /// points outside it. A Markdown image path is somebody else's text, so `../../`
    /// must not walk out of the document's directory into the rest of the disk.
    static func imageURL(forRelativePath path: String, under directory: URL) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/") else { return nil }
        let root = directory.standardizedFileURL
        // `appendingPathComponent`, not `URL(fileURLWithPath:relativeTo:)`: the latter
        // treats a directory URL without a trailing slash as a file and resolves the
        // path against its *parent*, which would silently widen the confinement by one
        // level.
        let candidate = root.appendingPathComponent(path).standardizedFileURL
        // Compared by path component, not by string prefix: a sibling folder named
        // `docs-private` shares the prefix of `docs` but is a different directory.
        let rootParts = root.pathComponents
        let candidateParts = candidate.pathComponents
        guard candidateParts.count > rootParts.count,
              Array(candidateParts.prefix(rootParts.count)) == rootParts
        else { return nil }
        return candidate
    }
}


/// How the host writes a value into the page.
///
/// The seam where a document's own text could become script: the buffer is handed over
/// as a JavaScript literal, and real Markdown contains `</script>` in fenced examples.
/// JSON does the escaping — nothing here is hand-rolled — plus the three characters JSON
/// leaves raw that JavaScript does not tolerate in a script element.
enum DomdScript {
    static func string(_ value: String) -> String? { literal(value) }
    static func object(_ value: [String: Any]) -> String? { literal(value) }

    private static func literal(_ value: Any) -> String? {
        // The array wrapper is what makes a bare string a valid JSON top level.
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(data: data, encoding: .utf8),
              json.count >= 2
        else { return nil }
        return json.dropFirst().dropLast()
            .replacingOccurrences(of: "<", with: "\\u003C")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
