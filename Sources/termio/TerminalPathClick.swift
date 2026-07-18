import AppKit
import GhosttyTerminal

// Makes a file path printed inside a mouse-capturing TUI (Claude Code) cmd-clickable.
//
// In a plain shell ghostty detects links itself and reports them via its hover-link action, so
// the existing `TerminalLinkState.hoveredURL` path in `linkClickMonitor` already opens them. But
// once a full-screen app turns on mouse reporting, ghostty stops running its hover-link detection
// (it forwards mouse motion to the app instead), so `hoveredURL` stays nil and nothing is
// clickable — even though the path is right there on screen. libghostty exposes no per-cell link
// query, so we reconstruct the path from the grid text ourselves: map the click pixel to a cell,
// read that row, pull out the token under the cursor, resolve it against the surface's working
// directory, and open it if it's a real file.
//
// This is deliberately click-only: no hover cursor or underline (ghostty won't render a decoration
// for a match it didn't make, and won't run hover detection under capture). The cmd-click event is
// intercepted at the AppKit layer *before* ghostty forwards it to the TUI, which is why this works
// at all while the app has grabbed the mouse.
extension TermioStore {
    /// Attempts to open the file path under a cmd+left-click. Returns `true` only when a real file
    /// was found and opened (so the caller consumes the event); `false` leaves the click alone.
    func openFilePathUnderTerminalClick(_ event: NSEvent) -> Bool {
        // Don't compete with an editor/diff/trace overlay covering the terminal (mirrors
        // `TerminalContextMenu.intercept`).
        guard openFileURL == nil, openDiff == nil, openTrace == nil,
              let window = event.window,
              window.frameAutosaveName == AppDelegate.mainWindowFrameAutosaveName,
              let contentView = window.contentView
        else { return false }

        // Resolve the clicked pane by geometry: every activated session stays mounted, so raw
        // hit-testing can land on a hidden sibling; visible panes tile without overlap, so
        // "contains the point and is visible" is unambiguous (same approach as the context menu).
        let point = event.locationInWindow
        let clicked = terminalSurfaceViews(in: contentView).first { view in
            guard view.window === window,
                  view.convert(view.bounds, to: nil).contains(point),
                  let id = sessionID(forSurfaceView: view) else { return false }
            return visiblePaneIDs.contains(id)
        }
        guard let view = clicked,
              let id = sessionID(forSurfaceView: view),
              let state = surfaces[id],
              let metrics = state.surfaceSize,
              metrics.columns > 0, metrics.rows > 0,
              let viewport = surfaceSessions[id]?.readViewportText()
        else { return false }

        guard let (row, column) = cell(at: point, in: view, metrics: metrics) else { return false }

        // `readViewportText` joins the viewport rows with "\n"; index the clicked row, then the
        // clicked column within it. Trailing cells are trimmed, so a click past end-of-text misses.
        let lines = viewport.components(separatedBy: "\n")
        guard row < lines.count else { return false }
        guard let token = pathToken(in: lines[row], atColumn: column) else { return false }

        guard let (url, line) = resolveFile(token, forSession: id) else { return false }
        openFileInEditor(url, at: line)
        return true
    }

    /// Grid (row, column) under a window-space point, or nil if the click lands outside the cells.
    private func cell(at windowPoint: NSPoint, in view: NSView, metrics: TerminalGridMetrics) -> (row: Int, column: Int)? {
        let local = view.convert(windowPoint, from: nil)
        let scale = view.window?.backingScaleFactor ?? 2
        let cellW = Double(metrics.cellWidthPixels) / scale
        let cellH = Double(metrics.cellHeightPixels) / scale
        guard cellW > 0, cellH > 0 else { return nil }

        // ghostty centers the grid inside the surface; account for the leftover padding.
        let padX = max(0, (view.bounds.width - Double(metrics.columns) * cellW) / 2)
        let padY = max(0, (view.bounds.height - Double(metrics.rows) * cellH) / 2)

        // Grid row 0 is at the top; AppKit's default view origin is bottom-left.
        let yTop = view.isFlipped ? local.y : (view.bounds.height - local.y)
        let column = Int((local.x - padX) / cellW)
        let row = Int((yTop - padY) / cellH)
        guard column >= 0, column < Int(metrics.columns), row >= 0, row < Int(metrics.rows) else { return nil }
        return (row, column)
    }

