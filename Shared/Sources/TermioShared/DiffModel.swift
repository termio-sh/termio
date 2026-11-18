import Foundation

// MARK: - Unified diff model

/// One line of a parsed unified diff. `text` is the line *without* its `+`/`-`/space
/// marker, so a renderer can style the marker itself (or draw it outside the text, the
/// way both the desktop gutter and the phone's edge bar do) instead of baking it in.
public struct DiffLine: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case addition, deletion, context, hunk }

    public let id: Int
    public let kind: Kind
    public let text: String
    public let oldLine: Int?
    public let newLine: Int?
    /// The changed spans within a paired deletion/addition line, in `Character`
    /// offsets — rendered with a stronger tint so a one-word edit inside a long line
    /// reads at a glance. A line with two separate edits carries two spans. Empty when
    /// the line has no counterpart, or the two sides share too little for spans to mean
    /// anything.
    public var emphasis: [Range<Int>]

    public init(
        id: Int, kind: Kind, text: String, oldLine: Int?, newLine: Int?,
        emphasis: [Range<Int>] = []
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.oldLine = oldLine
        self.newLine = newLine
        self.emphasis = emphasis
    }
}

/// What a renderer actually lays out: a code line, or a band standing in for a run of
/// unchanged lines that is folded away.
public enum DiffItem: Sendable, Equatable {
    case line(DiffLine)
    /// A folded run, named by the line range it hides (new-side numbers, so it reads
    /// against the gutter) — "227–348" says where you are; a count would only describe
    /// the fold. `controls` are the directions the run can be revealed from; empty means
    /// the band is inert (a 3-line-context diff, where the hidden lines were never
    /// fetched, so there is nothing to splice back in). `heading` is git's section
    /// heading when the gap came from a hunk boundary — the enclosing scope being skipped.
    case band(id: Int, lines: ClosedRange<Int>, controls: DiffBandControls, heading: String?)
}

/// Which end of a folded run a reveal acts on. The direction is the one the reader is
/// looking: `up` pulls down the lines nearest the code *below* the band, `down` the lines
/// nearest the code above it. `all` drops the band entirely.
public enum DiffBandDirection: Sendable {
    case up, down, all
}

/// The reveal directions a band offers. A run with nothing rendered above it has no
/// downward control (there is no code to continue from), and likewise upward. Where the
/// control is *drawn* is a renderer's business — the desktop puts buttons in the gutter,
/// the phone makes the whole row one tap target — but which ones exist is model.
public struct DiffBandControls: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let up = DiffBandControls(rawValue: 1 << 0)
    public static let down = DiffBandControls(rawValue: 1 << 1)
    /// One control that opens the whole run at once, for a gap no longer than a single
    /// step — GitHub Desktop's "Expand All", where two ends would each swallow the gap.
    public static let all = DiffBandControls(rawValue: 1 << 2)
}

/// The file's own text for lines a fixed-context patch never carried, keyed by new-side
/// line number. A `git diff` termio runs itself asks for the whole file as context, so its
/// gaps are already in the rows; GitHub's PR `patch` is fixed at three lines, and a hunk
/// boundary there can only be opened by reading the file. Empty means the surface has no
/// file to read, and the band draws inert — GitHub Desktop's placeholder state.
public struct DiffGapText: Sendable, Equatable {
    private let lines: [Int: String]

    public static let unavailable = DiffGapText(lines: [:])

    public init(lines: [Int: String]) { self.lines = lines }

    /// The new-side text of a whole file, `first` being the line number of `text`'s first
    /// line (1 for a complete file).
    public init(fileLines text: [String], startingAt first: Int = 1) {
        var lines: [Int: String] = [:]
        lines.reserveCapacity(text.count)
        for (offset, line) in text.enumerated() { lines[first + offset] = line }
        self.lines = lines
    }

    public var isEmpty: Bool { lines.isEmpty }

    public func line(_ number: Int) -> String? { lines[number] }

    /// Whether every line of `range` is on hand — a partial read must not offer a control
    /// that would splice a hole into the file.
    public func covers(_ range: ClosedRange<Int>) -> Bool {
        !lines.isEmpty && range.allSatisfy { lines[$0] != nil }
    }
}

/// How much of each folded run the reader has revealed, keyed by the run's anchor line id.
/// The anchor is the run's first hidden line, which is stable as the run shrinks: the
/// always-shown context lines on either side never move, so revealing from one end never
/// renames the band.
public struct DiffExpansion: Sendable {
    /// Lines revealed per step, matching what every other review surface uses. Revealing
    /// a 400-line gap in one jump loses the reader's place.
    public static let step = 20

    private struct Reveal {
        var head = 0
        var tail = 0
    }

    private var reveals: [Int: Reveal] = [:]

