import Foundation
import AppKit

// MARK: - Issues pane state

/// State for the Issues pane, per repo root (recreated by `.id(repoRoot)` like
/// `GitPanelModel`): the GitHub connection, the container binding resolved from
/// the origin remote, the list, and the pushed-in detail.
@MainActor
final class IssuesPanelModel: ObservableObject {
    /// Where the pane is in the connect → bind → read ladder; each step has a
    /// zero state except `.ready`.
    enum Phase: Equatable {
        /// No token — show Connect.
        case disconnected
        /// Device flow underway: show the code, wait for approval in the browser.
        case connecting(userCode: String)
        /// Connected, but the project's origin remote isn't a github.com repo.
        case unbound
        case ready
    }

    @Published private(set) var phase: Phase = .disconnected
    @Published private(set) var container: IssueContainer?
    @Published private(set) var items: [IssueSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// The pushed-in detail (list → detail, like git pane file → diff).
    @Published var openItem: IssueSummary?
    @Published private(set) var detail: IssueDetail?
    @Published private(set) var detailError: String?

    @Published var query = IssueQuery() {
        didSet { if query != oldValue { Task { await loadList() } } }
    }

    let repoRoot: String
    private var provider: GitHubIssueProvider?

    init(repoRoot: String) {
        self.repoRoot = repoRoot
    }

    var capabilities: IssueCapabilities? { provider?.capabilities }

    /// Entry point on appear: restore the Keychain token, resolve the binding
    /// from the origin remote, and load.
    func start() async {
        if provider == nil, let token = GitHubIssueAuth.storedToken() {
            provider = GitHubIssueProvider(token: token)
        }
        guard provider != nil else {
            phase = .disconnected
            return
        }
        await resolveContainer()
        await loadList()
    }

    // MARK: Connect / disconnect

    /// Runs the whole device flow: shows the code, opens the verification page,
    /// polls until approved, then loads the pane.
    func connect() async {
        errorMessage = nil
        do {
            let code = try await GitHubIssueAuth.requestDeviceCode()
            phase = .connecting(userCode: code.userCode)
            NSWorkspace.shared.open(code.verificationURL)
            let token = try await GitHubIssueAuth.waitForToken(code)
            GitHubIssueAuth.store(token: token)
            provider = GitHubIssueProvider(token: token)
            await resolveContainer()
            await loadList()
        } catch {
            phase = .disconnected
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        GitHubIssueAuth.deleteToken()
        provider = nil
        items = []
        openItem = nil
        detail = nil
        phase = .disconnected
    }

    // MARK: Loading

    private func resolveContainer() async {
        if let slug = await GitService.gitHubRepoSlug(in: repoRoot) {
            container = IssueContainer(provider: .github, id: slug)
            phase = .ready
        } else {
            container = nil
            phase = .unbound
        }
    }

    /// The repo's labels, for the filter menu — loaded once per pane.
    @Published private(set) var availableLabels: [IssueLabel] = []

    func toggleLabelFilter(_ name: String) {
        if query.labels.contains(name) {
            query.labels.remove(name)
        } else {
            query.labels.insert(name)
        }
    }

    private func loadLabels() async {
        guard let provider, let container, availableLabels.isEmpty else { return }
        availableLabels = (try? await provider.availableLabels(in: container)) ?? []
    }

    func loadList() async {
        guard let provider, let container, phase == .ready else { return }
        if availableLabels.isEmpty { Task { await loadLabels() } }
        isLoading = true
        errorMessage = nil
        do {
            items = try await provider.issues(in: container, query: query)
        } catch {
            // A revoked token must degrade to the connect zero state, not wedge.
            if case GitHubIssueProvider.APIError.status(401) = error {
                disconnect()
            } else {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    func loadDetail(for item: IssueSummary) async {
        guard let provider, let container else { return }
        detail = nil
        detailError = nil
        prFiles = []
        prInfo = nil
        prDiffRange = nil
        checkoutError = nil
        do {
            if item.kind == .pullRequest {
                async let loadedDetail = provider.detail(item.number, in: container)
                async let info = provider.pullRequestGitInfo(item.number, in: container)
                async let files = provider.pullRequestFiles(item.number, in: container)
                (detail, prInfo, prFiles) = try await (loadedDetail, info, files)
            } else {
                detail = try await provider.detail(item.number, in: container)
            }
        } catch {
            detailError = error.localizedDescription
        }
    }

    // MARK: Pull-request extras

    /// The PR's changed files (empty for issues) and branch facts.
    @Published private(set) var prFiles: [GitChange] = []
    @Published private(set) var prInfo: PullRequestGitInfo?
    /// The `base...head` range diffs run over, set once the refs are fetched —
    /// the Files tab shows a spinner until this lands.
    @Published private(set) var prDiffRange: String?
    @Published private(set) var isFetchingDiffRefs = false
    @Published private(set) var isCheckingOut = false
    @Published var checkoutError: String?

    /// Fetches the PR's refs once per opened detail, so file rows diff locally
    /// (JetBrains' trick: read the code without checking anything out).
    func prepareDiffRefs() async {
        guard prDiffRange == nil, !isFetchingDiffRefs,
              let item = openItem, let info = prInfo
        else { return }
        isFetchingDiffRefs = true
        prDiffRange = await GitService.fetchPullRequestRef(
            number: item.number, baseRef: info.baseRef, in: repoRoot)
        isFetchingDiffRefs = false
    }

    func checkout() async {
        guard let item = openItem, let info = prInfo, !isCheckingOut else { return }
        isCheckingOut = true
        checkoutError = await GitService.checkoutPullRequest(
            number: item.number, headRef: info.headRef,
            crossRepository: info.crossRepository, in: repoRoot)
        isCheckingOut = false
    }
}