    /// The path-like token containing `column` in `line`, with a git-diff prefix and trailing
    /// `:line[:col]` / sentence punctuation stripped. Returns nil if the click isn't on a token.
    private func pathToken(in line: String, atColumn column: Int) -> String? {
        let chars = Array(line)
        guard column < chars.count, !isTokenSeparator(chars[column]) else { return nil }

        var start = column
        while start > 0, !isTokenSeparator(chars[start - 1]) { start -= 1 }
        var end = column
        while end + 1 < chars.count, !isTokenSeparator(chars[end + 1]) { end += 1 }
        var token = String(chars[start ... end])

        // git diff paths print as `a/path` / `b/path`.
        if token.hasPrefix("a/") || token.hasPrefix("b/") { token.removeFirst(2) }
        // Trailing sentence punctuation that isn't part of a filename.
        while let last = token.last, ".,;:)".contains(last) { token.removeLast() }
        guard !token.isEmpty else { return nil }
        return token
    }

    /// Splits the trailing `:line[:col]` suffix (e.g. `src/main.swift:42:10`) off a token, then
    /// resolves it against the session's working directory. Returns the file URL and 1-based line
    /// only if it points at an existing regular file.
    private func resolveFile(_ token: String, forSession id: Session.ID) -> (url: URL, line: Int?)? {
        let (path, line) = splitLineSuffix(token)
        let expanded = (path as NSString).expandingTildeInPath
        let base = surfaces[id]?.workingDirectory ?? sessionWorkspace(id)
        let url: URL = (expanded as NSString).isAbsolutePath || base == nil
            ? URL(fileURLWithPath: expanded)
            : URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: base!, isDirectory: true))
        let resolved = url.standardizedFileURL

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return (resolved, line)
    }

    /// Strips a trailing `:line` or `:line:col` from a path, returning the bare path and the line.
    private func splitLineSuffix(_ token: String) -> (path: String, line: Int?) {
        // Match `path:line` or `path:line:col`.
        let parts = token.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return (token, nil) }
        if parts.count >= 3, parts[parts.count - 1].allSatisfy(\.isNumber),
           parts[parts.count - 2].allSatisfy(\.isNumber), !parts[parts.count - 2].isEmpty {
            return (parts[0 ..< (parts.count - 2)].joined(separator: ":"), Int(parts[parts.count - 2]))
        }
        if parts[parts.count - 1].allSatisfy(\.isNumber), !parts[parts.count - 1].isEmpty {
            return (parts[0 ..< (parts.count - 1)].joined(separator: ":"), Int(parts[parts.count - 1]))
        }
        return (token, nil)
    }

    private func isTokenSeparator(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\"" || c == "'" || c == "`"
            || c == "(" || c == ")" || c == "[" || c == "]"
            || c == "{" || c == "}" || c == "<" || c == ">" || c == "|"
    }

    /// The working directory to resolve a relative path against when the surface hasn't reported an
    /// OSC 7 cwd: the session's worktree, else its project root.
    private func sessionWorkspace(_ id: Session.ID) -> String? {
        session(id)?.worktreePath ?? project(for: id)?.path
    }

    /// All terminal surface views under `root`, in tree order (mirrors `TerminalContextMenu`).
    private func terminalSurfaceViews(in root: NSView) -> [TerminalView] {
        var found: [TerminalView] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let terminal = view as? TerminalView { found.append(terminal) }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    private func sessionID(forSurfaceView view: TerminalView) -> Session.ID? {
        surfaces.first { $0.value.controller === view.controller }?.key
    }
}
