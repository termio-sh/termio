import Foundation

/// What a settings-initiated (re)install actually did, per target.
///
/// The installers write *outside* the app — a PATH symlink, each agent's config
/// file, the user-level instruction files — and report problems only to stderr,
/// which nobody clicking a button in Settings ever sees. Returning the outcome
/// lets the row say what landed, and name what didn't, instead of leaving a click
/// that succeeded and a click that silently failed looking identical.
struct InstallOutcome {
    /// Names of the targets that now carry termio's wiring.
    private(set) var succeeded: [String] = []
    /// Names of the targets that refused it (unparseable config, failed write, or
    /// a file termio doesn't own sitting at its path).
    private(set) var failed: [String] = []

    var isEmpty: Bool { succeeded.isEmpty && failed.isEmpty }

    mutating func record(_ name: String, installed: Bool) {
        if installed { succeeded.append(name) } else { failed.append(name) }
    }

    /// A human list of target names: spelled out up to three ("Claude Code, Codex
    /// and Cursor"), counted beyond that ("6 agents") so a confirmation line stays
    /// one line no matter how many agents are in the catalog.
    static func list(_ names: [String], unit: String) -> String {
        switch names.count {
        case 0: return localized("nothing")
        case 1: return names[0]
        case 2: return localized("\(names[0]) and \(names[1])")
        case 3: return localized("\(names[0]), \(names[1]) and \(names[2])")
        default: return localized("\(names.count) \(unit)")
        }
    }
}
