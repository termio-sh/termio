import OSLog

/// Unified-logging categories for the Mac app. One `Logger` per subsystem area,
/// so Console.app and the `log` CLI can filter first-class:
///
///     log stream --predicate 'subsystem == "sh.termio.app" && category == "companion"'
///
/// The subsystem is taken from the bundle id at runtime rather than hardcoded, so
/// it always matches the app's real identity — release (`sh.termio.app`) or the
/// side-by-side dev build (`sh.termio.app.dev`), which lets `log stream` filter to
/// one channel.
///
/// Levels carry persistence semantics: `.debug` is memory-only (free in
/// release), `.info`/`.notice` are the default operational trail, and
/// `.error`/`.fault` are always persisted to disk. Interpolated values are
/// redacted by default — tag operational (non-sensitive) values `.public`;
/// never log the pairing token or anything that would grant access.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "sh.termio.app"
    static let tunnel = Logger(subsystem: subsystem, category: "tunnel")
    static let pty = Logger(subsystem: subsystem, category: "pty")
    static let termiod = Logger(subsystem: subsystem, category: "termiod")
    static let companion = Logger(subsystem: subsystem, category: "companion")
    static let files = Logger(subsystem: subsystem, category: "files")
    static let issues = Logger(subsystem: subsystem, category: "issues")
    static let focus = Logger(subsystem: subsystem, category: "focus")
    static let app = Logger(subsystem: subsystem, category: "app")
    static let markdown = Logger(subsystem: subsystem, category: "markdown")
}
