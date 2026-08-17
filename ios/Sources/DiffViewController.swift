import Highlightr
import TermioShared
import UIKit

/// Full-screen unified diff, phone rules. The desktop pane renders the same model in
/// AppKit; what changes here is what a 390pt screen can carry:
///
/// - **Never scroll horizontally.** Lines soft-wrap, and a hanging indent keeps a
///   wrapped continuation visually inside its line.
/// - **A saturated edge bar, not a full-line fill.** A heavy green behind a whole line
///   drowns the syntax colors at this size, so the strong ink is a 3pt bar at the
///   leading edge and the line itself takes a very light wash.
/// - **One line-number column.** Two would cost a tenth of the width; a deletion shows
///   its old number, everything else the new one, which is what a reviewer quotes.
/// - **Folds are a pill on a hairline**, named by the line range they hide. The whole
///   row is the tap target, so it clears 44pt without a slab of grey in the code.
/// - **The file walker is in the view.** ‹ 3 of 12 › moves between changed files without
///   a trip back to the list, and the floating button jumps to the next hunk.
/// - **Selection feeds the agent.** Long-press → "Send to Agent" bracketed-pastes the
///   selected code into the session's PTY: the thing a phone diff is *for*.
final class DiffViewController: UIViewController {
    private var files: [WireChange]
    private var index: Int

    /// Ask the owner (which holds the companion socket) for one file's diff, passing the
    /// status from the listing so the Mac needn't re-derive it; the reply arrives back
    /// through `receive(_:)`.
    var onRequestDiff: ((String, String) -> Void)?
    /// Bracketed-paste selected code into the session's terminal. nil hides the action —
    /// a plain shell has no prompt to feed.
    var onSendToAgent: ((String) -> Void)?

    private var rows: [DiffLine] = []
    private var expansion = DiffExpansion()
    /// The path a `readDiff` is in flight for, so a late reply for the previous file
    /// can't paint over the current one.
    private var pendingPath: String?

    private let storage = NSTextStorage()
    private var textView: DiffTextView!
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let walkerLabel = UILabel()
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let hunkButton = UIButton(type: .system)

    /// A `readDiff` is outstanding, so a failure belongs to this screen.
    var isAwaitingDiff: Bool { pendingPath != nil }

    private var change: WireChange? {
        files.indices.contains(index) ? files[index] : nil
    }

    private var document: DiffDocument? { textView.document }

    init(files: [WireChange], index: Int) {
        self.files = files
        self.index = min(max(index, 0), max(files.count - 1, 0))
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let header = configureHeader()
        let walker = configureWalker()
        configureText(below: header, above: walker)
        configureHunkButton(above: walker)
        configureStatus()
        reloadFile()
    }

    // MARK: - Chrome

    private func configureHeader() -> UIView {
        let close = UIButton(type: .system)
        close.applyGlassSymbol("xmark")
        close.tintColor = .label
        close.addAction(UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        }, for: .touchUpInside)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingMiddle

        subtitleLabel.font = .preferredFont(forTextStyle: .caption2)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.lineBreakMode = .byTruncatingHead

        let titles = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titles.axis = .vertical
        titles.alignment = .center

        spinner.hidesWhenStopped = true

