import Foundation

/// Writes an edit made in the rendered Markdown face back into the file's own formatting.
///
/// The domd kernel's model is Markdown text, but it is *canonical* Markdown text: parsing
/// a file and serializing it straight back re-pads table columns, inserts blank lines
/// around blocks, and renumbers a `0.`-anchored ordered list to `1.`. That round trip is
/// not the identity for most real documents — 110 of the 164 Markdown files in this
/// repository change — so adopting the page's document wholesale would turn one typed
/// character into a whole-file rewrite, and the `0.` case silently changes what a staged
/// list means.
///
/// Opening a file is already safe: the page reports nothing until the document actually
/// changes (`app.js`, `flush`). This is the other half — once the user does type, only
/// what they typed should reach the file.
///
/// It is an ordinary three-way merge. The base is `canonical`, the file as the kernel
/// serializes it with no edit at all; `original` is what is on disk; `edited` is what the
/// kernel reports after the edit. What separates `canonical` from `original` is formatting
/// the file already had and keeps; what separates `canonical` from `edited` is the edit and
/// lands. Where the two overlap — the user typed into a line canonicalization had also
/// rewritten — the edit wins, because losing a keystroke is worse than re-padding one row.
enum MarkdownWriteBack {

    /// `original` with the user's edit applied and nothing else changed.
    ///
    /// Line-granular, because that is the granularity formatting differs at: a re-padded
    /// table row or an inserted blank line is a whole-line difference, and anchoring on
    /// the lines both sides agree on is what keeps the rest of the file untouched.
    static func merge(edited: String, canonical: String, original: String) -> String {
        // Nothing was typed. The file on disk is already the answer, byte for byte.
        guard edited != canonical else { return original }
        // The kernel round-trips this document exactly, so there is no formatting to
        // protect and the page's own text is the whole truth.
        guard canonical != original else { return edited }

        let base = canonical.components(separatedBy: "\n")
        let ours = original.components(separatedBy: "\n")
        let theirs = edited.components(separatedBy: "\n")

        // Where `original` says the same thing `canonical` does. These are the only
        // positions an edit can be placed at with any confidence.
        let anchors = agreements(between: base, and: ours)

        var result: [String] = []
        var copied = 0
        for hunk in hunks(from: base, to: theirs) {
            // A hunk's edges are expressed in `canonical`; the anchors carry them over to
            // `original`. The end is measured from the last line the hunk covers rather
            // than from the first line past it, so lines `original` has and `canonical`
            // dropped — a blank between two list items, say — are left where they are
            // instead of being swept up by an edit to the line above them.
            let start = max(copied, oursPosition(of: hunk.base.lowerBound,
                                                 in: anchors, count: ours.count))
            let end = max(start, hunk.base.isEmpty ? start
                : oursPosition(after: hunk.base.upperBound - 1, in: anchors, count: ours.count))
            result.append(contentsOf: ours[copied..<start])
            result.append(contentsOf: hunk.lines)
            copied = end
        }
        result.append(contentsOf: ours[copied...])
        return result.joined(separator: "\n")
    }

    /// One replaced span: the `canonical` lines the edit removed, and the lines it put
    /// in their place. An insertion is an empty range; a deletion is an empty `lines`.
    private struct Hunk {
        let base: Range<Int>
        let lines: [String]
    }

    private static func hunks(from base: [String], to theirs: [String]) -> [Hunk] {
        var hunks: [Hunk] = []
        var b = 0, t = 0
        for agreement in agreements(between: base, and: theirs) {
            if b < agreement.left || t < agreement.right {
                hunks.append(Hunk(base: b..<agreement.left, lines: Array(theirs[t..<agreement.right])))
            }
            b = agreement.left + 1
            t = agreement.right + 1
        }
        if b < base.count || t < theirs.count {
            hunks.append(Hunk(base: b..<base.count, lines: Array(theirs[t...])))
        }
        return hunks
    }

    /// The lines the two sides hold in common, as index pairs in ascending order on both.
    private static func agreements(between left: [String],
                                   and right: [String]) -> [(left: Int, right: Int)] {
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in right.difference(from: left) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var pairs: [(left: Int, right: Int)] = []
        var l = 0, r = 0
        while l < left.count, r < right.count {
            if removed.contains(l) { l += 1; continue }
            if inserted.contains(r) { r += 1; continue }
            pairs.append((l, r))
            l += 1
            r += 1
        }
        return pairs
    }

    /// Where a `canonical` line sits in `original`.
    ///
    /// On an anchor the answer is exact. Between two anchors — a run canonicalization
    /// rewrote, a re-padded table say — there is no exact answer, so the offset into the
    /// run is carried across and clamped to it. That is exact whenever the run is the
    /// same length on both sides, which is every rewrite that changes lines rather than
    /// adding or removing them, and it is what confines an edit there to the run instead
    /// of letting it swallow the rest of the file.
    private static func oursPosition(of index: Int,
                                     in anchors: [(left: Int, right: Int)],
                                     count: Int) -> Int {
        let position = firstAnchor(atOrAfter: index, in: anchors)
        if position < anchors.count, anchors[position].left == index {
            return anchors[position].right
        }
        let runBase = position == 0 ? 0 : anchors[position - 1].left + 1
        let runStart = position == 0 ? 0 : anchors[position - 1].right + 1
        let runEnd = position == anchors.count ? count : anchors[position].right
        return min(runStart + (index - runBase), runEnd)
    }

    /// Where in `original` the line after a `canonical` line sits — the closing edge of a
    /// hunk, kept tight so only the lines the hunk actually covers are replaced.
    private static func oursPosition(after index: Int,
                                     in anchors: [(left: Int, right: Int)],
                                     count: Int) -> Int {
        let position = firstAnchor(atOrAfter: index, in: anchors)
        if position < anchors.count, anchors[position].left == index {
            return anchors[position].right + 1
        }
        let runBase = position == 0 ? 0 : anchors[position - 1].left + 1
        let runStart = position == 0 ? 0 : anchors[position - 1].right + 1
        let runEnd = position == anchors.count ? count : anchors[position].right
        return min(runStart + (index - runBase) + 1, runEnd)
    }

    private static func firstAnchor(atOrAfter index: Int,
                                    in anchors: [(left: Int, right: Int)]) -> Int {
        var low = 0
        var high = anchors.count
        while low < high {
            let middle = (low + high) / 2
            if anchors[middle].left < index { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
