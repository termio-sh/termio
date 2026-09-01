import TermioShared
import Foundation

/// The git plane: reading a device's checkout through the `git:` resource and
/// the `git.*` verbs (`termiod/src/git.rs`).
///
/// Status is a **subscription**, not a poll. The device already watches the
/// workspace, so it knows when status moved and the client does not have to ask;
/// what arrives is a delta against what the subscriber holds. Zed publishes the
/// same object under a different name (`UpdateRepository`: `updated_statuses`,
/// `removed_statuses`, `branch_summary`), and VS Code arrives at it from the
/// other side by running the git extension itself on the remote. A client that
/// polled would be the only one of the three doing so.
///
/// Everything here reads. Stage, commit, discard and push are a separate tier
/// that needs the prompt-forwarding channel (`docs/rfcs/remote-git-plane.md` §3)
/// and are deliberately absent — a remote checkout's Changes pane offers no
/// action it cannot honestly perform.
extension Termiod {
    /// What a git channel negotiates. The pool keys channels by capability set,
    /// so this is also what decides whether the Changes pane shares a connection
    /// with the file tree or gets its own — deliberately its own, because the
    /// tree's `["files"]` channel could not answer a `git` verb and handing it
    /// one would hang on a reply the daemon will never send.
    static let gitCapabilities = ["resources", "git"]

    /// The `git:` resource id for a checkout — `resource.rs` `GIT_PREFIX`.
    static func gitResource(root: String) -> String { "git:\(root)" }

    /// One `git_changed` batch: a delta against the subscriber's baseline, with
    /// branch metadata carried whole so a client never merges it.
    struct GitChangedPayload: Sendable {
        let seq: UInt64
        let updatedStatuses: [GitStatusEntryPayload]
        let removedPaths: [String]
        let branch: String?
        let head: String?
        let ahead: Int
        let behind: Int
        let conflicts: [String]
        /// How many paths the device's status run named, when it cut the list
        /// below that (`git.rs` `STATUS_CAP`) — so the pane can say how much
        /// of it is missing, not merely that some is.
        let total: Int?
    }

    /// One changed path. The two-axis `status` is the porcelain-v2 vocabulary
    /// the device and the Mac's own parser both speak, so the pane's row reads
    /// the same either way.
    struct GitStatusEntryPayload: Sendable {
        let path: String
        let status: WireGitStatus
        let originalPath: String?
        let additions: Int
        let deletions: Int
        let binary: Bool
    }

    /// `git.rs`'s `GitFileStatus`, as it arrives. Kept as the wire's own shape
    /// rather than flattened on decode: which axis moved is what says whether a
    /// change is staged, and collapsing that here would throw it away.
    enum WireGitStatus: Sendable {
        case untracked
        case ignored
        case tracked(index: String, worktree: String)
        case unmerged
        /// A status this build has never heard of. Additive evolution applies to
        /// the *batch* — one unreadable row must not sink the list — but not to
        /// the row itself, which is dropped rather than drawn as a guess.
        case unknown
    }

    static func decodeGitChanged(_ payload: Data) throws -> GitChangedPayload {
        try gitDecoder().decode(WireGitChanged.self, from: payload).payload
    }

    /// The unified diff for one path, rendered client-side.
    ///
    /// `staged` is a hint about where the change lives; the device walks the
    /// same ladder the Mac's local path does either way, so an untracked file
    /// and a fully-staged one both answer. `context` is the `-U`: the overlay
    /// asks for the whole file so it can fold unchanged runs into expandable
    /// bands, which git's default three lines cannot support.
    static func gitDiff(
        route: TermiodRoute, root: String, path: String, staged: Bool, context: Int? = nil
    ) async throws -> (text: String, truncated: Bool) {
        let result = try await readTier(
            route: route, GitDiffResult.self, operation: "git diff \(path)"
        ) { seq in
            try encodeControl(GitDiffOperation(
                root: root, path: path, staged: staged,
                context: context.map(UInt64.init), seq: seq))
        }
        return (result.diff, result.truncated)
    }

    // MARK: History and Compare — the read tier