        let bar = UIStackView(arrangedSubviews: [close, titles, spinner])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 4
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            close.widthAnchor.constraint(equalToConstant: 40),
            close.heightAnchor.constraint(equalToConstant: 40),
            spinner.widthAnchor.constraint(equalToConstant: 40),
        ])
        return bar
    }

    /// ‹ 3 of 12 › — walking the changed files without going back to the list. Absent
    /// for a single file, where it would only take height away from the code.
    private func configureWalker() -> UIView {
        previousButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        previousButton.addAction(UIAction { [weak self] _ in self?.walk(-1) }, for: .touchUpInside)
        nextButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)
        nextButton.addAction(UIAction { [weak self] _ in self?.walk(1) }, for: .touchUpInside)

        walkerLabel.font = .roundedCounter(size: 13, weight: .medium)
        walkerLabel.textColor = .secondaryLabel
        walkerLabel.textAlignment = .center

        let bar = UIStackView(arrangedSubviews: [previousButton, walkerLabel, nextButton])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.distribution = .fill
        bar.isLayoutMarginsRelativeArrangement = true
        bar.directionalLayoutMargins = .init(top: 6, leading: 12, bottom: 6, trailing: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isHidden = files.count < 2
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            previousButton.widthAnchor.constraint(equalToConstant: 44),
            previousButton.heightAnchor.constraint(equalToConstant: 44),
            nextButton.widthAnchor.constraint(equalToConstant: 44),
            nextButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        return bar
    }

    private func configureText(below header: UIView, above walker: UIView) {
        let layoutManager = DiffWashLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        // Breathing room between the edge bar and the first glyph lives in the
        // container's padding, so the wash the layout manager paints still reaches the
        // full width instead of stopping at an inset.
        container.lineFragmentPadding = 8
        layoutManager.addTextContainer(container)

        textView = DiffTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .clear
        textView.delegate = self
        // The left inset is the line-number column the text view paints into.
        textView.textContainerInset = UIEdgeInsets(top: 10, left: DiffTextView.gutterWidth, bottom: 24, right: 8)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: walker.topAnchor),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        textView.addGestureRecognizer(tap)
    }

    /// Jump to the next change in a long diff — the one navigation a scrolling reader
    /// actually needs. Floats over the code, out of the text's way.
    private func configureHunkButton(above walker: UIView) {
        hunkButton.applyGlassSymbol("chevron.down")
        hunkButton.tintColor = .label
        hunkButton.isHidden = true
        hunkButton.addAction(UIAction { [weak self] _ in self?.scrollToNextChange() }, for: .touchUpInside)
        hunkButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hunkButton)
        NSLayoutConstraint.activate([
            hunkButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            hunkButton.bottomAnchor.constraint(equalTo: walker.topAnchor, constant: -14),
            hunkButton.widthAnchor.constraint(equalToConstant: 44),
            hunkButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func configureStatus() {
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
    }

    // MARK: - Files

    private func walk(_ delta: Int) {
        let target = index + delta
        guard files.indices.contains(target) else { return }
        index = target
        reloadFile()
    }

    private func reloadFile() {
        guard let change else { return }
        rows = []
        expansion = DiffExpansion()
        textView.document = nil
        storage.setAttributedString(NSAttributedString())
        titleLabel.text = change.name
        subtitleLabel.text = change.caption
        walkerLabel.text = localized("\(index + 1) of \(files.count)")
        previousButton.isEnabled = index > 0
        nextButton.isEnabled = index < files.count - 1
        hunkButton.isHidden = true
        statusLabel.isHidden = true
        guard !change.isBinary else {
            show(status: localized("Binary file — no text diff to show."))
            return
        }
        pendingPath = change.path
        spinner.startAnimating()
        onRequestDiff?(change.path, change.status)
    }

    /// A `readDiff` reply arrived (routed in by the owner).
    func receive(_ diff: WireDiff) {
        guard diff.path == pendingPath else { return }
        pendingPath = nil
        spinner.stopAnimating()
        guard !diff.binary else {
            show(status: localized("Binary file — no text diff to show."))
            return
        }
        rows = DiffParser.lines(from: diff.text)
        guard !rows.isEmpty else {
            show(status: localized("No textual changes in this file."))
            return
        }
        statusLabel.isHidden = true
        rebuild()
        highlightSyntax()
    }

    /// The Mac refused the request (routed in by the owner).
    func failed(_ message: String) {
        pendingPath = nil
        spinner.stopAnimating()
        show(status: message)
    }

    private func show(status: String) {
        storage.setAttributedString(NSAttributedString())
        textView.document = nil
        hunkButton.isHidden = true
        statusLabel.text = status
        statusLabel.isHidden = false
    }

    // MARK: - Rendering

    /// `anchor` pins a row to a screen position across the rebuild — the tapped band's
    /// first revealed line stays where the band was, so expanding never teleports the
    /// reader. nil rebuilds from the top.
    private func rebuild(anchor: (rowId: Int, y: CGFloat)? = nil) {
        let items = DiffParser.displayItems(lines: rows, expansion: expansion)
        let built = DiffDocument.build(items: items, font: MobileSettings.shared.codeFont())
        textView.document = built
        storage.setAttributedString(built.attributed)
        hunkButton.isHidden = built.changeAnchors.count < 2
        guard let anchor, let line = built.lines.first(where: { $0.rowId == anchor.rowId })
        else { return }
        let rect = textView.rect(forParagraph: line)
        let offset = max(rect.minY - anchor.y, -textView.adjustedContentInset.top)
        textView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
    }

    /// Colors the diff the way the desktop does: each side is highlighted as one text so
    /// multi-line constructs (block comments, raw strings) keep their real state, then
    /// the per-line results are dropped onto the built document. Context lines take the
    /// new side's colors; the old side contributes only its deletions.
    private func highlightSyntax() {
        guard let change,
              let language = CodeHighlighter.language(forFileNamed: (change.path as NSString).lastPathComponent)
        else { return }
        let dark = traitCollection.userInterfaceStyle == .dark
        let font = MobileSettings.shared.codeFont()
        let newSide = rows.filter { $0.kind == .context || $0.kind == .addition }
        let oldSide = rows.filter { $0.kind == .deletion }
        let path = change.path
        DiffSyntaxHighlighter.shared.styledLines(
            newSide: newSide, oldSide: oldSide, language: language,
            theme: dark ? "xcode-dark" : "xcode", font: font
        ) { [weak self] styled in
            guard let self, !styled.isEmpty, self.change?.path == path else { return }
            apply(styled: styled)
        }
    }

    private func apply(styled: [Int: NSAttributedString]) {
        guard let document else { return }
        storage.beginEditing()
        for line in document.lines {
            guard case .code = line.role, let colored = styled[line.rowId],
                  colored.length == line.range.length - 1 else { continue }
            colored.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: colored.length)) {
                value, range, _ in
                guard let color = value as? UIColor else { return }
                storage.addAttribute(
                    .foregroundColor, value: color,
                    range: NSRange(location: line.range.location + range.location, length: range.length)
                )
            }
        }
        storage.endEditing()
    }

    // MARK: - Interaction

    /// A tap on a fold band reveals its lines. Everything else is the text view's own
    /// business (a tap in code just dismisses any selection).
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: textView)
        guard let line = textView.line(at: point), case .band(let expandable) = line.role else { return }
        guard expandable else {
            // A fixed band's lines were never fetched — say so instead of no-oping.
            let alert = UIAlertController(
                title: localized("Not available"),
                message: localized("This diff was fetched without full context because the file is large, so the skipped lines aren't on the phone."),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: localized("OK"), style: .default))
            present(alert, animated: true)
            return
        }
        let anchorY = textView.rect(forParagraph: line).minY - textView.contentOffset.y
        // One tap reveals the whole gap — a phone has no room for a per-direction control,
        // so the row is the button and `.all` is the only reveal it asks for.
        expansion.reveal(line.rowId, .all)
        rebuild(anchor: (line.rowId, anchorY))
    }

    private func scrollToNextChange() {
        guard let document, !document.changeAnchors.isEmpty else { return }
        let current = textView.contentOffset.y + textView.adjustedContentInset.top
        let next = document.changeAnchors.first {
            textView.rect(forParagraph: document.lines[$0]).minY > current + 8
        } ?? document.changeAnchors[0]
        let target = textView.rect(forParagraph: document.lines[next]).minY - 12
        textView.setContentOffset(CGPoint(x: 0, y: max(target, -textView.adjustedContentInset.top)), animated: true)
    }

    /// The selected text as pure code: band labels are chrome, so a selection that
    /// spans one hands the agent the code around it, not "⋯ 24 unchanged lines".
    private func selectedCode() -> String? {
        guard let document, let range = textView.selectedTextRange, !range.isEmpty else { return nil }
        let selection = textView.selectedRange
        var parts: [String] = []
        var index = document.lineIndex(at: selection.location)
        while index < document.lines.count {
            let line = document.lines[index]
            index += 1
            if line.range.location >= NSMaxRange(selection) { break }
            if case .band = line.role { continue }
            let clipped = NSIntersectionRange(line.range, selection)
            guard clipped.length > 0 else { continue }
            parts.append((storage.string as NSString).substring(with: clipped))
        }
        let text = parts.joined()
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}

