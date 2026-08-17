import AppKit
import Foundation

// MARK: - Diff syntax coloring

// NSFont is documented immutable ("Font objects are immutable, so they can be
// shared by threads"); the SDK just hasn't marked it Sendable. Blessing it lets
// the resolved font cross into this actor and live in `static let` caches.
extension NSFont: @retroactive @unchecked Sendable {}

/// The colored lines handed off the actor, keyed by row id. @unchecked: the
/// values are immutable `attributedSubstring` copies built for this one call;
/// the actor keeps no reference to them once they are returned.
struct StyledLines: @unchecked Sendable {
    let byRow: [Int: NSAttributedString]
}

/// One reusable Highlightr behind an actor. Building its JavaScriptCore context and
/// parsing highlight.min.js costs on the order of 100 ms — far too much to pay per
/// file switch — and the context is not safe to share across concurrent tasks. The
/// actor amortizes the setup, serializes requests (rapid arrow-key walking queues
/// instead of racing), and re-themes only when the theme or font actually changes.
actor DiffHighlighter {
    static let shared = DiffHighlighter()

    private var highlightr: Highlightr?
    private var appliedTheme: String?
    private var appliedFont: NSFont?

    /// Syntax-colors a diff, one side at a time: each side is highlighted as a single
    /// text so multi-line constructs (block comments, raw strings) keep their true
    /// state — per-line coloring can't do that. Context lines take the new side's
    /// colors; the old side contributes only its deletions. Returns Highlightr's
    /// attributed lines by row id, used directly by the TextKit pane — the theme's
    /// background never carries over; the wash and emphasis layers own that.
    func styledLines(newSide: [DiffRow], oldSide: [DiffRow], language: String,
                     theme: String, font: NSFont) -> StyledLines {
        guard let highlightr = prepared(theme: theme, font: font) else {
            return StyledLines(byRow: [:])
        }
        var result: [Int: NSAttributedString] = [:]
        apply(newSide, keeping: [.context, .addition], highlightr, language, into: &result)
        apply(oldSide, keeping: [.deletion], highlightr, language, into: &result)
        return StyledLines(byRow: result)
    }

    private func prepared(theme: String, font: NSFont) -> Highlightr? {
        if highlightr == nil { highlightr = Highlightr() }
        guard let highlightr else { return nil }
        if appliedTheme != theme {
            guard highlightr.setTheme(to: theme) else { return nil }
            appliedTheme = theme
            appliedFont = nil
        }
        if appliedFont != font {
            highlightr.theme.setCodeFont(font)
            appliedFont = font
        }
        return highlightr
    }

    private func apply(_ side: [DiffRow], keeping kinds: Set<DiffRow.Kind>,
                       _ highlightr: Highlightr, _ language: String,
                       into result: inout [Int: NSAttributedString]) {
        let joined = side.map(\.text).joined(separator: "\n")
        // The colored text must round-trip exactly, or the per-line offsets below
        // would attribute the wrong spans — bail to plain rendering instead.
        guard let colored = highlightr.highlight(joined, as: language, fastRender: true),
              colored.string == joined else { return }
        var location = 0
        for row in side {
            let length = (row.text as NSString).length
            defer { location += length + 1 }
            guard kinds.contains(row.kind), length > 0 else { continue }
            result[row.id] = colored.attributedSubstring(
                from: NSRange(location: location, length: length))
        }
    }
}
