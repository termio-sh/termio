import Foundation

/// One directory entry, as the device reported it. Every node in the file tree
/// is built from one of these — the local machine's included, since the local
/// tree reads the same `fs.list` over the unix socket — so ordering, icons,
/// expansion and selection behave the same on any machine.
struct FileEntry: Sendable {
    enum Kind: Sendable, Equatable {
        case file
        case directory
        /// A symlink. The host reports it as itself and never follows one while
        /// listing; `target` is what it resolves to.
        case symlink
        /// FIFOs, sockets, devices, and any other non-previewable filesystem node.
        case other
    }

    let name: String
    let kind: Kind
    /// What a symlink resolves to, and only when the target stays inside the
    /// workspace root. `nil` for anything else — including a link that dangles
    /// or points out of the root, which the host would refuse to list, and a
    /// host too old to say.
    let target: Kind?
    /// Where a symlink points, verbatim, for the row's tooltip.
    let symlinkTarget: String?

    init(name: String, kind: Kind, target: Kind? = nil, symlinkTarget: String? = nil) {
        self.name = name
        self.kind = kind
        self.target = target
        self.symlinkTarget = symlinkTarget
    }

    var isSymbolicLink: Bool { kind == .symlink }

    /// Whether this browses as a folder — resolved *through* a symlink, so a
    /// link to a directory expands like the directory it points at, which is
    /// what the Finder and the VS Code explorer both do.
    var isDirectory: Bool { kind == .directory || target == .directory }

    var isPreviewable: Bool { kind == .file || target == .file }
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
