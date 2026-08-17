import Foundation
import JavaScriptCore

/// The JavaScript the Markdown renderers borrow: highlight.js for fenced code, KaTeX for
/// math. Both run *here*, in a context the app owns, and hand back finished markup — the
/// rendered pages stay script-free, which is what lets the same HTML serve the file
/// reader, the session trace (untrusted agent output), and the phone unchanged. It also
/// keeps the reader's `termio-md` scheme handler unreachable from document content.
///
/// highlight.js is the copy Highlightr already bundles for the editor, so fenced code in
/// Preview is colored exactly like the source behind it. KaTeX (MIT) is vendored beside it
/// as `Resources/assets/katex.min.js`; only its parser ships, since MathML output needs
/// neither its stylesheet nor its ~1MB of web fonts.
///
/// One shared `JSContext` created on first use behind a lock: `MarkdownHTML.html` runs on
/// the companion server's queue as well as the main thread, and a context is not
/// thread-safe. Each engine loads lazily — a document with no code fence never parses
/// highlight.js, one with no math never parses KaTeX.
enum MarkdownScripting {
    /// Highlighted HTML (`<span class="hljs-…">`) for a fenced code block, or `nil` when
    /// the language is unknown to highlight.js or the engine is unavailable — the caller
    /// then emits the plain escaped code it always did.
    static func highlight(_ code: String, language: String) -> String? {
        ScriptEngine.shared.highlight(code, language: language)
    }

    /// TeX → MathML, which WebKit lays out natively. MathML output is why no KaTeX
    /// stylesheet or web font ships: the ~1MB of KaTeX faces only exists for its HTML
    /// renderer. Malformed TeX comes back as KaTeX's own escaped error span rather than
    /// throwing, so a typo in one formula never blanks the document.
    static func math(_ tex: String, display: Bool) -> String? {
        ScriptEngine.shared.math(tex, display: display)
    }
}

// @unchecked: every stored property is touched only with `lock` held — the same
// lock the doc above names as what makes one `JSContext` safe to share between
// the companion queue and the main thread. Retire with `Mutex` once the
// deployment floor reaches macOS 15.
private final class ScriptEngine: @unchecked Sendable {
    static let shared = ScriptEngine()

    private let lock = NSLock()
    private var context: JSContext?
    private var hljs: JSValue?
    private var katex: JSValue?
    private var cache: [String: String] = [:]

    func highlight(_ code: String, language: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let key = "h\u{0}\(language)\u{0}\(code)"
        if let hit = cache[key] { return hit }
        // `loadHighlightJS` is what creates the context, so it has to run first.
        guard let hljs = loadHighlightJS(), let context,
              hljs.invokeMethod("getLanguage", withArguments: [language])?.isObject == true,
              let options = JSValue(
                  object: ["language": language, "ignoreIllegals": true], in: context),
              let result = hljs.invokeMethod("highlight", withArguments: [code, options]),
              let html = result.objectForKeyedSubscript("value")?.toString()
        else { return nil }
        store(key, html)
        return html
    }

    func math(_ tex: String, display: Bool) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let key = "m\(display ? "d" : "i")\u{0}\(tex)"
        if let hit = cache[key] { return hit }
        guard let katex = loadKaTeX(), let context,
              let options = JSValue(
                  object: ["output": "mathml", "displayMode": display, "throwOnError": false],
                  in: context),
              let html = katex.invokeMethod("renderToString", withArguments: [tex, options])?
                  .toString(), !html.isEmpty
        else { return nil }
        store(key, html)
        return html
    }

    // MARK: - Engines

    /// `loadHighlightJS` is called with the lock held; `context` is non-nil afterwards.
    private func loadHighlightJS() -> JSValue? {
        if let hljs { return hljs }
        guard let context = sharedContext(), evaluate(resource: "highlight.min", in: context),
              let value = context.objectForKeyedSubscript("hljs"), !value.isUndefined
        else { return nil }
        hljs = value
        return value
    }

    private func loadKaTeX() -> JSValue? {
        if let katex { return katex }
        guard let context = sharedContext(), evaluate(resource: "katex.min", in: context),
              let value = context.objectForKeyedSubscript("katex"), !value.isUndefined
        else { return nil }
        katex = value
        return value
    }

    private func sharedContext() -> JSContext? {
        if let context { return context }
        guard let fresh = JSContext() else {
            Log.markdown.error("markdown: could not create a JavaScript context")
            return nil
        }
        // Both libraries are UMD bundles: with no `module`/`define`/`self` in scope they
        // fall through to assigning their export onto the global object.
        fresh.exceptionHandler = { _, exception in
            Log.markdown.error(
                "markdown script exception: \(exception?.toString() ?? "unknown", privacy: .public)")
        }
        context = fresh
        return fresh
    }

    private func evaluate(resource: String, in context: JSContext) -> Bool {
        guard let url = Bundle.termioResources.url(forResource: resource, withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            Log.markdown.error("markdown: \(resource, privacy: .public).js is missing from the bundle")
            return false
        }
        context.evaluateScript(source)
        return true
    }

    /// A flat cap rather than an LRU: the cache exists so re-rendering the *same* document
    /// (a theme flip, a keystroke in the editor behind Preview) doesn't re-run the parsers,
    /// and a document's blocks are always re-requested together. Past the cap the whole
    /// table is dropped — one extra full render beats per-entry bookkeeping.
    private func store(_ key: String, _ html: String) {
        if cache.count >= 512 { cache.removeAll(keepingCapacity: true) }
        cache[key] = html
    }
}