    /// One read-tier request: send the operation, wait for its reply, decode it
    /// here. None of these replies are in the shared decode table — each is its
    /// own plane's answer and nothing else consumes it — so they all arrive as
    /// `.unknown` and are decoded against `Wire`.
    private static func readTier<Wire: Decodable & Sendable>(
        route: TermiodRoute, _ wire: Wire.Type, operation: String,
        encode: @escaping @Sendable (UInt64) throws -> Data
    ) async throws -> Wire {
        try await offMain {
            try withPooledRequest(route: route, caps: gitCapabilities) { call, channel in
                guard channel.capabilities.contains("git") else {
                    throw DeviceGitError.unsupported
                }
                try call.send(payload: encode(call.seq))
                while true {
                    let frame = try call.next(
                        timeoutSeconds: connectTimeoutSeconds, operation: operation)
                    guard frame.kind == .control else { continue }
                    let reply = try decodeControl(frame.payload)
                    if case .error(let failure) = reply {
                        throw TermiodClientError.requestFailed(failure.message)
                    }
                    guard case .unknown = reply else { continue }
                    return try gitDecoder().decode(Wire.self, from: frame.payload)
                }
            }
        }
    }

    /// The checkout's recent commits, newest first — the History tab, and with
    /// `range` (`base..HEAD`) the commit half of a branch comparison.
    static func gitLog(
        route: TermiodRoute, root: String, limit: Int = 100, range: String? = nil
    ) async throws -> (commits: [GitCommit], truncated: Bool) {
        let result = try await readTier(
            route: route, WireGitLogResult.self, operation: "git log"
        ) { seq in
            try encodeControl(GitLogOperation(
                root: root, limit: UInt64(limit), range: range, seq: seq))
        }
        return (commits(from: result.commits), result.truncated)
    }

    /// The files one commit touched — the rows a History entry expands to.
    static func gitCommitFiles(
        route: TermiodRoute, root: String, commit: String
    ) async throws -> [GitChange] {
        let result = try await readTier(
            route: route, WireGitShowResult.self, operation: "git show \(commit)"
        ) { seq in
            try encodeControl(GitShowOperation(root: root, commit: commit, path: nil, seq: seq))
        }
        return result.files.compactMap(\.change)
    }

    /// One file's diff as of one commit — what a History file row opens.
    static func gitShowDiff(
        route: TermiodRoute, root: String, commit: String, path: String
    ) async throws -> String {
        try await readTier(
            route: route, WireGitShowResult.self, operation: "git show \(commit) \(path)"
        ) { seq in
            try encodeControl(GitShowOperation(root: root, commit: commit, path: path, seq: seq))
        }.diff
    }

    /// The checkout's refs, composed into the Compare tab's base-picker context
    /// with the same suggestion rule the local pane uses.
    static func gitBranches(
        route: TermiodRoute, root: String
    ) async throws -> GitService.CompareContext {
        let result = try await readTier(
            route: route, WireGitBranchesResult.self, operation: "git branches"
        ) { seq in
            try encodeControl(GitBranchesOperation(root: root, seq: seq))
        }
        return compareContext(from: result)
    }

    /// The branch against a base — files, commits, and behind count in one
    /// reply, all describing the one head the device pinned before walking. A
    /// `problem` means the checkout could not be compared and says why.
    static func gitCompare(
        route: TermiodRoute, root: String, base: String
    ) async throws -> (
        files: [GitChange], commits: [GitCommit], behind: Int,
        problem: GitService.CompareProblem?
    ) {
        let result = try await readTier(
            route: route, WireGitCompareResult.self, operation: "git compare \(base)"
        ) { seq in
            try encodeControl(GitCompareOperation(root: root, base: base, path: nil, seq: seq))
        }
        return (result.files.compactMap(\.change), commits(from: result.commits),
                result.behind, result.compareProblem)
    }

    /// One file's three-dot diff across `base...HEAD` — what a Compare file
    /// row opens.
    static func gitCompareDiff(
        route: TermiodRoute, root: String, base: String, path: String
    ) async throws -> String {
        try await readTier(
            route: route, WireGitCompareResult.self, operation: "git compare \(base) \(path)"
        ) { seq in
            try encodeControl(GitCompareOperation(root: root, base: base, path: path, seq: seq))
        }.diff
    }

