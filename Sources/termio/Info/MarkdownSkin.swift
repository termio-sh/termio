import Foundation

/// The styling that belongs to `MarkdownHTML`'s *markup* rather than to any one page.
///
/// Three surfaces render that markup and each has its own register: the reader reads as a
/// document, the session trace as a dashboard, the Issues pane as a conversation. Margins
/// and type sizes should differ between them. What can't differ is the handful of rules
/// the markup depends on to mean what it says — a punctuation span pulled back by exactly
/// the amount the compressor assumed, an alert's kind selecting its hue, a highlighted
/// `<code>` giving up the hljs theme's own background. Those live here, once, beside the
/// code that emits the classes, so a page can't be added that renders the markup wrong.
enum MarkdownSkin {
    /// `scope` is the selector the host's markdown sits under — `".reader "` for the
    /// reader, `".text.md "` for the trace, `""` for a page that is nothing else.
    static func css(scope: String) -> String {
        """
        \(scope).alert-note { --alert-color: var(--alert-note); }
        \(scope).alert-tip { --alert-color: var(--alert-tip); }
        \(scope).alert-important { --alert-color: var(--alert-important); }
        \(scope).alert-warning { --alert-color: var(--alert-warning); }
        \(scope).alert-caution { --alert-color: var(--alert-caution); }
        \(scope).punctuation-half { margin-inline-end: -0.5em; }
        \(scope).punctuation-quarter { margin-inline-end: -0.25em; }
        \(scope)pre code.hljs { display: block; background: none; padding: 0; color: inherit; }
        \(scope).math-display { text-align: center; overflow-x: auto; max-width: 100%; }
        \(scope).footnotes p { display: inline; margin: 0; }
        \(scope).footnote-ref a, \(scope).footnote-back { text-decoration: none; }
        """
    }

    /// The five GitHub alert hues, as note / tip / important / warning / caution.
    ///
    /// Fixed rather than theme-derived: an alert's whole job is to say *which* kind it is
    /// at a glance, and a palette that followed the chrome accent would make five kinds
    /// look like one. Both sets are tuned to sit on the page without shouting.
    static func alertVariables(dark: Bool) -> String {
        let colors = dark
            ? ["#4493f8", "#3fb950", "#ab7df8", "#d29922", "#f85149"]
            : ["#0969da", "#1a7f37", "#8250df", "#9a6700", "#cf222e"]
        return zip(["note", "tip", "important", "warning", "caution"], colors)
            .map { "  --alert-\($0): \($1);" }
            .joined(separator: "\n")
    }

    /// highlight.js token colors for fenced code, taken from the same xcode / xcode-dark
    /// themes the source editor uses — so a code block in Preview is colored exactly like
    /// the file behind it. The theme's own `.hljs` background and padding are overridden
    /// by `css(scope:)`, which owns how a code block looks.
    static func highlightTheme(dark: Bool) -> String {
        guard let url = Bundle.termioResources.url(
                  forResource: dark ? "xcode-dark.min" : "xcode.min", withExtension: "css"),
              let css = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        // Both xcode themes paint `diff` additions and deletions on opaque pastel fills
        // meant for a white editor gutter; on a dark page that is white-on-mint. Replace
        // them with a tint of the page's own text color, which reads on either.
        return css + """

        .hljs-addition { background: color-mix(in srgb, #3fb950 20%, transparent); color: inherit; }
        .hljs-deletion { background: color-mix(in srgb, #f85149 20%, transparent); color: inherit; }
        """
    }
}
