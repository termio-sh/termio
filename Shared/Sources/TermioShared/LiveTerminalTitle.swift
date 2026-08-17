import Foundation

/// The running program's live terminal title (`OSC 0/2`), as both platforms show it.
public enum LiveTerminalTitle {
    /// Drops the leading run of non-alphanumerics (a status star, bullets, emoji)
    /// and the whitespace after it. Agents animate a mark in that prefix and
    /// republish the title several times a second, so stripping it collapses every
    /// frame onto one string — a view that deduplicates on the result redraws only
    /// when the words change — and the row's own agent icon stops being doubled.
    public static func sanitized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.drop { !$0.isLetter && !$0.isNumber }
        return String(stripped).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
