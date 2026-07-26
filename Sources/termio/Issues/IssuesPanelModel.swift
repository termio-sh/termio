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

    func loadList() async {
        guard let provider, let container, phase == .ready else { return }
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
        do {
            detail = try await provider.detail(item.number, in: container)
        } catch {
            detailError = error.localizedDescription
        }
    }
}
