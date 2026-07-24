import Foundation

/// Turns an agent transcript JSONL file into a single self-contained HTML document
/// rendered *inside* termio (loaded into the `TraceView` web overlay), not a browser.
/// Both Claude Code and Codex are understood — their on-disk schemas differ, so the
/// first line picks the parser (Codex opens with a `session_meta` header) — and both
/// render into the same dashboard-over-trace layout. Each line of the transcript is
/// one JSON object; we decode them leniently — skipping any line we can't read rather
/// than failing the whole render, so an evolving transcript schema degrades gracefully
/// — laid out as a dashboard (turn / tool-call / token stats) above a collapsible
/// conversation trace, all painted in the caller's live termio theme (see `TraceTheme`).
enum SessionTraceRenderer {
    enum RenderError: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let path): return "Could not read the transcript at \(path)."
            }
        }
    }

    /// Reads the JSONL at `jsonlPath` and returns a full HTML document string, themed
    /// with `theme`. The caller hands the string to a `WKWebView`.
    static func html(jsonlPath: String, title: String, theme: TraceTheme) throws -> String {
        // A conversation rotation (Claude Code's `/clear`) advances the transcript
        // pointer before the agent writes the new file — it appears on the first
        // message. Until then an absent file means "new conversation", not an error.
        guard FileManager.default.fileExists(atPath: jsonlPath) else {
            return placeholder(message: "New conversation — no messages yet.",
                               theme: theme, title: title)
        }
        guard let data = FileManager.default.contents(atPath: jsonlPath),
              let text = String(data: data, encoding: .utf8) else {
            throw RenderError.unreadable(jsonlPath)
        }

        let rows: [[String: Any]] = text
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                guard let d = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                else { return nil }
                return obj
            }

        // Codex rollouts open with a `session_meta` header. Grok is detected without
        // waiting for an assistant row (early sessions are system + synthetic users
        // only) — see `isGrokTranscript`. Everything else falls through to Claude.
        let isCodex = rows.first?["type"] as? String == "session_meta"
        let isGrok = !isCodex && isGrokTranscript(rows: rows, jsonlPath: jsonlPath)
        // Grok's chat_history.jsonl has no cwd/version/timestamps — those live in
        // the sibling `summary.json` in the same session directory.
        let grokMeta = isGrok ? grokSessionMeta(jsonlPath: jsonlPath) : nil
        let stats = isCodex ? analyzeCodex(rows) : isGrok ? analyzeGrok(rows, meta: grokMeta) : analyze(rows)
        let renderEntry = isCodex ? renderCodexEntry : isGrok ? renderGrokEntry : renderEntry
        let body = rows.map(renderEntry).filter { !$0.isEmpty }.joined(separator: "\n")
        return document(title: title, stats: stats, body: body, theme: theme)
    }

    /// A themed one-line page for when there is nothing to render yet — used by
    /// the companion server so a trace request always returns a valid document
    /// (never a fatal `.error` on the PTY-bridge socket).
    static func placeholder(message: String, theme: TraceTheme, title: String = "Trace") -> String {
        let body = "<div class=\"turn\"><div class=\"text\">\(escaped(message))</div></div>"
        return document(title: title, stats: Stats(), body: body, theme: theme)
    }

    // MARK: Stats

    /// Aggregate figures shown in the dashboard, gathered in one pass over the rows.
    private struct Stats {
        var userTurns = 0
        var assistantTurns = 0
        var toolCounts: [String: Int] = [:]
        var toolErrors = 0
        var inputTokens = 0
        var outputTokens = 0
        var cacheTokens = 0
        var models: Set<String> = []
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var cwd: String?
        var gitBranch: String?
        var version: String?
        var systemNotes: [String] = []

        var toolTotal: Int { toolCounts.values.reduce(0, +) }
    }

    /// Both Claude and Codex stamp their timestamps with fractional seconds
    /// (`…:01.327Z`), which the default `ISO8601DateFormatter` won't parse — so try the
    /// fractional format first and fall back to the plain one.
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()
    private static func date(from string: String) -> Date? {
        isoFractional.date(from: string) ?? iso.date(from: string)
    }

    private static func analyze(_ rows: [[String: Any]]) -> Stats {
        var s = Stats()
        for entry in rows {
            if let ts = entry["timestamp"] as? String, let date = date(from: ts) {
                if s.firstTimestamp == nil { s.firstTimestamp = date }
                s.lastTimestamp = date
            }
            if s.cwd == nil, let cwd = entry["cwd"] as? String { s.cwd = cwd }
            if s.gitBranch == nil, let b = entry["gitBranch"] as? String, !b.isEmpty { s.gitBranch = b }
            if s.version == nil, let v = entry["version"] as? String { s.version = v }

            let type = entry["type"] as? String
            if type == "system", let c = entry["content"] as? String, !c.isEmpty {
                s.systemNotes.append(c)
            }
            guard type == "user" || type == "assistant",
                  let message = entry["message"] as? [String: Any] else { continue }

            if let model = message["model"] as? String { s.models.insert(model) }
            if let usage = message["usage"] as? [String: Any] {
                s.inputTokens += (usage["input_tokens"] as? Int) ?? 0
                s.outputTokens += (usage["output_tokens"] as? Int) ?? 0
                s.cacheTokens += (usage["cache_read_input_tokens"] as? Int) ?? 0
                s.cacheTokens += (usage["cache_creation_input_tokens"] as? Int) ?? 0
            }

            let blocks = (message["content"] as? [[String: Any]]) ?? []
            let hasText = message["content"] is String
                || blocks.contains { ($0["type"] as? String) == "text" }
            if type == "user", hasText { s.userTurns += 1 }
            if type == "assistant", hasText { s.assistantTurns += 1 }

            for b in blocks {
                switch b["type"] as? String {
                case "tool_use":
                    let name = b["name"] as? String ?? "tool"
                    s.toolCounts[name, default: 0] += 1
                case "tool_result":
                    if (b["is_error"] as? Bool) ?? false { s.toolErrors += 1 }
                default:
                    break
                }
            }
        }
        return s
    }

    // MARK: Grok

    /// Whether `jsonlPath` / `rows` look like a Grok `chat_history.jsonl`.
    /// Prefer path and sibling metadata over waiting for an assistant with
    /// `model_id` — real sessions open with `system` + synthetic `user` rows
    /// and only later append an assistant.
    private static func isGrokTranscript(rows: [[String: Any]], jsonlPath: String) -> Bool {
        // Manifest-declared transcript name (and the only name Grok writes).
        if (jsonlPath as NSString).lastPathComponent == "chat_history.jsonl" {
            return true
        }
        // Sibling `summary.json` with Grok session fields.
        if grokSessionMeta(jsonlPath: jsonlPath) != nil {
            return true
        }
        // Row heuristics for paths that are not the declared name (e.g. a
        // hand-copied file): top-level assistant `model_id`, or ConversationItem
        // shape (user/assistant with top-level `content`, no Claude `message`
        // envelope) plus a system row.
        if rows.contains(where: {
            ($0["type"] as? String) == "assistant" && $0["model_id"] != nil
        }) {
            return true
        }
        let hasSystem = rows.contains { ($0["type"] as? String) == "system" }
        let hasFlatUser = rows.contains {
            ($0["type"] as? String) == "user"
                && $0["message"] == nil
                && $0["content"] != nil
        }
        return hasSystem && hasFlatUser
    }

    /// Grok's `chat_history.jsonl` schema: no `message` wrapper, `model_id` at
    /// top level, standalone `tool_result`/`reasoning` entries, and no token usage
    /// or timestamp fields — so the dashboard omits Tokens and Duration when
    /// those aren't available. Tool calls live on the assistant entry's
    /// `tool_calls` array rather than inside content blocks.
    /// `meta` is the sibling `summary.json` carrying cwd, model, git branch,
    /// and timestamps the chat history itself lacks.
    private static func analyzeGrok(_ rows: [[String: Any]], meta: GrokSessionMeta?) -> Stats {
        var s = Stats()

        // Session-level metadata from summary.json.
        if let meta {
            s.cwd = meta.cwd
            s.gitBranch = meta.gitBranch
            s.version = meta.version
            s.firstTimestamp = meta.createdAt
            s.lastTimestamp = meta.updatedAt
            if let model = meta.model { s.models.insert(model) }
            if let usage = meta.usage {
                s.inputTokens = usage.inputTokens
                s.outputTokens = usage.outputTokens
                s.cacheTokens = usage.cacheTokens
            }
        }

        for entry in rows {
            let type = entry["type"] as? String

            // Per-message model_id (may differ from the session-level model).
            if let model = entry["model_id"] as? String { s.models.insert(model) }

            switch type {
            case "system":
                // The system prompt is huge and not useful as metadata — skip.
                break
            case "user":
                // Runtime injections carry `synthetic_reason`; skip them for the
                // turn counter. Genuine turns (and the untagged `<user_info>`
                // preamble) are filtered by visible-content extraction below.
                if entry["synthetic_reason"] != nil { break }
                if let fullText = grokUserText(entry),
                   !grokExtractUserQuery(fullText).isEmpty {
                    s.userTurns += 1
                }
            case "assistant":
                // Mirror Claude: only text-bearing assistant rows count as turns.
                // Tool-only steps (empty `content` + `tool_calls`) still contribute
                // to the tool-call chart below.
                let text = (entry["content"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty { s.assistantTurns += 1 }
                if let toolCalls = entry["tool_calls"] as? [[String: Any]] {
                    for tc in toolCalls {
                        let name = tc["name"] as? String ?? "tool"
                        s.toolCounts[name, default: 0] += 1
                    }
                }
            case "tool_result":
                if let content = entry["content"] as? String, grokToolResultFailed(content) {
                    s.toolErrors += 1
                }
            case "reasoning":
                break
            default:
                break
            }
        }
        return s
    }

    /// Metadata mined from Grok's `summary.json` (sibling of `chat_history.jsonl`
    /// in the session directory), filling the cwd/version/timestamps the chat
    /// history itself doesn't carry.
    private struct GrokSessionMeta {
        var cwd: String?
        var gitBranch: String?
        var version: String?
        var model: String?
        var createdAt: Date?
        var updatedAt: Date?
        /// Token counts from the last `turn_completed` event in `updates.jsonl`.
        var usage: GrokUsage?
    }

    /// Token usage from Grok's `updates.jsonl` `turn_completed` events — cumulative
    /// per turn, so the last occurrence is the session total.
    private struct GrokUsage {
        var inputTokens: Int
        var outputTokens: Int
        var cacheTokens: Int
    }

    /// Reads the `summary.json` next to `jsonlPath` plus `~/.grok/version.json`
    /// and `updates.jsonl`, returning whatever metadata Grok recorded for this session.
    private static func grokSessionMeta(jsonlPath: String) -> GrokSessionMeta? {
        let dir = URL(fileURLWithPath: jsonlPath).deletingLastPathComponent()
        let summaryURL = dir.appendingPathComponent("summary.json")
        guard let data = try? Data(contentsOf: summaryURL),
              let summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var meta = GrokSessionMeta()
        if let info = summary["info"] as? [String: Any] {
            meta.cwd = info["cwd"] as? String
        }
        meta.gitBranch = summary["head_branch"] as? String
        meta.model = summary["current_model_id"] as? String
        if let ts = summary["created_at"] as? String { meta.createdAt = date(from: ts) }
        if let ts = summary["updated_at"] as? String { meta.updatedAt = date(from: ts) }

        // Grok CLI version lives in ~/.grok/version.json, not per-session.
        let versionURL = URL(fileURLWithPath: ("~/.grok/version.json" as NSString).expandingTildeInPath)
        if let vData = try? Data(contentsOf: versionURL),
           let version = try? JSONSerialization.jsonObject(with: vData) as? [String: Any] {
            meta.version = version["version"] as? String
        }

        // Token counts: scan updates.jsonl for the last turn_completed event.
        // Grok reports cumulative usage per turn, so the last one is the total.
        meta.usage = grokSessionUsage(in: dir)
        return meta
    }

    /// Scans `updates.jsonl` in the session directory for the last `turn_completed`
    /// event and returns its cumulative token counts. Each turn_completed carries
    /// `inputTokens`, `outputTokens`, and `cachedReadTokens` — the running total.
    private static func grokSessionUsage(in dir: URL) -> GrokUsage? {
        let updatesURL = dir.appendingPathComponent("updates.jsonl")
        guard let text = try? String(contentsOf: updatesURL, encoding: .utf8) else { return nil }
        var last: GrokUsage?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let params = obj["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any],
                  update["sessionUpdate"] as? String == "turn_completed",
                  let usage = update["usage"] as? [String: Any]
            else { continue }
            last = GrokUsage(
                inputTokens: (usage["inputTokens"] as? Int) ?? 0,
                outputTokens: (usage["outputTokens"] as? Int) ?? 0,
                cacheTokens: (usage["cachedReadTokens"] as? Int) ?? 0)
        }
        return last
    }

    // MARK: Dashboard

    private static func dashboard(_ s: Stats) -> String {
        var chips: [String] = []
        chips.append(chip("Turns", "\(s.userTurns + s.assistantTurns)",
                          sub: "\(s.userTurns) you · \(s.assistantTurns) agent"))
        chips.append(chip("Tool calls", "\(s.toolTotal)",
                          sub: s.toolErrors > 0 ? "\(s.toolErrors) errored" : "no errors"))
        if s.inputTokens + s.outputTokens > 0 {
            chips.append(chip("Tokens", "\(compact(s.inputTokens))↓ \(compact(s.outputTokens))↑",
                              sub: s.cacheTokens > 0 ? "\(compact(s.cacheTokens)) cached" : "input · output"))
        }
        if let model = s.models.sorted().first {
            let extra = s.models.count > 1 ? " +\(s.models.count - 1)" : ""
            chips.append(chip("Model", escaped(shortModel(model)) + extra, sub: "model"))
        }
        if let first = s.firstTimestamp, let last = s.lastTimestamp, last > first {
            chips.append(chip("Duration", duration(last.timeIntervalSince(first)), sub: "wall clock"))
        }

        var sections = "<div class=\"stats\">\(chips.joined())</div>"

        // Tool-call breakdown, busiest first.
        if !s.toolCounts.isEmpty {
            let rows = s.toolCounts.sorted { $0.value > $1.value }.map { name, count in
                let pct = s.toolTotal > 0 ? Int(round(Double(count) / Double(s.toolTotal) * 100)) : 0
                return """
                <div class="tool-row">
                  <span class="tool-label">\(escaped(name))</span>
                  <span class="tool-bar"><span style="width:\(pct)%"></span></span>
                  <span class="tool-count">\(count)</span>
                </div>
                """
            }.joined()
            sections += "<details class=\"panel\" open><summary>Tool calls</summary><div class=\"tools\">\(rows)</div></details>"
        }

        // Session / system metadata.
        var meta: [String] = []
        if let cwd = s.cwd { meta.append(metaRow("cwd", cwd)) }
        if let b = s.gitBranch { meta.append(metaRow("branch", b)) }
        if let v = s.version { meta.append(metaRow("cli version", v)) }
        for note in s.systemNotes.prefix(20) {
            meta.append("<div class=\"sysnote\">\(escaped(note))</div>")
        }
        if !meta.isEmpty {
            let label = s.systemNotes.isEmpty ? "Session" : "Session &amp; system"
            sections += "<details class=\"panel\"><summary>\(label)</summary><div class=\"meta\">\(meta.joined())</div></details>"
        }

        return "<section class=\"dashboard\">\(sections)</section>"
    }

    private static func chip(_ label: String, _ value: String, sub: String) -> String {
        "<div class=\"chip\"><div class=\"chip-value\">\(value)</div><div class=\"chip-label\">\(escaped(label))</div><div class=\"chip-sub\">\(escaped(sub))</div></div>"
    }

    private static func metaRow(_ key: String, _ value: String) -> String {
        "<div class=\"meta-row\"><span class=\"meta-key\">\(escaped(key))</span><span class=\"meta-val\">\(escaped(value))</span></div>"
    }

    // MARK: Entries

    private static func renderEntry(_ entry: [String: Any]) -> String {
        switch entry["type"] as? String {
        case "user": return renderMessage(entry, role: "user")
        case "assistant": return renderMessage(entry, role: "assistant")
        case "summary": return renderSummary(entry)
        default: return ""
        }
    }

    /// A turn. Text/thinking blocks are wrapped under a role label; tool_use and
    /// tool_result render as standalone collapsible cards (so a user message that is
    /// purely tool output doesn't masquerade as something the human typed).
    private static func renderMessage(_ entry: [String: Any], role: String) -> String {
        guard let message = entry["message"] as? [String: Any] else { return "" }

        var conversational: [String] = []
        var cards: [String] = []

        let markdown = role == "assistant"
        if let s = message["content"] as? String {
            conversational.append(textBlock(s, markdown: markdown))
        } else if let blocks = message["content"] as? [[String: Any]] {
            for b in blocks {
                switch b["type"] as? String {
                case "text": conversational.append(textBlock(b["text"] as? String ?? "", markdown: markdown))
                case "thinking":
                    let t = b["thinking"] as? String ?? ""
                    if !t.isEmpty {
                        conversational.append("<details class=\"thinking\"><summary>Thinking</summary><div>\(escaped(t))</div></details>")
                    }
                case "tool_use": cards.append(toolUseCard(b))
                case "tool_result": cards.append(toolResultCard(b))
                case "image": cards.append("<div class=\"image\">🖼 image</div>")
                default: break
                }
            }
        }

        let convo = conversational.filter { !$0.isEmpty }.joined(separator: "\n")
        let toolCards = cards.filter { !$0.isEmpty }.joined(separator: "\n")

        if !convo.isEmpty {
            return turnCard(role: role, label: role == "user" ? "You" : "Agent", body: convo + toolCards)
        }
        // Only tool blocks: render them bare, no speaker label.
        return toolCards
    }

    /// A conversational turn card: a role label above its body. Shared by both parsers.
    private static func turnCard(role: String, label: String, body: String) -> String {
        "<div class=\"turn \(role)\"><div class=\"role\">\(escaped(label))</div>\(body)</div>"
    }

    // MARK: Codex

    /// Codex's rollout schema: every line is `{timestamp, type, payload}`. Conversation
    /// text arrives as `event_msg` (`user_message` / `agent_message`), tool activity as
    /// `response_item` (`function_call` / `function_call_output`), and the running token
    /// total as `event_msg` `token_count`. We read only those and ignore the rest
    /// (raw protocol messages, encrypted reasoning) so the trace stays conversational.
    private static func analyzeCodex(_ rows: [[String: Any]]) -> Stats {
        var s = Stats()
        for entry in rows {
            if let ts = entry["timestamp"] as? String, let date = date(from: ts) {
                if s.firstTimestamp == nil { s.firstTimestamp = date }
                s.lastTimestamp = date
            }
            guard let payload = entry["payload"] as? [String: Any] else { continue }
            switch entry["type"] as? String {
            case "session_meta":
                s.cwd = payload["cwd"] as? String
                s.version = payload["cli_version"] as? String
            case "turn_context":
                if let model = payload["model"] as? String { s.models.insert(model) }
            case "event_msg":
                switch payload["type"] as? String {
                case "user_message": s.userTurns += 1
                case "agent_message": s.assistantTurns += 1
                case "token_count":
                    // Codex reports a running session total each turn, so the last wins.
                    if let info = payload["info"] as? [String: Any],
                       let total = info["total_token_usage"] as? [String: Any] {
                        s.inputTokens = (total["input_tokens"] as? Int) ?? s.inputTokens
                        s.outputTokens = (total["output_tokens"] as? Int) ?? s.outputTokens
                        s.cacheTokens = (total["cached_input_tokens"] as? Int) ?? s.cacheTokens
                    }
                default: break
                }
            case "response_item":
                switch payload["type"] as? String {
                case "function_call":
                    s.toolCounts[payload["name"] as? String ?? "tool", default: 0] += 1
                case "function_call_output":
                    if codexOutputFailed(payload["output"]) { s.toolErrors += 1 }
                default: break
                }
            default: break
            }
        }
        return s
    }

    private static func renderCodexEntry(_ entry: [String: Any]) -> String {
        guard let payload = entry["payload"] as? [String: Any] else { return "" }
        switch entry["type"] as? String {
        case "event_msg":
            switch payload["type"] as? String {
            case "user_message": return codexTurn(payload["message"], role: "user", label: "You")
            case "agent_message": return codexTurn(payload["message"], role: "assistant", label: "Agent")
            default: return ""
            }
        case "response_item":
            switch payload["type"] as? String {
            case "function_call": return codexToolUseCard(payload)
            case "function_call_output": return codexToolResultCard(payload)
            default: return ""
            }
        default: return ""
        }
    }

    private static func codexTurn(_ message: Any?, role: String, label: String) -> String {
        let body = textBlock(message as? String ?? "", markdown: role == "assistant")
        return body.isEmpty ? "" : turnCard(role: role, label: label, body: body)
    }

    private static func codexToolUseCard(_ payload: [String: Any]) -> String {
        let name = payload["name"] as? String ?? "tool"
        let args = codexArguments(payload["arguments"])
        let pre = args.isEmpty ? "" : "<pre>\(escaped(args))</pre>"
        return "<details class=\"tool-use\"><summary>▶ \(escaped(name))</summary>\(pre)</details>"
    }

    private static func codexToolResultCard(_ payload: [String: Any]) -> String {
        let out = (payload["output"] as? String) ?? ""
        guard !out.isEmpty else { return "" }
        let failed = codexOutputFailed(out)
        return "<details class=\"tool-result\(failed ? " error" : "")\"><summary>\(failed ? "⚠ result" : "◀ result")</summary><pre>\(escaped(out))</pre></details>"
    }

    /// Codex encodes a function call's arguments as a JSON *string*; pretty-print it
    /// when it parses, else show it verbatim.
    private static func codexArguments(_ raw: Any?) -> String {
        guard let text = raw as? String else { return prettyJSON(raw) }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: pretty, encoding: .utf8) else { return text }
        return string
    }

    /// Codex exec results embed the process exit line; a non-zero code marks a failed
    /// tool call. When absent (non-exec tools) we don't guess and treat it as success.
    private static func codexOutputFailed(_ output: Any?) -> Bool {
        guard let text = output as? String,
              let range = text.range(of: "exited with code ") else { return false }
        let code = text[range.upperBound...].prefix { $0.isNumber }
        return !code.isEmpty && code != "0"
    }

    private static func toolUseCard(_ b: [String: Any]) -> String {
        let name = b["name"] as? String ?? "tool"
        let input = prettyJSON(b["input"])
        let pre = input.isEmpty ? "" : "<pre>\(escaped(input))</pre>"
        return "<details class=\"tool-use\"><summary>▶ \(escaped(name))</summary>\(pre)</details>"
    }

    private static func toolResultCard(_ b: [String: Any]) -> String {
        let out = toolResultText(b["content"])
        guard !out.isEmpty else { return "" }
        let isError = (b["is_error"] as? Bool) ?? false
        return "<details class=\"tool-result\(isError ? " error" : "")\"><summary>\(isError ? "⚠ result" : "◀ result")</summary><pre>\(escaped(out))</pre></details>"
    }

    /// Grok entry renderer: dispatches on the top-level `type` field and shapes
    /// content that is unwrapped (no `message` envelope).
    private static func renderGrokEntry(_ entry: [String: Any]) -> String {
        switch entry["type"] as? String {
        case "system": return "" // shown in dashboard metadata, not the trace body
        case "user": return renderGrokUser(entry)
        case "assistant": return renderGrokAssistant(entry)
        case "tool_result": return renderGrokToolResult(entry)
        case "reasoning": return renderGrokReasoning(entry)
        default: return ""
        }
    }

    private static func renderGrokUser(_ entry: [String: Any]) -> String {
        // Prefer the structured flag Grok writes for runtime injections
        // (`project_instructions`, `system_reminder`, …). Untagged preambles
        // such as `<user_info>` still fall through to tag stripping below.
        if entry["synthetic_reason"] != nil { return "" }
        guard let fullText = grokUserText(entry) else { return "" }
        let visible = grokExtractUserQuery(fullText)
        guard !visible.isEmpty else { return "" }
        return turnCard(role: "user", label: "You", body: textBlock(visible))
    }

    /// Joined text of a Grok user entry's content blocks (ConversationItem
    /// `UserItem.content: Vec<ContentPart>`).
    private static func grokUserText(_ entry: [String: Any]) -> String? {
        guard let blocks = entry["content"] as? [[String: Any]] else { return nil }
        let fullText = blocks.compactMap { b -> String? in
            guard (b["type"] as? String) == "text" else { return nil }
            return b["text"] as? String
        }.joined()
        return fullText.isEmpty ? nil : fullText
    }

    /// Extracts the user-visible content from a Grok user turn's concatenated text.
    /// When `<user_query>…</user_query>` is present, only its inner content is shown;
    /// otherwise, all known system-injection tags (and their content) are stripped, and
    /// the remainder — the user's own words — is returned.
    private static func grokExtractUserQuery(_ text: String) -> String {
        // First, strip every known system-injection block — tags AND content — from
        // the joined text, regardless of whether they span multiple original blocks.
        // Covers the untagged `<user_info>` preamble (synthetic_reason is nil there).
        let systemTags = ["user_info", "system-reminder", "git_status",
                          "action_safety", "tool_calling", "background_tasks",
                          "output_efficiency", "formatting", "user_guide"]
        var cleaned = text
        for tag in systemTags {
            // Match `<tag>…</tag>` across newlines (dot matches line separators off by
            // default in ICU regex, so use (?s) to make `.` match newlines too).
            let pattern = "<" + NSRegularExpression.escapedPattern(for: tag) + ">.*?</" + NSRegularExpression.escapedPattern(for: tag) + ">"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
                let ns = cleaned as NSString
                cleaned = regex.stringByReplacingMatches(in: cleaned, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            }
        }
        // `<user_query>` is intentionally not in `systemTags` so the delimiters remain
        // for this range extraction; only the inner text is returned.
        if let start = cleaned.range(of: "<user_query>"),
           let end = cleaned.range(of: "</user_query>", range: start.upperBound..<cleaned.endIndex) {
            return String(cleaned[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // No `<user_query>`: after stripping system tags, whatever is left is the user's
        // own text. Collapse multiple blank lines into one.
        let lines = cleaned.components(separatedBy: "\n")
        let nonEmpty = lines.drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        let result = nonEmpty.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Normalize runs of blank lines.
        return result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    }

    private static func renderGrokAssistant(_ entry: [String: Any]) -> String {
        var parts: [String] = []
        // Text content — a plain string, not a block array.
        if let text = entry["content"] as? String, !text.isEmpty {
            parts.append(textBlock(text, markdown: true))
        }
        // Tool calls from the `tool_calls` array.
        if let toolCalls = entry["tool_calls"] as? [[String: Any]] {
            for tc in toolCalls {
                let name = tc["name"] as? String ?? "tool"
                let args = tc["arguments"] as? String ?? ""
                let prettyArgs = codexArguments(args) // reuses Codex arg-prettifier (JSON string → pretty)
                let pre = prettyArgs.isEmpty ? "" : "<pre>\(escaped(prettyArgs))</pre>"
                parts.append("<details class=\"tool-use\"><summary>▶ \(escaped(name))</summary>\(pre)</details>")
            }
        }
        return parts.isEmpty ? "" : turnCard(role: "assistant", label: "Agent", body: parts.joined(separator: "\n"))
    }

    private static func renderGrokToolResult(_ entry: [String: Any]) -> String {
        let out = entry["content"] as? String ?? ""
        guard !out.isEmpty else { return "" }
        // Grok's ToolResultItem has no `is_error` flag; failed tools typically
        // prefix the content with `Error:` (mirrors what the model sees).
        let failed = grokToolResultFailed(out)
        return "<details class=\"tool-result\(failed ? " error" : "")\"><summary>\(failed ? "⚠ result" : "◀ result")</summary><pre>\(escaped(out))</pre></details>"
    }

    /// Heuristic for Grok tool failures — content often begins with `Error:`.
    private static func grokToolResultFailed(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("Error:") || trimmed.hasPrefix("error:")
    }

    private static func renderGrokReasoning(_ entry: [String: Any]) -> String {
        // Summaries are `[{type: "summary_text", text: "..."}]`.
        let summaries = entry["summary"] as? [[String: Any]] ?? []
        let text = summaries.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !text.isEmpty else { return "" }
        return "<details class=\"thinking\"><summary>Thinking</summary><div>\(escaped(text))</div></details>"
    }

    private static func renderSummary(_ entry: [String: Any]) -> String {
        let s = entry["summary"] as? String ?? ""
        return s.isEmpty ? "" : "<div class=\"summary\">\(escaped(s))</div>"
    }

    // MARK: Helpers

    /// Agent text renders as markdown (headings, fences, tables…); user text stays
    /// plain pre-wrap, since prompts often contain pasted output that markdown
    /// markers would mangle.
    private static func textBlock(_ s: String, markdown: Bool = false) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        return markdown
            ? "<div class=\"text md\">\(MarkdownHTML.html(s))</div>"
            : "<div class=\"text\">\(escaped(s))</div>"
    }

    private static func toolResultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    private static func prettyJSON(_ value: Any?) -> String {
        guard let value else { return "" }
        if let s = value as? String { return s }
        guard JSONSerialization.isValidJSONObject(value),
              let d = try? JSONSerialization.data(withJSONObject: value,
                                                  options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else {
            return String(describing: value)
        }
        return s
    }

    /// `12345` → `12.3k`; small counts stay exact.
    private static func compact(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        let k = Double(n) / 1000
        return k >= 100 ? "\(Int(k.rounded()))k" : String(format: "%.1fk", k)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }

    /// `claude-opus-4-8-20260101` → `opus-4-8`, trimming the vendor prefix and any
    /// trailing date so the chip stays short.
    private static func shortModel(_ model: String) -> String {
        var m = model
        if m.hasPrefix("claude-") { m = String(m.dropFirst("claude-".count)) }
        // Drop a trailing 8-digit date component.
        let parts = m.split(separator: "-")
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            m = parts.dropLast().joined(separator: "-")
        }
        return m
    }

    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: Document

    private static func document(title: String, stats: Stats, body: String, theme: TraceTheme) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escaped(title)) — termio trace</title>
        <style>\(themeVariables(theme))\n\(css)</style></head>
        <body>
        <header>
          <h1>\(escaped(title))</h1>
        </header>
        <main>
        \(dashboard(stats))
        <section class="trace">\(body)</section>
        </main>
        </body></html>
        """
    }

    /// The live termio theme injected as CSS custom properties; the static stylesheet
    /// below references them, so the page always matches the app's current colors.
    private static func themeVariables(_ t: TraceTheme) -> String {
        """
        :root {
          color-scheme: \(t.isDark ? "dark" : "light");
          --bg: \(t.background);
          --panel: \(t.panel);
          --fg: \(t.foreground);
          --muted: \(t.secondary);
          --accent: \(t.accent);
          --line: \(t.isDark ? "rgba(255,255,255,0.10)" : "rgba(0,0,0,0.10)");
          --soft: \(t.isDark ? "rgba(255,255,255,0.045)" : "rgba(0,0,0,0.035)");
        }
        """
    }

    /// Static stylesheet, all colors via `var(--…)` from `themeVariables`. Only `{`/`}`
    /// (safe in a plain Swift string — interpolation is solely `\(…)`) and no `\`.
    private static let css = """
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--bg); color: var(--fg);
      font: 13.5px/1.6 -apple-system, "SF Pro Text", system-ui, sans-serif; }
    header { position: sticky; top: 0; z-index: 2; padding: 8px 22px;
      background: color-mix(in srgb, var(--bg) 88%, transparent);
      backdrop-filter: blur(12px); border-bottom: 1px solid var(--line); }
    header h1 { margin: 0; font-size: 14px; font-weight: 600; }
    main { max-width: 900px; margin: 0 auto; padding: 20px 22px 96px; }
    .dashboard { margin-bottom: 26px; }
    .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
      gap: 10px; margin-bottom: 14px; }
    .chip { background: var(--soft); border: 1px solid var(--line); border-radius: 10px; padding: 10px 12px; }
    .chip-value { font-size: 17px; font-weight: 650; }
    .chip-label { font-size: 11px; color: var(--fg); opacity: 0.8; margin-top: 3px; }
    .chip-sub { font-size: 10.5px; color: var(--muted); margin-top: 1px; }
    .panel { background: var(--soft); border: 1px solid var(--line); border-radius: 10px;
      padding: 4px 12px; margin: 8px 0; }
    .panel > summary { cursor: pointer; font-size: 11px; font-weight: 600; color: var(--muted);
      text-transform: uppercase; letter-spacing: 0.5px; padding: 8px 0; list-style: none; }
    .panel > summary::-webkit-details-marker { display: none; }
    .tools { padding: 4px 0 10px; }
    .tool-row { display: flex; align-items: center; gap: 10px; padding: 3px 0; }
    .tool-label { flex: 0 0 34%; font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 12px; }
    .tool-bar { flex: 1; height: 6px; background: var(--line); border-radius: 3px; overflow: hidden; }
    .tool-bar > span { display: block; height: 100%; background: var(--accent); }
    .tool-count { flex: 0 0 auto; color: var(--muted); font-size: 12px; min-width: 24px; text-align: right; }
    .meta { padding: 4px 0 10px; }
    .meta-row { display: flex; gap: 10px; padding: 2px 0; font-size: 12px; }
    .meta-key { flex: 0 0 90px; color: var(--muted); text-transform: uppercase; font-size: 10.5px; letter-spacing: 0.4px; padding-top: 1px; }
    .meta-val { font-family: ui-monospace, "SF Mono", Menlo, monospace; word-break: break-all; }
    .sysnote { white-space: pre-wrap; color: var(--muted); font-size: 12px; margin: 6px 0;
      border-left: 2px solid var(--line); padding-left: 10px; }
    .trace { }
    .turn { margin: 16px 0; padding: 12px 14px; border-radius: 10px; }
    .turn.user { background: var(--soft); }
    .turn.assistant { background: color-mix(in srgb, var(--accent) 8%, transparent); }
    .role { font-size: 11px; text-transform: uppercase; letter-spacing: 0.6px;
      color: var(--muted); margin-bottom: 8px; font-weight: 600; }
    .text { white-space: pre-wrap; word-wrap: break-word; }
    .text.md { white-space: normal; }
    .text.md > *:first-child { margin-top: 0; }
    .text.md > *:last-child { margin-bottom: 0; }
    .text.md p { margin: 0 0 10px; }
    .text.md h1, .text.md h2, .text.md h3, .text.md h4, .text.md h5, .text.md h6 {
      margin: 16px 0 8px; line-height: 1.35; }
    .text.md h1 { font-size: 16px; }
    .text.md h2 { font-size: 15px; }
    .text.md h3 { font-size: 14px; }
    .text.md h4, .text.md h5, .text.md h6 { font-size: 13.5px; }
    .text.md code { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 12px;
      background: var(--soft); border: 1px solid var(--line); border-radius: 4px; padding: 1px 5px; }
    .text.md pre { background: var(--soft); border: 1px solid var(--line); border-radius: 8px; margin: 10px 0; }
    .text.md pre code { background: none; border: none; padding: 0; }
    .text.md ul, .text.md ol { margin: 8px 0; padding-left: 22px; }
    .text.md li { margin: 3px 0; }
    .text.md blockquote { margin: 10px 0; padding-left: 12px;
      border-left: 3px solid var(--line); color: var(--muted); }
    .text.md table { border-collapse: collapse; margin: 10px 0; font-size: 12.5px; display: block; overflow-x: auto; }
    .text.md th, .text.md td { border: 1px solid var(--line); padding: 4px 10px; text-align: left; }
    .text.md th { background: var(--soft); }
    .text.md hr { border: none; border-top: 1px solid var(--line); margin: 14px 0; }
    .text.md a { color: var(--accent); }
    details.thinking { margin: 8px 0; }
    details.thinking > summary { cursor: pointer; color: var(--muted); font-style: italic; font-size: 12px; list-style: none; }
    details.thinking > summary::-webkit-details-marker { display: none; }
    details.thinking > div { white-space: pre-wrap; color: var(--muted); font-style: italic;
      border-left: 2px solid var(--line); padding-left: 12px; margin-top: 6px; }
    .tool-use, .tool-result { margin: 8px 0; border-radius: 8px; border: 1px solid var(--line); overflow: hidden; }
    .tool-use > summary, .tool-result > summary { cursor: pointer; font-family: ui-monospace, "SF Mono", Menlo, monospace;
      font-size: 12px; padding: 8px 12px; background: var(--soft); list-style: none; }
    .tool-use > summary { color: var(--accent); }
    .tool-result > summary { color: var(--muted); }
    .tool-use > summary::-webkit-details-marker, .tool-result > summary::-webkit-details-marker { display: none; }
    pre { margin: 0; padding: 12px; overflow-x: auto; white-space: pre-wrap; word-wrap: break-word;
      font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 12px; opacity: 0.92; }
    .tool-result.error { border-color: color-mix(in srgb, red 45%, var(--line)); }
    .tool-result.error > summary { color: #ff9a9a; }
    .image { color: var(--muted); font-size: 12px; margin: 8px 0; }
    .summary { font-size: 12px; color: var(--fg); background: var(--soft);
      padding: 6px 12px; border-radius: 999px; display: inline-block; margin: 8px 0; }
    """
}
