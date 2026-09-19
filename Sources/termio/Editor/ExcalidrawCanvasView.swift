import AppKit
import SwiftUI
import WebKit

/// The drawing face of `FileEditorView` for Excalidraw files: the real Excalidraw canvas,
/// running in a `WKWebView`, backed by the file on disk.
///
/// This is an editor, not a preview. What it draws is what the file holds, and what you
/// draw is written back into the same container the file arrived in — a `.excalidraw`
/// stays JSON, a `.excalidraw.png` stays a PNG with the scene embedded in it. The
/// serializing happens in the page (only Excalidraw can produce those shapes); this side
/// owns the file and decides when bytes reach it.
///
/// It is deliberately the only place in termio where page script is the point rather than
/// a hazard, so the page is pinned shut: it loads from a string with no base URL, the one
/// scheme handler it has serves bundled fonts and nothing else, and no navigation it
/// starts is ever followed (see `Coordinator.decidePolicyFor`).
struct ExcalidrawCanvasView: NSViewRepresentable {
    let fileURL: URL
    /// The file's bytes as loaded. The canvas mounts from these once; afterwards the page
    /// holds the live scene and hands back new bytes as you draw.
    let data: Data
    /// Read-only files (a peek at a device copy, a revision out of the Changes pane) mount
    /// the canvas in Excalidraw's own view mode rather than hiding it: panning, zooming and
    /// reading a drawing are worth having without the right to change it.
    let readOnly: Bool
    @ObservedObject var settings: AppSettings
    let colorScheme: ColorScheme
    /// Raised while edited bytes are waiting to be written, so the header's unsaved dot
    /// means the same thing over a drawing as it does over text.
    var onDirtyChange: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(ExcalidrawAssetHandler(), forURLScheme: Self.assetScheme)
        configuration.userContentController.add(context.coordinator, name: Self.messageHandler)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        // Cleared so the terminal background shows through until the canvas paints, rather
        // than a white flash on open.
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.attach(view: view, representable: self)
        view.loadHTMLString(Self.page(), baseURL: nil)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.representable = self
        context.coordinator.applyTheme(isDark: isDark)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL, data: data, readOnly: readOnly, isDark: isDark)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        // A drawing edited in the last moments before the overlay closes still has to land,
        // and the page is about to go away with it.
        coordinator.flush()
        view.configuration.userContentController.removeScriptMessageHandler(forName: messageHandler)
    }

    private var isDark: Bool {
        settings.chromeTheme(for: colorScheme)?.isDark ?? (colorScheme == .dark)
    }

    /// Whether this file is one termio opens as a drawing. `.excalidraw` is the scene
    /// itself; the doubled extensions are Excalidraw's own convention for an image with the
    /// scene embedded in it, and those open as the drawing rather than as flat art.
    ///
    /// Suffix work rather than `pathExtension`, because three of the four end in a format
    /// termio otherwise previews as an image.
    static func isDrawing(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        for suffix in [".excalidraw", ".excalidraw.json", ".excalidraw.svg", ".excalidraw.png"]
        where name.hasSuffix(suffix) {
            return true
        }
        return false
    }

    // MARK: - The page

    static let messageHandler = "termioExcalidraw"
    /// Excalidraw resolves its font files against `EXCALIDRAW_ASSET_PATH`. It gets a scheme
    /// of its own rather than a `file://` base URL, so the page can reach the faces termio
    /// bundles and nothing else on the disk.
    static let assetScheme = "termio-excalidraw"

    private static func page() -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(asset("excalidraw-render", "css"))</style>
        <style>
        html, body, #root { height: 100%; margin: 0; }
        /* The canvas paints its own surface; letting the page background through until it
           does is what keeps the open from flashing white over the terminal. */
        body { background: transparent; }
        </style>
        </head>
        <body>
        <div id="root"></div>
        <script>window.EXCALIDRAW_ASSET_PATH = "\(assetScheme):///";</script>
        <script>\(asset("excalidraw-render", "js"))</script>
        </body>
        </html>
        """
    }

    /// The page the canvas loads, for tests that check it is self-contained and for the
    /// WebKit-backed tests that run the bundled engine against it.
    static func pageForTesting() -> String { page() }

    private static func asset(_ name: String, _ ext: String) -> String {
        guard let url = Bundle.termioResources.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            Log.markdown.error("excalidraw: \(name).\(ext, privacy: .public) is missing from the bundle")
            return ""
        }
        return text
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        fileprivate var representable: ExcalidrawCanvasView?
        private weak var view: WKWebView?
        private let fileURL: URL
        private let data: Data
        private let readOnly: Bool
        private var isDark: Bool
        private var mounted = false

        /// The most recent bytes the canvas produced, and the write that is waiting to put
        /// them on disk. Drawing emits a new scene several times a second; coalescing means
        /// a stroke costs one write rather than one per frame.
        private var pending: Data?
        private var writeTask: Task<Void, Never>?

        init(fileURL: URL, data: Data, readOnly: Bool, isDark: Bool) {
            self.fileURL = fileURL
            self.data = data
            self.readOnly = readOnly
            self.isDark = isDark
        }

        func attach(view: WKWebView, representable: ExcalidrawCanvasView) {
            self.view = view
            self.representable = representable
        }

        func applyTheme(isDark: Bool) {
            guard mounted, isDark != self.isDark else { return }
            self.isDark = isDark
            view?.evaluateJavaScript("window.termioExcalidrawSetTheme?.(\(isDark));")
        }

        // MARK: Mounting

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in await self.mount() }
        }

        private func mount() async {
            guard let view, !mounted else { return }
            do {
                let result = try await view.callAsyncJavaScript(
                    "return await window.termioExcalidrawMount(options);",
                    arguments: ["options": [
                        "scene": data.base64EncodedString(),
                        "dark": isDark,
                        "readOnly": readOnly,
                        "library": ExcalidrawLibrary.read() as Any,
                    ]],
                    contentWorld: .page)
                if let payload = result as? [String: Any], payload["ok"] as? Bool == false {
                    let message = payload["message"] as? String ?? "unknown error"
                    Log.markdown.info("excalidraw: \(message, privacy: .public)")
                    representable?.onError?(message)
                    return
                }
                mounted = true
            } catch {
                Log.markdown.error(
                    "excalidraw: canvas failed to mount: \(error.localizedDescription, privacy: .public)")
                representable?.onError?(error.localizedDescription)
            }
        }

        // MARK: Messages from the canvas

        nonisolated func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            Task { @MainActor in self.handle(type: type, body: body) }
        }

        private func handle(type: String, body: [String: Any]) {
            switch type {
            case "change":
                guard !readOnly, let base64 = body["scene"] as? String,
                      let bytes = Data(base64Encoded: base64) else { return }
                schedule(bytes)
            case "library":
                guard let json = body["library"] as? String else { return }
                ExcalidrawLibrary.write(json)
            case "link":
                guard let link = body["url"] as? String else { return }
                open(link: link)
            case "error":
                let message = body["message"] as? String ?? "unknown error"
                Log.markdown.info("excalidraw: \(message, privacy: .public)")
                representable?.onError?(message)
            default:
                break
            }
        }

        // MARK: Writing

        /// Holds the newest bytes and writes them once the drawing pauses. The window is
        /// short enough that a save is never a thing you wait for, and long enough that a
        /// continuous stroke doesn't write a file per frame.
        private func schedule(_ bytes: Data) {
            pending = bytes
            representable?.onDirtyChange?(true)
            writeTask?.cancel()
            writeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }

        /// Writes whatever is waiting. Also the exit path: closing the overlay or switching
        /// files must not drop the last stroke.
        func flush() {
            writeTask?.cancel()
            writeTask = nil
            guard let bytes = pending else { return }
            pending = nil
            do {
                try bytes.write(to: fileURL, options: .atomic)
                representable?.onDirtyChange?(false)
            } catch {
                Log.markdown.error(
                    "excalidraw: save failed: \(error.localizedDescription, privacy: .public)")
                representable?.onError?(error.localizedDescription)
            }
        }

        // MARK: Links

        /// An element's link, resolved the way the Markdown reader resolves one: a sibling
        /// file opens with its default app, anything else goes to the browser. The canvas
        /// itself never navigates.
        private func open(link: String) {
            guard let url = URL(string: link) else { return }
            if url.scheme == nil || url.scheme == "file" {
                let target = URL(fileURLWithPath: url.path.isEmpty ? link : url.path,
                                 relativeTo: fileURL.deletingLastPathComponent())
                NSWorkspace.shared.open(target.standardizedFileURL)
            } else {
                NSWorkspace.shared.open(url)
            }
        }

        // MARK: Navigation

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            // The only navigation this page ever legitimately does is the initial
            // `loadHTMLString`. Anything else — a link the canvas didn't route to the host,
            // a redirect out of some corner of the editor — would replace the canvas with a
            // web page inside the app's own window, so it opens in the browser instead.
            guard navigationAction.navigationType != .other || navigationAction.request.url != nil else {
                return decisionHandler(.allow)
            }
            guard let url = navigationAction.request.url, url.scheme != "about" else {
                return decisionHandler(.allow)
            }
            if url.scheme == ExcalidrawCanvasView.assetScheme {
                return decisionHandler(.allow)
            }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }
}

/// The shape library, kept as a file termio owns rather than in the web view's storage,
/// which a rebuild or a cleared cache would wipe. One library across every drawing, which
/// is what the library is for.
private enum ExcalidrawLibrary {
    static func read() -> String? {
        try? String(contentsOf: fileURL, encoding: .utf8)
    }

    static func write(_ json: String) {
        let url = fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try json.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.markdown.error(
                "excalidraw: library save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static var fileURL: URL {
        AppChannel.supportDirectory.appendingPathComponent("excalidraw-library.excalidrawlib")
    }
}

/// Serves the bundled Excalidraw faces to the canvas page under its own scheme.
///
/// The page has no base URL and therefore no filesystem access; this is the one door it
/// has, and it opens onto exactly the woff2 files termio ships. Requests are matched by
/// file name alone — Excalidraw asks for `fonts/<Family>/<file>.woff2` while `.process`
/// flattens resources to the bundle root — and anything that isn't one of those faces is
/// refused rather than looked up.
private final class ExcalidrawAssetHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            return task.didFailWithError(URLError(.badURL))
        }
        let name = (url.lastPathComponent as NSString).deletingPathExtension
        guard url.pathExtension.lowercased() == "woff2",
              !name.isEmpty, !name.contains("/"),
              let fileURL = Bundle.termioResources.url(forResource: name, withExtension: "woff2"),
              let data = try? Data(contentsOf: fileURL)
        else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let response = URLResponse(
            url: url, mimeType: "font/woff2", expectedContentLength: data.count,
            textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
