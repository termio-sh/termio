import Foundation

/// One directory entry, however it was read. `FileNode` (local disk) and
/// `RemoteFileNode` (an SSH host over SFTP) are both built from these, so the
/// tree's ordering, icons, and selection logic stay the same on either side.
struct FileEntry: Sendable {
    enum Kind: Sendable, Equatable {
        case file
        case directory
        /// A symlink. Remote previews never chase it, even when its target is a
        /// regular file or directory.
        case symlink
        /// FIFOs, sockets, devices, and any other non-previewable filesystem node.
        case other
    }

    let name: String
    let kind: Kind
    var isDirectory: Bool { kind == .directory }
    var isPreviewable: Bool { kind == .file }
    /// Byte size, when a provider reports one. The tree does not draw it yet.
    let size: Int64?
    /// Modification time, when a provider reports one.
    let modified: Date?

    init(name: String, kind: Kind, size: Int64? = nil, modified: Date? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
    }
}

extension [FileEntry] {
    /// The tree's shared listing conventions, applied by every provider so a
    /// remote directory reads exactly like a local one: VCS/OS metadata dropped
    /// (see `ignoredNames`), folders first, each group alphabetized the way the
    /// Finder orders names.
    func sortedForTree() -> [FileEntry] {
        filter { !FileEntry.ignoredNames.contains($0.name) }
            .sorted { left, right in
                if left.isDirectory != right.isDirectory { return left.isDirectory }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
    }
}

extension FileEntry {
    /// VCS and OS metadata that is always noise, dropped even though dotfiles are
    /// otherwise shown. Mirrors VS Code's default `files.exclude`
    /// (`.git`/`.svn`/`.hg`/`.DS_Store`/`Thumbs.db`); like VS Code it does *not* hide
    /// `node_modules` or build output — those stay visible, loaded lazily on expand.
    static let ignoredNames: Set<String> = [".git", ".svn", ".hg", ".DS_Store", "Thumbs.db"]
}
