import AppKit
import Foundation
import SwiftUI

// MARK: - Diff syntax coloring

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
    /// colors; the old side contributes only its deletions. Returns SwiftUI-scope
    /// attributed lines by row id, with the intraline emphasis layered back on top.
    func styledLines(newSide: [DiffRow], oldSide: [DiffRow], language: String,
                     theme: String, font: NSFont) -> [Int: AttributedString] {
        guard let highlightr = prepared(theme: theme, font: font) else { return [:] }
        var result: [Int: AttributedString] = [:]
        apply(newSide, keeping: [.context, .addition], highlightr, language, into: &result)
        apply(oldSide, keeping: [.deletion], highlightr, language, into: &result)
        return result
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
                       into result: inout [Int: AttributedString]) {
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
            let line = colored.attributedSubstring(from: NSRange(location: location, length: length))
            var attributed = Self.swiftUIAttributed(line)
            attributed.applyDiffEmphasis(row.emphasis, kind: row.kind)
            result[row.id] = attributed
        }
    }

    /// Re-emits an AppKit attributed line as SwiftUI attributes. `Text` only honors
    /// the SwiftUI attribute scope, so the theme's `NSColor`/`NSFont` runs must be
    /// translated, not just bridged; the theme's background never carries over — the
    /// row's add/delete wash owns that layer.
    private static func swiftUIAttributed(_ line: NSAttributedString) -> AttributedString {
        var attributed = AttributedString("")
        line.enumerateAttributes(in: NSRange(location: 0, length: line.length)) { attributes, range, _ in
            var piece = AttributedString(line.attributedSubstring(from: range).string)
            if let color = attributes[.foregroundColor] as? NSColor {
                piece.foregroundColor = Color(nsColor: color)
            }
            if let font = attributes[.font] as? NSFont {
                piece.font = Font(font)
            }
            attributed += piece
        }
        return attributed
    }
}

extension AttributedString {
    /// Lays a diff row's intraline emphasis span over the line — the deeper second
    /// shade of the row's own tint. Shared by the syntax-colored path and the plain
    /// fallback so the two can never drift apart.
    mutating func applyDiffEmphasis(_ emphasis: Range<Int>?, kind: DiffRow.Kind) {
        guard let emphasis, !emphasis.isEmpty else { return }
        guard let start = characters.index(characters.startIndex, offsetBy: emphasis.lowerBound,
                                           limitedBy: characters.endIndex),
              let end = characters.index(characters.startIndex, offsetBy: emphasis.upperBound,
                                         limitedBy: characters.endIndex),
              start < end else { return }
        self[start..<end].backgroundColor =
            kind == .addition ? Color.green.opacity(0.28) : Color.red.opacity(0.28)
    }
}
