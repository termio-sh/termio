import Foundation
import GhosttyTheme
import TermioShared

/// termio's terminal-theme library: the files in termio's `Themes` folder, and
/// nothing else.
///
/// A theme is a Ghostty-format file — the same `key = value` text Ghostty itself
/// reads from `~/.config/ghostty/themes` (`background = #hex`, `palette = 0=#hex`,
/// …) — so the thousands of community color schemes work unchanged. This is the
/// VSCode/Zed model: a theme the user has is a file on their computer.
///
/// `GhosttyThemeCatalog` (the ~485 schemes compiled into the `GhosttyTheme`
/// product) is a warehouse, not a library. It is read only to install a store
/// theme and to materialize a name that was selected before the library existed;
/// `theme(named:)` never falls back to it. A selected name that resolves to no
/// file would otherwise be a ghost: listed nowhere, yet painting the chrome.
///
/// Loading is lenient: a malformed file is skipped rather than failing the whole
/// load.
@MainActor
enum ThemeLibrary {
    /// Where theme files live, alongside termio's other support data
    /// (`~/Library/Application Support/termio/Themes`).
    static var directory: URL {
        AppChannel.supportDirectory.appendingPathComponent("Themes", isDirectory: true)
    }

    /// Themes parsed from `directory`, cached after the first load. Call `reload()`
    /// to pick up files added or edited while the app is running.
    private static var cachedUserThemes: [GhosttyThemeDefinition]?

    static var userThemes: [GhosttyThemeDefinition] {
        if let cachedUserThemes { return cachedUserThemes }
        let loaded = loadUserThemes()
        cachedUserThemes = loaded
        return loaded
    }

    /// Re-reads the `Themes` folder and refreshes the cache, returning the fresh
    /// list. The pickers call this on appear (so newly dropped files show up) and
    /// from a "Reload" button (so an edit to an open theme takes effect live).
    @discardableResult
    static func reload() -> [GhosttyThemeDefinition] {
        let loaded = loadUserThemes()
        cachedUserThemes = loaded
        return loaded
    }

    /// Resolves a theme by name — from a file in the `Themes` folder, and only
    /// from there. See the type comment for why the catalog is not a fallback.
    static func theme(named name: String) -> GhosttyThemeDefinition? {
        userThemes.first { $0.name == name }
    }

    /// Installed theme names for one slot, filtered by each theme's own `isDark`
    /// (background luminance) so the Dark slot can never offer a theme that would
    /// render the wrong way.
    static func installedThemeNames(dark: Bool) -> [String] {
        userThemes.filter { $0.isDark == dark }
            .map(\.name)
            .sorted { $0.lowercased() < $1.lowercased() }
    }

    /// Every installed theme name, sorted — the Appearance tab's "N installed".
    static var userThemeNames: [String] {
        userThemes.map(\.name).sorted { $0.lowercased() < $1.lowercased() }
    }

    // MARK: - Store

    /// The store's index in display order, filtered to the names the pinned
    /// catalog resolves so a package rename drops a stale row instead of showing a
    /// dead one. The names themselves are shared with the iPhone's picker (see
    /// `ThemeStoreCatalog`), which offers the same set.
    static let storeCatalog: [String] = ThemeStoreCatalog.names
        .filter { GhosttyThemeCatalog.theme(named: $0) != nil }

    /// A store row's definition, read from the catalog so an uninstalled row can
    /// still draw its swatch. The only other catalog readers are `install` and
    /// `materializeFromCatalog`; nothing on the resolve path calls this.
    static func storeTheme(named name: String) -> GhosttyThemeDefinition? {
        GhosttyThemeCatalog.theme(named: name)
    }

    /// Why an Install did not happen.
    enum InstallRefusal: Error {
        /// The store name is not in the pinned catalog — only reachable if the
        /// package renamed a theme between the filter above and the call.
        case unknownTheme(String)
        /// A file in the `Themes` folder already answers to that name. It may be
        /// the user's own hand-dropped theme, so Install refuses and the caller
        /// offers an explicit Replace naming this path.
        case alreadyInstalled(URL)
    }

