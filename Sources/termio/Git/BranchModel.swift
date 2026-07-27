import Foundation
import Combine

/// Tracks the *current* git branch of one or more folders and keeps each label
/// live: when the user runs `git checkout` / `git switch` inside a folder, the
/// label updates on its own. This is what lets the sidebar's worktree nodes and
/// the terminal title bar show a folder's real branch instead of a value frozen
/// at the moment the project was opened.
///
/// Identity is the *folder* (a stable directory path); the branch is a mutable
/// attribute read from that folder's `HEAD`. A folder is watched by observing the
/// directory that contains its `HEAD` file — for the primary checkout that is
/// `<repo>/.git`, for a linked worktree it is `<repo>/.git/worktrees/<name>`. Git
/// resolves the right one via `rev-parse --git-path HEAD` (the one git spawn left
/// here, once per folder when the watch is armed). Watching the *directory*
/// (not the file) survives git's atomic replace-on-write of `HEAD`, where the file
/// inode is swapped out from under a file-level watch.
///
/// The state itself is read **in-process** — `HEAD` is a one-line text file and the
/// linked worktrees are a directory listing. The previous shape spawned 2–3 `git
/// rev-parse` processes per event, and the watched directory is `.git` itself, whose
/// busiest file by far is `index`: every `git status` run by *anyone* (an agent's
/// shell loop, the git pane's own reload) rewrites it and fired this watch. With a
/// fleet of agent sessions that added up to a machine-wide process storm — dozens of
/// short-lived `git` spawns a second, with trustd/tccd re-validating each one.
///
/// All reads run off the main thread; `branches` is only ever mutated on main,
/// so SwiftUI observers stay safe.
final class BranchModel: ObservableObject {
    /// Folder path → branch label (the branch name, or a short commit SHA when the
    /// folder is in a detached HEAD). Absent when the folder is not a git repo, so
    /// callers can hide the branch chip entirely.
    @Published private(set) var branches: [String: String] = [:]
    /// Detached state stays separate from the label because existing branch chips
    /// still use the short SHA, while a worktree folder node uses its directory name
    /// and keeps that SHA for the tooltip.
    @Published private(set) var detachedFolders: Set<String> = []

    /// Fired on the main thread when a watched folder's git state *actually changed*:
    /// its HEAD moved (checkout, commit, rebase) or its linked-worktree set gained or
    /// lost an entry. Deliberately not fired for every `.git` directory event — index
    /// refreshes are the overwhelming majority and mean nothing to the worktree list.
    /// Carries the folder so the store can reconcile just that project, not all of them.
    var onGitStateChange: ((String) -> Void)?

    private let queue = DispatchQueue(label: "sh.termio.branch", qos: .utility)
    private var watchers: [String: Watcher] = [:]
    /// The currently wanted watch set and the folders whose HEAD-directory resolution
    /// is in flight — both main-only, so an overlapping `setWatched` can't double-arm.
    private var wanted: Set<String> = []
    private var arming: Set<String> = []
    /// Pending debounce work items per folder, touched only on `queue`.
    private var pending: [String: DispatchWorkItem] = [:]
    /// The last state read per folder, touched only on `queue` — the change gate for
    /// `onGitStateChange`.
    private var lastStates: [String: GitState] = [:]

    /// A live file-system observer on the directory holding a folder's `HEAD`.
    private final class Watcher {
        let source: DispatchSourceFileSystemObject
        init(source: DispatchSourceFileSystemObject) { self.source = source }
    }

    /// The current branch label for `folder`, or `nil` when it is not a git repo
    /// (or has not resolved yet).
    func branch(for folder: String) -> String? {
        branches[Self.standardized(folder)]
    }

    func isDetached(_ folder: String) -> Bool {
        detachedFolders.contains(Self.standardized(folder))
    }

