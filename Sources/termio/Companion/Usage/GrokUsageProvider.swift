import Foundation

/// Grok's usage, read from the OIDC entry in `$GROK_HOME/auth.json`
/// (default `~/.grok`). No dollar estimate anywhere: termio doesn't carry xAI
/// pricing.
struct GrokUsageProvider: UsageProvider {
    var agent: AgentPreset { .grok }

    private var home: URL { cliHome(environment: "GROK_HOME", directory: ".grok") }
    private var credentialFile: URL { home.appendingPathComponent("auth.json") }

    // MARK: - Plan limits

    /// The CLI's chat proxy answers to the bearer alone, no extra headers.
    /// `creditUsagePercent` is the plan's fill and `currentPeriod` names the
    /// window and when it resets.
    func planLimits(allowKeychain: Bool) async -> PlanLimitReading {
        guard let token = await accessToken(),
              let request = request(
                "https://cli-chat-proxy.grok.com/v1/billing?format=credits", bearer: token),
              let config = await getObject(request)?["config"] as? [String: Any],
              let percent = number(config["creditUsagePercent"]) else { return .none }

        let period = config["currentPeriod"] as? [String: Any]
        let type = (period?["type"] as? String) ?? ""
        let label = type.contains("WEEK") ? "Weekly"
            : type.contains("MONTH") ? "Monthly" : "Usage"
        return PlanLimitReading([UsageWindow(
            label: label,
            usedPercent: Int(percent.rounded()),
            resetsAt: (period?["end"] as? String).flatMap(UsageTime.iso8601))])
    }

    // MARK: - Credentials

    /// One entry of `auth.json`'s scope→credential map. `key` is the access
    /// token; `expires_at` is an RFC 3339 string.
    private struct Credential {
        /// The entry's key in the map, needed for the write-back.
        var scope: String
        var accessToken: String
        var refreshToken: String
        var issuer: String
        var clientId: String
        var expiresAt: Date
    }

    /// The OIDC entry, or the first usable entry when none is marked as such.
    /// API-key entries are skipped where an OIDC one exists — the billing
    /// endpoint doesn't answer for them, the same reason the CLI hides its own
    /// /usage there.
    private func credential() -> Credential? {
        guard let scopes = jsonObject(at: credentialFile) else { return nil }
        var fallback: Credential?
        for (scope, value) in scopes {
            guard let entry = value as? [String: Any],
                  let key = entry["key"] as? String, !key.isEmpty,
                  let refreshToken = entry["refresh_token"] as? String, !refreshToken.isEmpty,
                  let expiresAt = (entry["expires_at"] as? String)
                    .flatMap(UsageTime.iso8601) else { continue }
            let credential = Credential(
                scope: scope, accessToken: key, refreshToken: refreshToken,
                issuer: (entry["oidc_issuer"] as? String) ?? "https://auth.x.ai",
                clientId: (entry["oidc_client_id"] as? String) ?? "",
                expiresAt: expiresAt)
            if entry["auth_mode"] as? String == "oidc" { return credential }
            fallback = fallback ?? credential
        }
        return fallback
    }

    /// A usable access token. The CLI treats a token as dead five minutes before
    /// `expires_at`; under that buffer this refreshes via OIDC discovery.
    private func accessToken() async -> String? {
        guard let stored = credential() else { return nil }
        if stored.expiresAt.timeIntervalSinceNow > 300 { return stored.accessToken }
        return await refresh(stored)?.accessToken
    }

    /// Exchanges the refresh token at the discovered token endpoint and persists
    /// the rotated pair. As with Kimi, the write-back is skipped when the file's
    /// refresh token changed under us — a running CLI refreshed concurrently and
    /// its newer pair must win.
    private func refresh(_ stale: Credential) async -> Credential? {
        guard let discovery = request("\(stale.issuer)/.well-known/openid-configuration"),
              let endpoint = await getObject(discovery)?["token_endpoint"] as? String,
              let response = await postForm(endpoint, fields: [
                "grant_type": "refresh_token",
                "refresh_token": stale.refreshToken,
                "client_id": stale.clientId,
              ]),
              let accessToken = response["access_token"] as? String else { return nil }
        // The CLI falls back to a 30-day TTL when the response carries no expiry.
        let expiresIn = (response["expires_in"] as? Double) ?? 30 * 86_400
        let refreshed = Credential(
            scope: stale.scope, accessToken: accessToken,
            refreshToken: (response["refresh_token"] as? String) ?? stale.refreshToken,
            issuer: stale.issuer, clientId: stale.clientId,
            expiresAt: Date().addingTimeInterval(expiresIn))
        if credential()?.refreshToken == stale.refreshToken { persist(refreshed) }
        return refreshed
    }

    /// Rewrites `auth.json` with the rotated pair inside its scope entry, keeping
    /// the other scopes and the entry's profile fields.
    private func persist(_ credential: Credential) {
        guard var root = jsonObject(at: credentialFile),
              var entry = root[credential.scope] as? [String: Any] else { return }
        entry["key"] = credential.accessToken
        entry["refresh_token"] = credential.refreshToken
        entry["expires_at"] = UsageTime.iso8601(credential.expiresAt)
        root[credential.scope] = entry
        write(root, to: credentialFile)
    }

    // MARK: - Token usage

    /// Scans the session updates (`$GROK_HOME/sessions/*/*/updates.jsonl`) for
    /// `turn_completed` rows — one per prompt, de-duplicated by `prompt_id` —
    /// and totals tokens into the windows and per-day buckets. `inputTokens`
    /// counts the cache lanes too, so they are split out to keep the total
    /// matching Grok's own `totalTokens`.
    func tokenUsage(in windows: DateWindows) -> AgentTokenUsage {
        var tally = TokenTally(windows)
        UsageLog.records(
            under: home.appendingPathComponent("sessions"),
            probe: Data("\"turn_completed\"".utf8), since: windows.scanStart,
            isLog: { $0.lastPathComponent == "updates.jsonl" }
        ) { object in
            guard let seconds = object["timestamp"] as? Double,
                  let params = object["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any],
                  update["sessionUpdate"] as? String == "turn_completed",
                  let usage = update["usage"] as? [String: Any] else { return }
            let timestamp = Date(timeIntervalSince1970: seconds)
            guard timestamp >= windows.scanStart,
                  !tally.isDuplicate(update["prompt_id"] as? String) else { return }

            let inputTotal = usage["inputTokens"] as? Int ?? 0
            let cacheRead = usage["cachedReadTokens"] as? Int ?? 0
            let cacheWrite = usage["cacheCreationTokens"] as? Int ?? 0
            tally.add(TokenWindowStats(
                input: max(0, inputTotal - cacheRead - cacheWrite),
                output: usage["outputTokens"] as? Int ?? 0,
                cacheWrite: cacheWrite, cacheRead: cacheRead), at: timestamp)
        }
        return tally.result
    }
}