extension DiffViewController: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard onSendToAgent != nil, range.length > 0 else { return nil }
        let send = UIAction(title: localized("Send to Agent"), image: UIImage(systemName: "arrow.up.message")) {
            [weak self] _ in
            guard let self, let code = selectedCode() else { return }
            onSendToAgent?(code)
            self.textView.selectedTextRange = nil
            dismiss(animated: true)
        }
        return UIMenu(children: [send] + suggestedActions)
    }
}

// MARK: - Document

/// The folded diff laid down as one attributed string plus per-paragraph metadata the
/// text view reads at draw time. One document means one scroll and one continuous
/// selection, which is what lets a selection cross lines and reach the agent intact.
final class DiffDocument {
    enum Role {
        case code(DiffLine.Kind)
        case band(expandable: Bool)
    }

    struct Line {
        let role: Role

        /// The paragraph's range, including its trailing newline.
        let range: NSRange
        /// `DiffLine.id` for code (keys the syntax pass), the first hidden line's id for
        /// a band (keys the expand).
        let rowId: Int
        /// The number drawn in the gutter: a deletion's old line, else the new one.
        let number: Int?

        var isBand: Bool {
            if case .band = role { return true }
            return false
        }
    }

    let attributed: NSAttributedString
    let lines: [Line]
    /// Indices into `lines` where a run of additions/deletions starts — the stops the
    /// next-hunk button walks.
    let changeAnchors: [Int]

