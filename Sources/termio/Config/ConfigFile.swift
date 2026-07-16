import Foundation

/// The user's editable configuration file: `~/.config/termio[-dev]/config`, in the
/// same `key = value` text shape Ghostty uses. This is termio's canonical config
/// store — the Settings window edits a curated subset and writes back here, the file
/// exposes the full set for hand-editing, and `AppSettings` watches it so an external
/// edit live-applies. The mapping between keys and settings, plus the load/seed/
/// write-back wiring, lives in `AppSettings` (see `Settings.swift`); this type is just
/// the path, the text parse, and the surgical rewrite.
enum ConfigFile {
    /// `~/.config/termio[-dev]/`. Deliberately the XDG location CLI users (and
    /// Ghostty) expect — not termio's Application Support dir, which holds internal
    /// state, nor `~/.termio`, which is where dropped agent/worktree files go.
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("termio" + AppChannel.suffix, isDirectory: true)
    }

    /// `~/.config/termio[-dev]/config`.
    static var url: URL {
        directory.appendingPathComponent("config", isDirectory: false)
    }

    /// Parses `key = value` lines into a dictionary (last value wins). Blank lines and
    /// lines whose first non-space character is `#` are ignored. The split is on the
    /// first `=` only and both sides are trimmed, so a value may itself contain `=`.
    static func parse(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }

    /// Rewrites `contents` so every managed key in `values` reflects the given value,
    /// updating the first line for each key in place (keeping its position) and
    /// appending — in `order` — any managed key that wasn't already present. Comments,
    /// blank lines, and unknown keys pass through untouched, so a hand-edited file
    /// keeps its structure and any keys termio doesn't manage.
    static func rewrite(_ contents: String, values: [String: String], order: [String]) -> String {
        var seen: Set<String> = []
        var lines = contents.components(separatedBy: "\n")
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
            guard let value = values[key], !seen.contains(key) else { continue }
            lines[index] = "\(key) = \(value)"
            seen.insert(key)
        }
        let missing = order.filter { values[$0] != nil && !seen.contains($0) }
        if !missing.isEmpty {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("")
            }
            for key in missing { lines.append("\(key) = \(values[key]!)") }
        }
        return lines.joined(separator: "\n")
    }
}

/// Watches the config file's *directory* and fires `onChange` on the main queue after
/// a short debounce. Watching the directory (not the file) is deliberate: editors save
/// atomically by swapping the file inode, which a file-level watch would lose — the
/// same reason `BranchModel` watches a folder's `HEAD` container rather than `HEAD`.
///
/// Standalone and non-actor-isolated so its dispatch source can live on a utility
/// queue; the single `onChange` hop back to main is where it re-enters `AppSettings`.
final class ConfigFileWatcher {
    private let queue = DispatchQueue(label: "sh.termio.config.watch", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private let onChange: () -> Void

    /// `onChange` is invoked on the main queue.
    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    func start(directory: URL) {
        stop()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .link, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    /// Coalesces a burst of events (an atomic save is several) into one reload.
    private func schedule() {
        pending?.cancel()
        let onChange = self.onChange
        let item = DispatchWorkItem { DispatchQueue.main.async(execute: onChange) }
        pending = item
        queue.asyncAfter(deadline: .now() + 0.12, execute: item)
    }
}
