import Foundation
import SwiftUI

// MARK: - Issue tracker models

/// A built-in issue tracker backend. Linear/Jira arrive as further cases +
/// `IssueProvider` conformances (see docs/design/issue-tracker-integration.md);
/// the UI never branches on this — it reads `IssueCapabilities` instead.
enum IssueProviderID: String, Sendable {
    case github
}

/// What a provider can do, so the UI shrinks to the backend's real surface
/// instead of branching per provider: Linear has no GitHub-style emoji
/// reactions and no pull requests, so those controls disappear for it.
struct IssueCapabilities: Sendable {
    /// The tracker distinguishes pull requests from issues — shows the
    /// Issues / Pull Requests kind switch.
    let pullRequests: Bool
}

/// Which kind of item the list is showing. On GitHub a PR *is* an issue with
/// extra fields (one `/issues` endpoint serves both), so the kind is a filter
/// over one model, not a second model.
enum IssueKind: Hashable, Sendable {
    case issue, pullRequest
}

/// An item's lifecycle state, normalized across kinds. `merged` and `draft`
/// exist only for pull requests.
enum IssueItemState: Hashable, Sendable {
    case open, closed, merged, draft

    /// The state color, following GitHub's own convention: open green; closed
    /// issue and merged PR purple (done-states); a closed *unmerged* PR red —
    /// rejected is the opposite outcome of merged, so they must not share a
    /// color; draft grey.
    func tint(for kind: IssueKind) -> Color {
        switch self {
        case .open: return .green
        case .closed: return kind == .pullRequest ? .red : .purple
        case .merged: return .purple
        case .draft: return .gray
        }
    }

    var label: String {
        switch self {
        case .open: return "Open"
        case .closed: return "Closed"
        case .merged: return "Merged"
        case .draft: return "Draft"
        }
    }
}

/// A tracker label, with the server-assigned color carried as a hex string.
struct IssueLabel: Hashable, Sendable {
    let name: String
    /// Six-digit hex without `#`, as GitHub's API returns it.
    let colorHex: String

    var color: Color {
        var value: UInt64 = 0
        guard Scanner(string: colorHex).scanHexInt64(&value), colorHex.count == 6 else {
            return .secondary
        }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// The remote container a project is bound to — a GitHub `owner/repo` (a
/// Linear team later). `id` is the provider-native identifier.
struct IssueContainer: Hashable, Sendable {
    let provider: IssueProviderID
    let id: String

    var displayName: String { id }
}

/// The list request: which kind, and the light filters the top bar offers.
/// Selected labels combine as AND, GitHub's own filter semantics.
struct IssueQuery: Hashable, Sendable {
    var kind: IssueKind = .issue
    var openOnly = true
    var assignedToMe = false
    var labels: Set<String> = []
}

/// One row of the list. `identifier` is the provider-native short handle —
/// GitHub's `#95`, Linear's `TER-123`.
struct IssueSummary: Identifiable, Hashable, Sendable {
    let number: Int
    let identifier: String
    let title: String
    let kind: IssueKind
    let state: IssueItemState
    let labels: [IssueLabel]
    let author: String
    let commentCount: Int
    let updatedAt: Date
    let url: URL?

    var id: Int { number }
}

/// One comment in the detail thread.
struct IssueComment: Identifiable, Sendable {
    let id: Int
    let author: String
    let avatarURL: URL?
    let createdAt: Date
    let bodyMarkdown: String
}

/// The full item: the summary plus its markdown body and comment thread.
struct IssueDetail: Sendable {
    let summary: IssueSummary
    let bodyMarkdown: String
    let authorAvatarURL: URL?
    let createdAt: Date
    let comments: [IssueComment]
}

/// The branch facts the Files tab and Checkout need from a pull request —
/// which refs to fetch and diff, and whether the head lives in a fork (a fork's
/// branch is only reachable through the `refs/pull/N/head` ref).
struct PullRequestGitInfo: Sendable {
    let headRef: String
    let baseRef: String
    let crossRepository: Bool
}

// MARK: - Provider protocol

/// The read surface every tracker backend implements. Write operations
/// (reactions, labels, comments — issue #100) extend this protocol when they
/// land; keeping M1's surface read-only keeps the first conformance honest.
protocol IssueProvider: Sendable {
    var id: IssueProviderID { get }
    var capabilities: IssueCapabilities { get }

    func issues(in container: IssueContainer, query: IssueQuery) async throws -> [IssueSummary]
    func detail(_ number: Int, in container: IssueContainer) async throws -> IssueDetail
}
