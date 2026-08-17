import Foundation

/// Codex's usage, read from the OAuth bearer in `$CODEX_HOME/auth.json`
/// (default `~/.codex`). No dollar estimate anywhere: termio doesn't carry
/// OpenAI model pricing.
struct CodexUsageProvider: UsageProvider {
    var agent: AgentPreset { .codex }

    private var home: URL { cliHome(environment: "CODEX_HOME", directory: ".codex") }

    // MARK: - Plan limits

    /// `rate_limit.primary_window` / `secondary_window` are the active lanes; the
    /// lane's `limit_window_seconds` names the period so a free-plan monthly
    /// window isn't mislabelled "session".
    func planLimits(allowKeychain: Bool) async -> PlanLimitReading {
        guard let tokens = jsonObject(at: home.appendingPathComponent("auth.json"))?["tokens"]
                as? [String: Any],
              let token = tokens["access_token"] as? String,
              let request = request("https://chatgpt.com/backend-api/wham/usage", bearer: token),
              let payload: CodexUsageResponse = await getJSON(request),
              let limit = payload.rate_limit else { return .none }

        return PlanLimitReading(
            [limit.primary_window, limit.secondary_window].compactMap { $0?.window() })
    }

    // MARK: - Token usage

    /// Scans Codex's rollout logs (`$CODEX_HOME/sessions/YYYY/MM/DD/*.jsonl`) for
    /// `token_count` events and totals tokens into the windows and per-day
    /// buckets. The date is in the directory path, so whole days before the scan
    /// window are skipped without opening a file. Codex's `last_token_usage` is
    /// the per-turn delta (its `total_token_usage` is cumulative — summing that
    /// would double-count).
    func tokenUsage(in windows: DateWindows) -> AgentTokenUsage {
        var tally = TokenTally(windows)
        let probe = Data("token_count".utf8)
        for directory in dayDirectories(
            under: home.appendingPathComponent("sessions"), onOrAfter: windows.scanStart) {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil) else { continue }
            for url in files where url.pathExtension == "jsonl" {
                UsageLog.records(in: url, probe: probe) { object in
                    guard let timestampString = object["timestamp"] as? String,
                          let timestamp = UsageTime.logTimestamp(timestampString),
                          timestamp >= windows.scanStart,
                          let payload = object["payload"] as? [String: Any],
                          payload["type"] as? String == "token_count",
                          let info = payload["info"] as? [String: Any],
                          let last = info["last_token_usage"] as? [String: Any] else { return }

                    let inputTotal = last["input_tokens"] as? Int ?? 0
                    let cached = last["cached_input_tokens"] as? Int ?? 0
                    tally.add(TokenWindowStats(
                        input: max(0, inputTotal - cached),
                        output: last["output_tokens"] as? Int ?? 0,
                        cacheRead: cached), at: timestamp)
                }
            }
        }
        return tally.result
    }

    /// Codex day-directories at or after `start`, read from the `YYYY/MM/DD` path
    /// layout so old sessions are never opened. A malformed path component just
    /// skips that branch rather than failing the scan.
    private func dayDirectories(under root: URL, onOrAfter start: Date) -> [URL] {
        let manager = FileManager.default
        let calendar = Calendar.current
        func children(_ url: URL) -> [URL] {
            (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        }
        var result: [URL] = []
        for year in children(root) {
            guard let yearValue = Int(year.lastPathComponent) else { continue }
            for month in children(year) {
                guard let monthValue = Int(month.lastPathComponent) else { continue }
                for day in children(month) {
                    guard let dayValue = Int(day.lastPathComponent),
                          let date = calendar.date(from: DateComponents(
                            year: yearValue, month: monthValue, day: dayValue)),
                          date >= calendar.startOfDay(for: start) else { continue }
                    result.append(day)
                }
            }
        }
        return result
    }
}

// MARK: - Wire format

private struct CodexUsageResponse: Decodable {
    let rate_limit: CodexRateLimit?
}

private struct CodexRateLimit: Decodable {
    let primary_window: CodexWindow?
    let secondary_window: CodexWindow?
}

private struct CodexWindow: Decodable {
    let used_percent: Double?
    let limit_window_seconds: Double?
    let reset_after_seconds: Double?
    let reset_at: Double?

    func window() -> UsageWindow? {
        guard let used_percent else { return nil }
        return UsageWindow(
            label: UsageWindow.label(forSeconds: limit_window_seconds),
            usedPercent: Int(used_percent.rounded()),
            resetsAt: resetDate()
        )
    }

    /// Prefers the absolute `reset_at` (unix seconds); falls back to "now plus the
    /// remaining seconds" when only a relative value is given.
    private func resetDate() -> Date? {
        if let reset_at { return Date(timeIntervalSince1970: reset_at) }
        if let reset_after_seconds { return Date().addingTimeInterval(reset_after_seconds) }
        return nil
    }
}
