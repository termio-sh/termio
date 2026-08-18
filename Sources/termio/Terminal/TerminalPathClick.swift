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
        for candidate in candidates(in: row, nearColumn: nearColumn) {
            if let match = validate(candidate, baseDirectories: bases) {
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

    /// How many adjacent whitespace tokens may be rejoined into one candidate. Four
    /// covers the shapes that occur in practice (`Application Support/…`, `My Project
    /// Notes.md`) while keeping the widening from wandering across a whole row.
    private static let maximumJoinedTokens = 4

    /// A whitespace-delimited run of the row, with the character range it occupies so
    /// candidates can be ranked by how close they are to the click column.
    private struct Token {
        let text: String
        let start: Int
        let end: Int
    }

    /// Every spelling on the row worth checking, precise-first: each whitespace token,
    /// plus the runs of adjacent tokens that a path containing a space would have been
    /// torn into. Ordered by distance to the click and then by width, so the token the
    /// user actually pointed at is checked before any widened span — the filesystem
    /// gate then decides, and the widening only ever costs extra misses.
    private static func candidates(in row: String, nearColumn column: Int) -> [String] {
        let tokens = tokens(in: row)
        guard !tokens.isEmpty else { return [] }
        let characters = Array(row)

        var ranked: [(text: String, distance: Int, width: Int)] = []
        for start in tokens.indices {
            for end in start..<min(start + maximumJoinedTokens, tokens.count) {
                let span = (lower: tokens[start].start, upper: tokens[end].end)
                // A widened span exists only to repair a path the whitespace split tore
                // in half, so it has to cover the click. Widening away from the pointer
                // would let a row of prose join into something that happens to exist.
                if end > start, !(span.lower <= column && column < span.upper) { continue }
                let text = end == start
                    ? tokens[start].text
                    : String(characters[span.lower..<span.upper])
                ranked.append((text, distance(from: span.lower, to: span.upper, column: column), end - start + 1))
            }
        }

        return ranked.enumerated().sorted {
            if $0.element.distance != $1.element.distance { return $0.element.distance < $1.element.distance }
            if $0.element.width != $1.element.width { return $0.element.width < $1.element.width }
            return $0.offset < $1.offset
        }.map(\.element.text)
    }

    private static func distance(from lower: Int, to upper: Int, column: Int) -> Int {
        if column >= lower, column < upper { return 0 }
        return min(abs(column - lower), abs(column - upper))
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

    private static func validate(_ token: String, baseDirectories: [String]) -> Match? {
        // Strip wrapping punctuation first — a closing `).` sits *after* the `:line`
        // suffix (`(file.swift:10).`), so peeling the line has to see a clean tail.
        let (rawPath, line) = peelLineColumn(strip(token))
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
        var variants: [String] = []
        func add(_ value: String) {
            guard !value.isEmpty, !variants.contains(value) else { return }
            variants.append(value)
            for prefix in diffPrefixes where value.hasPrefix(prefix) {
                let dePrefixed = String(value.dropFirst(prefix.count))
                guard !dePrefixed.isEmpty, !variants.contains(dePrefixed) else { continue }
                variants.append(dePrefixed)
            }
        }
        add(path)
        add(unescapingShellBackslashes(path))
        return variants
    }

    /// Folds shell backslash escapes into the character they escape: a shell echoes
    /// `src/my\ file.ts`, but the name on disk is `src/my file.ts`.
    private static func unescapingShellBackslashes(_ path: String) -> String {
        guard path.contains("\\") else { return path }
        var result = ""
        var escaping = false
        for character in path {
            if escaping {
                result.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        // A lone trailing backslash isn't an escape; keep it so the spelling stays honest.
        if escaping { result.append("\\") }
        return result
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
        guard let window = event.window else { return false }
        let windowPoint = event.locationInWindow

        // Find the surface by enumerating terminal views and testing which one's frame
        // contains the click — robust to overlays/hosting layers that a plain `hitTest`
        // would return instead (ghostty disables link detection under mouse reporting,
        // so this fallback must not depend on the same z-order hitTest gives).
        guard let (terminal, state) = terminalSurface(at: windowPoint, in: window) else {
            return false
        }
        // Only this Mac's own sessions may be resolved, and the surface has to be
        // identified before that can be asked — a surface we cannot name is a surface
        // whose device we do not know, so it is declined rather than assumed local.
        // Every surface is registered under its session id when it is built, so this
        // costs nothing in practice.
        guard let surfaceID = surfaces.first(where: { $0.value === state })?.key,
              let owner = session(surfaceID), isOnThisMac(owner) else { return false }
        guard let metrics = state.surfaceSize,
              metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0 else {
            return false
        }
        guard case .inMemory(let session) = state.configuration.backend else {
            return false
        }
        guard let viewport = session.readViewportText() else {
            return false
        }

        // Same mapping the surface view uses internally: view-local points, y flipped
        // to a top-left origin. Cell size is the surface's cell metric (backing
        // pixels) brought back to points by the window's scale factor.
        let local = terminal.convert(windowPoint, from: nil)
        let scale = terminal.window?.backingScaleFactor ?? 2
        let cellWidth = CGFloat(metrics.cellWidthPixels) / scale
        let cellHeight = CGFloat(metrics.cellHeightPixels) / scale
        guard cellWidth > 0, cellHeight > 0 else { return false }

        let column = Int(local.x / cellWidth)
        let rowIndex = Int((terminal.bounds.height - local.y) / cellHeight)
        let rows = viewport.components(separatedBy: "\n")
        guard rowIndex >= 0, rowIndex < rows.count else { return false }

        guard let match = TerminalPathScanner.resolve(
            in: rows[rowIndex],
            nearColumn: column,
            baseDirectories: pathBaseDirectories(surfaceID: surfaceID, state: state)
        ) else {
            return false
        }

        openFileReadOnly = true
        openFileLine = match.line
        openFileURL = match.url
        return true
    }

    /// The session whose surface a cmd-click landed in, for the hovered-link path — which gets a
    /// URL string from ghostty and no clue where it came from. `nil` when the click was not in a
    /// terminal, or in one no session claims; `openTerminalLink` treats that as "device unknown"
    /// and declines to touch local disk.
    @MainActor
    func sessionUnderCommandClick(_ event: NSEvent) -> Session.ID? {
        guard let window = event.window,
              let (_, state) = terminalSurface(at: event.locationInWindow, in: window)
        else { return nil }
        return sessionID(ofSurface: state)
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
    ///
    /// Every root here belongs to the *clicked* session. The selected session is
    /// deliberately not consulted as a last resort: on a multi-device window it can be
    /// a session on another machine, and its project root would resolve the path
    /// against a tree the clicked terminal has never been in.
    private func pathBaseDirectories(surfaceID: UUID, state: TerminalViewState) -> [String] {
        var bases: [String] = []
        // Live cwd straight from the kernel (`PROC_PIDVNODEPATHINFO`), the reliable
        // anchor: it tracks a plain `cd` even when the shell never emits OSC 7 — the
        // exact case where the OSC 7 `workingDirectory` read is stale (still `~`).
        if let liveCwd = ptyProcesses[surfaceID]?.currentWorkingDirectory() { bases.append(liveCwd) }
        if let worktree = session(surfaceID)?.worktreePath { bases.append(worktree) }
        if let project = project(for: surfaceID) { bases.append(project.path) }
        if let cwd = state.workingDirectory { bases.append(cwd) }
        return bases
    }
}
