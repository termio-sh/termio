import Combine
import Foundation

/// Reads the usage of the coding agents termio runs, on demand.
///
/// The data comes for free: termio already launches `claude`, `codex`, `kimi`,
/// and `grok`, and those CLIs leave OAuth credentials and session logs on disk.
/// We reuse exactly those — no login flow, no stored passwords — the same
/// approach as steipete's CodexBar. Each agent's reading lives behind a
/// `UsageProvider`; this type only knows the list, so only agents with a clean
/// local-cred endpoint appear and the rest simply show nothing.
///
/// Reading another app's data is opt-in per agent (`usageAuthorizedAgents`), and
/// nothing runs in the background: refreshes happen only when the Usage tab asks.
/// Claude's Keychain credential is doubly gated — a Deny on the macOS prompt is
/// remembered (`claudeKeychainDeclined`) and never retried automatically, so the
/// system prompt can only ever appear as the direct result of a click in the tab.
///
/// Every failure is swallowed into "no reading" rather than surfaced as an error:
/// the endpoints are private and may change, and a usage strip is an ambient
/// convenience that must never get in the way of the terminal.
@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var usage: [AgentPreset: AgentUsage] = [:]

    /// Today / this-week / this-month token totals per agent, scanned from each
    /// agent's own local session logs. This is the "what have I actually burned"
    /// view — independent of how the plan bills — the same thing ccusage computes.
    @Published private(set) var tokenUsage: [AgentPreset: AgentTokenUsage] = [:]

    /// Every agent termio can read usage for. Supporting one more is a new
    /// provider file plus a line here.
    private static let providers: [any UsageProvider] = [
        ClaudeUsageProvider(), CodexUsageProvider(), KimiUsageProvider(), GrokUsageProvider(),
    ]

    /// The agents with a usable local-credential usage source. Kept here so the
    /// UI can ask "is this agent monitorable?" without duplicating the list.
    static let supportedAgents: [AgentPreset] = providers.map(\.agent)

    private let settings: AppSettings
    private var refreshTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    /// Whether a local-log scan is currently running, so overlapping `refresh()`
    /// calls let it finish instead of cancelling and restarting it forever.
    private var isScanning = false
    /// When the heavy local-log scan last published, so routine refreshes can skip
    /// re-reading gigabytes of logs that have barely changed.
    private var lastTokenScan: Date?
    /// How stale token totals may get before an automatic refresh re-scans. The
    /// plan-limit lanes refresh on the faster `interval`; the log scan is far
    /// heavier (it reads every session file), so it runs much less often.
    private let tokenScanMaxAge: TimeInterval = 1800

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Refreshes both surfaces, re-scanning the logs only if the totals have gone
    /// stale. The cheap path for the Usage tab appearing.
    func refresh() {
        refreshPlanLimits()
        scanTokens(force: false)
    }

    /// Refreshes both and forces a fresh log scan regardless of age — the Refresh
    /// button's "I want it now".
    func forceRefresh() {
        refreshPlanLimits()
        scanTokens(force: true)
    }

    /// The providers for agents the user has both enabled and allowed termio to
    /// read. Nothing else is ever touched.
    private var authorizedProviders: [any UsageProvider] {
        Self.providers.filter {
            settings.isAgentEnabled($0.agent) && settings.isUsageAuthorized($0.agent)
        }
    }

    /// Fetches every authorized agent's plan limits off the main actor and
    /// publishes them. An agent that errors is dropped from the map (its row
    /// disappears) rather than left showing a stale number.
    private func refreshPlanLimits() {
        let providers = authorizedProviders
        let allowKeychain = !settings.claudeKeychainDeclined
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            var fetched: [AgentPreset: AgentUsage] = [:]
            var keychainDeclined = false
            for provider in providers {
                let reading = await provider.planLimits(allowKeychain: allowKeychain)
                if let usage = reading.usage { fetched[provider.agent] = usage }
                if reading.keychainDeclined { keychainDeclined = true }
            }
            guard !Task.isCancelled else { return }
            let declined = keychainDeclined
            await MainActor.run {
                guard let self else { return }
                self.usage = fetched
                // The user said No to the macOS Keychain prompt: remember it so
                // nothing asks again until they explicitly retry from the tab.
                if declined { self.settings.claudeKeychainDeclined = true }
            }
        }
    }

    /// Scans the local session logs for token totals, off the main actor.
    ///
    /// Skipped entirely when a scan is already running (the multi-second walk must
    /// run to completion — restarting it on every `refresh()` would mean it never
    /// finishes) or, unless `force`d, when the last scan is still fresh. The
    /// published `tokenUsage` is never cleared between scans, so the Usage tab
    /// shows the last totals instantly while a fresh scan runs underneath.
    private func scanTokens(force: Bool) {
        guard !isScanning else { return }
        if !force, let last = lastTokenScan, Date().timeIntervalSince(last) < tokenScanMaxAge {
            return
        }
        let providers = authorizedProviders
        isScanning = true
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let windows = DateWindows()
            var scanned: [AgentPreset: AgentTokenUsage] = [:]
            for provider in providers {
                let usage = provider.tokenUsage(in: windows)
                if !usage.isEmpty { scanned[provider.agent] = usage }
            }
            let result = scanned
            await self?.finishTokenScan(result)
        }
    }

    @MainActor
    private func finishTokenScan(_ result: [AgentPreset: AgentTokenUsage]) {
        tokenUsage = result
        lastTokenScan = Date()
        isScanning = false
    }
}
