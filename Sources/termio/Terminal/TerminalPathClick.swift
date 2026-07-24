import AppKit
import Foundation
import GhosttyTerminal

// Bare file paths that agent CLIs print — `BranchModel.swift`, `src/foo.ts:42`,
// `Sources/App/App.swift:88:15` — are plain text, not OSC 8 hyperlinks and not a
// URL scheme, so libghostty's link detector never lights them up (its regex only
// matches real schemes, and the maintainers have declined to add row/column
// parsing — see the design notes on this feature). VS Code makes the same paths
// clickable with its own `terminalLinkParsing` layer, and the reason that layer is
// *stable* rather than a false-positive machine is not its regex: it is that every
// candidate is validated against the filesystem before it becomes a link. termio
// mirrors that shape here — reconstruct the token under a cmd-click from the grid
// text, peel a trailing `:line[:col]`, resolve it against the surface's working
// directory, and open it **only if it resolves to a real file on disk**. Anything
// that doesn't validate is silently dropped, so an imprecise click column or a
// stray word never opens the wrong thing.
enum TerminalPathScanner {
    /// A file path successfully reconstructed from a grid row and confirmed to exist.
    struct Match: Equatable {
        let url: URL
        /// 1-based line to jump to, from a `:line` / `:line:col` suffix, else `nil`.
        let line: Int?
    }

    /// Finds the file path a user cmd-clicked in `row`. Every whitespace token is a
    /// candidate; they are tried nearest-to-the-click first and the first one that
    /// resolves to an existing regular file wins. Returns `nil` when nothing on the
    /// row resolves — the caller then lets the click fall through to the terminal.
    ///
    /// `nearColumn` is the clicked cell column; it only orders candidates, so a
    /// column that is off by a cell (grid padding, a wide glyph) still resolves the
    /// right path as long as the row holds a single real file — the common case.
    ///
    /// `baseDirectories` are the roots a relative path is tried against, in order —
    /// the terminal's own cwd, then the session's worktree / project root. Trusting
    /// only the terminal-reported cwd is fragile (a shell that doesn't emit OSC 7, or
    /// `ls` run in a subdir leaves the cwd stale); resolving against the project root
    /// too is what lets `package.json` open even when the cwd read is `~`.
    static func resolve(in row: String, nearColumn: Int, baseDirectories: [String]) -> Match? {
        let bases = orderedUnique(baseDirectories)
        let ordered = tokens(in: row).sorted {
            $0.distance(to: nearColumn) < $1.distance(to: nearColumn)
        }
        for token in ordered {
            if let match = validate(token, baseDirectories: bases) {
                return match
            }
        }
        return nil
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: - Tokenising

    /// A whitespace-delimited run of the row, with the character range it occupies so
    /// candidates can be ranked by how close they are to the click column.
    private struct Token {
        let text: String
        let start: Int
        let end: Int

        func distance(to column: Int) -> Int {
            if column >= start, column < end { return 0 }
            return min(abs(column - start), abs(column - end))
        }
    }

    private static func tokens(in row: String) -> [Token] {
        var result: [Token] = []
        var current = ""
        var startIndex = 0
        for (index, character) in row.enumerated() {
            if character == " " || character == "\t" {
                if !current.isEmpty {
                    result.append(Token(text: current, start: startIndex, end: index))
                    current = ""
                }
            } else {
                if current.isEmpty { startIndex = index }
                current.append(character)
            }
        }
        if !current.isEmpty {
            result.append(Token(text: current, start: startIndex, end: row.count))
        }
        return result
    }

    // MARK: - Path + line/column parsing

    /// Wrapping punctuation an agent or shell tends to put around a path — matched
    /// brackets/quotes and trailing sentence punctuation — stripped before resolving.
    private static let leadingTrim = CharacterSet(charactersIn: "([{<'\"`")
    private static let trailingTrim = CharacterSet(charactersIn: ")]}>'\"`,;.")

    /// Git-diff path prefixes (`a/foo`, `b/foo`, …). If the raw token misses on disk
    /// but the de-prefixed form hits, that's the file the tool meant.
    private static let diffPrefixes = ["a/", "b/", "c/", "i/", "o/", "w/"]

    private static func validate(_ token: Token, baseDirectories: [String]) -> Match? {
        // Strip wrapping punctuation first — a closing `).` sits *after* the `:line`
        // suffix (`(file.swift:10).`), so peeling the line has to see a clean tail.
        let (rawPath, line) = peelLineColumn(strip(token.text))
        let stripped = strip(rawPath)
        guard !stripped.isEmpty else { return nil }

        for candidate in pathVariants(stripped) {
            for url in urls(for: candidate, baseDirectories: baseDirectories) {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                   !isDirectory.boolValue {
                    return Match(url: url, line: line)
                }
            }
        }
        return nil
    }

    /// Peels a trailing `:line` or `:line:col` off a token, returning the bare path
    /// and the 1-based line (the column is parsed to keep it off the path but isn't
    /// used yet — the preview jumps by line). Only trailing all-digit segments are
    /// taken, so a path that genuinely contains a colon is left intact.
    private static func peelLineColumn(_ token: String) -> (path: String, line: Int?) {
        let parts = token.components(separatedBy: ":")
        guard parts.count >= 2 else { return (token, nil) }

        var trailingNumbers: [Int] = []
        var lastPathIndex = parts.count - 1
        while lastPathIndex >= 1, trailingNumbers.count < 2, let value = Int(parts[lastPathIndex]) {
            trailingNumbers.append(value)
            lastPathIndex -= 1
        }
        guard !trailingNumbers.isEmpty else { return (token, nil) }

        let path = parts[0...lastPathIndex].joined(separator: ":")
        // Reversed: for `file:line:col` we collected [col, line]; for `file:line`, [line].
        let line = trailingNumbers.last
        return (path, line)
    }

    private static func strip(_ path: String) -> String {
        var result = Substring(path)
        while let first = result.unicodeScalars.first, leadingTrim.contains(first) {
            result = result.dropFirst()
        }
        while let last = result.unicodeScalars.last, trailingTrim.contains(last) {
            result = result.dropLast()
        }
        return String(result)
    }

    private static func pathVariants(_ path: String) -> [String] {
        var variants = [path]
        for prefix in diffPrefixes where path.hasPrefix(prefix) {
            variants.append(String(path.dropFirst(prefix.count)))
        }
        return variants
    }

    private static func urls(for path: String, baseDirectories: [String]) -> [URL] {
        let expanded = (path as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return [URL(fileURLWithPath: expanded).standardizedFileURL]
        }
        return baseDirectories.map { base in
            URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: base, isDirectory: true))
                .standardizedFileURL
        }
    }
}

