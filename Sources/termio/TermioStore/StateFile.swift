import Foundation

/// The session tree's on-disk home: it owns the file location and the JSON
/// (de)serialization, so `TermioStore` only ever hands it values. Live state
/// (terminal surfaces, per-session activity) is intentionally never written —
/// shells restart fresh, so only the tree and the current selection persist.
struct StateFile {
    struct Snapshot: Codable {
        var projects: [Project]
        var selectedSessionID: Session.ID?
        /// The single split layout builds before split *groups* used to write.
        /// Never written anymore, only decoded — `TermioStore.restored` migrates
        /// it into `splitGroups` as one group.
        var splitRoot: SplitNode?
        /// The split groups (see `TermioStore.splitGroups`). Optional so state
        /// files written before groups existed still decode.
        var splitGroups: [SplitNode]?
        /// Each session's inspector layout, keyed by session `id.uuidString`. Only the
        /// durable subset is written — the tab and the open *file* — since a diff / PR /
        /// trace is a snapshot of data that gets re-fetched (see `TermioStore.InspectorState`).
        /// Optional so older state files still decode.
        var inspectorLayouts: [String: InspectorLayout]?
    }

    /// The persisted slice of a session's inspector layout: which tab, and the file it
    /// had open (validated for existence on restore, since the file may have been deleted
    /// or its worktree removed while the app was closed).
    struct InspectorLayout: Codable {
        var tab: InspectorTab
        var filePath: String?
        var fileLine: Int?
        var fileReadOnly: Bool?
    }

    let url = AppChannel.supportDirectory

    private var stateURL: URL { url.appendingPathComponent("state.json") }

    /// The saved snapshot, or `nil` on first launch or an unreadable/corrupt file
    /// (in which case the caller seeds fresh state rather than failing).
    func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Best-effort, atomic write. Failures are logged rather than crashing —
    /// losing a save is recoverable, trapping is not. Indented and key-sorted so
    /// the file reads like a config and diffs cleanly, not a one-line blob.
    func save(_ snapshot: Snapshot) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: stateURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("termio: failed to persist state: \(error)\n".utf8))
        }
    }
}
