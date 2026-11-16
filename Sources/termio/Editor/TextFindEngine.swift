import AppKit

/// The incremental-find engine behind the code editor's ⌘F (`HighlightedTextView`). It finds
/// every match of a query (literal or regex, with case / whole-word modifiers), paints them as
/// temporary background highlights over any `NSTextView`, and reveals the focused one. The diff
/// overlay shows the same `FileFindBar`, but its lines live in a web page, so the page runs its
/// own search with the same options and the same two highlight colors (`diffs-page.js`).
@MainActor
final class TextFindEngine {
    private(set) var matches: [NSRange] = []

    private static let matchColor = NSColor.systemYellow.withAlphaComponent(0.35)
    private static let focusedColor = NSColor.systemYellow.withAlphaComponent(0.7)

    /// What counts as "inside a word" for whole-word find. Shared with `OccurrenceTarget` so the
    /// word the occurrence wash picks up and the boundary this engine matches on can't disagree.
    nonisolated static let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))

    /// Rebuild the match list for `query` over the text view's current string. Returns the count.
    @discardableResult
    func recompute(query: String, options: FindOptions, in textView: NSTextView) -> Int {
        matches = Self.matches(of: query, options: options, in: textView.string as NSString)
        return matches.count
    }

    /// Every match of `query` in `text`, in document order. The scan itself, with no text view in
    /// it — `FindReplace` asks the same question of the same buffer when it plans a replacement,
    /// and a match list the two could disagree about is a wrong "n of m" waiting to happen.
    nonisolated static func matches(of query: String, options: FindOptions, in text: NSString) -> [NSRange] {
        guard !query.isEmpty, text.length > 0 else { return [] }
        let total = text.length

        if options.regex {
            guard let regex = regularExpression(for: query, options: options) else { return [] }
            return regex.matches(in: text as String, range: NSRange(location: 0, length: total))
                .map(\.range)
                .filter { $0.length > 0 && (!options.wholeWord || isWordBoundary($0, in: text)) }
        }

        var found: [NSRange] = []
        var searchOptions: NSString.CompareOptions = []
        if !options.caseSensitive { searchOptions.insert(.caseInsensitive) }
        var searchStart = 0
        while searchStart < total {
            let searchRange = NSRange(location: searchStart, length: total - searchStart)
            let hit = text.range(of: query, options: searchOptions, range: searchRange)
            if hit.location == NSNotFound { break }
            if !options.wholeWord || isWordBoundary(hit, in: text) { found.append(hit) }
            // `hit.length` can be zero for a pathological pattern; step by 1 to guarantee termination.
            searchStart = hit.location + max(hit.length, 1)
        }
        return found
    }

    /// The compiled pattern behind a `.*`-mode query, or nil while it is still half-typed and
    /// doesn't parse. Shared with the replace planner, which needs the match *results* — not just
    /// their ranges — to expand `$1` capture groups.
    nonisolated static func regularExpression(
        for query: String, options: FindOptions
    ) -> NSRegularExpression? {
        var regexOptions: NSRegularExpression.Options = []
        if !options.caseSensitive { regexOptions.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: query, options: regexOptions)
    }

    /// Repaint every match, tinting `focused` brighter. `reveal` scrolls the focused match into
    /// view and pulses the find indicator — pass true only when the focus genuinely moved (a new
    /// query or a next/prev step), never on a passive repaint after an in-document edit.
    func paint(focused: Int, reveal: Bool, in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        clearHighlights(in: textView)
        for (index, range) in matches.enumerated() {
            layoutManager.addTemporaryAttribute(
                .backgroundColor, value: index == focused ? Self.focusedColor : Self.matchColor,
                forCharacterRange: range)
        }
        if reveal, matches.indices.contains(focused) {
            let range = matches[focused]
            textView.scrollRangeToVisible(range)
            textView.showFindIndicator(for: range)
        }
    }

    /// Wash `ranges` in `color` without disturbing anything else already painted — the additive
    /// counterpart to `paint(focused:reveal:)`, which owns the whole document. The occurrence
    /// highlight goes through here so it shares the layer with the bracket wash instead of wiping
    /// it, and `removeHighlight` lifts exactly what this laid down.
    static func addHighlight(_ ranges: [NSRange], color: NSColor, in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        for range in ranges {
            guard let clamped = clamp(range, to: length) else { continue }
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: clamped)
        }
    }

    static func removeHighlight(_ ranges: [NSRange], in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        for range in ranges {
            guard let clamped = clamp(range, to: length) else { continue }
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: clamped)
        }
    }

    /// `range` cut down to fit a text of `length`, or `nil` when it starts past the end — an edit
    /// can shrink the document between painting and lifting, and touching an attribute past the
    /// end raises.
    private static func clamp(_ range: NSRange, to length: Int) -> NSRange? {
        guard range.location < length else { return nil }
        return NSRange(location: range.location, length: min(range.length, length - range.location))
    }

    private func clearHighlights(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
    }

    nonisolated static func isWordBoundary(_ range: NSRange, in string: NSString) -> Bool {
        let letters = wordCharacters
        if range.location > 0 {
            let prev = string.character(at: range.location - 1)
            if let scalar = Unicode.Scalar(prev), letters.contains(scalar) { return false }
        }
        let end = range.location + range.length
        if end < string.length {
            let next = string.character(at: end)
            if let scalar = Unicode.Scalar(next), letters.contains(scalar) { return false }
        }
        return true
    }
}