extension TermioStore {
    /// Cmd-click fallback for a bare file path that libghostty didn't detect as a link.
    /// Maps the click to the grid cell under it (reusing the wrapper's own point→cell
    /// convention), reads the row's text, and — if a token on that row resolves to a
    /// real file — opens it in the read-only preview at the referenced line. Returns
    /// `true` when it opened something, so the caller can consume the click; `false`
    /// lets the click fall through to the terminal untouched.
    @MainActor
    func openBarePathUnderCommandClick(_ event: NSEvent) -> Bool {
        guard let window = event.window else { pathClickLog("no window"); return false }
        let windowPoint = event.locationInWindow

        // Find the surface by enumerating terminal views and testing which one's frame
        // contains the click — robust to overlays/hosting layers that a plain `hitTest`
        // would return instead (ghostty disables link detection under mouse reporting,
        // so this fallback must not depend on the same z-order hitTest gives).
        guard let (terminal, state) = terminalSurface(at: windowPoint, in: window) else {
            pathClickLog("no terminal surface under click")
            return false
        }
        guard let metrics = state.surfaceSize,
              metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0 else {
            pathClickLog("no surfaceSize")
            return false
        }
        guard case .inMemory(let session) = state.configuration.backend else {
            pathClickLog("backend not inMemory")
            return false
        }
        guard let viewport = session.readViewportText() else {
            pathClickLog("nil viewport text")
            return false
        }

        // Same mapping the surface view uses internally: view-local points, y flipped
        // to a top-left origin. Cell size is the surface's cell metric (backing
        // pixels) brought back to points by the window's scale factor.
        let local = terminal.convert(windowPoint, from: nil)
        let scale = terminal.window?.backingScaleFactor ?? 2
        let cellWidth = CGFloat(metrics.cellWidthPixels) / scale
        let cellHeight = CGFloat(metrics.cellHeightPixels) / scale
        guard cellWidth > 0, cellHeight > 0 else { pathClickLog("zero cell size"); return false }

        let column = Int(local.x / cellWidth)
        let rowIndex = Int((terminal.bounds.height - local.y) / cellHeight)
        let rows = viewport.components(separatedBy: "\n")
        let bases = pathBaseDirectories(for: state)
        pathClickLog("local=\(local) bounds=\(terminal.bounds.size) cell=\(cellWidth)x\(cellHeight) "
            + "col=\(column) row=\(rowIndex) rows=\(rows.count) bases=\(bases)")
        guard rowIndex >= 0, rowIndex < rows.count else { pathClickLog("row out of range"); return false }
        pathClickLog("rowText=<\(rows[rowIndex])>")

        guard let match = TerminalPathScanner.resolve(
            in: rows[rowIndex], nearColumn: column, baseDirectories: bases
        ) else {
            pathClickLog("no path resolved on row")
            return false
        }

        pathClickLog("OPEN \(match.url.path) line=\(match.line.map(String.init) ?? "nil")")
        openFileReadOnly = true
        openFileLine = match.line
        openFileURL = match.url
        return true
    }

