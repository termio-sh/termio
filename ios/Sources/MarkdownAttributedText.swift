import UIKit

/// Renders an agent's Markdown into an attributed string for the chat lens.
///
/// Foundation's `AttributedString(markdown:)` handles inline syntax well and
/// block syntax not at all — it flattens fenced code, headings and lists into
/// one run of prose, which is most of what an agent writes. So block structure
/// is parsed here and each block's *inline* markup is handed to Foundation.
///
/// The renderer is incremental at the block level, not the token level: the
/// content plane's source is a transcript the agent flushes a message at a time,
/// so there is no half-written sentence to stream. New text arrives as new
/// blocks appended below, which is also why nothing here needs to re-lay-out
/// what is already on screen.
enum MarkdownAttributedText {
    struct Style {
        var body: UIFont = .preferredFont(forTextStyle: .body)
        var code: UIFont = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        var textColor: UIColor = .label
        var secondaryColor: UIColor = .secondaryLabel
        /// A fenced block reads as one slab. Inline code sits *inside* a
        /// sentence, so it takes a far lighter tint: at the block's weight, an
        /// attributed background paints a full line-height box behind every
        /// span and shreds the paragraph into stripes.
        var codeBackground: UIColor = .tertiarySystemFill
        var inlineCodeBackground: UIColor = .quaternarySystemFill

        /// Leading and block spacing are derived from the body size, so Dynamic
        /// Type scales the page's rhythm and not just its glyphs. The system
        /// default sets lines tight enough that a few paragraphs of agent prose
        /// read as one wall of text; ~0.22em of extra leading and a full blank
        /// line's worth between blocks is what separates the thoughts.
        var lineSpacing: CGFloat { (body.pointSize * 0.22).rounded() }
        var blockSpacing: CGFloat { (body.pointSize * 0.62).rounded() }
        /// Where a list item's text column starts. Wrapped lines land here too,
        /// so the marker keeps its own gutter instead of the second line sliding
        /// back underneath the number.
        var listIndent: CGFloat { (body.pointSize * 1.35).rounded() }
    }