    /// Reconciles the watched set with `folders`: starts watching (and resolves) any
    /// newly present folder and stops watching any that has gone. Idempotent, so the
    /// store can call it after every change to the project tree. Main-actor only.
    func setWatched(_ folders: Set<String>) {
        wanted = Set(folders.map(Self.standardized))

        for (folder, watcher) in watchers where !wanted.contains(folder) {
            watcher.source.cancel()
            watchers[folder] = nil
            branches[folder] = nil
            detachedFolders.remove(folder)
            queue.async { [weak self] in self?.lastStates[folder] = nil }
        }
        for folder in wanted where watchers[folder] == nil && !arming.contains(folder) {
            arming.insert(folder)
            // Resolve the HEAD directory off the main thread: it is the one git spawn
            // left in this model, and launch-time git has hung in the kernel before
            // (post-rebuild code-sign stall) — that must stall a utility queue, never
            // app startup. The watch is then armed back on main, where `watchers` lives.
            queue.async { [weak self] in
                let headDirectory = self?.headDirectory(for: folder)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.arming.remove(folder)
                    // The wanted set may have moved while git ran; arm only if current.
                    guard let headDirectory, self.wanted.contains(folder),
                          self.watchers[folder] == nil else { return }
                    self.arm(folder, headDirectory: headDirectory)
                    // Seed the state without notifying: the store reconciles everything
                    // at launch anyway; the seed makes the first *event* comparable.
                    self.queue.async { [weak self] in
                        self?.refresh(folder, headDirectory: headDirectory, notify: false)
                    }
                }
            }
        }
    }

    /// Opens a directory-level watch on the folder's already-resolved `HEAD` container.
    private func arm(_ folder: String, headDirectory: String) {
        let descriptor = open(headDirectory, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .link, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleRefresh(folder, headDirectory: headDirectory)
        }
        source.setCancelHandler { close(descriptor) }
        watchers[folder] = Watcher(source: source)
        source.resume()
    }

    /// Coalesces a burst of file-system events (a checkout rewrites several refs)
    /// into a single re-read. Runs on `queue`, where `pending` lives.
    private func scheduleRefresh(_ folder: String, headDirectory: String) {
        pending[folder]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.pending[folder] = nil
            self?.refresh(folder, headDirectory: headDirectory, notify: true)
        }
        pending[folder] = item
        queue.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    /// Re-reads a folder's git state, publishes the branch label, and — when notifying
    /// and something really moved — reports the change. Runs on `queue`.
    private func refresh(_ folder: String, headDirectory: String, notify: Bool) {
        let state = readGitState(headDirectory: headDirectory)
        let changed = lastStates[folder] != state
        lastStates[folder] = state
        publish(folder, state: state.branch)
        guard notify, changed else { return }
        DispatchQueue.main.async { [weak self] in self?.onGitStateChange?(folder) }
    }

    private func publish(_ folder: String, state: BranchState?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let isDetached = state?.isDetached == true
            if isDetached {
                self.detachedFolders.insert(folder)
            } else {
                self.detachedFolders.remove(folder)
            }
            if self.branches[folder] != state?.label { self.branches[folder] = state?.label }
        }
    }

    // MARK: - In-process git state

    private struct BranchState: Equatable {
        var label: String
        var isDetached: Bool
    }

    /// Everything a git-dir event can meaningfully change for us: where HEAD points,
    /// and which linked worktrees exist. Equatable so an `index` refresh — same HEAD,
    /// same worktrees — is recognized as the no-op it is.
    private struct GitState: Equatable {
        var branch: BranchState?
        var worktreeEntries: [String]
    }

    private func readGitState(headDirectory: String) -> GitState {
        GitState(branch: readBranch(headDirectory: headDirectory),
                 worktreeEntries: readWorktreeEntries(headDirectory: headDirectory))
    }

    /// Parses `HEAD` directly instead of spawning `git rev-parse`: the file is either
    /// `ref: refs/heads/<branch>` or a bare commit hash (detached). The label matches
    /// what `--abbrev-ref` printed, except a detached SHA is always 7 chars (git may
    /// lengthen its abbreviation for ambiguity; for a display chip that nicety isn't
    /// worth a process per event).
    private func readBranch(headDirectory: String) -> BranchState? {
        guard let raw = try? String(
            contentsOfFile: headDirectory + "/HEAD", encoding: .utf8) else { return nil }
        let head = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("ref: ") {
            let ref = head.dropFirst("ref: ".count)
            let label = ref.hasPrefix("refs/heads/") ? ref.dropFirst("refs/heads/".count) : ref
            guard !label.isEmpty else { return nil }
            return BranchState(label: String(label), isDetached: false)
        }
        // Detached HEAD (rebase in progress, or checked out at a bare commit): show
        // the short SHA so the node still reads as "somewhere specific".
        guard head.count >= 7, head.allSatisfy(\.isHexDigit) else { return nil }
        return BranchState(label: String(head.prefix(7)), isDetached: true)
    }

    /// The primary checkout's git directory — where the `worktrees` listing lives.
    /// A linked worktree's HEAD directory (`<common>/worktrees/<name>`) carries a
    /// `commondir` file pointing back, usually relatively, at the common dir; the
    /// primary checkout has no such file and is its own common dir.
    private func commonDirectory(for headDirectory: String) -> String {
        guard let raw = try? String(
            contentsOfFile: headDirectory + "/commondir", encoding: .utf8) else {
            return headDirectory
        }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return headDirectory }
        if path.hasPrefix("/") { return path }
        return URL(fileURLWithPath: headDirectory)
            .appendingPathComponent(path).standardizedFileURL.path
    }

    /// One line per linked worktree: the entry name plus its admin `gitdir` contents,
    /// so an add, a remove, *and* a `git worktree move` (same name, new checkout path)
    /// all read as changes. Resolved through the common dir, so a linked checkout's
    /// events see the same listing the primary one does — its own HEAD directory has
    /// no `worktrees` child. Empty for a repo with no linked worktrees.
    private func readWorktreeEntries(headDirectory: String) -> [String] {
        let root = commonDirectory(for: headDirectory) + "/worktrees"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            return []
        }
        return names.sorted().map { name in
            let gitdir = (try? String(
                contentsOfFile: root + "/" + name + "/gitdir", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name + "\u{0}" + gitdir
        }
    }

    // MARK: - Git (watch setup only)

    /// The directory that contains the folder's `HEAD` file. `git-path` resolves the
    /// linked-worktree case (`…/.git/worktrees/<name>/HEAD`) as well as the primary
    /// checkout (`…/.git/HEAD`). Returns `nil` for a non-repo. The one place this
    /// model still runs git — once per folder, when its watch is armed.
    private func headDirectory(for folder: String) -> String? {
        guard let headPath = git(["rev-parse", "--git-path", "HEAD"], in: folder) else { return nil }
        let absolute = headPath.hasPrefix("/")
            ? headPath
            : URL(fileURLWithPath: folder).appendingPathComponent(headPath).path
        return (absolute as NSString).deletingLastPathComponent
    }

    /// Runs `git -C <folder> <arguments…>` synchronously, returning trimmed stdout on
    /// success or `nil` on any failure — the same no-trap, degrade-gracefully stance
    /// the rest of the app takes.
    private func git(_ arguments: [String], in folder: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder] + arguments
        process.environment = GitEnvironment.optionalLocksDisabled
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func standardized(_ folder: String) -> String {
        URL(fileURLWithPath: folder).standardizedFileURL.path
    }
}
