import AppKit
import SwiftUI
import WebKit

/// Diffs drawn by @pierre/diffs in a web view (`PierreDiffs/README.md`). The page's half of
/// the bridge is `diffs-page.js`. Two views use it: the diff overlay shows one file with no
/// header, and the pull request's narrow Files view stacks every file in one scroll.
///
/// The stack replaced a SwiftUI `LazyVStack` of native diff cards. That stack walked every row
/// on each frame of a scroller drag, so a pull request of a thousand files held the main
/// thread at 90%. The page virtualizes its list and WebKit scrolls it, so the app's main
/// thread does no work per frame here.
struct DiffWebView: NSViewRepresentable {
    let files: [GitChange]
    /// Each file's unified diff, keyed by path: `git diff` output, or the hunks-only `patch`
    /// of the GitHub API.
    let patches: [String: String]
    /// Reads a file in full, for expanding the context a patch left out.
    let fileText: (String) async -> DiffFullText?
    let look: DiffLook
    let onClose: () -> Void
    /// One file with no header. Nil stacks every file under its own header.
    var single: DiffWebSingle? = nil

    func makeCoordinator() -> DiffWebBridge { DiffWebBridge() }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.update(from: self)
        return context.coordinator.makeWebView()
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(from: self)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: DiffWebBridge) {
        coordinator.tearDown()
    }
}

/// A file in full, as far as the caller has it.
enum DiffFullText {
    /// Only the new side. The page takes the patch back out of it to get the old side.
    case new(String)
    case sides(old: String, new: String)

    /// Both sides of a file, read out of a diff that carries the whole file as context
    /// (`git diff -U999999`). Nil for a diff of more than one hunk: its hunks leave lines out.
    init?(fullContextPatch text: String) {
        var old: [Substring] = []
        var new: [Substring] = []
        var oldEndsWithNewline = true
        var newEndsWithNewline = true
        var hunks = 0
        var last: Character?
        // Not `split`: to a Swift string a CRLF is one character, so a file with Windows line
        // endings would come back as a single line.
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("@@") {
                hunks += 1
                guard hunks == 1 else { return nil }
                continue
            }
            guard hunks == 1, let first = line.first else { continue }
            switch first {
            case " ": old.append(line.dropFirst()); new.append(line.dropFirst())
            case "-": old.append(line.dropFirst())
            case "+": new.append(line.dropFirst())
            case "\\":
                // "\ No newline at end of file" speaks for the line above it.
                if last != "+" { oldEndsWithNewline = false }
                if last != "-" { newEndsWithNewline = false }
            default: continue
            }
            last = first
        }
        guard hunks == 1 else { return nil }
        func joined(_ lines: [Substring], _ endsWithNewline: Bool) -> String {
            lines.isEmpty ? "" : lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        }
        self = .sides(old: joined(old, oldEndsWithNewline), new: joined(new, newEndsWithNewline))
    }

    fileprivate var reply: Any {
        switch self {
        case .new(let text): return text
        case .sides(let old, let new): return ["old": old, "new": new]
        }
    }
}

/// What the diff overlay asks of the page beyond drawing: columns, find, the walk between
/// files, and "Add to Chat".
struct DiffWebSingle {
    var isSplit = false
    /// Nil while the find bar is closed.
    var find: DiffWebFind? = nil
    var onFindCount: (Int) -> Void = { _ in }
    /// The file changed after its diff was read, so a band could not be expanded.
    var onStale: () -> Void = {}
    /// Steps to the previous or next file. False at either end.
    var onWalk: (Int) -> Bool = { _ in false }
    /// The argument is the selected text. Nil means no selection.
    var addToChat: ((String?) -> Void)? = nil
    var canAddToChat: () -> Bool = { false }
    /// Bumped when the web view has to take the keyboard back, as when the find bar closes.
    var reclaimFocus = 0
}

struct DiffWebFind: Equatable {
    var query: String
    var options: FindOptions
    /// The match to bring into view.
    var index: Int
}

/// What the page draws with: termio's terminal font and background, and its scheme.
struct DiffLook: Equatable {
    let isDark: Bool
    let fontFamily: String
    let fontSize: CGFloat
    let lineHeight: CGFloat
    let background: String
    let foreground: String

    @MainActor
    init(settings: AppSettings, colorScheme: ColorScheme) {
        let font = settings.resolvedTerminalFont()
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        isDark = colorScheme == .dark
        fontFamily = font.familyName ?? "SF Mono"
        fontSize = font.pointSize
        lineHeight = (NSLayoutManager().defaultLineHeight(for: font)
            + settings.codeLineSpacing(for: font)).rounded()
        background = FileTreeWebView.css(settings.terminalBackgroundColor, in: appearance)
        foreground = FileTreeWebView.css(.labelColor, in: appearance)
    }

