import WebKit

/// The `WKWebView` for read-only preview surfaces — the session trace and HTML/SVG
/// file previews. Its right-click menu is stripped to Copy: WebKit's default menu
/// carries Reload, Look Up, Translate, Services, and search items rendered-and-done
/// content has no use for. Same whitelist-by-identifier treatment as the Markdown
/// reader and the issue detail (non-editable web content never gets AutoFill, and
/// WebKit's proposed menu exists by `willOpenMenu` time, so the filter holds here —
/// unlike an editable NSTextView, where AppKit appends extras later).
final class PreviewWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        menu.items = menu.items.filter { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }
    }
}
