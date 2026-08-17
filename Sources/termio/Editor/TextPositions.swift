import Foundation

/// The editor's one line/offset vocabulary. `NSString` offsets *are* UTF-16 code units — the
/// unit `NSTextView` selections use — so the conversion here is pure newline bookkeeping, no
/// transcoding. A linear scan is fine: the caller is user-initiated (a search-hit reveal) on an
/// editor-sized buffer, and the scan allocates nothing.
enum TextPositions {
    /// 1-based line number → the offset of that line's first character, clamped to the last
    /// line when the number runs past the end (the reveal-a-search-hit contract).
    static func offset(ofLine line: Int, in text: NSString) -> Int {
        var location = 0
        var current = 1
        while current < line, location < text.length {
            location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
            current += 1
        }
        return min(location, max(text.length - 1, 0))
    }
}