    static func render(_ markdown: String, style: Style = Style()) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for block in blocks(in: markdown) {
            if output.length > 0 { output.append(NSAttributedString(string: "\n")) }
            output.append(render(block, style: style))
        }
        return output
    }

    // MARK: - Block parsing

    private enum Block {
        case paragraph(String)
        case heading(level: Int, text: String)
        case code(language: String?, body: String)
        case listItem(marker: String, text: String)
        case quote(String)
        case rule
    }

    private static func blocks(in markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph.removeAll()
        }

        var lines = markdown.components(separatedBy: "\n")[...]
        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                // An unterminated fence runs to the end rather than swallowing
                // the rest as prose: a transcript can be read mid-write.
                while let next = lines.first, !next.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(next)
                    lines = lines.dropFirst()
                }
                if lines.first != nil { lines = lines.dropFirst() }
                blocks.append(.code(language: language.isEmpty ? nil : language, body: body.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                continue
            }
            if let hashes = trimmed.range(of: "^#{1,6} ", options: .regularExpression) {
                flushParagraph()
                let level = trimmed.distance(from: trimmed.startIndex, to: hashes.upperBound) - 1
                blocks.append(.heading(level: level, text: String(trimmed[hashes.upperBound...])))
                continue
            }
            if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
                continue
            }
            if let bullet = trimmed.range(of: "^([-*+]|\\d+\\.) ", options: .regularExpression) {
                flushParagraph()
                let marker = trimmed[bullet].trimmingCharacters(in: .whitespaces)
                blocks.append(
                    .listItem(
                        marker: marker == "-" || marker == "*" || marker == "+" ? "•" : marker,
                        text: String(trimmed[bullet.upperBound...])))
                continue
            }
            paragraph.append(line)
        }
        flushParagraph()
        return blocks
    }

    // MARK: - Block rendering

    private static func render(_ block: Block, style: Style) -> NSAttributedString {
        switch block {
        case .paragraph(let text):
            let rendered = NSMutableAttributedString(
                attributedString: inline(text, font: style.body, color: style.textColor, style: style))
            return rendered.laidOut(with: baseParagraph(style))

        case .heading(let level, let text):
            let size = max(style.body.pointSize + CGFloat(4 - level) * 2, style.body.pointSize)
            let font = UIFont.systemFont(ofSize: size, weight: level <= 2 ? .bold : .semibold)
            let paragraphStyle = baseParagraph(style)
            // A heading belongs to what follows it, so it takes its air from
            // above and keeps a short gap below.
            paragraphStyle.paragraphSpacingBefore = style.blockSpacing
            paragraphStyle.paragraphSpacing = (style.blockSpacing * 0.35).rounded()
            let rendered = NSMutableAttributedString(
                attributedString: inline(text, font: font, color: style.textColor, style: style))
            return rendered.laidOut(with: paragraphStyle)

        case .code(let language, let body):
            let paragraphStyle = baseParagraph(style)
            // Code is already vertical; prose leading between its lines only
            // loosens the one block that should read as a unit.
            paragraphStyle.lineSpacing = (style.lineSpacing * 0.4).rounded()
            paragraphStyle.firstLineHeadIndent = 10
            paragraphStyle.headIndent = 10
            paragraphStyle.paragraphSpacingBefore = (style.blockSpacing * 0.5).rounded()
            paragraphStyle.paragraphSpacing = (style.blockSpacing * 0.5).rounded()
            let rendered = NSMutableAttributedString(
                string: body,
                attributes: [
                    .font: style.code, .foregroundColor: style.textColor,
                    .backgroundColor: style.codeBackground, .paragraphStyle: paragraphStyle,
                ])
            if let language {
                let caption = NSAttributedString(
                    string: language + "\n",
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 11, weight: .medium),
                        .foregroundColor: style.secondaryColor,
                        .paragraphStyle: paragraphStyle,
                    ])
                rendered.insert(caption, at: 0)
            }
            return rendered

        case .listItem(let marker, let text):
            let paragraphStyle = baseParagraph(style)
            // Items in one list are one thought — they sit closer to each other
            // than the list sits to the prose around it.
            paragraphStyle.paragraphSpacing = (style.blockSpacing * 0.4).rounded()
            // The marker occupies a gutter and the text starts at a tab stop, so
            // "10." and "•" open the same column and wrapped lines stay in it.
            paragraphStyle.firstLineHeadIndent = 0
            paragraphStyle.headIndent = style.listIndent
            paragraphStyle.defaultTabInterval = style.listIndent
            paragraphStyle.tabStops = [NSTextTab(textAlignment: .left, location: style.listIndent)]
            let rendered = NSMutableAttributedString(
                string: marker + "\t",
                attributes: [.font: style.body, .foregroundColor: style.secondaryColor])
            rendered.append(inline(text, font: style.body, color: style.textColor, style: style))
            return rendered.laidOut(with: paragraphStyle)

        case .quote(let text):
            let paragraphStyle = baseParagraph(style)
            paragraphStyle.headIndent = style.listIndent
            paragraphStyle.firstLineHeadIndent = style.listIndent
            let rendered = NSMutableAttributedString(
                attributedString: inline(text, font: style.body, color: style.secondaryColor, style: style))
            return rendered.laidOut(with: paragraphStyle)

        case .rule:
            return NSAttributedString(
                string: "───",
                attributes: [
                    .font: style.body, .foregroundColor: style.secondaryColor,
                    .paragraphStyle: baseParagraph(style),
                ])
        }
    }

    /// The leading and trailing air every block starts from.
    private static func baseParagraph(_ style: Style) -> NSMutableParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = style.lineSpacing
        paragraphStyle.paragraphSpacing = style.blockSpacing
        return paragraphStyle
    }

    /// Inline markup only — bold, italic, inline code, links. Falls back to the
    /// raw text when Foundation rejects the markup, so a stray backtick shows
    /// the character rather than blanking the message.
    private static func inline(
        _ text: String, font: UIFont, color: UIColor, style: Style
    ) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        guard
            let parsed = try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return NSAttributedString(string: text, attributes: base) }

        let rendered = NSMutableAttributedString(parsed)
        rendered.addAttributes(base, range: NSRange(location: 0, length: rendered.length))

        // Re-apply the inline intents Foundation recorded, since the base font
        // above just flattened them.
        rendered.enumerateAttribute(
            .inlinePresentationIntent, in: NSRange(location: 0, length: rendered.length)
        ) { value, range, _ in
            guard let raw = value as? UInt else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            var traits: UIFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            if intent.contains(.code) {
                rendered.addAttributes(
                    [.font: style.code, .backgroundColor: style.inlineCodeBackground], range: range)
                return
            }
            if !traits.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                rendered.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: range)
            }
        }
        return rendered
    }
}

private extension NSMutableAttributedString {
    /// Stamps one paragraph style over the whole block. Applied last, because
    /// Foundation's inline parse leaves its own default style behind on any run
    /// it touched and the block's rhythm has to win.
    func laidOut(with paragraphStyle: NSParagraphStyle) -> NSAttributedString {
        addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: length))
        return self
    }
}