    var payload: [String: Any] {
        let family = "\"\(fontFamily.replacingOccurrences(of: "\"", with: ""))\", ui-monospace, monospace"
        return [
            "scheme": isDark ? "dark" : "light",
            "variables": [
                "--diffs-bg": background,
                "--diffs-font-family": family,
                "--diffs-font-size": "\(fontSize)px",
                "--diffs-line-height": "\(lineHeight)px",
                "--diffs-header-font-family": "-apple-system, system-ui, sans-serif",
            ],
            // The theme sets its own ground above the diff; the terminal's background
            // replaces it there, so the list reads as part of the pane.
            "css": """
                :host, [data-diff], [data-diffs-header] {
                  --diffs-light-bg: \(background) !important;
                  --diffs-dark-bg: \(background) !important;
                }
                """,
        ]
    }
}

/// Talks to the page: sends the files and the look, answers its requests.
@MainActor
final class DiffWebBridge: NSObject, WKScriptMessageHandlerWithReply {
    private weak var webView: DiffWKWebView?
    private var files: [GitChange] = []
    private var patches: [String: String] = [:]
    private var fileText: (String) async -> DiffFullText? = { _ in nil }
    private var look: DiffLook?
    private var onClose: () -> Void = {}
    private var single: DiffWebSingle?

    /// The page has loaded its scripts. Nothing can be sent before.
    private var isReady = false
    private var sentFiles: [GitChange]?
    private var sentPatches: [String: String]?
    private var sentLook: DiffLook?
    private var sentSplit: Bool?
    private var sentFind: DiffWebFind?
    private var appliedReclaim = 0
    /// What the reader has selected in the page, kept for the right-click menu, which
    /// opens too soon to ask the page.
    private var selectedText = ""

    private static let messageName = "termioDiffs"

