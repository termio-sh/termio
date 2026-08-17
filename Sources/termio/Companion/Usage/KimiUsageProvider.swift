import Foundation

/// Kimi Code's usage, read from the OAuth pair its CLI stores in
/// `$KIMI_CODE_HOME/credentials/kimi-code.json` (default `~/.kimi-code`; the
/// legacy `~/.kimi` home predates the rename and is not read). No dollar
/// estimate anywhere: termio doesn't carry Kimi pricing.
struct KimiUsageProvider: UsageProvider {
    var agent: AgentPreset { .kimi }

    private var home: URL { cliHome(environment: "KIMI_CODE_HOME", directory: ".kimi-code") }
    private var credentialFile: URL {
        home.appendingPathComponent("credentials/kimi-code.json")
    }

    // MARK: - Plan limits

    /// The `/usages` payload is a weekly summary lane plus rolling rate-limit
    /// windows (e.g. the 5-hour one), with absolute used/limit counts rather than
    /// percents. The endpoint is private and its key spellings have drifted, so
    /// the read is dictionary-tolerant instead of Codable — mirroring the CLI's
    /// own deliberately loose parser.
    func planLimits(allowKeychain: Bool) async -> PlanLimitReading {
        guard let token = await accessToken(),
              let request = request("https://api.kimi.com/coding/v1/usages", bearer: token),
              let payload = await getObject(request) else { return .none }

        var windows: [UsageWindow] = []
        if let summary = payload["usage"] as? [String: Any],
           let window = window(summary, label: "Weekly", reset: resetDate(summary)) {
            windows.append(window)
        }
        for lane in payload["limits"] as? [[String: Any]] ?? [] {
            let detail = (lane["detail"] as? [String: Any]) ?? lane
            let label = windowLabel(lane["window"] as? [String: Any])
                ?? lane["name"] as? String ?? "Usage"
            let reset = resetDate(lane) ?? resetDate(detail)
            if let window = window(detail, label: label, reset: reset) {
                windows.append(window)
            }
        }
        return PlanLimitReading(windows)
    }

    /// A window for one lane: used/limit counts to a percent, `nil` when the lane
    /// has nothing measurable. `used` falls back to `limit - remaining`, the other
    /// spelling the service has shipped.
    private func window(_ lane: [String: Any], label: String, reset: Date?) -> UsageWindow? {
        guard let limit = number(lane["limit"]), limit > 0 else { return nil }
        guard let used = number(lane["used"])
            ?? number(lane["remaining"]).map({ limit - $0 }) else { return nil }
        return UsageWindow(
            label: label,
            usedPercent: Int((used / limit * 100).rounded()),
            resetsAt: reset)
    }

    /// The reset instant of a lane, tolerating every key the service has used:
    /// absolute ISO strings (`resetAt`/`reset_at`/`resetTime`/`reset_time`) or
    /// relative seconds (`reset_in`/`resetIn`/`ttl`).
    private func resetDate(_ lane: [String: Any]) -> Date? {
        for key in ["resetAt", "reset_at", "resetTime", "reset_time"] {
            if let string = lane[key] as? String, let date = UsageTime.iso8601(string) {
                return date
            }
        }
        for key in ["reset_in", "resetIn", "ttl"] {
            if let seconds = number(lane[key]) { return Date().addingTimeInterval(seconds) }
        }
        return nil
    }

    /// Names a rate-limit window from its duration, in the shared vocabulary.
    /// `timeUnit` arrives in proto-enum form (`TIME_UNIT_MINUTE`).
    private func windowLabel(_ window: [String: Any]?) -> String? {
        guard let duration = number(window?["duration"]),
              let unit = (window?["timeUnit"] as? String)?.uppercased() else { return nil }
        let multiplier: Double = unit.contains("MINUTE") ? 60
            : unit.contains("HOUR") ? 3600
            : unit.contains("DAY") ? 86_400 : 0
        let seconds = duration * multiplier
        return seconds > 0 ? UsageWindow.label(forSeconds: seconds) : nil
    }

    // MARK: - Credentials

    /// The OAuth pair the CLI stores. The access token lives 15 minutes, so a
    /// read almost always refreshes first, and the rotated pair must be written
    /// back or the stored token dies.
    private struct Credential {
        var accessToken: String
        var refreshToken: String
        /// Unix seconds.
        var expiresAt: TimeInterval
        var expiresIn: TimeInterval
    }