    private init(attributed: NSAttributedString, lines: [Line], changeAnchors: [Int]) {
        self.attributed = attributed
        self.lines = lines
        self.changeAnchors = changeAnchors
    }

    /// Extra height around a band's text, so the whole row clears a 44pt tap target.
    fileprivate static let bandPadding: CGFloat = 13

    static func build(items: [DiffItem], font: UIFont) -> DiffDocument {
        var text = String()
        var lines: [Line] = []
        var changeAnchors: [Int] = []
        var previousWasChange = false
        // A running offset: `(text as NSString).length` on the growing string is O(n) for
        // non-ASCII content, which would make laying the document down quadratic.
        var location = 0

        for item in items {
            switch item {
            case .line(let row):
                text += row.text
                text += "\n"
                let length = (row.text as NSString).length + 1
                let isChange = row.kind == .addition || row.kind == .deletion
                if isChange, !previousWasChange { changeAnchors.append(lines.count) }
                previousWasChange = isChange
                lines.append(Line(
                    role: .code(row.kind),
                    range: NSRange(location: location, length: length),
                    rowId: row.id,
                    number: row.kind == .deletion ? row.oldLine : row.newLine
                ))
                location += length
            case .band(let id, let range, let controls, let heading):
                // The range names the code the fold hides, against the same numbers the
                // gutter shows. A count would only describe the fold itself. git's section
                // heading rides along when the gap came from a hunk boundary — on a phone
                // it is the only hint of what scope you are skipping over.
                let expandable = !controls.isEmpty
                let rangeLabel = "\(range.lowerBound)–\(range.upperBound)"
                let label = heading.map { "\(rangeLabel)  \($0)" } ?? rangeLabel
                text += label
                text += "\n"
                let length = (label as NSString).length + 1
                previousWasChange = false
                lines.append(Line(
                    role: .band(expandable: expandable),
                    range: NSRange(location: location, length: length),
                    rowId: id,
                    number: nil
                ))
                location += length
            }
        }

        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor.label,
        ])
        let band = NSMutableParagraphStyle()
        band.alignment = .center
        band.lineSpacing = 2
        band.paragraphSpacingBefore = bandPadding
        band.paragraphSpacing = bandPadding
        // A wrapped continuation hangs off the line's *own* indentation, not off the
        // margin: on a 390pt screen most lines wrap, and a continuation that jumps back
        // to column 0 reads as a new statement. One style per distinct indent, cached —
        // a 5000-line diff has a handful.
        var styles: [String: NSParagraphStyle] = [:]

        attributed.beginEditing()
        for (item, line) in zip(items, lines) {
            switch item {
            case .band(_, _, let controls, _):
                let expandable = !controls.isEmpty
                attributed.addAttributes([
                    .font: UIFont.roundedCounter(size: 11, weight: .medium),
                    // A fixed band is inert (its lines were never fetched), so it sits a
                    // step back in the ink hierarchy.
                    .foregroundColor: expandable ? UIColor.secondaryLabel : UIColor.tertiaryLabel,
                    .paragraphStyle: band,
                ], range: line.range)
            case .line(let row):
                let indent = String(row.text.prefix { $0 == " " || $0 == "\t" })
                let style = styles[indent] ?? {
                    let style = NSMutableParagraphStyle()
                    style.lineSpacing = 2
                    style.headIndent = (indent as NSString).size(withAttributes: [.font: font]).width + 16
                    styles[indent] = style
                    return style
                }()
                attributed.addAttribute(.paragraphStyle, value: style, range: line.range)
                guard !row.emphasis.isEmpty else { continue }
                let color: UIColor = row.kind == .addition
                    ? UIColor.systemGreen.withAlphaComponent(0.3)
                    : UIColor.systemRed.withAlphaComponent(0.3)
                // A line with two separate edits carries two spans.
                for span in row.emphasis {
                    guard !span.isEmpty, let range = utf16Range(of: span, in: row.text) else { continue }
                    attributed.addAttribute(
                        .backgroundColor, value: color,
                        range: NSRange(location: line.range.location + range.location,
                                       length: range.length)
                    )
                }
            }
        }
        attributed.endEditing()

        return DiffDocument(attributed: attributed, lines: lines, changeAnchors: changeAnchors)
    }

    /// The index of the first line whose paragraph ends past `location`.
    func lineIndex(at location: Int) -> Int {
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(lines[mid].range) <= location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    func line(at location: Int) -> Line? {
        let index = lineIndex(at: location)
        guard index < lines.count, NSLocationInRange(location, lines[index].range) else { return nil }
        return lines[index]
    }

    /// `DiffLine.emphasis` counts `Character`s (the intraline pass is CJK-aware);
    /// attributed ranges are UTF-16. Bail rather than misplace the span.
    private static func utf16Range(of emphasis: Range<Int>, in text: String) -> NSRange? {
        guard let lower = text.index(text.startIndex, offsetBy: emphasis.lowerBound, limitedBy: text.endIndex),
              let upper = text.index(text.startIndex, offsetBy: emphasis.upperBound, limitedBy: text.endIndex),
              lower < upper else { return nil }
        return NSRange(lower..<upper, in: text)
    }
}