    func update(from view: DiffWebView) {
        files = view.files
        patches = view.patches
        fileText = view.fileText
        look = view.look
        onClose = view.onClose
        single = view.single
        push()
        if let single, single.reclaimFocus != appliedReclaim {
            appliedReclaim = single.reclaimFocus
            webView?.window?.makeFirstResponder(webView)
        }
    }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = configuration.userContentController
        // The worker runs from a blob the page makes of this source: a page loaded from a
        // string has no origin a worker script could be fetched from.
        if let worker = Self.resource("pierre-diffs-worker"),
           let data = try? JSONSerialization.data(withJSONObject: [worker], options: [.fragmentsAllowed]),
           let literal = String(data: data, encoding: .utf8) {
            controller.addUserScript(WKUserScript(
                source: "window.__pierreDiffsWorker = \(literal)[0];",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        for name in ["pierre-diffs.min", "diffs-page"] {
            guard let source = Self.resource(name) else { continue }
            controller.addUserScript(WKUserScript(
                source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.messageName)
        let view = DiffWKWebView(frame: .zero, configuration: configuration)
        view.bridge = self
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(Self.page, baseURL: nil)
        webView = view
        appliedReclaim = single?.reclaimFocus ?? 0
        if single != nil {
            // The overlay opens with the keyboard on the diff, so the arrows walk and Escape
            // closes. A text field that already holds the keyboard keeps it.
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                if window.firstResponder === window || window.firstResponder is NSTextView == false {
                    window.makeFirstResponder(view)
                }
            }
        }
        return view
    }

    func tearDown() {
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.messageName, contentWorld: .page)
    }

    private static func resource(_ name: String) -> String? {
        guard let url = Bundle.termioResources.url(forResource: name, withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            Log.issues.error("diff page: \(name, privacy: .public).js is missing from the bundle")
            return nil
        }
        return source
    }

    private static let page = """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>
          html, body { margin: 0; height: 100%; background: transparent; }
          #root { height: 100%; overflow: auto; }
        </style>
        </head><body><div id="root"></div></body></html>
        """

    // MARK: Swift → page

    private func push() {
        guard isReady, let look else { return }
        let isSplit = single?.isSplit ?? false
        if sentFiles != files || sentPatches != patches {
            sentFiles = files
            sentPatches = patches
            sentLook = look
            sentSplit = isSplit
            // Another file has other matches, so the count is asked for again.
            sentFind = nil
            selectedText = ""
            call("termioDiffs.load(payload)", ["payload": [
                "files": payloadFiles(), "look": lookPayload(look, isSplit: isSplit),
                "single": single != nil,
            ]])
        } else if sentLook != look || sentSplit != isSplit {
            sentLook = look
            sentSplit = isSplit
            call("termioDiffs.setLook(look)", ["look": lookPayload(look, isSplit: isSplit)])
        }
        pushFind()
    }

    private func lookPayload(_ look: DiffLook, isSplit: Bool) -> [String: Any] {
        var payload = look.payload
        payload["style"] = isSplit ? "split" : "unified"
        return payload
    }

    private func pushFind() {
        guard let single, single.find != sentFind else { return }
        sentFind = single.find
        guard let find = single.find, !find.query.isEmpty else {
            call("termioDiffs.find(null)", [:])
            single.onFindCount(0)
            return
        }
        let spec: [String: Any] = [
            "query": find.query, "index": find.index,
            "caseSensitive": find.options.caseSensitive,
            "wholeWord": find.options.wholeWord, "regex": find.options.regex,
        ]
        webView?.callAsyncJavaScript(
            "return termioDiffs.find(spec)", arguments: ["spec": spec], in: nil, in: .page
        ) { [weak self] result in
            switch result {
            case .success(let count):
                // An answer for a query the reader has since changed is dropped.
                guard let self, self.sentFind == find else { return }
                self.single?.onFindCount(count as? Int ?? 0)
            case .failure(let error):
                Log.issues.error("diff page find: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Every file, including one with no patch: it keeps its header and says why it shows
    /// no lines, as a binary file or one too large for an inline patch.
    private func payloadFiles() -> [[String: Any]] {
        files.map { change in
            let patch = patches[change.path] ?? ""
            var file: [String: Any] = [
                "id": change.path,
                "path": change.path,
                "patch": patch,
                "status": Self.status(change.status),
            ]
            if let original = change.originalPath { file["oldPath"] = original }
            if patch.isEmpty {
                file["note"] = change.isBinary
                    ? localized("Binary file — open it on GitHub to view.")
                    : localized("This diff is too large to show here — open the file on GitHub.")
            }
            return file
        }
    }

    private static func status(_ status: GitFileStatus) -> String {
        switch status {
        case .added, .untracked: return "added"
        case .deleted: return "deleted"
        case .renamed: return "renamed"
        case .modified, .copied, .conflicted: return "modified"
        }
    }

    private func call(_ body: String, _ arguments: [String: Any]) {
        guard let webView else { return }
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
            if case .failure(let error) = result {
                Log.issues.error("diff page: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Page → Swift

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else {
            return (nil, "malformed message")
        }
        switch type {
        case "ready":
            isReady = true
            push()
            return (nil, nil)
        case "fileText":
            guard let path = body["path"] as? String,
                  files.contains(where: { $0.path == path }) else { return (nil, "unknown file") }
            guard let text = await fileText(path) else { return (nil, "no text for \(path)") }
            return (text.reply, nil)
        case "walk":
            if let delta = body["delta"] as? Int { _ = single?.onWalk(delta) }
            return (nil, nil)
        case "stale":
            single?.onStale()
            return (nil, nil)
        case "selection":
            selectedText = body["text"] as? String ?? ""
            return (nil, nil)
        case "close":
            onClose()
            return (nil, nil)
        case "log":
            Log.issues.error("diff page: \(body["message"] as? String ?? "", privacy: .public)")
            return (nil, nil)
        default:
            return (nil, "unknown message \(type)")
        }
    }

    // MARK: Right-click menu

    /// Copy, "Add to Chat" and Close, in place of WebKit's menu for a web page (Reload,
    /// Look Up, Translate, Share), which a diff has no use for.
    fileprivate func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.allowsContextMenuPlugIns = false
        let selection = selectedText.isEmpty ? nil : selectedText
        // Not `copy:`: macOS 26 decorates the standard editing selectors with a system symbol
        // that `image = nil` cannot clear, and the rest of this menu is plain text.
        let copy = ClosureMenuItem(title: localized("Copy")) {
            guard let selection else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selection, forType: .string)
        }
        copy.isEnabled = selection != nil
        menu.autoenablesItems = false
        menu.addItem(copy)
        if let single, let addToChat = single.addToChat, single.canAddToChat() {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: localized("Add to Chat")) { addToChat(selection) })
        }
        if single != nil {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: localized("Close")) { [onClose] in onClose() })
        }
    }
}

/// The web view of a diff. It exists to hand the right-click menu to the bridge.
final class DiffWKWebView: WKWebView {
    weak var bridge: DiffWebBridge?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        bridge?.fill(menu)
    }
}