    /// Writes one store theme into the `Themes` folder. Refuses when a file
    /// already parses to that name unless `replacingExisting` is set, so a
    /// hand-dropped `Dracula` is never silently overwritten.
    static func install(named name: String, replacingExisting: Bool = false) throws {
        guard let definition = GhosttyThemeCatalog.theme(named: name) else {
            throw InstallRefusal.unknownTheme(name)
        }
        if !replacingExisting, let existing = fileURL(forInstalledTheme: name) {
            throw InstallRefusal.alreadyInstalled(existing)
        }
        try write(definition)
        reload()
    }

    /// Deletes the file backing an installed theme.
    static func remove(named name: String) throws {
        guard let url = fileURL(forInstalledTheme: name) else { return }
        try FileManager.default.removeItem(at: url)
        reload()
    }

    /// The file an installed theme was parsed from, or `nil` when no file in the
    /// folder parses to that name. Resolved by re-parsing rather than by guessing
    /// the file name, because a theme's name comes from its file's stem and the
    /// user may have named the file anything.
    static func fileURL(forInstalledTheme name: String) -> URL? {
        sortedFiles().first { url in
            parse(name: url.deletingPathExtension().lastPathComponent,
                  contents: (try? String(contentsOf: url, encoding: .utf8)) ?? "")?.name == name
        }
    }

    /// Whether the installed file for `name` still holds exactly what `write`
    /// would emit. A file the user has edited is theirs: Remove confirms first,
    /// and the store never offers to reinstall over it.
    static func isPristine(installedTheme name: String) -> Bool {
        guard let url = fileURL(forInstalledTheme: name),
              let contents = try? String(contentsOf: url, encoding: .utf8),
              let catalogDefinition = GhosttyThemeCatalog.theme(named: name)
        else { return false }
        return contents == serialize(catalogDefinition)
    }

    // MARK: - Materialization

    /// Writes `name`'s catalog definition into the `Themes` folder when the
    /// library has no file for it yet, so a name selected before the library
    /// existed becomes a library entry instead of a ghost selection. Returns
    /// whether a file was written.
    ///
    /// Bounded by design: the caller passes only names that are already selected
    /// (the two slots, and a Ghostty-inherited `theme = X`), never the catalog.
    @discardableResult
    static func materializeFromCatalog(named name: String) throws -> Bool {
        guard !name.isEmpty, theme(named: name) == nil,
              fileURL(forInstalledTheme: name) == nil,
              let definition = GhosttyThemeCatalog.theme(named: name)
        else { return false }
        try write(definition)
        reload()
        return true
    }

    // MARK: - Files