    /// Composes the wire's ref list into the local pane's picker context, so
    /// the Compare tab renders a device checkout through the identical view —
    /// same lists, same suggestion rule.
    static func compareContext(from result: WireGitBranchesResult) -> GitService.CompareContext {
        let locals = result.branches.filter { !$0.remote && $0.name != result.current }
            .map(\.name)
        let remotes = result.branches.filter(\.remote).map(\.name)
        return GitService.CompareContext(
            branch: result.current,
            remoteBranches: remotes,
            localBranches: locals,
            suggestedBase: GitService.suggestedCompareBase(
                branch: result.current, originHead: result.defaultBranch,
                remoteBranches: remotes, localBranches: locals))
    }

    /// Runs a blocking pooled request off the main thread. Every verb here is
    /// blocking by construction — the pool hands out a frame reader, not a
    /// future — and the panes calling them are on the main actor.
    private static func offMain<Value: Sendable>(
        _ body: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    /// Subscribes to the checkout's status. The first batch is the whole state
    /// — the device synthesizes it for a subscriber with no cursor — so the
    /// caller starts from empty and applies what arrives.
    static func watchGit(
        route: TermiodRoute,
        root: String,
        since: UInt64? = nil,
        onBatch: @escaping @Sendable (GitChangedPayload) -> Void,
        onInterrupted: @escaping @Sendable () -> Void
    ) async throws -> (subscription: ResourceSubscription, gap: Bool, seq: UInt64) {
        try await offMain {
            try subscribeResource(
                route: route,
                caps: gitCapabilities,
                resource: gitResource(root: root),
                since: since,
                onEvent: { payload in
                    guard let batch = try? decodeGitChanged(payload) else { return }
                    onBatch(batch)
                },
                onInterrupted: onInterrupted)
        }
    }

    private struct GitDiffOperation: Encodable {
        let op = "git_diff"
        let root: String
        let path: String
        let staged: Bool
        let context: UInt64?
        let seq: UInt64
    }

    private struct GitDiffResult: Decodable {
        let diff: String
        let truncated: Bool

        private enum CodingKeys: String, CodingKey { case diff, truncated }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            diff = try container.decodeIfPresent(String.self, forKey: .diff) ?? ""
            truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        }
    }

    /// Maps wire commits to the pane's rows. The wire carries both the box's
    /// own rendered `relative_date` and the instant: the box may speak another
    /// language, so the date is formatted here from `timestamp` and the box's
    /// rendering is only the fallback for a host too old to send one.
    static func commits(from wire: [WireGitCommit]) -> [GitCommit] {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let now = Date()
        return wire.map { $0.commit(formatter: formatter, now: now) }
    }

    /// A commit-file status as `GitStatusCode` spells it on the wire. `nil` for
    /// a status this build cannot draw — the row is dropped rather than drawn
    /// as a guess, the same additive-evolution rule the status batches follow.
    static func commitFileStatus(_ code: String) -> GitFileStatus? {
        switch code {
        case "modified", "type_changed": return .modified
        case "added": return .added
        case "deleted": return .deleted
        case "renamed": return .renamed
        case "copied": return .copied
        default: return nil
        }
    }

    struct WireGitCommit: Decodable, Sendable {
        let sha: String
        let shortSha: String
        let subject: String
        let author: String
        let authorEmail: String
        let relativeDate: String
        let timestamp: Int64
        let tags: [String]
        let unpushed: Bool

        private enum CodingKeys: String, CodingKey {
            case sha, shortSha, subject, author, authorEmail, relativeDate
            case timestamp, tags, unpushed
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sha = try container.decode(String.self, forKey: .sha)
            shortSha = try container.decodeIfPresent(String.self, forKey: .shortSha)
                ?? String(sha.prefix(7))
            subject = try container.decodeIfPresent(String.self, forKey: .subject) ?? ""
            author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
            authorEmail = try container.decodeIfPresent(String.self, forKey: .authorEmail) ?? ""
            relativeDate = try container.decodeIfPresent(String.self, forKey: .relativeDate) ?? ""
            timestamp = try container.decodeIfPresent(Int64.self, forKey: .timestamp) ?? 0
            tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
            unpushed = try container.decodeIfPresent(Bool.self, forKey: .unpushed) ?? false
        }

