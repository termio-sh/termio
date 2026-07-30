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

    /// How the user can recover from a failed load, so the error state offers the *right* action.
    /// `reauthorize` (the reconnect / grant-org path) is reserved for a genuine access 403 — a
    /// valid token with no rights to this repo. Everything else (rate limits, 404, 5xx, network,
    /// decode) is `retry`, since reconnecting can't fix it. `nil` when there's no error.
    enum Recovery { case reauthorize, retry }
    @Published private(set) var recovery: Recovery?
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

    /// Whether the one-time resolve-and-load has run for this model. The model is registered on
    /// the store (see `TermioStore.registerIssuesModel`), whose `.task` re-fires on every remount
    /// — so the initial git resolve + list pull must run once, not on each maximize toggle.
    private var didStart = false

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
        guard !didStart else { return }
        didStart = true
        await resolveContainer()
        await loadList()
    }

    // MARK: Connect / disconnect

    /// Runs the whole device flow: shows the code, opens the verification page,
    /// polls until approved, then loads the pane.
    func connect() async {
        errorMessage = nil
        recovery = nil
        do {
            let code = try await GitHubIssueAuth.requestDeviceCode()
            phase = .connecting(userCode: code.userCode)
            NSWorkspace.shared.open(code.verificationURL)
            let token = try await GitHubIssueAuth.waitForToken(code)
            GitHubIssueAuth.store(token: token)
            provider = GitHubIssueProvider(token: token)
            didStart = true
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
        didStart = false
        phase = .disconnected
        errorMessage = nil
        recovery = nil
    }

    /// Recover from a non-401 failure (typically a 403: the token is valid but has
    /// no rights to *this* repo). A 401 self-heals via `disconnect()` in `loadList`,
    /// but a 403 leaves the pane bound-yet-empty with no way out — so drop the token
    /// and re-run the device flow, letting the user approve under a different account
    /// (or after granting termio org access, see `openConnectionSettings`).
    func reconnect() async {
        disconnect()
        await connect()
    }

    /// Opens the OAuth app's connections page, where the user grants termio access
    /// to the org that owns a private repo — the fix a bare reconnect can't make,
    /// since GitHub re-issues the same token without re-prompting for org grants.
    func openConnectionSettings() {
        NSWorkspace.shared.open(GitHubIssueAuth.settingsURL)
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
        recovery = nil
        do {
            items = try await provider.issues(in: container, query: query)
        } catch {
            // A revoked token must degrade to the connect zero state, not wedge.
            if case GitHubIssueProvider.APIError.status(401) = error {
                disconnect()
            } else if case GitHubIssueProvider.APIError.status(403) = error {
                // A genuine 403 (rate-limit 403s are classified as `.rateLimited` upstream) means
                // the token is valid but has no rights to *this* repo — usually an org that hasn't
                // authorized termio. This is the one case reconnect / grant-org access can fix.
                errorMessage = error.localizedDescription
                recovery = .reauthorize
            } else {
                // Rate limits, 404, 5xx, decode, network: reconnecting won't help — offer a retry.
                errorMessage = error.localizedDescription
                recovery = .retry
            }
        }
        isLoading = false
    }

    func loadDetail(for item: IssueSummary) async {
        guard let provider, let container else { return }
        // Maximizing hoists the detail into the full-window host, which remounts the view and
        // re-fires its `.task` — but the model outlives that. Skip the wipe-and-refetch when this
        // exact item is already loaded, so a layout change costs no spinner or network round-trip.
        if openItem?.number == item.number, detail != nil { return }
        // The model's own record of which item is open, independent of what drives the UI.
        openItem = item
        detail = nil
        detailError = nil
        prFiles = []
        prFilePatches = [:]
        prInfo = nil
        do {
            if item.kind == .pullRequest {
                async let loadedDetail = provider.detail(item.number, in: container)
                async let info = provider.pullRequestGitInfo(item.number, in: container)
                async let files = provider.pullRequestFiles(item.number, in: container)
                let loadedFiles = try await files
                (detail, prInfo) = try await (loadedDetail, info)
                prFiles = loadedFiles.map(\.change)
                // The diff arrives inline with the file list — key each file's patch by
                // path so the Files tab renders with no further network or git work.
                prFilePatches = Dictionary(
                    uniqueKeysWithValues: loadedFiles.compactMap { file in
                        file.patch.map { (file.change.path, $0) }
                    })
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
    /// Each file's inline unified-diff patch from the API, keyed by path — what the Files
    /// tab renders. Absent keys are files GitHub gave no patch for (binary / too large).
    @Published private(set) var prFilePatches: [String: String] = [:]
    @Published private(set) var prInfo: PullRequestGitInfo?
}