    /// Creates the `Themes` folder if it does not exist yet and returns it, so
    /// "Open Themes Folder" always lands somewhere real even on a fresh install.
    /// Throws so a write can report why it could not happen.
    @discardableResult
    static func ensureDirectoryExists() throws -> URL {
        let url = directory
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Serializes a definition back to Ghostty `key = value` text and writes it to
    /// `directory` under the theme's name, with no file extension — the folder
    /// already names a theme after its file's stem, so an extension would only be
    /// stripped back off on the next load. `parse` reads back an equal definition.
    static func write(_ definition: GhosttyThemeDefinition) throws {
        try write(definition, into: ensureDirectoryExists())
    }

    /// Writes into an explicit folder. `write(_:)` is this against the library's
    /// own folder; the parameter exists so the round-trip test can prove the file
    /// reads back equal without writing into the user's Themes folder.
    static func write(_ definition: GhosttyThemeDefinition, into folder: URL) throws {
        let url = folder.appendingPathComponent(definition.name, isDirectory: false)
        try serialize(definition).write(to: url, atomically: true, encoding: .utf8)
    }

    /// The Ghostty-format text for a definition. Palette entries are emitted in
    /// index order so the file is stable across writes and comparable byte for
    /// byte (see `isPristine(installedTheme:)`).
    static func serialize(_ definition: GhosttyThemeDefinition) -> String {
        var lines: [String] = [
            "background = #\(definition.background)",
            "foreground = #\(definition.foreground)",
        ]
        if let cursorColor = definition.cursorColor { lines.append("cursor-color = #\(cursorColor)") }
        if let cursorText = definition.cursorText { lines.append("cursor-text = #\(cursorText)") }
        if let selectionBackground = definition.selectionBackground {
            lines.append("selection-background = #\(selectionBackground)")
        }
        if let selectionForeground = definition.selectionForeground {
            lines.append("selection-foreground = #\(selectionForeground)")
        }
        for index in definition.palette.keys.sorted() {
            guard let color = definition.palette[index] else { continue }
            lines.append("palette = \(index)=#\(color)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The folder's files in a stable order. Directory enumeration order is
    /// filesystem-dependent, so sorting by path is what makes the dedupe below
    /// deterministic rather than "whichever inode came back first".
    private static func sortedFiles() -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { !$0.hasDirectoryPath }
            .sorted { $0.path < $1.path }
    }

    private static func loadUserThemes() -> [GhosttyThemeDefinition] {
        var seen: Set<String> = []
        var result: [GhosttyThemeDefinition] = []
        for url in sortedFiles() {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // A theme's name is its file name (sans extension), matching how Ghostty
            // names themes after their file. Files may have no extension at all.
            guard let definition = parse(
                name: url.deletingPathExtension().lastPathComponent,
                contents: contents
            ) else { continue }
            // Two files can claim one name ("Dracula" and "Dracula.conf"). The
            // first in path order wins, and the rest are ignored rather than
            // shadowing each other differently on every launch.
            guard seen.insert(definition.name).inserted else { continue }
            result.append(definition)
        }
        return result
    }

    /// Parses one Ghostty-format theme file into a definition. Returns `nil` when
    /// the file lacks the background/foreground a usable theme needs. Hex values
    /// keep the catalog's bare (no leading `#`) convention so they flow through the
    /// existing `toTerminalConfiguration` and chrome-color paths unchanged.
    static func parse(name: String, contents: String) -> GhosttyThemeDefinition? {
        var background: String?
        var foreground: String?
        var cursorColor: String?
        var cursorText: String?
        var selectionBackground: String?
        var selectionForeground: String?
        var palette: [Int: String] = [:]

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Ghostty config comments begin a line with `#`; a `#` mid-line is the
            // start of a hex value, not a comment.
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "background": background = strippedHex(value)
            case "foreground": foreground = strippedHex(value)
            case "cursor-color": cursorColor = strippedHex(value)
            case "cursor-text": cursorText = strippedHex(value)
            case "selection-background": selectionBackground = strippedHex(value)
            case "selection-foreground": selectionForeground = strippedHex(value)
            case "palette":
                // The value is itself `index=#hex`.
                guard let equals = value.firstIndex(of: "=") else { continue }
                let indexText = value[..<equals].trimmingCharacters(in: .whitespaces)
                let colorText = value[value.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if let index = Int(indexText) {
                    palette[index] = strippedHex(colorText)
                }
            default:
                continue
            }
        }

        guard let background, let foreground else { return nil }
        return GhosttyThemeDefinition(
            name: name,
            background: background,
            foreground: foreground,
            cursorColor: cursorColor,
            cursorText: cursorText,
            selectionBackground: selectionBackground,
            selectionForeground: selectionForeground,
            palette: palette
        )
    }

    /// Drops a leading `#` so parsed hex matches the bundled catalog's bare form.
    private static func strippedHex(_ value: String) -> String {
        value.hasPrefix("#") ? String(value.dropFirst()) : value
    }
}