    /// The terminal surface (and its state) whose frame contains `windowPoint`. Walks
    /// the whole view tree and geometry-tests each `TerminalView` rather than trusting
    /// `hitTest`, so a transparent overlay above the grid can't hide the surface.
    private func terminalSurface(
        at windowPoint: CGPoint, in window: NSWindow
    ) -> (TerminalView, TerminalViewState)? {
        guard let root = window.contentView else { return nil }
        var terminals: [TerminalView] = []
        collectTerminalViews(under: root, into: &terminals)
        pathClickLog("terminalViews=\(terminals.count)")
        for terminal in terminals {
            let local = terminal.convert(windowPoint, from: nil)
            guard terminal.bounds.contains(local),
                  let state = terminal.delegate as? TerminalViewState else { continue }
            return (terminal, state)
        }
        return nil
    }

    private func collectTerminalViews(under view: NSView, into out: inout [TerminalView]) {
        if let terminal = view as? TerminalView { out.append(terminal) }
        for subview in view.subviews { collectTerminalViews(under: subview, into: &out) }
    }

    /// Roots a relative path from the clicked surface is resolved against, most-specific
    /// first: the terminal's own reported cwd, then the owning session's worktree and
    /// project root. The project root is the reliable anchor — the terminal cwd can be
    /// stale or unreported (no OSC 7), which is why a bare `package.json` must still
    /// resolve against the project the surface belongs to.
    private func pathBaseDirectories(for state: TerminalViewState) -> [String] {
        var bases: [String] = []
        if let id = surfaces.first(where: { $0.value === state })?.key {
            // Live cwd straight from the kernel (`PROC_PIDVNODEPATHINFO`), the reliable
            // anchor: it tracks a plain `cd` even when the shell never emits OSC 7 — the
            // exact case where the OSC 7 `workingDirectory` read is stale (still `~`).
            if let liveCwd = ptyProcesses[id]?.currentWorkingDirectory() { bases.append(liveCwd) }
            if let worktree = session(id)?.worktreePath { bases.append(worktree) }
            if let project = project(for: id) { bases.append(project.path) }
        }
        if let cwd = state.workingDirectory { bases.append(cwd) }
        if let workspace = selectedSessionWorkspace { bases.append(workspace) }
        return bases
    }
}

/// Temporary trace for the cmd-click path fallback while it's being brought up. Only
/// fires on a cmd-left-click with no libghostty-detected link, so it is not chatty.
@MainActor
private func pathClickLog(_ message: @autoclosure () -> String) {
    NSLog("[PATHCLICK] %@", message())
}