        func commit(formatter: RelativeDateTimeFormatter, now: Date) -> GitCommit {
            GitCommit(
                sha: sha, shortSHA: shortSha, subject: subject,
                author: author, authorEmail: authorEmail,
                relativeDate: timestamp > 0
                    ? formatter.localizedString(
                        for: Date(timeIntervalSince1970: TimeInterval(timestamp)),
                        relativeTo: now)
                    : relativeDate,
                tags: tags, isUnpushed: unpushed)
        }
    }

    struct WireGitCommitFile: Decodable, Sendable {
        let path: String
        let originalPath: String?
        let status: String
        let additions: Int
        let deletions: Int
        let binary: Bool

        private enum CodingKeys: String, CodingKey {
            case path, originalPath, status, additions, deletions, binary
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            originalPath = try container.decodeIfPresent(String.self, forKey: .originalPath)
            status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
            additions = try container.decodeIfPresent(Int.self, forKey: .additions) ?? 0
            deletions = try container.decodeIfPresent(Int.self, forKey: .deletions) ?? 0
            binary = try container.decodeIfPresent(Bool.self, forKey: .binary) ?? false
        }

        var change: GitChange? {
            guard let status = Termiod.commitFileStatus(status) else { return nil }
            return GitChange(
                path: path, status: status, isUntracked: false,
                additions: additions, deletions: deletions,
                originalPath: originalPath, isBinary: binary)
        }
    }

    struct WireGitLogResult: Decodable, Sendable {
        let commits: [WireGitCommit]
        let truncated: Bool