    public init() {}

    public mutating func reveal(_ anchor: Int, _ direction: DiffBandDirection) {
        var reveal = reveals[anchor] ?? Reveal()
        switch direction {
        case .down: reveal.head += Self.step
        case .up: reveal.tail += Self.step
        // Halved rather than `Int.max`, so a later step still adds without trapping.
        case .all: reveal.head = Int.max / 2
        }
        reveals[anchor] = reveal
    }

    /// How many of a run's `count` hidden lines to splice back in at each end.
    public func revealed(_ anchor: Int, of count: Int) -> (head: Int, tail: Int) {
        guard let reveal = reveals[anchor] else { return (0, 0) }
        let head = min(reveal.head, count)
        return (head, min(reveal.tail, count - head))
    }
}

/// Parsing and folding unified-diff text, kept free of any UI framework so both ends
/// share one reading of a diff. The desktop renders through its own AppKit document
/// today; this is the model the iOS diff view is built on.
public enum DiffParser {
    /// Parses unified-diff text into lines, tracking old/new line numbers from each
    /// hunk header and dropping the file-header plumbing (`diff --git`, `+++`, …).
    public static func lines(from text: String) -> [DiffLine] {
        var rows: [DiffLine] = []
        var id = 0
        var oldNo = 0
        var newNo = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                if let (o, n) = parseHunkHeader(line) { oldNo = o; newNo = n }
                // Hunk rows carry their start numbers so a renderer can size the gap to
                // the previous hunk when it draws the boundary as a band.
                rows.append(DiffLine(id: id, kind: .hunk, text: String(line), oldLine: oldNo, newLine: newNo))
                id += 1
                continue
            }
            if isFileHeader(line) { continue }
            guard let first = line.first else { continue }
            let body = String(line.dropFirst())
            switch first {
            case "+":
                rows.append(DiffLine(id: id, kind: .addition, text: body, oldLine: nil, newLine: newNo))
                id += 1; newNo += 1
            case "-":
                rows.append(DiffLine(id: id, kind: .deletion, text: body, oldLine: oldNo, newLine: nil))
                id += 1; oldNo += 1
            case " ":
                rows.append(DiffLine(id: id, kind: .context, text: body, oldLine: oldNo, newLine: newNo))
                id += 1; oldNo += 1; newNo += 1
            default:
                continue
            }
        }
        applyIntraline(&rows)
        return rows
    }

    /// The id of a line spliced in from the file instead of parsed out of the patch.
    /// Negative, so it can never collide with a parsed row's id, and stable per line
    /// number, so re-folding keeps the syntax pass and the selection anchored.
    public static func gapLineID(forNewLine number: Int) -> Int { -(number + 1) }

    /// Folds parsed lines into the display list: hunk plumbing disappears (its gap
    /// becomes a band), unchanged runs longer than a handful of lines collapse to a
    /// band keeping 3 lines of context on the side(s) facing a change, and ids in
    /// `expanded` splice their hidden lines back in.
    public static func displayItems(lines rows: [DiffLine],
                                    expansion: DiffExpansion,
                                    gapText: DiffGapText = .unavailable) -> [DiffItem] {
        var items: [DiffItem] = []
        var run: [DiffLine] = []
        var sawChange = false
        var lastNewLine = 0

        func flush(isLast: Bool) {
            defer { run = [] }
            guard !run.isEmpty else { return }
            let head = sawChange ? 3 : 0
            let tail = isLast ? 0 : 3
            let hidden = run.count - head - tail
            guard hidden >= 10 else {
                items += run.map(DiffItem.line)
                return
            }
            items += run.prefix(head).map(DiffItem.line)
            // A slice, not a copy: a folded run can be thousands of lines, and the
            // collapsed case only reads its two ends.
            let hiddenRows = run[head..<(run.count - tail)]
            guard let anchor = hiddenRows.first?.id else { return }
            let revealed = expansion.revealed(anchor, of: hiddenRows.count)
            items += hiddenRows.prefix(revealed.head).map(DiffItem.line)
            let stillHidden = hiddenRows.dropFirst(revealed.head).dropLast(revealed.tail)
            if let firstHidden = stillHidden.first, let lastHidden = stillHidden.last {
                // A control only points somewhere there is code to continue from.
                var controls: DiffBandControls = []
                if !items.isEmpty { controls.insert(.down) }
                if !isLast || revealed.tail > 0 { controls.insert(.up) }
                let first = firstHidden.newLine ?? firstHidden.oldLine ?? 0
                let last = lastHidden.newLine ?? lastHidden.oldLine ?? first
                items.append(.band(id: anchor, lines: first...max(first, last),
                                   controls: controls, heading: nil))
            }
            items += hiddenRows.suffix(revealed.tail).map(DiffItem.line)
            items += run.suffix(tail).map(DiffItem.line)
        }

        for row in rows {
            switch row.kind {
            case .hunk:
                flush(isLast: false)
                if let start = row.newLine, start > lastNewLine + 1 {
                    let gap = (lastNewLine + 1)...(start - 1)
                    let heading = hunkHeading(row.text)
                    // The gap's own lines are never in the patch, so the reveal splices them
                    // from the file. Without the file the band stays inert, the way GitHub
                    // Desktop draws a placeholder where it cannot expand.
                    guard gapText.covers(gap) else {
                        items.append(.band(id: row.id, lines: gap, controls: [], heading: heading))
                        break
                    }
                    // Unchanged through the gap, so both sides advance together: this hunk's
                    // own numbers give the offset back to the old side.
                    let oldOffset = (row.oldLine ?? start) - start
                    let revealed = expansion.revealed(row.id, of: gap.count)
                    func spliced(_ numbers: some Sequence<Int>) -> [DiffItem] {
                        numbers.compactMap { number in
                            gapText.line(number).map { text in
                                .line(DiffLine(id: gapLineID(forNewLine: number), kind: .context,
                                               text: text, oldLine: number + oldOffset,
                                               newLine: number))
                            }
                        }
                    }
                    items += spliced(gap.prefix(revealed.head))
                    let hidden = gap.dropFirst(revealed.head).dropLast(revealed.tail)
                    if let first = hidden.first, let last = hidden.last {
                        // GitHub Desktop's `getHunkExpansionType`: the file's first hunk can
                        // only be read upward, a gap within one step opens in a single jump,
                        // and anything longer offers both ends.
                        var controls: DiffBandControls = [.up, .down]
                        if items.isEmpty {
                            controls = .up
                        } else if hidden.count <= DiffExpansion.step {
                            controls = .all
                        }
                        items.append(.band(id: row.id, lines: first...last,
                                           controls: controls, heading: heading))
                    }
                    items += spliced(gap.suffix(revealed.tail))
                }
            case .context:
                run.append(row)
                lastNewLine = row.newLine ?? lastNewLine
            case .addition:
                flush(isLast: false)
                sawChange = true
                items.append(.line(row))
                lastNewLine = row.newLine ?? lastNewLine
            case .deletion:
                flush(isLast: false)
                sawChange = true
                items.append(.line(row))
            }
        }
        flush(isLast: true)
        return items
    }

    /// Marks the changed spans inside modified lines: within each run, a block of
    /// deletions immediately followed by a block of additions is paired index-wise, and
    /// each pair is word-diffed by `DiffIntraline`.
    private static func applyIntraline(_ rows: inout [DiffLine]) {
        var i = 0
        while i < rows.count {
            guard rows[i].kind == .deletion else { i += 1; continue }
            let delStart = i
            while i < rows.count, rows[i].kind == .deletion { i += 1 }
            let addStart = i
            while i < rows.count, rows[i].kind == .addition { i += 1 }
            for k in 0..<min(addStart - delStart, i - addStart) {
                guard let spans = DiffIntraline.spans(old: rows[delStart + k].text,
                                                      new: rows[addStart + k].text)
                else { continue }
                rows[delStart + k].emphasis = spans.old
                rows[addStart + k].emphasis = spans.new
            }
        }
    }

    // MARK: Line scanning

    /// git's plumbing lines, which carry no code and no line numbers.
    private static let fileHeaderPrefixes = [
        "diff ", "index ", "--- ", "+++ ", "new file", "deleted file",
        "old mode", "new mode", "similarity ", "dissimilarity ",
        "rename ", "copy ", "\\ ",
    ]

    private static func isFileHeader(_ line: Substring) -> Bool {
        fileHeaderPrefixes.contains(where: line.hasPrefix)
    }

    /// The section heading git appends to a hunk header (`@@ -a,b +c,d @@ func foo() {`) —
    /// the enclosing scope of the lines that follow, which a folded band shows to say what
    /// is being skipped.
    public static func hunkHeading(_ text: String) -> String? {
        let parts = text.components(separatedBy: "@@")
        guard parts.count >= 3 else { return nil }
        let heading = parts[2...].joined(separator: "@@").trimmingCharacters(in: .whitespaces)
        return heading.isEmpty ? nil : heading
    }

    /// Pulls the starting old and new line numbers out of `@@ -a,b +c,d @@`.
    private static func parseHunkHeader(_ line: Substring) -> (Int, Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        func start(_ s: Substring) -> Int? {
            Int(s.dropFirst().split(separator: ",").first ?? s.dropFirst())
        }
        guard let o = start(parts[1]), let n = start(parts[2]) else { return nil }
        return (o, n)
    }
}
