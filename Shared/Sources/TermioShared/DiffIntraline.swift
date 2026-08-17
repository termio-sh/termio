import Foundation

/// Marks the changed spans inside a modified line pair (Critique's and Xcode's intraline
/// highlight).
///
/// The spans come from a word-level diff, not from stripping the pair's common prefix and
/// suffix: a line with two separate edits — `foo(a, b)` → `bar(a, c)` — has no common
/// middle to strip, so prefix/suffix stripping has to emphasize everything between the
/// first and last change and the reader learns nothing. Diffing the words finds both
/// edits and leaves `(a, ` alone.
///
/// Offsets are `Character` counts, matching `DiffRow.text`.
public enum DiffIntraline {
    /// Longer lines are left plain rather than diffed — the pathological cases here are
    /// minified bundles and embedded data, where every span would be noise anyway.
    private static let maximumLineLength = 2000

    /// The changed spans of a deletion/addition line pair, or `nil` when the two share so
    /// little that spans would be noise (a rewritten line reads better as a plain
    /// add/delete pair than as one line-long highlight).
    public static func spans(old oldText: String, new newText: String)
        -> (old: [Range<Int>], new: [Range<Int>])? {
        guard oldText != newText else { return nil }
        let oldCharacters = Array(oldText), newCharacters = Array(newText)
        guard oldCharacters.count <= maximumLineLength,
              newCharacters.count <= maximumLineLength else { return nil }

        let oldTokens = tokenize(oldCharacters)
        let newTokens = tokenize(newCharacters)

        var prefix = 0
        while prefix < oldTokens.count, prefix < newTokens.count,
              oldTokens[prefix].text == newTokens[prefix].text {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldTokens.count - prefix, suffix < newTokens.count - prefix,
              oldTokens[oldTokens.count - 1 - suffix].text
                == newTokens[newTokens.count - 1 - suffix].text {
            suffix += 1
        }

        let oldCore = Array(oldTokens[prefix..<(oldTokens.count - suffix)])
        let newCore = Array(newTokens[prefix..<(newTokens.count - suffix)])
        guard !oldCore.isEmpty || !newCore.isEmpty else { return nil }

        let changed = changedTokens(oldCore, newCore)
        let oldSpans = spans(of: oldCore, changed: changed.old)
        let newSpans = spans(of: newCore, changed: changed.new)

        // "Too different to be worth marking": at least a fifth of the shorter line must
        // survive unchanged. Survival is measured per side against that side's own length
        // — charging the longer side's inserted characters against the shorter line reads
        // a pure insertion (`call()` -> `call(aVeryLongName)`, where the old line survives
        // whole) as a rewrite and drops the highlight entirely.
        let shorter = min(oldCharacters.count, newCharacters.count)
        let oldSurvived = oldCharacters.count - oldSpans.reduce(0) { $0 + $1.count }
        let newSurvived = newCharacters.count - newSpans.reduce(0) { $0 + $1.count }
        guard shorter == 0 || min(oldSurvived, newSurvived) * 5 >= shorter else { return nil }

        return (oldSpans, newSpans)
    }

    private struct Token {
        let text: String
        let range: Range<Int>
        let isBlank: Bool
    }

    /// Splits a line into word runs, whitespace runs, and single characters. CJK scripts
    /// have no intra-word boundaries, so each ideograph or kana is its own token rather
    /// than being swallowed into a run that would span the whole line.
    private static func tokenize(_ characters: [Character]) -> [Token] {
        var tokens: [Token] = []
        var index = 0
        while index < characters.count {
            let start = index
            let character = characters[index]
            if isWord(character) {
                while index < characters.count, isWord(characters[index]) { index += 1 }
            } else if character == " " || character == "\t" {
                while index < characters.count,
                      characters[index] == " " || characters[index] == "\t" { index += 1 }
            } else {
                index += 1
            }
            tokens.append(Token(text: String(characters[start..<index]),
                                range: start..<index,
                                isBlank: character == " " || character == "\t"))
        }
        return tokens
    }

    private static func isWord(_ character: Character) -> Bool {
        guard character.isLetter || character.isNumber || character == "_" else { return false }
        guard let scalar = character.unicodeScalars.first else { return false }
        return scalar.value < 0x2E80
    }

    /// Which tokens on each side fall outside the longest common subsequence. The
    /// stdlib's Myers diff answers exactly this, and answers it in O(ND) — a hand-rolled
    /// LCS table needed a comparison cap to bound its memory, and that cap degraded long
    /// lines to a single span.
    private static func changedTokens(_ old: [Token], _ new: [Token]) -> (old: [Bool], new: [Bool]) {
        var oldChanged = Array(repeating: false, count: old.count)
        var newChanged = Array(repeating: false, count: new.count)
        for change in new.map(\.text).difference(from: old.map(\.text)) {
            switch change {
            case .remove(let offset, _, _): oldChanged[offset] = true
            case .insert(let offset, _, _): newChanged[offset] = true
            }
        }
        return (oldChanged, newChanged)
    }

    /// Contiguous runs of changed tokens, as character ranges. Runs separated only by
    /// unchanged whitespace are joined: `a = 1` → `b = 2` reads better as one span than
    /// as two boxes with a gap.
    private static func spans(of tokens: [Token], changed: [Bool]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var index = 0
        while index < tokens.count {
            guard changed[index] else { index += 1; continue }
            var end = index
            var probe = index
            while probe < tokens.count {
                if changed[probe] {
                    end = probe
                    probe += 1
                } else if tokens[probe].isBlank, probe + 1 < tokens.count, changed[probe + 1] {
                    probe += 1
                } else {
                    break
                }
            }
            // A span that opens or closes on whitespace would paint empty background at
            // its edge; trim it back to real content unless whitespace *is* the change
            // (an indent edit, where there is nothing else to mark).
            var first = index, last = end
            while first < last, tokens[first].isBlank { first += 1 }
            while last > first, tokens[last].isBlank { last -= 1 }
            result.append(tokens[first].range.lowerBound..<tokens[last].range.upperBound)
            index = end + 1
        }
        return result
    }
}
