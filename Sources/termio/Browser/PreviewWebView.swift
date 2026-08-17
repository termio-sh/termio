import WebKit

/// Right-click for termio's web surfaces — the Markdown reader, the session trace, HTML/SVG file
/// previews, the issue conversation — *without* WebKit's own menu.
///
/// WebKit's proposed menu cannot be trimmed down to plain text. Filtering it in `willOpenMenu`
/// leaves Services behind, because AppKit appends that submenu afterwards and
/// `allowsContextMenuPlugIns = false` does not stop it; and macOS 26 synthesizes a symbol image for
/// any item carrying the standard `copy:` selector, which reads back even right after assigning
/// `image = nil`. So the page cancels its own context menu and posts the click over instead, and
/// the host pops a menu it built itself — the same "pop it ourselves" shape the file tree uses.
final class WebContextMenuBridge: NSObject, WKScriptMessageHandler {
    /// What the page reports about a right-click.
    struct Click {
        /// The page's selected text, empty when nothing is selected.
        let selection: String
        /// The `href` of the link under the pointer, if any.
        let link: URL?
    }

    private var makeMenu: ((Click) -> NSMenu)?
    private weak var webView: WKWebView?

    private static let handlerName = "termioContextMenu"

    private static let script = """
    document.addEventListener('contextmenu', function (event) {
        event.preventDefault();
        var target = event.target;
        var link = target && target.closest ? target.closest('a') : null;
        window.webkit.messageHandlers.\(handlerName).postMessage({
            x: event.clientX,
            y: event.clientY,
            selection: String(window.getSelection()),
            link: link ? link.href : ''
        });
    }, true);
    """

    /// Adds the page script and the message handler. This has to happen *before* the web view is
    /// created — `WKWebView.configuration` hands back a copy, so a script added afterwards would
    /// never reach the page. `attach(to:makeMenu:)` finishes the wiring once the view exists.
    func install(on configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: Self.script,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        controller.add(self, name: Self.handlerName)
    }

    /// The controller owns the bridge and the bridge holds the view weakly, so `makeMenu` must
    /// capture its owner weakly too.
    func attach(to webView: WKWebView, makeMenu: @escaping (Click) -> NSMenu) {
        self.webView = webView
        self.makeMenu = makeMenu
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let webView, let makeMenu else { return }
        let link = (body["link"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let menu = makeMenu(Click(selection: body["selection"] as? String ?? "", link: link))
        guard !menu.items.isEmpty else { return }
        // The page reports viewport coordinates, top-left origin; an unflipped view counts from the
        // bottom.
        let x = (body["x"] as? NSNumber)?.doubleValue ?? 0
        let y = (body["y"] as? NSNumber)?.doubleValue ?? 0
        let point = NSPoint(x: x, y: webView.isFlipped ? y : webView.bounds.height - y)
        menu.popUp(positioning: nil, at: point, in: webView)
    }
}

extension NSMenu {
    /// A plain-text item: no image, and never a standard editing selector for macOS 26 to decorate.
    @discardableResult
    func addPlainItem(_ title: String, target: AnyObject, action: Selector,
                      representedObject: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = representedObject
        addItem(item)
        return item
    }
}

/// The `WKWebView` for read-only preview surfaces — the session trace and HTML/SVG file previews.
/// Its right-click menu is just Copy: WebKit's default carries Reload, Look Up, Translate,
/// Services, and search items rendered-and-done content has no use for.
final class PreviewWebView: WKWebView {
    private var bridge: WebContextMenuBridge?

    init() {
        let configuration = WKWebViewConfiguration()
        let bridge = WebContextMenuBridge()
        bridge.install(on: configuration)
        self.bridge = bridge
        super.init(frame: .zero, configuration: configuration)
        bridge.attach(to: self) { [weak self] click in
            self?.contextMenu(for: click) ?? NSMenu()
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    private func contextMenu(for click: WebContextMenuBridge.Click) -> NSMenu {
        let menu = NSMenu()
        guard !click.selection.isEmpty else { return menu }
        menu.addPlainItem(localized("Copy"), target: self, action: #selector(copySelection(_:)),
                          representedObject: click.selection)
        return menu
    }

    @objc private func copySelection(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