// MARK: - Text view

/// The diff's text view: TextKit 1, so `DiffWashLayoutManager` can paint the row
/// semantics — washes, edge bars, and the line-number column — underneath the glyphs.
/// The view itself draws nothing of its own; see the layout manager for why.
final class DiffTextView: UITextView {
    static let gutterWidth: CGFloat = 34

    var document: DiffDocument? {
        didSet {
            (layoutManager as? DiffWashLayoutManager)?.document = document
            setNeedsDisplay()
        }
    }

    /// The paragraph's rect in content coordinates.
    func rect(forParagraph line: DiffDocument.Line) -> CGRect {
        let glyphs = layoutManager.glyphRange(forCharacterRange: line.range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerInset.left
        rect.origin.y += textContainerInset.top
        return rect
    }

    /// The line under a point in view coordinates, if any.
    func line(at point: CGPoint) -> DiffDocument.Line? {
        guard let document else { return nil }
        let inContainer = CGPoint(
            x: point.x - textContainerInset.left,
            y: point.y - textContainerInset.top
        )
        let index = layoutManager.characterIndex(
            for: inContainer, in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        // `characterIndex` snaps to the nearest character, so a tap in the empty space
        // past the end would "hit" the last line. Take the hit only if the point is
        // actually inside that paragraph — with a band's row grown to a full 44pt, since
        // its pill is a smaller target than the row it stands for.
        guard let line = document.line(at: index) else { return nil }
        var hit = rect(forParagraph: line)
        if line.isBand {
            let grow = max(0, 44 - hit.height) / 2
            hit = hit.insetBy(dx: 0, dy: -grow)
        }
        guard hit.contains(point) else { return nil }
        return line
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        (layoutManager as? DiffWashLayoutManager)?.contentWidth = bounds.width
    }

}

/// Paints each line's meaning behind its glyphs: a saturated 3pt bar at the leading
/// edge and a light wash across the row for additions and deletions, a flat fill for
/// fold bands. The bar is what carries at phone size — the wash stays light enough that
/// syntax colors on top stay readable, which a full-strength green does not.
final class DiffWashLayoutManager: NSLayoutManager {
    var document: DiffDocument?
    /// The hosting view's width — washes span the whole row, including the line-number
    /// column, not just the laid-out text.
    var contentWidth: CGFloat = 0

    static let barWidth: CGFloat = 3

    /// Everything below is constant per document; a draw pass fires on every scroll
    /// tick, so none of it is rebuilt there.
    private static let additionWash = UIColor.systemGreen.withAlphaComponent(0.09)
    private static let deletionWash = UIColor.systemRed.withAlphaComponent(0.09)
    private lazy var numberAttributes = Self.numberAttributes()
    /// One digit's advance in the (monospaced-digit) number font, so a number can be
    /// right-aligned by arithmetic instead of a measuring layout pass per line.
    private lazy var digitWidth: CGFloat = ("0" as NSString).size(withAttributes: numberAttributes).width

    /// Everything the row means is drawn here, in one pass over the visible lines:
    /// washes, edge bars, and the line numbers.
    ///
    /// The numbers belong on *this* surface specifically. TextKit renders a layout
    /// manager's drawing into the text view's scrolling container, so it travels with
    /// `contentOffset` for free; a `UITextView.draw(_:)` override paints into the view's
    /// own layer instead, which does not move — the numbers then hang in the viewport
    /// while the code scrolls under them, and the only way back is repainting the whole
    /// viewport every frame. The desktop learned the same lesson from the other side
    /// (see `Sources/termio/Git/DiffTextView.swift`, where AppKit's copy-on-scroll
    /// forces a full ruler invalidation). They still stay out of any selection, because
    /// they are painted, not part of the string.
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        if let document, let container = textContainers.first {
            let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            // The view's width, not the used rect: the text soft-wraps, so it never
            // exceeds the view — and `usedRect` would lay out the whole container on
            // every pass to tell us so.
            let width = contentWidth
            var index = document.lineIndex(at: charRange.location)
            while index < document.lines.count {
                let line = document.lines[index]
                index += 1
                if line.range.location >= NSMaxRange(charRange) { break }
                let glyphs = glyphRange(forCharacterRange: line.range, actualCharacterRange: nil)
                var rect = boundingRect(forGlyphRange: glyphs, in: container)
                rect.origin.y += origin.y
                if case .band(let expandable) = line.role {
                    // The fold reads as a seam in the file with a control sitting on it —
                    // Mail's trimmed-quote pill — not as a grey slab competing with the
                    // code around it. The used rect is the centered label's real extent,
                    // so the capsule wraps the text wherever it lands.
                    var used = lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                    used.origin.x += origin.x
                    used.origin.y += origin.y
                    drawBand(around: used, across: width, expandable: expandable)
                } else if let (wash, bar) = Self.fills(for: line.role) {
                    var fill = rect
                    fill.origin.x = 0
                    fill.size.width = width
                    wash.setFill()
                    UIRectFill(fill)
                    bar.setFill()
                    UIRectFill(CGRect(x: 0, y: fill.minY, width: Self.barWidth, height: fill.height))
                }
                // `origin.x` is the container's left inset — exactly the column the
                // numbers live in, and it holds no glyphs to collide with. Drawn on the
                // paragraph's first line, so a wrapped line is numbered once.
                if let number = line.number {
                    let digits = "\(number)"
                    NSAttributedString(string: digits, attributes: numberAttributes).draw(at: CGPoint(
                        x: origin.x - CGFloat(digits.count) * digitWidth - 8,
                        y: rect.minY
                    ))
                }
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// A hairline across the row with an opaque capsule behind the label. Drawn under
    /// the glyphs, so the range text lands inside the capsule.
    private func drawBand(around label: CGRect, across width: CGFloat, expandable: Bool) {
        let capsule = label.insetBy(dx: -10, dy: -4)
        let rule = CGRect(x: 0, y: capsule.midY - 0.25, width: width, height: 0.5)
        UIColor.separator.withAlphaComponent(expandable ? 0.6 : 0.35).setFill()
        UIRectFill(rule)
        let path = UIBezierPath(roundedRect: capsule, cornerRadius: capsule.height / 2)
        // Opaque, so the rule stops cleanly at the capsule instead of striking through it.
        UIColor.secondarySystemBackground.setFill()
        path.fill()
        if expandable {
            UIColor.separator.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }

    private static func numberAttributes() -> [NSAttributedString.Key: Any] {
        let size = max(9, MobileSettings.shared.codeFont().pointSize - 2)
        return [
            .font: UIFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: UIColor.tertiaryLabel,
        ]
    }

    /// (row wash, leading bar) for a code line. The wash is deliberately faint; the bar
    /// is full strength. Bands paint themselves — see `drawBand`.
    private static func fills(for role: DiffDocument.Role) -> (UIColor, UIColor)? {
        switch role {
        case .code(.addition): return (additionWash, .systemGreen)
        case .code(.deletion): return (deletionWash, .systemRed)
        case .band, .code: return nil
        }
    }
}

// MARK: - Syntax

/// One reusable Highlightr on a serial queue. Building its JavaScriptCore context costs
/// on the order of 100 ms — too much to pay per file — and the context is not safe to
/// share across threads, so every request is funnelled through the same queue. The
/// desktop keeps the same arrangement behind an actor.
final class DiffSyntaxHighlighter {
    static let shared = DiffSyntaxHighlighter()

    /// Past this, highlighting a whole file's diff costs more than it returns on a
    /// phone; the reader stays readable in plain ink.
    private static let maxCharacters = 200_000

    private let queue = DispatchQueue(label: "sh.termio.diff-syntax", qos: .userInitiated)
    private var highlightr: Highlightr?
    private var appliedTheme: String?
    private var appliedFont: UIFont?

    func styledLines(
        newSide: [DiffLine], oldSide: [DiffLine], language: String,
        theme: String, font: UIFont,
        completion: @escaping ([Int: NSAttributedString]) -> Void
    ) {
        let total = newSide.reduce(0) { $0 + $1.text.utf8.count }
            + oldSide.reduce(0) { $0 + $1.text.utf8.count }
        guard total <= Self.maxCharacters else { return }
        queue.async { [weak self] in
            guard let self, let highlightr = prepared(theme: theme, font: font) else { return }
            var result: [Int: NSAttributedString] = [:]
            Self.apply(newSide, highlightr, language, into: &result)
            Self.apply(oldSide, highlightr, language, into: &result)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func prepared(theme: String, font: UIFont) -> Highlightr? {
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

    private static func apply(
        _ side: [DiffLine], _ highlightr: Highlightr, _ language: String,
        into result: inout [Int: NSAttributedString]
    ) {
        let joined = side.map(\.text).joined(separator: "\n")
        // The colored text must round-trip exactly, or the per-line offsets below would
        // attribute the wrong spans — bail to plain rendering instead.
        guard let colored = highlightr.highlight(joined, as: language, fastRender: true),
              colored.string == joined else { return }
        var location = 0
        for row in side {
            let length = (row.text as NSString).length
            defer { location += length + 1 }
            guard length > 0 else { continue }
            result[row.id] = colored.attributedSubstring(from: NSRange(location: location, length: length))
        }
    }
}
