import Foundation

// MARK: - GitHub provider (REST, read)

/// The GitHub conformance, over the REST API with a bare `URLSession` — no SDK,
/// matching `UsageMonitor`'s API-client shape. One `/issues` request serves both
/// kinds: GitHub models a pull request as an issue with a `pull_request` key
/// (plus `draft` / `merged_at` for the PR-only states), so the kind filter is
/// applied client-side over a single fetch.
struct GitHubIssueProvider: IssueProvider {
    let id = IssueProviderID.github
    let capabilities = IssueCapabilities(pullRequests: true)

    /// Bearer token from the device-flow connect.
    let token: String

    enum APIError: LocalizedError {
        case status(Int)
        case decoding

        var errorDescription: String? {
            switch self {
            case .status(401): return "GitHub rejected the token. Reconnect from the zero state."
            case .status(403): return "GitHub denied the request — the token may lack access to this repository."
            case .status(404): return "GitHub can’t find this repository with the connected account."
            case .status(let code): return "GitHub replied with HTTP \(code)."
            case .decoding: return "GitHub returned an unexpected reply."
            }
        }
    }

    func issues(in container: IssueContainer, query: IssueQuery) async throws -> [IssueSummary] {
        var components = URLComponents(string: "https://api.github.com/repos/\(container.id)/issues")!
        var items = [
            URLQueryItem(name: "state", value: query.openOnly ? "open" : "all"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "per_page", value: "100"),
        ]
        if query.assignedToMe, let login = try await login() {
            items.append(URLQueryItem(name: "assignee", value: login))
        }
        if !query.labels.isEmpty {
            // Comma-joined = AND on this endpoint, matching GitHub's own filter.
            items.append(URLQueryItem(name: "labels", value: query.labels.sorted().joined(separator: ",")))
        }
        components.queryItems = items
        let raw: [RawIssue] = try await get(components.url!)
        return raw
            .filter { ($0.pullRequest != nil) == (query.kind == .pullRequest) }
            .map { $0.summary(in: container) }
    }

    func detail(_ number: Int, in container: IssueContainer) async throws -> IssueDetail {
        let base = "https://api.github.com/repos/\(container.id)/issues/\(number)"
        async let rawIssue: RawIssue = get(URL(string: base)!)
        async let rawComments: [RawComment] = get(URL(string: "\(base)/comments?per_page=100")!)
        let (issue, comments) = try await (rawIssue, rawComments)
        return IssueDetail(
            summary: issue.summary(in: container),
            bodyMarkdown: issue.body ?? "",
            authorAvatarURL: issue.user?.avatarUrl,
            createdAt: issue.createdAt,
            comments: comments.map {
                IssueComment(
                    id: $0.id,
                    author: $0.user?.login ?? "ghost",
                    avatarURL: $0.user?.avatarUrl,
                    createdAt: $0.createdAt,
                    bodyMarkdown: $0.body ?? ""
                )
            }
        )
    }

    /// The repo's label set, for the filter menu. (Becomes the protocol's
    /// `availableLabels` when the write milestone lands — it's already needed
    /// read-only here.)
    func availableLabels(in container: IssueContainer) async throws -> [IssueLabel] {
        struct RawLabel: Decodable {
            let name: String
            let color: String?
        }
        let raw: [RawLabel] = try await get(
            URL(string: "https://api.github.com/repos/\(container.id)/labels?per_page=100")!)
        return raw.map { IssueLabel(name: $0.name, colorHex: $0.color ?? "") }
    }

    // MARK: Pull-request extras (GitHub-specific, outside the tracker protocol)

    /// The PR's branch facts, from `/pulls/{n}` — the fields the `/issues` view of
    /// a PR doesn't carry.
    func pullRequestGitInfo(_ number: Int, in container: IssueContainer) async throws -> PullRequestGitInfo {
        struct RawPR: Decodable {
            struct Side: Decodable {
                struct Repo: Decodable { let fullName: String }
                let ref: String
                let repo: Repo?
            }
            let head: Side
            let base: Side
        }
        let raw: RawPR = try await get(
            URL(string: "https://api.github.com/repos/\(container.id)/pulls/\(number)")!)
        return PullRequestGitInfo(
            headRef: raw.head.ref,
            // A deleted fork leaves `head.repo` null — only the pull ref remains.
            crossRepository: raw.head.repo?.fullName != raw.base.repo?.fullName
        )
    }