        private enum CodingKeys: String, CodingKey { case commits, truncated }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            commits = try container.decodeIfPresent([WireGitCommit].self, forKey: .commits) ?? []
            truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        }
    }

    struct WireGitShowResult: Decodable, Sendable {
        let files: [WireGitCommitFile]
        let diff: String
        let truncated: Bool
        let filesTruncated: Bool

        private enum CodingKeys: String, CodingKey {
            case files, diff, truncated, filesTruncated
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            files = try container.decodeIfPresent([WireGitCommitFile].self, forKey: .files) ?? []
            diff = try container.decodeIfPresent(String.self, forKey: .diff) ?? ""
            truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
            filesTruncated = try container.decodeIfPresent(
                Bool.self, forKey: .filesTruncated) ?? false
        }
    }

    struct WireGitBranch: Decodable, Sendable {
        let name: String
        let remote: Bool

        private enum CodingKeys: String, CodingKey { case name, remote }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            remote = try container.decodeIfPresent(Bool.self, forKey: .remote) ?? false
        }
    }

    struct WireGitBranchesResult: Decodable, Sendable {
        let branches: [WireGitBranch]
        let current: String?
        let defaultBranch: String?

        private enum CodingKeys: String, CodingKey { case branches, current, defaultBranch }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            branches = try container.decodeIfPresent([WireGitBranch].self, forKey: .branches) ?? []
            current = try container.decodeIfPresent(String.self, forKey: .current)
            defaultBranch = try container.decodeIfPresent(String.self, forKey: .defaultBranch)
        }
    }

    struct WireGitCompareResult: Decodable, Sendable {
        let files: [WireGitCommitFile]
        let commits: [WireGitCommit]
        let behind: Int
        let diff: String
        let problem: String?

        private enum CodingKeys: String, CodingKey {
            case files, commits, behind, diff, problem
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            files = try container.decodeIfPresent([WireGitCommitFile].self, forKey: .files) ?? []
            commits = try container.decodeIfPresent(
                [WireGitCommit].self, forKey: .commits) ?? []
            behind = try container.decodeIfPresent(Int.self, forKey: .behind) ?? 0
            diff = try container.decodeIfPresent(String.self, forKey: .diff) ?? ""
            problem = try container.decodeIfPresent(String.self, forKey: .problem)
        }

        /// The device's stated problem in the pane's vocabulary. A problem this
        /// build has never heard of still *is* one — it must not fold into a
        /// clean empty comparison, so it maps to the unreadable case.
        var compareProblem: GitService.CompareProblem? {
            switch problem {
            case nil: return nil
            case "missing_base": return .missingBase
            case "no_common_history": return .noCommonHistory
            default: return .unreadable
            }
        }
    }

    private struct GitLogOperation: Encodable {
        let op = "git_log"
        let root: String
        let limit: UInt64
        let range: String?
        let seq: UInt64
    }

    private struct GitShowOperation: Encodable {
        let op = "git_show"
        let root: String
        let commit: String
        let path: String?
        let seq: UInt64
    }

    private struct GitBranchesOperation: Encodable {
        let op = "git_branches"
        let root: String
        let seq: UInt64
    }

    private struct GitCompareOperation: Encodable {
        let op = "git_compare"
        let root: String
        let base: String
        let path: String?
        let seq: UInt64
    }

    private struct WireGitChanged: Decodable {
        let seq: UInt64
        let updatedStatuses: [WireStatusEntry]
        let removedPaths: [String]
        let branch: String?
        let head: String?
        let aheadBehind: [Int]?
        let conflicts: [String]
        let total: Int?

        private enum CodingKeys: String, CodingKey {
            case seq, updatedStatuses, removedPaths, branch, head, aheadBehind, conflicts
            case total
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            seq = try container.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
            updatedStatuses = try container.decodeIfPresent(
                [WireStatusEntry].self, forKey: .updatedStatuses) ?? []
            removedPaths = try container.decodeIfPresent(
                [String].self, forKey: .removedPaths) ?? []
            branch = try container.decodeIfPresent(String.self, forKey: .branch)
            head = try container.decodeIfPresent(String.self, forKey: .head)
            aheadBehind = try container.decodeIfPresent([Int].self, forKey: .aheadBehind)
            conflicts = try container.decodeIfPresent([String].self, forKey: .conflicts) ?? []
            total = try container.decodeIfPresent(Int.self, forKey: .total)
        }

        var payload: GitChangedPayload {
            GitChangedPayload(
                seq: seq,
                updatedStatuses: updatedStatuses.map(\.payload),
                removedPaths: removedPaths,
                branch: branch,
                head: head,
                ahead: aheadBehind?.first ?? 0,
                behind: aheadBehind?.dropFirst().first ?? 0,
                conflicts: conflicts,
                total: total)
        }
    }

    private struct WireStatusEntry: Decodable {
        let path: String
        let status: WireStatusValue
        let originalPath: String?
        let additions: Int
        let deletions: Int
        let binary: Bool

        private enum CodingKeys: String, CodingKey {
            case path, status, originalPath, additions, deletions, binary
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            status = try container.decode(WireStatusValue.self, forKey: .status)
            originalPath = try container.decodeIfPresent(String.self, forKey: .originalPath)
            additions = try container.decodeIfPresent(Int.self, forKey: .additions) ?? 0
            deletions = try container.decodeIfPresent(Int.self, forKey: .deletions) ?? 0
            binary = try container.decodeIfPresent(Bool.self, forKey: .binary) ?? false
        }

        var payload: GitStatusEntryPayload {
            GitStatusEntryPayload(
                path: path, status: status.status, originalPath: originalPath,
                additions: additions, deletions: deletions, binary: binary)
        }
    }

    /// Serde's externally-tagged enum: `"untracked"` for a unit case, and
    /// `{"tracked": {...}}` for one with fields. Decoded by hand because the two
    /// shapes are a string and an object, which no synthesized initializer will
    /// accept as one type.
    private struct WireStatusValue: Decodable {
        let status: WireGitStatus

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(),
               let name = try? single.decode(String.self) {
                switch name {
                case "untracked": status = .untracked
                case "ignored": status = .ignored
                default: status = .unknown
                }
                return
            }
            guard let container = try? decoder.container(keyedBy: Key.self) else {
                status = .unknown
                return
            }
            if let tracked = try? container.decode(
                TrackedAxes.self, forKey: Key(stringValue: "tracked")) {
                status = .tracked(index: tracked.indexStatus, worktree: tracked.worktreeStatus)
            } else if container.contains(Key(stringValue: "unmerged")) {
                status = .unmerged
            } else {
                status = .unknown
            }
        }

        private struct TrackedAxes: Decodable {
            let indexStatus: String
            let worktreeStatus: String
        }

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
    }

    private static func gitDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

/// What can go wrong reading a device's git, in the pane's vocabulary.
enum DeviceGitError: Error, Equatable {
    /// The daemon did not grant `git` — too old, or built without it.
    case unsupported
}
