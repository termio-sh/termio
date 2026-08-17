import Foundation
import Security

/// Claude Code's usage, read from the credential the CLI leaves on disk.
///
/// Plan limits come from `/api/oauth/usage` with the OAuth bearer in
/// `~/.claude/.credentials.json` (a plain file, no prompt) or, only when
/// allowed, the `Claude Code-credentials` Keychain item the CLI writes on macOS.
/// The endpoint needs the `user:profile` scope, which Claude Code's tokens carry.
/// Token totals come from the per-session JSONL logs, and Claude is the one agent
/// termio can price, so its scan carries a dollar estimate.
struct ClaudeUsageProvider: UsageProvider {
    var agent: AgentPreset { .claudeCode }

    /// Claude Code has no home-directory override, so this one is fixed.
    private var home: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    // MARK: - Plan limits

    /// `five_hour` → session lane, `seven_day` → weekly lane.
    func planLimits(allowKeychain: Bool) async -> PlanLimitReading {
        let credential = accessToken(allowKeychain: allowKeychain)
        guard case .token(let token) = credential else {
            return PlanLimitReading(keychainDeclined: credential == .keychainDeclined)
        }
        guard let request = request(
            "https://api.anthropic.com/api/oauth/usage",
            bearer: token,
            headers: ["anthropic-beta": "oauth-2025-04-20"]),
            let payload: ClaudeUsageResponse = await getJSON(request) else { return .none }

        return PlanLimitReading([
            payload.five_hour?.window(label: "5h"),
            payload.seven_day?.window(label: "Weekly"),
        ].compactMap { $0 })
    }

    // MARK: - Credentials

    /// How a credential lookup ended: a usable token, nothing readable, or the
    /// user actively refusing the Keychain prompt (which the caller must
    /// remember, not retry).
    private enum Credential: Equatable {
        case token(String)
        case unavailable
        case keychainDeclined
    }

    private func accessToken(allowKeychain: Bool) -> Credential {
        let file = home.appendingPathComponent(".credentials.json")
        if let token = jsonObject(at: file).flatMap(parseToken) { return .token(token) }
        guard allowKeychain else { return .unavailable }
        switch keychainPassword(service: "Claude Code-credentials") {
        case .success(let data):
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = parseToken(root) else { return .unavailable }
            return .token(token)
        case .declined:
            return .keychainDeclined
        case .unavailable:
            return .unavailable
        }
    }

    private func parseToken(_ root: [String: Any]) -> String? {
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        return oauth["accessToken"] as? String
    }

    private enum KeychainRead {
        case success(Data)
        /// The user refused the system's access prompt (Deny, or cancelling the
        /// unlock dialog) — distinct from "nothing there" so it can be remembered.
        case declined
        case unavailable
    }

    /// Reads a generic-password Keychain item by service name. This is what the
    /// Claude CLI uses on macOS; the read may raise the system's Keychain access
    /// prompt ("Always Allow" makes it silent), so callers must only reach here as
    /// the direct result of a user action.
    private func keychainPassword(service: String) -> KeychainRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data else { return .unavailable }
            return .success(data)
        case errSecAuthFailed, errSecUserCanceled:
            return .declined
        default:
            return .unavailable
        }
    }

    // MARK: - Token usage

    /// Scans Claude Code's per-session JSONL logs (`~/.claude/projects/**/*.jsonl`)
    /// and totals tokens + estimated cost into the windows and per-day buckets.
    /// Each line is one API turn carrying `message.usage` and `message.model`.
    /// Duplicate turns (re-emitted on resume) are de-duplicated by request id.
    func tokenUsage(in windows: DateWindows) -> AgentTokenUsage {
        var tally = TokenTally(windows, hasCost: true)
        UsageLog.records(
            under: home.appendingPathComponent("projects"),
            probe: Data("\"usage\"".utf8), since: windows.scanStart,
            isLog: { $0.pathExtension == "jsonl" }
        ) { object in
            guard let timestampString = object["timestamp"] as? String,
                  let timestamp = UsageTime.logTimestamp(timestampString),
                  timestamp >= windows.scanStart,
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }
            let id = (object["requestId"] as? String) ?? (message["id"] as? String)
            guard !tally.isDuplicate(id) else { return }

            let price = ModelPrice.forClaudeModel(message["model"] as? String ?? "")
            let input = usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            tally.add(TokenWindowStats(
                input: input, output: output, cacheWrite: cacheWrite, cacheRead: cacheRead,
                costUSD: Double(input) * price.input + Double(output) * price.output
                    + Double(cacheWrite) * price.cacheWrite + Double(cacheRead) * price.cacheRead),
                at: timestamp)
        }
        return tally.result
    }
}

// MARK: - Wire format

/// Just the fields termio reads from Claude's `/api/oauth/usage`. The response
/// carries many more lanes (model-specific weekly, extra usage); the session and
/// weekly windows are all the footer needs.
private struct ClaudeUsageResponse: Decodable {
    let five_hour: ClaudeLane?
    let seven_day: ClaudeLane?
}

private struct ClaudeLane: Decodable {
    let utilization: Double?
    let resets_at: String?

    /// A window for this lane, or `nil` when the lane has no utilization to show.
    func window(label: String) -> UsageWindow? {
        guard let utilization else { return nil }
        return UsageWindow(
            label: label,
            usedPercent: Int(utilization.rounded()),
            resetsAt: resets_at.flatMap(UsageTime.iso8601)
        )
    }
}

// MARK: - Pricing

/// Per-token prices for the models termio can price, in dollars. Cache-write is
/// the 5-minute ephemeral rate (1.25× input); cache-read is 0.1× input — the
/// economics the prompt-caching docs specify. Source: the claude-api skill's
/// current pricing table (Fable 5 $10/$50, Opus 4.8 $5/$25, Sonnet 4.6 $3/$15,
/// Haiku 4.5 $1/$5 per million). Kept in one place so a price change is a
/// one-line edit.
private struct ModelPrice {
    let input: Double
    let output: Double
    let cacheWrite: Double
    let cacheRead: Double

    static func perMillion(input: Double, output: Double) -> ModelPrice {
        ModelPrice(
            input: input / 1_000_000,
            output: output / 1_000_000,
            cacheWrite: input * 1.25 / 1_000_000,
            cacheRead: input * 0.1 / 1_000_000
        )
    }

    /// Matches a Claude model id (e.g. `claude-opus-4-8`) to its tier by family
    /// name, so a new dated snapshot still prices correctly. An unknown model
    /// falls back to Opus — not the top of the range (Fable is costlier), so a
    /// genuinely unrecognised premium model can under-count; the named tiers
    /// below keep every model termio actually sees priced exactly. (CodexBar's
    /// answer to this is a live models.dev catalog; termio stays a flat table.)
    static func forClaudeModel(_ model: String) -> ModelPrice {
        let lowered = model.lowercased()
        if lowered.contains("fable") { return .perMillion(input: 10, output: 50) }
        if lowered.contains("haiku") { return .perMillion(input: 1, output: 5) }
        if lowered.contains("sonnet") { return .perMillion(input: 3, output: 15) }
        return .perMillion(input: 5, output: 25)
    }
}