    /// The PR's changed files as `GitChange` rows (the git pane's own model) *with the
    /// diff inline*: the `/pulls/{n}/files` response already carries each file's unified
    /// `patch`, so the Files tab renders straight from this one call — no `git fetch` of
    /// the PR refs, no per-file `git diff`, and it works for cross-fork PRs with nothing
    /// checked out locally. GitHub omits `patch` for binaries and diffs too large to
    /// inline; those arrive as `nil` and the UI shows a note instead.
    func pullRequestFiles(_ number: Int, in container: IssueContainer) async throws -> [PullRequestFile] {
        struct RawFile: Decodable {
            let filename: String
            let status: String
            let additions: Int
            let deletions: Int
            let previousFilename: String?
            let patch: String?
        }
        let raw: [RawFile] = try await get(
            URL(string: "https://api.github.com/repos/\(container.id)/pulls/\(number)/files?per_page=100")!)
        return raw.map { file in
            let status: GitFileStatus
            switch file.status {
            case "added": status = .added
            case "removed": status = .deleted
            case "renamed": status = .renamed
            case "copied": status = .copied
            default: status = .modified
            }
            var change = GitChange(path: file.filename, status: status, isUntracked: false)
            change.additions = file.additions
            change.deletions = file.deletions
            change.originalPath = file.previousFilename
            // No `patch` on a binary file; GitHub also drops it past its inline-size cap.
            change.isBinary = file.patch == nil && file.additions == 0 && file.deletions == 0
            return PullRequestFile(change: change, patch: file.patch)
        }
    }

    /// The connected account's login, fetched once per app run — the `assignee`
    /// filter needs a username, not a token.
    private func login() async throws -> String? {
        if let cached = Self.cachedLogin { return cached }
        struct RawUser: Decodable { let login: String }
        let user: RawUser = try await get(URL(string: "https://api.github.com/user")!)
        Self.cachedLogin = user.login
        return user.login
    }

    private nonisolated(unsafe) static var cachedLogin: String?

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw APIError.status(http.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Log.issues.error("decode failed for \(url.path, privacy: .public): \(error, privacy: .public)")
            throw APIError.decoding
        }
    }
}

// MARK: - Wire types

private struct RawIssue: Decodable {
    struct RawLabel: Decodable {
        let name: String
        let color: String?
    }
    struct RawUser: Decodable {
        let login: String
        let avatarUrl: URL?
    }
    /// Present on PR items. `mergedAt` marks a closed PR as merged.
    struct RawPullRequest: Decodable {
        let mergedAt: Date?
    }

    let number: Int
    let title: String
    let state: String
    let body: String?
    let labels: [RawLabel]
    let user: RawUser?
    let comments: Int?
    let createdAt: Date
    let updatedAt: Date
    let htmlUrl: URL?
    let draft: Bool?
    let pullRequest: RawPullRequest?

    func summary(in container: IssueContainer) -> IssueSummary {
        let kind: IssueKind = pullRequest == nil ? .issue : .pullRequest
        let itemState: IssueItemState
        if state == "open" {
            itemState = (kind == .pullRequest && draft == true) ? .draft : .open
        } else {
            itemState = pullRequest?.mergedAt != nil ? .merged : .closed
        }
        return IssueSummary(
            number: number,
            identifier: "#\(number)",
            title: title,
            kind: kind,
            state: itemState,
            labels: labels.map { IssueLabel(name: $0.name, colorHex: $0.color ?? "") },
            author: user?.login ?? "ghost",
            commentCount: comments ?? 0,
            updatedAt: updatedAt,
            url: htmlUrl
        )
    }
}

private struct RawComment: Decodable {
    let id: Int
    let user: RawIssue.RawUser?
    let body: String?
    let createdAt: Date
}
