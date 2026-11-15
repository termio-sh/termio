import AppKit
import SwiftUI
import WebKit

/// Every changed file of a pull request in one scroll, drawn by @pierre/diffs in a web
/// view (`PierreDiffs/README.md`). The page's half of the bridge is `pr-diff.js`.
///
/// It replaced a SwiftUI `LazyVStack` of native diff cards. That stack walked every row on
/// each frame of a scroller drag, so a pull request of a thousand files held the main
/// thread at 90%. The page virtualizes its list and WebKit scrolls it, so the app's main
/// thread does no work per frame here.
struct PRDiffWebView: NSViewRepresentable {
    let files: [GitChange]
    /// Each file's inline unified-diff `patch` from the GitHub API, keyed by path.
    let patches: [String: String]
    /// Reads a file at the PR head, for expanding the context a patch left out.
    let fileText: (String) async -> String?
    let look: PRDiffLook
    let onClose: () -> Void

    func makeCoordinator() -> PRDiffBridge { PRDiffBridge() }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.update(from: self)
        return context.coordinator.makeWebView()
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(from: self)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: PRDiffBridge) {
        coordinator.tearDown()
    }
}

/// What the page draws with: termio's terminal font and background, and its scheme.
struct PRDiffLook: Equatable {
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
final class PRDiffBridge: NSObject, WKScriptMessageHandlerWithReply {
    private weak var webView: WKWebView?
    private var files: [GitChange] = []
    private var patches: [String: String] = [:]
    private var fileText: (String) async -> String? = { _ in nil }
    private var look: PRDiffLook?
    private var onClose: () -> Void = {}

    /// The page has loaded its scripts. Nothing can be sent before.
    private var isReady = false
    private var sentFiles: [GitChange]?
    private var sentPatches: [String: String]?
    private var sentLook: PRDiffLook?

    private static let messageName = "prDiff"

    func update(from view: PRDiffWebView) {
        files = view.files
        patches = view.patches
        fileText = view.fileText
        look = view.look
        onClose = view.onClose
        push()
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
        for name in ["pierre-diffs.min", "pr-diff"] {
            guard let source = Self.resource(name) else { continue }
            controller.addUserScript(WKUserScript(
                source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.messageName)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(Self.page, baseURL: nil)
        webView = view
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
            Log.issues.error("pr diff: \(name, privacy: .public).js is missing from the bundle")
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
        if sentFiles != files || sentPatches != patches {
            sentFiles = files
            sentPatches = patches
            sentLook = look
            call("termioDiffs.load(payload)", ["payload": ["files": payloadFiles(), "look": look.payload]])
        } else if sentLook != look {
            sentLook = look
            call("termioDiffs.setLook(look)", ["look": look.payload])
        }
    }

    /// Every file, including one the API sent no patch for: it keeps its header and says why
    /// it shows no lines, as a binary file or one too large for an inline patch.
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
                Log.issues.error("pr diff: \(error.localizedDescription, privacy: .public)")
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
            return (await fileText(path), nil)
        case "close":
            onClose()
            return (nil, nil)
        case "log":
            Log.issues.error("pr diff page: \(body["message"] as? String ?? "", privacy: .public)")
            return (nil, nil)
        default:
            return (nil, "unknown message \(type)")
        }
    }
}