    private func credential() -> Credential? {
        guard let root = jsonObject(at: credentialFile),
              let accessToken = root["access_token"] as? String, !accessToken.isEmpty,
              let refreshToken = root["refresh_token"] as? String, !refreshToken.isEmpty,
              let expiresAt = root["expires_at"] as? Double else { return nil }
        return Credential(
            accessToken: accessToken, refreshToken: refreshToken,
            expiresAt: expiresAt, expiresIn: (root["expires_in"] as? Double) ?? 900)
    }

    /// A usable access token, refreshing first when the stored one is inside the
    /// CLI's own trigger window (under half the token's life, floored at five
    /// minutes). Any failure is "no reading" — termio never writes the CLI's
    /// logged-out tombstone.
    private func accessToken() async -> String? {
        guard let stored = credential() else { return nil }
        let threshold = max(300, stored.expiresIn / 2)
        if stored.expiresAt - Date().timeIntervalSince1970 >= threshold {
            return stored.accessToken
        }
        return await refresh(stored)?.accessToken
    }

    /// Exchanges the refresh token at the CLI's OAuth host and persists the
    /// rotated pair. The write-back is skipped when the file's refresh token has
    /// changed under us — that's the CLI having refreshed concurrently, and its
    /// newer pair must win (overwriting it would strand the CLI logged out).
    private func refresh(_ stale: Credential) async -> Credential? {
        guard let response = await postForm(
            "https://auth.kimi.com/api/oauth/token",
            fields: [
                "client_id": "17e5f671-d194-4dfb-9706-5516cb48c098",
                "grant_type": "refresh_token",
                "refresh_token": stale.refreshToken,
            ]),
            let accessToken = response["access_token"] as? String else { return nil }
        let expiresIn = (response["expires_in"] as? Double) ?? stale.expiresIn
        let refreshed = Credential(
            accessToken: accessToken,
            refreshToken: (response["refresh_token"] as? String) ?? stale.refreshToken,
            expiresAt: Date().timeIntervalSince1970 + expiresIn,
            expiresIn: expiresIn)
        if credential()?.refreshToken == stale.refreshToken { persist(refreshed) }
        return refreshed
    }

    /// Rewrites the credential file with the rotated pair, keeping any other
    /// fields the CLI stores there.
    private func persist(_ credential: Credential) {
        var root = jsonObject(at: credentialFile) ?? [:]
        root["access_token"] = credential.accessToken
        root["refresh_token"] = credential.refreshToken
        root["expires_in"] = credential.expiresIn
        // Whole seconds, the CLI's own wire shape — a fractional double would
        // read fine today but is a needless divergence to debug later.
        root["expires_at"] = Int(credential.expiresAt)
        write(root, to: credentialFile)
    }

    // MARK: - Token usage

    /// Scans the wire logs (`$KIMI_CODE_HOME/sessions/*/*/agents/*/wire.jsonl`)
    /// for `usage.record` events and totals tokens into the windows and per-day
    /// buckets. One record per LLM step plus one per compaction summary — both
    /// count, so nothing is filtered by `usageScope`. Records carry no id, so
    /// there is no de-dup: a forked session's copied history double-counts while
    /// the fork is inside the scan window.
    func tokenUsage(in windows: DateWindows) -> AgentTokenUsage {
        var tally = TokenTally(windows)
        UsageLog.records(
            under: home.appendingPathComponent("sessions"),
            probe: Data("\"usage.record\"".utf8), since: windows.scanStart,
            isLog: { $0.lastPathComponent == "wire.jsonl" }
        ) { object in
            guard object["type"] as? String == "usage.record",
                  let milliseconds = object["time"] as? Double else { return }
            let timestamp = Date(timeIntervalSince1970: milliseconds / 1000)
            guard timestamp >= windows.scanStart,
                  let usage = object["usage"] as? [String: Any] else { return }

            tally.add(TokenWindowStats(
                input: usage["inputOther"] as? Int ?? 0,
                output: usage["output"] as? Int ?? 0,
                cacheWrite: usage["inputCacheCreation"] as? Int ?? 0,
                cacheRead: usage["inputCacheRead"] as? Int ?? 0), at: timestamp)
        }
        return tally.result
    }
}
