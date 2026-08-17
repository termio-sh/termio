import Foundation

/// Turns an agent transcript JSONL file into a single self-contained HTML document
/// rendered *inside* termio (loaded into the `TraceView` web overlay), not a browser.
/// Claude Code, Codex and Grok are understood — their on-disk schemas differ, so the
/// first line picks the parser (Codex opens with a `session_meta` header) — and all
/// three project onto one intermediate `Record` list, which the ledger below renders.
/// Each line of the transcript is one JSON object; we decode them leniently — skipping
/// any line we can't read rather than failing the whole render, so an evolving
/// transcript schema degrades gracefully.
///
/// The layout is a trajectory, not a chat log: summary chips, a proportional timeline
/// of the session, then a turn-grouped ledger where every step — message, thinking,
/// tool call paired with its result — is one dense row that expands in place. A tool
/// call and its result are one row, not two, because the pair is the unit you reason
/// about, and its wall time is the interval between them.
///
/// The page carries no script. Agent output is untrusted, and the same document serves
/// the Mac overlay and the phone, so folding, filtering, selection and the timeline are
/// all CSS: label-driven checkboxes for disclosure, radios for the filter bar, and
/// `:target` for jumping from a timeline bar to its row.
enum SessionTraceRenderer {
    enum RenderError: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let path): return "Couldn’t read the transcript at \(path)."
            }
        }
    }

    /// Reads the JSONL at `jsonlPath` and returns a full HTML document string, themed
    /// with `theme`. The caller hands the string to a `WKWebView`.
    /// `includeHeader` draws the document's own sticky `<header>` with the title. The Mac
    /// overlay sets it false and draws a native SwiftUI header instead; the phone leaves it
    /// on, since its web view is the only place the session title appears.
    static func html(jsonlPath: String, title: String, theme: TraceTheme,
                     includeHeader: Bool = true) throws -> String {
        // A conversation rotation (Claude Code's `/clear`) advances the transcript
        // pointer before the agent writes the new file — it appears on the first
        // message. Until then an absent file means "new conversation", not an error.
        guard FileManager.default.fileExists(atPath: jsonlPath) else {
            return placeholder(message: "New conversation — no messages yet.",
                               theme: theme, title: title, includeHeader: includeHeader)
        }
        guard let data = FileManager.default.contents(atPath: jsonlPath) else {
            throw RenderError.unreadable(jsonlPath)
        }
        let rows = jsonlObjects(in: data)

        // Codex rollouts open with a `session_meta` header. Grok is detected without
        // waiting for an assistant row (early sessions are system + synthetic users
        // only) — see `isGrokTranscript`. Everything else falls through to Claude.
        let isCodex = rows.first?["type"] as? String == "session_meta"
        let isGrok = !isCodex && isGrokTranscript(rows: rows, jsonlPath: jsonlPath)
        // Grok's chat_history.jsonl has no cwd/version/timestamps — those live in
        // the sibling `summary.json` in the same session directory.
        let grokMeta = isGrok ? grokSessionMeta(jsonlPath: jsonlPath) : nil
        let stats = isCodex ? analyzeCodex(rows) : isGrok ? analyzeGrok(rows, meta: grokMeta) : analyze(rows)
        let records = isCodex ? codexRecords(rows) : isGrok ? grokRecords(rows) : claudeRecords(rows)
        return document(title: title, stats: stats, records: records, theme: theme,
                        includeHeader: includeHeader)
    }

    /// A themed one-line page for when there is nothing to render yet — used by
    /// the companion server so a trace request always returns a valid document
    /// (never a fatal `.error` on the PTY-bridge socket).
    static func placeholder(message: String, theme: TraceTheme, title: String = "Trajectory",
                            includeHeader: Bool = true) -> String {
        document(title: title, stats: Stats(), records: [], theme: theme,
                 includeHeader: includeHeader, notice: message)
    }

    /// Every line of the transcript, decoded leniently — a line we can't read is skipped
    /// rather than failing the whole render, so an evolving schema degrades gracefully.
    ///
    /// This splits the raw *bytes* on `\n` and hands each slice straight to
    /// `JSONSerialization`. The obvious spelling — decode the file to a `String` and
    /// `split(whereSeparator: \.isNewline)` — costs a grapheme-cluster walk of the entire
    /// file: 762ms of an 817ms parse on a 23 MB transcript, against 37ms of actual JSON.
    /// A long-running agent session reaches that size routinely, and the whole render sits
    /// between the user and the page.
    private static func jsonlObjects(in data: Data) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var start = 0
            while start < raw.count {
                let remaining = raw.count - start
                let newline = memchr(base + start, 0x0A, remaining)
                let end = newline.map { base.distance(to: $0) } ?? raw.count
                if end > start {
                    let line = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start),
                                    count: end - start, deallocator: .none)
                    if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        rows.append(object)
                    }
                }
                if newline == nil { break }
                start = end + 1
            }
        }
        return rows
    }

    // MARK: Records

    /// One row of the ledger: a materialised step of the session, whatever agent
    /// produced it. Each parser projects its own schema onto this; only the ledger
    /// renderer knows HTML, so a new agent costs a parser and nothing else.
    private struct Record {
        enum Kind: String {
            case user, assistant, thinking, tool, note
        }

        var kind: Kind
        /// The row's first column of content — a speaker (`You`, the model) or a tool name.
        var title: String
        /// One line of context after the title, truncated by CSS.
        var preview: String = ""
        /// Rendered HTML for the expanded row. Empty means there is nothing to open.
        var body: String = ""
        var startedAt: Date?
        var duration: TimeInterval?
        /// Compact token label for the trailing column, e.g. `316↑`.
        var tokens: String?
        /// The full usage breakdown, shown as the column's native tooltip.
        var tokensTitle: String?
        var isError = false
        /// Sub-agent (Claude sidechain) steps are indented one level under their parent.
        var isNested = false
        /// The first record of a turn — a message the user (or the harness) sent.
        var startsTurn = false
    }

    // MARK: Claude

    /// Claude Code's transcript: one row per message, tool calls as `tool_use` blocks on
    /// an assistant row and their results as `tool_result` blocks on the *next* user row.
    /// Pairing them by `tool_use_id` is what turns two rows into one ledger step with a
    /// real duration.
    private static func claudeRecords(_ rows: [[String: Any]]) -> [Record] {
        var records: [Record] = []
        var pending: [String: Int] = [:]
        var previousRowDate: Date?

        for entry in rows {
            let date = (entry["timestamp"] as? String).flatMap(date(from:))
            defer { if let date { previousRowDate = date } }
            let nested = (entry["isSidechain"] as? Bool) ?? false
            // The model spent the gap since the last recorded event producing this row.
            let rowDuration = elapsed(from: previousRowDate, to: date)
            var firstOfRow = true

            switch entry["type"] as? String {
            case "user":
                guard let message = entry["message"] as? [String: Any] else { break }
                let isMeta = (entry["isMeta"] as? Bool) ?? false
                var texts: [String] = []
                var images: [String] = []

                if let text = message["content"] as? String {
                    texts.append(text)
                } else if let blocks = message["content"] as? [[String: Any]] {
                    for block in blocks {
                        switch block["type"] as? String {
                        case "text": texts.append(block["text"] as? String ?? "")
                        case "image": images.append(imageCard(block))
                        case "tool_result":
                            completeClaudeTool(block, in: &records, pending: &pending, at: date)
                        default: break
                        }
                    }
                }

                let joined = texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !joined.isEmpty || !images.isEmpty else { break }
                // Harness-injected context (`isMeta`) is part of what the model saw, but it
                // is not a turn the human took — it reads as a note, and the Messages
                // filter leaves it out.
                records.append(Record(
                    kind: isMeta ? .note : .user,
                    title: isMeta ? "Context" : "You",
                    preview: oneLine(joined),
                    body: textBlock(joined) + images.joined(),
                    startedAt: date,
                    isNested: nested,
                    startsTurn: !isMeta))

            case "assistant":
                guard let message = entry["message"] as? [String: Any] else { break }
                let model = (message["model"] as? String).map(shortModel) ?? "Agent"
                let usage = message["usage"] as? [String: Any]
                let blocks = (message["content"] as? [[String: Any]]) ?? []

                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        let text = block["text"] as? String ?? ""
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
                        records.append(Record(
                            kind: .assistant,
                            title: model,
                            preview: oneLine(text),
                            body: textBlock(text),
                            startedAt: date,
                            duration: firstOfRow ? rowDuration : nil,
                            tokens: usageLabel(usage),
                            tokensTitle: usageTooltip(usage),
                            isNested: nested))
                        firstOfRow = false
                    case "thinking":
                        let text = block["thinking"] as? String ?? ""
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
                        records.append(Record(
                            kind: .thinking,
                            title: "Thinking",
                            preview: oneLine(text),
                            body: "<div class=\"think\">\(escaped(text))</div>",
                            startedAt: date,
                            duration: firstOfRow ? rowDuration : nil,
                            isNested: nested))
                        firstOfRow = false
                    case "tool_use":
                        let name = block["name"] as? String ?? "tool"
                        records.append(Record(
                            kind: .tool,
                            title: name,
                            preview: toolPreview(block["input"]),
                            body: argumentList(block["input"]),
                            startedAt: date,
                            isNested: nested))
                        if let id = block["id"] as? String { pending[id] = records.count - 1 }
                        firstOfRow = false
                    default: break
                    }
                }

            case "summary":
                let text = entry["summary"] as? String ?? ""
                guard !text.isEmpty else { break }
                records.append(Record(kind: .note, title: "Summary", preview: oneLine(text),
                                      startedAt: date))

            default: break
            }
        }
        return records
    }

    /// Folds a `tool_result` block back into the row its `tool_use_id` opened: the output,
    /// the failure flag, and the call → result interval that is the step's real duration.
    private static func completeClaudeTool(_ block: [String: Any], in records: inout [Record],
                                           pending: inout [String: Int], at date: Date?) {
        guard let id = block["tool_use_id"] as? String, let index = pending.removeValue(forKey: id),
              records.indices.contains(index) else { return }
        let output = toolResultText(block["content"])
        let failed = (block["is_error"] as? Bool) ?? false
        records[index].isError = failed
        records[index].duration = elapsed(from: records[index].startedAt, to: date)
        if !output.isEmpty {
            records[index].body += ioBlock(label: failed ? "Failed" : "Output", text: output,
                                           isError: failed)
        }
    }

    // MARK: Codex

    /// Codex's rollout schema: every line is `{timestamp, type, payload}`. Conversation text
    /// arrives as `event_msg` (`user_message` / `agent_message`); tool activity as
    /// `response_item` — `function_call` for the classic shape and `custom_tool_call` for the
    /// code-mode `exec` sandbox, each with a matching `…_output` carrying the same `call_id`.
    /// Raw protocol rows (developer prompts, encrypted reasoning) stay out of the ledger.
    private static func codexRecords(_ rows: [[String: Any]]) -> [Record] {
        var records: [Record] = []
        var pending: [String: Int] = [:]
        var previousRowDate: Date?
        // Codex names its model once per turn context rather than on each message.
        var model = "Agent"

        for entry in rows {
            let date = (entry["timestamp"] as? String).flatMap(date(from:))
            defer { if let date { previousRowDate = date } }
            guard let payload = entry["payload"] as? [String: Any] else { continue }
            let rowDuration = elapsed(from: previousRowDate, to: date)

            switch entry["type"] as? String {
            case "turn_context":
                if let name = payload["model"] as? String, !name.isEmpty { model = shortModel(name) }

            case "event_msg":
                switch payload["type"] as? String {
                case "user_message":
                    let text = payload["message"] as? String ?? ""
                    guard !text.isEmpty else { break }
                    records.append(Record(kind: .user, title: "You", preview: oneLine(text),
                                          body: textBlock(text), startedAt: date, startsTurn: true))
                case "agent_message":
                    let text = payload["message"] as? String ?? ""
                    guard !text.isEmpty else { break }
                    records.append(Record(kind: .assistant, title: model, preview: oneLine(text),
                                          body: textBlock(text), startedAt: date,
                                          duration: rowDuration))
                case "agent_reasoning":
                    let text = payload["text"] as? String ?? ""
                    guard !text.isEmpty else { break }
                    records.append(Record(kind: .thinking, title: "Thinking", preview: oneLine(text),
                                          body: "<div class=\"think\">\(escaped(text))</div>",
                                          startedAt: date, duration: rowDuration))
                case "context_compacted":
                    records.append(Record(kind: .note, title: "Compacted",
                                          preview: "context compacted", startedAt: date))
                default: break
                }

            case "response_item":
                switch payload["type"] as? String {
                case "function_call", "custom_tool_call":
                    let name = payload["name"] as? String ?? "tool"
                    // `arguments` is a JSON string on function calls; `input` is the code-mode
                    // script, which is already source and must not be JSON-parsed.
                    let raw = payload["arguments"] as? String
                    let script = payload["input"] as? String
                    records.append(Record(
                        kind: .tool,
                        title: name,
                        preview: raw.map(toolPreview(json:)) ?? oneLine(script ?? ""),
                        body: raw.map { argumentList(decodedJSON($0)) }
                            ?? ioBlock(label: "Input", text: script ?? ""),
                        startedAt: date))
                    if let id = payload["call_id"] as? String { pending[id] = records.count - 1 }
                case "function_call_output", "custom_tool_call_output":
                    guard let id = payload["call_id"] as? String,
                          let index = pending.removeValue(forKey: id),
                          records.indices.contains(index) else { break }
                    let output = codexOutputText(payload["output"])
                    let failed = codexOutputFailed(output)
                    records[index].isError = failed
                    records[index].duration = elapsed(from: records[index].startedAt, to: date)
                    if !output.isEmpty {
                        records[index].body += ioBlock(label: failed ? "Failed" : "Output",
                                                       text: output, isError: failed)
                    }
                default: break
                }

            case "compacted":
                records.append(Record(kind: .note, title: "Compacted",
                                      preview: "context compacted", startedAt: date))

            default: break
            }
        }
        return records
    }

    // MARK: Grok

    /// Grok's `chat_history.jsonl`: no `message` wrapper, tool calls on the assistant
    /// entry's `tool_calls` array, results as standalone entries keyed by `tool_call_id`,
    /// and no timestamps at all — so every duration and the timeline are absent rather
    /// than invented.
    private static func grokRecords(_ rows: [[String: Any]]) -> [Record] {
        var records: [Record] = []
        var pending: [String: Int] = [:]

        for entry in rows {
            switch entry["type"] as? String {
            case "user":
                // Runtime injections carry `synthetic_reason`; the untagged `<user_info>`
                // preamble is stripped by `grokExtractUserQuery`.
                if entry["synthetic_reason"] != nil { break }
                guard let full = grokUserText(entry) else { break }
                let visible = grokExtractUserQuery(full)
                guard !visible.isEmpty else { break }
                records.append(Record(kind: .user, title: "You", preview: oneLine(visible),
                                      body: textBlock(visible), startsTurn: true))

            case "assistant":
                let model = (entry["model_id"] as? String).map(shortModel) ?? "Agent"
                if let text = entry["content"] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    records.append(Record(kind: .assistant, title: model, preview: oneLine(text),
                                          body: textBlock(text)))
                }
                for call in (entry["tool_calls"] as? [[String: Any]]) ?? [] {
                    let name = call["name"] as? String ?? "tool"
                    let raw = call["arguments"] as? String ?? ""
                    records.append(Record(kind: .tool, title: name, preview: toolPreview(json: raw),
                                          body: argumentList(decodedJSON(raw))))
                    if let id = call["id"] as? String { pending[id] = records.count - 1 }
                }

            case "tool_result":
                let output = entry["content"] as? String ?? ""
                guard !output.isEmpty else { break }
                let failed = grokToolResultFailed(output)
                if let id = entry["tool_call_id"] as? String, let index = pending.removeValue(forKey: id),
                   records.indices.contains(index) {
                    records[index].isError = failed
                    records[index].body += ioBlock(label: failed ? "Failed" : "Output",
                                                   text: output, isError: failed)
                } else {
                    records.append(Record(kind: .tool, title: "result", preview: oneLine(output),
                                          body: ioBlock(label: failed ? "Failed" : "Output",
                                                        text: output, isError: failed),
                                          isError: failed))
                }

            case "reasoning":
                let summaries = entry["summary"] as? [[String: Any]] ?? []
                let text = summaries.compactMap { $0["text"] as? String }.joined(separator: "\n")
                guard !text.isEmpty else { break }
                records.append(Record(kind: .thinking, title: "Thinking", preview: oneLine(text),
                                      body: "<div class=\"think\">\(escaped(text))</div>"))

            default: break
            }
        }
        return records
    }

    // MARK: Ledger

    /// A run of records under one user message. The header carries what the turn cost —
    /// steps, wall time, and which tools it leaned on — so a long session can be scanned
    /// by turn before any row is opened.
    private struct TurnGroup {
        var number: Int
        var range: Range<Int>
    }

    private static func groups(in records: [Record]) -> [TurnGroup] {
        var groups: [TurnGroup] = []
        var start = 0
        for (index, record) in records.enumerated() where record.startsTurn && index > start {
            groups.append(TurnGroup(number: groups.count + 1, range: start..<index))
            start = index
        }
        if !records.isEmpty {
            groups.append(TurnGroup(number: groups.count + 1, range: start..<records.count))
        }
        return groups
    }

    private static func ledger(_ records: [Record]) -> String {
        let maximumDuration = durationReference(records)
        return groups(in: records).map { group in
            let rows = group.range.map {
                row(records[$0], index: $0 + 1, maximumDuration: maximumDuration)
            }.joined()
            return """
            <section class="group">\(turnHeader(group, records: records))<div class="rows">\(rows)</div></section>
            """
        }.joined()
    }

    private static func turnHeader(_ group: TurnGroup, records: [Record]) -> String {
        let slice = Array(records[group.range])
        var facts: [String] = ["\(slice.count) \(slice.count == 1 ? "step" : "steps")"]
        if let span = wallSpan(of: slice) { facts.append(elapsedLabel(span)) }

        var counts: [String: Int] = [:]
        for record in slice where record.kind == .tool { counts[record.title, default: 0] += 1 }
        let histogram = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(3)
            .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        if !histogram.isEmpty { facts.append(histogram) }

        return """
        <div class="turn-head"><span class="turn-no">Turn \(group.number)</span>\
        <span class="turn-facts">\(escaped(facts.joined(separator: " · ")))</span></div>
        """
    }

    /// One ledger row. With a body it is a label driving its own checkbox — disclosure with
    /// no script — and without one it is a plain row, so the columns still line up.
    ///
    /// The clock leads, the way it does in every log viewer: it is the column the eye
    /// tracks down, and it is what lets a step be lined up against anything else that was
    /// running at the time. Cost and duration close the row on the right, where their
    /// tabular figures form their own scannable column.
    private static func row(_ record: Record, index: Int,
                            maximumDuration: TimeInterval?) -> String {
        let at = record.startedAt.map { "<span class=\"at\">\(escaped(clock($0)))</span>" }
            ?? "<span class=\"at dim\">—</span>"
        let tokens = record.tokens.map {
            "<span class=\"tok\"\(record.tokensTitle.map { " title=\"\(attribute($0))\"" } ?? "")>\(escaped($0))</span>"
        } ?? "<span class=\"tok\"></span>"
        let took = durationCell(record.duration, maximum: maximumDuration)
        let error = record.isError ? "<span class=\"fail\">Failed</span>" : ""
        let cells = """
        \(at)<span class="tag">\(escaped(kindLabel(record.kind)))</span>\
        <span class="what"><span class="name">\(escaped(record.title))</span>\
        <span class="prev">\(escaped(record.preview))</span>\(error)</span>\
        \(tokens)\(took)
        """
        let attributes = """
        class="rec\(record.isNested ? " nested" : "")" id="r\(index)" \
        data-kind="\(record.kind.rawValue)"\(record.isError ? " data-err=\"1\"" : "")
        """
        guard !record.body.isEmpty else {
            return "<div \(attributes)><div class=\"row plain\">\(cells)</div></div>"
        }
        return """
        <div \(attributes)><input class="disc" type="checkbox" id="d\(index)">\
        <label class="row" for="d\(index)">\(cells)</label>\
        <div class="body">\(record.body)</div></div>
        """
    }

    /// What a step's duration bar is measured against: the 90th percentile, not the
    /// slowest step.
    ///
    /// Step durations are wildly skewed — in a real session, 82% land under a second, the
    /// median is 150ms, and one outlier runs 93s. Against that maximum every ordinary step
    /// draws a 3% sliver and the bar says nothing, which is exactly what it looked like.
    /// Measuring against p90 spreads the ordinary range across the lane and lets the top
    /// tenth saturate — "this was one of the slow ones" is the message; the exact figure is
    /// already printed beside it. Below a handful of timed steps a percentile is noise, so
    /// the maximum stands in.
    private static func durationReference(_ records: [Record]) -> TimeInterval? {
        let timed = records.compactMap(\.duration).filter { $0 > 0 }.sorted()
        guard timed.count >= 8 else { return timed.last }
        return timed[min(timed.count - 1, Int(Double(timed.count) * 0.9))]
    }

    private static func durationCell(_ duration: TimeInterval?,
                                     maximum: TimeInterval?) -> String {
        guard let duration else { return "<span class=\"dur\"></span>" }
        let label = escaped(elapsedLabel(duration))
        guard let maximum, maximum > 0, duration > 0 else {
            return "<span class=\"dur\">\(label)</span>"
        }
        // The drawn length is the scale the eye reads, so the emphasis thresholds are read
        // off that same length rather than the raw ratio — otherwise a bar that looks
        // three-quarters full would carry no emphasis.
        let drawn = max(0, min(1, duration / maximum)).squareRoot()
        let emphasis = drawn >= 0.75 ? " dur-high" : drawn >= 0.5 ? " dur-medium" : ""
        let width = percent(drawn * 100)
        return "<span class=\"dur timed\(emphasis)\">\(label)<span class=\"dur-bar\" style=\"width:\(width)%\"></span></span>"
    }

    /// The column header, sticky under the filter bar. A log table earns one: without it
    /// the two right-hand number columns are unlabelled figures.
    private static let columnHeader = """
    <div class="colhead"><span class="at">Time</span><span class="tag">Kind</span>\
    <span class="what">Event</span><span class="tok">Tokens</span><span class="dur">Took</span></div>
    """

    private static func kindLabel(_ kind: Record.Kind) -> String {
        switch kind {
        case .user: return "User"
        case .assistant: return "Agent"
        case .thinking: return "Think"
        case .tool: return "Tool"
        case .note: return "Note"
        }
    }

    /// The filter bar's radios and the expand-all checkbox live *before* the ledger so the
    /// stylesheet can reach every row with a sibling combinator — the whole interaction
    /// model of the page, with no script.
    private static let controls = """
    <input class="ctl" type="radio" name="flt" id="f-all" checked>
    <input class="ctl" type="radio" name="flt" id="f-msg">
    <input class="ctl" type="radio" name="flt" id="f-tool">
    <input class="ctl" type="radio" name="flt" id="f-err">
    <input class="ctl" type="checkbox" id="f-open">
    <input class="ctl" type="checkbox" id="f-wrap">
    """

    /// Each filter carries the count it would leave behind, so the bar doubles as a
    /// breakdown of the session and a filter is never a click into an empty list. A count
    /// of zero disables its own chip rather than hiding it — a session with no failures
    /// should say so, and the bar should not change shape between sessions.
    private static func filterBar(_ records: [Record]) -> String {
        let messages = records.filter { $0.kind == .user || $0.kind == .assistant }.count
        let tools = records.filter { $0.kind == .tool }.count
        let errors = records.filter(\.isError).count
        func filter(_ id: String, _ label: String, _ count: Int) -> String {
            """
            <label for="\(id)" class="filter \(id)\(count == 0 ? " empty" : "")">\
            \(escaped(label))<span class="n">\(count)</span></label>
            """
        }
        return """
        <div class="filters">
          \(filter("f-all", "All", records.count))
          \(filter("f-msg", "Messages", messages))
          \(filter("f-tool", "Tools", tools))
          \(filter("f-err", "Errors", errors))
          <span class="spacer"></span>
          <label for="f-wrap" class="filter toggle">Wrap</label>
          <label for="f-open" class="filter toggle">Expand all</label>
        </div>
        """
    }

    // MARK: Histogram

    /// Activity over the session's wall clock, as a log viewer draws it: the time domain
    /// cut into buckets, each a column whose height is how many steps landed in it and
    /// whose segments are what kind they were. Density is the thing worth seeing at a
    /// glance — where the work clustered, where the session sat idle, where errors fell —
    /// and it survives a long session, which per-record bars do not: 451 records across
    /// 18 hours are sub-pixel slivers, while 60 buckets stay readable.
    ///
    /// Each column links to the first record in its bucket, so the histogram is also the
    /// page's navigation. Absent without timestamps (Grok) — an untimed session gets no
    /// invented geometry.
    private static func histogram(_ records: [Record]) -> String {
        let timed = records.enumerated().filter { $0.element.startedAt != nil }
        guard let first = timed.first?.element.startedAt,
              let last = timed.map({ $0.element.startedAt?.addingTimeInterval($0.element.duration ?? 0) })
                  .compactMap({ $0 }).max(),
              last > first else { return "" }
        let span = last.timeIntervalSince(first)

        // Resolution is fixed, not scaled to the number of records. Giving a 12-step
        // session 12 buckets makes each one 7 seconds wide, and the strip renders as a row
        // of fat blocks that says less than the timestamps beside it. At a constant 60
        // columns a short session simply draws thin marks near their true positions —
        // which is the honest picture, and the same picture a long session gets.
        let count = bucketCount
        var buckets = Array(repeating: Bucket(), count: count)
        for (index, record) in timed {
            guard let start = record.startedAt else { continue }
            let slot = min(count - 1, Int(start.timeIntervalSince(first) / span * Double(count)))
            buckets[slot].add(record, at: index + 1)
        }

        let tallest = max(1, buckets.map(\.total).max() ?? 1)
        let width = 100.0 / Double(count)
        let columns = buckets.enumerated().map { slot, bucket -> String in
            let from = first.addingTimeInterval(span * Double(slot) / Double(count))
            guard bucket.total > 0 else {
                return "<span class=\"col\" style=\"width:\(percent(width))%\"></span>"
            }
            // Bar heights are square-rooted: one 40-step burst otherwise flattens every
            // other bucket to a hairline, and the question the strip answers is "where did
            // work happen", not "exactly how many".
            let height = (Double(bucket.total) / Double(tallest)).squareRoot() * 100
            let segments = bucket.segments.map { kind, n in
                "<span class=\"seg k-\(kind.rawValue)\" style=\"flex:\(n)\"></span>"
            }.joined()
            let label = "\(clock(from)) · \(bucket.total) \(bucket.total == 1 ? "step" : "steps")"
                + (bucket.errors > 0 ? " · \(bucket.errors) failed" : "")
            return """
            <a class="col" style="width:\(percent(width))%" href="#r\(bucket.firstIndex)" \
            title="\(attribute(label))"><span class="stack" style="height:\(percent(height))%">\
            \(segments)</span></a>
            """
        }.joined()

        return """
        <div class="histogram"><div class="cols">\(columns)</div>\
        <div class="axis"><span>\(escaped(clock(first)))</span>\
        <span class="axis-span">\(escaped(duration(span)))</span>\
        <span>\(escaped(clock(last)))</span></div></div>
        """
    }

    private static let bucketCount = 60

    /// One column of the histogram: how many steps fell in this slice of the session, of
    /// which kinds, and which record to jump to when it is clicked.
    private struct Bucket {
        var segments: [(Record.Kind, Int)] = []
        var total = 0
        var errors = 0
        var firstIndex = 1

        mutating func add(_ record: Record, at index: Int) {
            if total == 0 { firstIndex = index }
            total += 1
            if record.isError { errors += 1 }
            if let existing = segments.firstIndex(where: { $0.0 == record.kind }) {
                segments[existing].1 += 1
            } else {
                segments.append((record.kind, 1))
            }
        }
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.4f", max(0, min(100, value)))
    }

    /// Wall-clock reading for the axis and the row's time column. A trajectory is read
    /// against the clock the rest of the machine logs on, so these are absolute times in
    /// the local zone rather than an offset from the session's first event.
    private static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    // MARK: Stats

    /// Aggregate figures shown in the summary chips, gathered in one pass over the rows.
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
    /// (`…:01.327Z`), which the default ISO 8601 style won't parse — so try the
    /// fractional style first and fall back to the plain one.
    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let iso = Date.ISO8601FormatStyle()
    private static func date(from string: String) -> Date? {
        (try? isoFractional.parse(string)) ?? (try? iso.parse(string))
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
                // Code mode dispatches through `custom_tool_call`; the classic shape is
                // `function_call`. Both are tool calls and both count here.
                case "function_call", "custom_tool_call":
                    s.toolCounts[payload["name"] as? String ?? "tool", default: 0] += 1
                case "function_call_output", "custom_tool_call_output":
                    if codexOutputFailed(codexOutputText(payload["output"])) { s.toolErrors += 1 }
                default: break
                }
            default: break
            }
        }
        return s
    }

    /// Grok's `chat_history.jsonl` carries no token usage or timestamps — so the chips omit
    /// Tokens and Duration unless the sibling `summary.json` supplied them.
    private static func analyzeGrok(_ rows: [[String: Any]], meta: GrokSessionMeta?) -> Stats {
        var s = Stats()

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
            if let model = entry["model_id"] as? String { s.models.insert(model) }

            switch type {
            case "system":
                // The system prompt is huge and not useful as metadata — skip.
                break
            case "user":
                if entry["synthetic_reason"] != nil { break }
                if let fullText = grokUserText(entry),
                   !grokExtractUserQuery(fullText).isEmpty {
                    s.userTurns += 1
                }
            case "assistant":
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
            default:
                break
            }
        }
        return s
    }

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

    // MARK: Summary

    /// The session's headline facts as one line, not a wall of tiles. Five stat cards cost
    /// most of the first screen, which on a log view is the screen that should be showing
    /// log: the reader came for the steps, and the totals are context they read once.
    private static func summary(_ s: Stats) -> String {
        var facts: [String] = []
        // Where before how much: which checkout and branch this ran in is what orients a
        // reader, and it was one disclosure click away for no reason. The folder's name
        // carries the full path as its tooltip, so the line stays short.
        if let cwd = s.cwd {
            let name = (cwd as NSString).lastPathComponent
            facts.append("""
            <span class="fact"><b title="\(attribute(cwd))">\(escaped(name))</b></span>
            """)
        }
        if let branch = s.gitBranch {
            facts.append("<span class=\"fact\"><b>\(escaped(branch))</b></span>")
        }
        facts.append(fact("\(s.userTurns + s.assistantTurns)", "turns"))
        facts.append(fact("\(s.toolTotal)", "tool calls"))
        if s.toolErrors > 0 {
            facts.append("<span class=\"fact bad\"><b>\(s.toolErrors)</b> failed</span>")
        }
        if s.inputTokens + s.outputTokens > 0 {
            let cached = s.cacheTokens > 0 ? " · \(compact(s.cacheTokens)) cached" : ""
            facts.append(fact("\(compact(s.inputTokens))↓ \(compact(s.outputTokens))↑",
                              "tokens" + cached))
        }
        if let model = s.models.sorted().first {
            let extra = s.models.count > 1 ? " +\(s.models.count - 1)" : ""
            facts.append("<span class=\"fact\"><b>\(escaped(shortModel(model)))\(extra)</b></span>")
        }
        if let first = s.firstTimestamp, let last = s.lastTimestamp, last > first {
            facts.append(fact(duration(last.timeIntervalSince(first)), "wall clock"))
        }

        // Which tools a session leaned on is a headline fact, but a full-width bar chart
        // is not a headline *shape* — it outweighed everything above it. So the naming
        // rides on the facts line, where it costs a few words, and the proportions go to
        // the disclosure with the rest of the drill-down. Nothing is duplicated: the line
        // says which, the panel says how much.
        let ranked = s.toolCounts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        if !ranked.isEmpty {
            let named = ranked.prefix(3).map { "\($0.key) \($0.value)" }.joined(separator: " · ")
            let rest = ranked.count > 3 ? " +\(ranked.count - 3)" : ""
            facts.append("<span class=\"fact quiet\">\(escaped(named + rest))</span>")
        }

        var sections = "<div class=\"facts\">\(facts.joined())</div>"

        // The drill-down: how the tool calls divide, then the full path, the CLI build, and
        // the harness's own notes. All of it is "look it up when you need it", which is
        // what a disclosure is for.
        var meta: [String] = []
        if !ranked.isEmpty {
            let rows = ranked.map { entry in
                let pct = s.toolTotal > 0 ? Int(round(Double(entry.value) / Double(s.toolTotal) * 100)) : 0
                return """
                <div class="tool-row">
                  <span class="tool-label">\(escaped(entry.key))</span>
                  <span class="tool-bar"><span style="width:\(pct)%"></span></span>
                  <span class="tool-count">\(entry.value)</span>
                </div>
                """
            }.joined()
            meta.append("<div class=\"tools\">\(rows)</div>")
        }
        if let cwd = s.cwd { meta.append(metaRow("cwd", cwd)) }
        if let v = s.version { meta.append(metaRow("cli version", v)) }
        for note in s.systemNotes.prefix(20) {
            meta.append("<div class=\"sysnote\">\(escaped(note))</div>")
        }
        if !meta.isEmpty {
            let label = s.systemNotes.isEmpty ? "Session details" : "Session details &amp; system notes"
            sections += "<details class=\"panel\"><summary>\(label)</summary><div class=\"meta\">\(meta.joined())</div></details>"
        }

        return "<section class=\"summary\">\(sections)</section>"
    }

    private static func fact(_ value: String, _ label: String) -> String {
        "<span class=\"fact\"><b>\(value)</b> \(escaped(label))</span>"
    }

    private static func metaRow(_ key: String, _ value: String) -> String {
        "<div class=\"meta-row\"><span class=\"meta-key\">\(escaped(key))</span><span class=\"meta-val\">\(escaped(value))</span></div>"
    }

    // MARK: Content

    /// A tool call's arguments as a field list rather than a JSON blob.
    ///
    /// The arguments arrive as JSON, but reading them as JSON is worse than reading them
    /// as what they are: a shell command comes back `"cmd": "echo \"a\"; head -120 x"`,
    /// where every quote the user typed is escaped and the value competes with braces for
    /// attention. Keys are labels and values are content, so they render that way — text
    /// as text, a multi-line value as its own block, and only a genuinely nested value
    /// falling back to JSON.
    private static func argumentList(_ input: Any?) -> String {
        guard let dict = input as? [String: Any], !dict.isEmpty else {
            return ioBlock(label: "Input", text: prettyJSON(input))
        }
        // Whatever the tool is *about* first (the command, the path), then the rest in a
        // stable order, so two calls to the same tool line up against each other.
        let ordered = dict.keys.sorted { a, b in
            let ra = previewKeys.firstIndex(of: a) ?? previewKeys.count
            let rb = previewKeys.firstIndex(of: b) ?? previewKeys.count
            return ra == rb ? a < b : ra < rb
        }
        let rows = ordered.map { key -> String in
            let value = dict[key]
            if let text = value as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.contains("\n") || trimmed.count > 120 {
                    return """
                    <div class="arg block"><span class="key">\(escaped(key))</span>\
                    <pre>\(escaped(cut(trimmed)))</pre></div>
                    """
                }
                return """
                <div class="arg"><span class="key">\(escaped(key))</span>\
                <span class="val">\(escaped(trimmed))</span></div>
                """
            }
            if let scalar = value as? CustomStringConvertible, !(value is [Any]), !(value is [String: Any]) {
                return """
                <div class="arg"><span class="key">\(escaped(key))</span>\
                <span class="val">\(escaped(scalar.description))</span></div>
                """
            }
            return """
            <div class="arg block"><span class="key">\(escaped(key))</span>\
            <pre>\(json(prettyJSON(value)))</pre></div>
            """
        }.joined()
        return "<div class=\"io\"><div class=\"io-label\">Input</div><div class=\"args\">\(rows)</div></div>"
    }

    /// The agents that hand their arguments over as a JSON *string* (Codex, Grok) decoded
    /// back to the dictionary `argumentList` wants; the raw string when it isn't one.
    private static func decodedJSON(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return text }
        return object
    }

    /// JSON coloured with the same highlighter the editor uses, or escaped plain text when
    /// it isn't JSON. Cheap because most payloads fail the first character test.
    private static func json(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let indented = String(data: pretty, encoding: .utf8)
        else { return escaped(text) }
        // Indent first, colour second. A tool that answers in JSON answers on one line, and
        // colouring that as-is paints the whole payload in the string colour — a wall of
        // red rather than a structure. Broken into lines, the keys and numbers are what
        // the colour is actually for.
        guard indented.count < maxHighlightCharacters,
              let highlighted = MarkdownScripting.highlight(indented, language: "json")
        else { return escaped(indented) }
        return "<code class=\"hljs\">\(highlighted)</code>"
    }

    /// Highlighting is a JavaScript round trip per payload; a big one is not worth it, and
    /// a session has hundreds.
    private static let maxHighlightCharacters = 8_000

    private static func cut(_ text: String) -> String {
        text.count > maxPayloadCharacters ? String(text.prefix(maxPayloadCharacters)) + "…" : text
    }

    /// A record's expanded payload: the labelled input or output of a tool call. Long
    /// outputs are cut — a build log can run to megabytes, and the whole session has to
    /// stay one document the web view can lay out.
    private static func ioBlock(label: String, text: String, isError: Bool = false) -> String {
        guard !text.isEmpty else { return "" }
        var shown = text
        var note = ""
        if shown.count > maxPayloadCharacters {
            let cut = shown.count - maxPayloadCharacters
            shown = String(shown.prefix(maxPayloadCharacters))
            note = "<div class=\"cut\">\(cut) more characters</div>"
        }
        // A tool's output is usually stdout, not JSON — but when it *is* JSON (a `gh --json`
        // call, an API response) it reads far better coloured, and the page already ships
        // the editor's highlighter for fenced code.
        return """
        <div class="io\(isError ? " error" : "")"><div class="io-label">\(escaped(label))</div>\
        <pre>\(json(shown))</pre>\(note)</div>
        """
    }

    private static let maxPayloadCharacters = 20_000

    /// A turn's conversational text. Both user and agent turns render as markdown
    /// (headings, fences, tables, inline code) — a skill/command invocation or a pasted
    /// doc in a user turn is authored markdown and reads as raw source otherwise. Any
    /// `[Image: source: …]` file markers are spliced out and inlined as `<img>` *around*
    /// the markdown: those aren't markdown image syntax, and markdown mode deliberately
    /// blocks raw `<img>`, so they can't go through the renderer.
    ///
    /// The tradeoff of markdown-for-user: pasted diffs / lines starting with `#` `-` `*`
    /// render as headings/lists rather than literally. The escape hatch is a code fence,
    /// same as anywhere else.
    private static func textBlock(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        guard let regex = imageRefRegex else { return markdownDiv(s) }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return markdownDiv(s) }

        // Interleave markdown-rendered text segments with inlined image markers.
        var out = ""
        var cursor = 0
        for m in matches {
            out += markdownDiv(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            let path = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if let uri = imageDataURI(path: path) {
                out += "<img class=\"shot\" src=\"\(uri)\" alt=\"attached image\">"
            } else {
                out += markdownDiv(ns.substring(with: m.range))
            }
            cursor = m.range.location + m.range.length
        }
        out += markdownDiv(ns.substring(from: cursor))
        return out
    }

    /// Wraps a text segment in a markdown-rendered block, or "" if it's blank.
    private static func markdownDiv(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "" : "<div class=\"text md\">\(MarkdownHTML.html(s))</div>"
    }

    // MARK: Images

    private static let inlineImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    /// Cap the bytes we inline so a stray huge capture can't bloat the document.
    private static let maxInlineImageBytes = 12 * 1024 * 1024

    /// A content `image` block. Claude embeds the bytes as base64, so inline it as a
    /// self-contained data URI — the only image source that loads under
    /// `loadHTMLString(baseURL: nil)`, which can't reach `file://` or the network.
    private static func imageCard(_ b: [String: Any]) -> String {
        guard let source = b["source"] as? [String: Any],
              (source["type"] as? String) == "base64",
              let media = source["media_type"] as? String,
              let data = source["data"] as? String, !data.isEmpty
        else { return "<div class=\"image\">🖼 image</div>" }
        return "<img class=\"shot\" src=\"data:\(escaped(media));base64,\(data)\" alt=\"attached image\">"
    }

    private static let imageRefRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: #"\[Image:\s*source:\s*([^\]]+?)\]"#)

    /// Reads an on-disk image and returns it as a base64 `data:` URI, or nil if it's
    /// not a web-renderable image, is missing, or is over `maxInlineImageBytes`.
    private static func imageDataURI(path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        let ext = (expanded as NSString).pathExtension.lowercased()
        guard inlineImageExtensions.contains(ext) else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: expanded),
              let size = (attrs[.size] as? NSNumber)?.intValue, size <= maxInlineImageBytes,
              let data = FileManager.default.contents(atPath: expanded) else { return nil }
        let media = ext == "jpg" ? "jpeg" : ext
        return "data:image/\(media);base64,\(data.base64EncodedString())"
    }

    // MARK: Helpers

    /// The keys a tool's arguments are most likely to be *about*, so a row can say
    /// `Bash · git status` instead of a wall of JSON. Falls back to the first few
    /// key=value pairs for a tool we don't know.
    private static let previewKeys = [
        "command", "cmd", "file_path", "path", "notebook_path", "pattern", "url", "query",
        "description", "prompt",
    ]

    /// The preview for an agent that hands its arguments over as a JSON *string* (Codex,
    /// Grok): read the argument that names the work, and fall back to the raw text — a
    /// code-mode script is source, not JSON, and reads fine as itself.
    private static func toolPreview(json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return oneLine(json)
        }
        return toolPreview(object)
    }

    private static func toolPreview(_ input: Any?) -> String {
        if let text = input as? String { return oneLine(text) }
        guard let dict = input as? [String: Any] else { return "" }
        for key in previewKeys {
            if let value = dict[key] as? String, !value.isEmpty { return oneLine(value) }
        }
        // An unknown tool: its first few arguments as JSON, not Swift's `String(describing:)`
        // dump of the decoded dictionary.
        return dict.keys.sorted().prefix(3).map { key in
            "\(key)=\(oneLine(compactJSON(dict[key])))"
        }.joined(separator: " ")
    }

    /// Collapses a block of text to the single line a ledger row shows. Cut server-side
    /// as well as by CSS so a megabyte of tool output never rides in the row markup.
    ///
    /// The cut happens *before* the whitespace collapse, not after: a preview is at most
    /// 240 characters, and running a regex over the full megabyte first only to throw
    /// away all but the head is the difference between a preview costing microseconds and
    /// costing milliseconds — once per record, over hundreds of records. The slack of
    /// `previewScanLimit` covers a head made mostly of indentation.
    private static func oneLine(_ s: String) -> String {
        let head = s.count > previewScanLimit ? String(s.prefix(previewScanLimit)) : s
        let flat = head.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // `s` is longer than what was scanned, so the ellipsis is honest either way.
        if flat.count > 240 { return String(flat.prefix(240)) + "…" }
        return s.count > previewScanLimit ? flat + "…" : flat
    }

    private static let previewScanLimit = 2_000

    private static func elapsed(from start: Date?, to end: Date?) -> TimeInterval? {
        guard let start, let end else { return nil }
        let delta = end.timeIntervalSince(start)
        return delta >= 0 ? delta : nil
    }

    /// Wall span of a turn: its first start to the end of the last record that finished.
    private static func wallSpan(of records: [Record]) -> TimeInterval? {
        let starts = records.compactMap(\.startedAt)
        guard let first = starts.min() else { return nil }
        let ends = records.compactMap { record -> Date? in
            record.startedAt?.addingTimeInterval(record.duration ?? 0)
        }
        guard let last = ends.max(), last > first else { return nil }
        return last.timeIntervalSince(first)
    }

    private static func usageLabel(_ usage: [String: Any]?) -> String? {
        guard let out = usage?["output_tokens"] as? Int, out > 0 else { return nil }
        return "\(compact(out))↑"
    }

    private static func usageTooltip(_ usage: [String: Any]?) -> String? {
        guard let usage else { return nil }
        var parts: [String] = []
        if let v = usage["input_tokens"] as? Int, v > 0 { parts.append("\(v) input") }
        let cache = ((usage["cache_read_input_tokens"] as? Int) ?? 0)
            + ((usage["cache_creation_input_tokens"] as? Int) ?? 0)
        if cache > 0 { parts.append("\(cache) cached") }
        if let v = usage["output_tokens"] as? Int, v > 0 { parts.append("\(v) output") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func toolResultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    /// Codex writes a tool's output either as a plain string or as the newer array of
    /// `{type: input_text, text}` parts.
    private static func codexOutputText(_ output: Any?) -> String {
        if let s = output as? String { return s }
        if let parts = output as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }

    /// Codex encodes a function call's arguments as a JSON *string*; pretty-print it
    /// when it parses, else show it verbatim.
    private static func codexArguments(_ raw: Any?) -> String {
        guard let text = raw as? String else { return prettyJSON(raw) }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.prettyPrinted, .sortedKeys,
                                                                 .withoutEscapingSlashes]),
              let string = String(data: pretty, encoding: .utf8) else { return text }
        return string
    }

    /// Codex exec results embed the process exit line; a non-zero code marks a failed
    /// tool call. When absent (non-exec tools) we don't guess and treat it as success.
    private static func codexOutputFailed(_ output: String) -> Bool {
        guard let range = output.range(of: "exited with code ") else { return false }
        let code = output[range.upperBound...].prefix { $0.isNumber }
        return !code.isEmpty && code != "0"
    }

    /// Heuristic for Grok tool failures — content often begins with `Error:`.
    private static func grokToolResultFailed(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("Error:") || trimmed.hasPrefix("error:")
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

    /// One-line JSON for a preview cell. `JSONSerialization` only serialises containers, so
    /// scalars are described directly.
    private static func compactJSON(_ value: Any?) -> String {
        guard let value else { return "" }
        if let s = value as? String { return s }
        guard JSONSerialization.isValidJSONObject(value),
              let d = try? JSONSerialization.data(withJSONObject: value,
                                                  options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else { return String(describing: value) }
        return s
    }

    private static func prettyJSON(_ value: Any?) -> String {
        guard let value else { return "" }
        if let s = value as? String { return s }
        guard JSONSerialization.isValidJSONObject(value),
              let d = try? JSONSerialization.data(withJSONObject: value,
                                                  options: [.prettyPrinted, .sortedKeys,
                                                            .withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else {
            return String(describing: value)
        }
        return s
    }

    /// `12345` → `12.3k`, `169304050` → `169M`; small counts stay exact. A long agent
    /// session reads hundreds of millions of cached tokens, and `169304k` is not a number
    /// anyone parses.
    private static func compact(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        let k = Double(n) / 1000
        if k < 100 { return String(format: "%.1fk", k) }
        if k < 1000 { return "\(Int(k.rounded()))k" }
        let m = k / 1000
        return m < 100 ? String(format: "%.1fM", m) : "\(Int(m.rounded()))M"
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }

    /// A single step's own time, at the resolution that step deserves: milliseconds for a
    /// fast tool call, a minute count for a long one.
    private static func elapsedLabel(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return duration(seconds)
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

    /// `escaped` plus the quote, for text that lands inside an attribute value.
    private static func attribute(_ s: String) -> String {
        escaped(s).replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Document

    private static func document(title: String, stats: Stats, records: [Record], theme: TraceTheme,
                                 includeHeader: Bool = true, notice: String? = nil) -> String {
        let headerHTML = includeHeader ? "<header>\n  <h1>\(escaped(title))</h1>\n</header>" : ""
        let content: String
        if let notice {
            content = "<div class=\"empty\">\(escaped(notice))</div>"
        } else if records.isEmpty {
            content = "<div class=\"empty\">No steps recorded yet.</div>"
        } else {
            content = """
            \(histogram(records))
            \(controls)
            \(filterBar(records))
            \(columnHeader)
            <section class="ledger">\(ledger(records))</section>
            """
        }
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escaped(title)) — termio trajectory</title>
        <style>\(themeVariables(theme))\n\(includeHeader ? ":root { --top: 33px; }" : "")
        \(MarkdownSkin.highlightTheme(dark: theme.isDark))\n\(MarkdownSkin.css(scope: ".text.md "))\n\(css)</style></head>
        <body>
        \(headerHTML)
        <main>
        \(summary(stats))
        \(content)
        </main>
        </body></html>
        """
    }

    /// The live termio theme injected as CSS custom properties; the static stylesheet
    /// below references them, so the page always matches the app's current colors.
    /// The four step hues are the only colors the page adds: low-emphasis tints that
    /// separate roles at a glance without borrowing success / warning meaning, plus one
    /// red that means exactly one thing — a tool call failed.
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
          --k-user: \(t.isDark ? "#e6e6e8" : "#1d1d1f");
          --k-agent: var(--accent);
          --k-think: var(--muted);
          --k-tool: \(t.isDark ? "#d9a441" : "#96681a");
          --k-err: #e5484d;
          --k-err-text: \(t.isDark ? "#f0666a" : "#d13c41");
        \(MarkdownSkin.alertVariables(dark: t.isDark))
        }
        """
    }

    /// Static stylesheet, all colors via `var(--…)` from `themeVariables`. Only `{`/`}`
    /// (safe in a plain Swift string — interpolation is solely `\(…)`) and no `\`.
    private static let css = """
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--bg); color: var(--fg);
      font: 13px/1.55 -apple-system, "SF Pro Text", system-ui, sans-serif; }
    header { position: sticky; top: 0; z-index: 3; padding: 8px 22px;
      background: color-mix(in srgb, var(--bg) 88%, transparent);
      backdrop-filter: blur(12px); border-bottom: 1px solid var(--line); }
    header h1 { margin: 0; font-size: 14px; font-weight: 600; }
    main { max-width: 940px; margin: 0 auto; padding: 18px 20px 96px; }
    .empty { color: var(--muted); padding: 32px 0; text-align: center; }

    /* The session's totals as one line of prose-weight facts, with the two breakdowns
       folded away beneath it. */
    .facts { display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 14px;
      padding: 2px 0 10px; color: var(--muted); font-size: 12px; }
    .fact { white-space: nowrap; font-variant-numeric: tabular-nums; }
    .fact b { color: var(--fg); font-weight: 600; }
    .fact.bad, .fact.bad b { color: var(--k-err-text); }
    /* The tool naming sits a step back from the counted facts around it. */
    .fact.quiet { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 11px;
      opacity: 0.75; }
    .panel { border-top: 1px solid var(--line); }
    .panel > summary { cursor: pointer; font-size: 11px; color: var(--muted);
      padding: 5px 0; list-style: none; }
    .panel > summary::-webkit-details-marker { display: none; }
    .panel > summary::before { content: "›"; display: inline-block; width: 12px;
      opacity: 0.6; transition: transform 0.16s cubic-bezier(0.23, 1, 0.32, 1); }
    .panel > summary .hint { margin-left: 8px; opacity: 0.65;
      font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 11px; }
    /* A clicked summary keeps focus, and WebKit paints that as a full-bleed band across
       the row. Keep a ring for the keyboard, drop the band for the mouse. */
    .panel > summary:focus { outline: none; }
    .panel > summary:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px;
      border-radius: 4px; }
    .panel[open] > summary::before { transform: rotate(90deg); }
    @media (hover: hover) and (pointer: fine) { .panel > summary:hover { color: var(--fg); } }
    .tools { padding: 2px 0 8px; }
    .tool-row { display: flex; align-items: center; gap: 10px; padding: 3px 0; }
    .tool-label { flex: 0 0 34%; min-width: 0; overflow: hidden; text-overflow: ellipsis;
      font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 12px; }
    .tool-bar { flex: 1; height: 6px; background: var(--line); border-radius: 3px; overflow: hidden; }
    .tool-bar > span { display: block; height: 100%; background: color-mix(in srgb, var(--fg) 32%, transparent); }
    .tool-count { flex: 0 0 auto; color: var(--muted); font-size: 12px; min-width: 24px; text-align: right; }
    .meta { padding: 4px 0 10px; }
    .meta-row { display: flex; gap: 10px; padding: 2px 0; font-size: 12px; }
    .meta-key { flex: 0 0 96px; color: var(--muted); font-size: 11px; }
    .meta-val { min-width: 0; font-family: ui-monospace, "SF Mono", Menlo, monospace;
      overflow-wrap: anywhere; word-break: break-all; }
    .sysnote { white-space: pre-wrap; color: var(--muted); font-size: 12px; margin: 6px 0;
      border-left: 2px solid var(--line); padding-left: 10px; }

    /* Histogram: where the session's work fell on the clock. Columns are links into the
       ledger, so the strip is navigation as much as it is a picture. */
    .histogram { margin: 14px 0 10px; }
    .cols { display: flex; align-items: flex-end; gap: 1px; height: 46px;
      padding: 0 1px 2px; border-bottom: 1px solid var(--line); }
    .col { position: relative; display: flex; align-items: flex-end; height: 100%;
      min-width: 2px; border-radius: 2px 2px 0 0; }
    a.col:hover { background: color-mix(in srgb, var(--fg) 7%, transparent); }
    .stack { display: flex; flex-direction: column-reverse; width: 100%; min-height: 2px;
      border-radius: 2px 2px 0 0; overflow: hidden; }
    /* Chart colours are not tag colours: `--k-user` is the foreground, and a bar painted
       in it is pure black on white or pure white on black — the heaviest mark on the page
       for the least interesting series. Segments step back to a neutral. */
    .seg { display: block; width: 100%; background: var(--k-agent); }
    .seg.k-user, .seg.k-note { background: color-mix(in srgb, var(--fg) 38%, transparent); }
    .seg.k-thinking { background: color-mix(in srgb, var(--k-think) 70%, transparent); }
    .seg.k-tool { background: color-mix(in srgb, var(--k-tool) 80%, transparent); }
    .axis { display: flex; justify-content: space-between; color: var(--muted);
      font-size: 11px; padding-top: 4px; font-variant-numeric: tabular-nums; }
    .axis-span { opacity: 0.7; }

    /* Filter bar. The inputs it drives are off-screen; the labels are the control. */
    .ctl { position: absolute; opacity: 0; pointer-events: none; }
    .filters { position: sticky; top: var(--top, 0px); z-index: 3; display: flex; gap: 4px;
      align-items: center; padding: 7px 0;
      background: color-mix(in srgb, var(--bg) 92%, transparent); backdrop-filter: blur(10px); }
    .filters .spacer { flex: 1; }
    /* `.filter`, not `.chip` — the summary tiles above already own that name, and a label
       inheriting their 10px padding is why these read as tiles rather than controls. */
    .filter { display: inline-flex; align-items: baseline; gap: 5px;
      cursor: pointer; user-select: none; padding: 3px 9px; border-radius: 7px;
      font-size: 12px; color: var(--muted); background: transparent;
      border: 1px solid transparent; transition: color 0.12s ease, background 0.12s ease; }
    .filter .n { font-size: 11px; opacity: 0.6; font-variant-numeric: tabular-nums; }
    .filter.empty { opacity: 0.35; pointer-events: none; }
    @media (hover: hover) and (pointer: fine) {
      .filter:hover { color: var(--fg); background: color-mix(in srgb, var(--fg) 5%, transparent); }
    }
    #f-all:checked ~ .filters .f-all, #f-msg:checked ~ .filters .f-msg,
    #f-tool:checked ~ .filters .f-tool, #f-err:checked ~ .filters .f-err,
    #f-open:checked ~ .filters .toggle[for="f-open"],
    #f-wrap:checked ~ .filters .toggle[for="f-wrap"] {
      color: var(--fg); background: color-mix(in srgb, var(--fg) 9%, transparent);
      border-color: var(--line); }

    /* One grid for the header and every row, so the columns are the same columns. */
    .colhead, .row, .plain { display: grid; align-items: center; gap: 10px;
      grid-template-columns: 62px 40px minmax(0, 1fr) 52px 84px;
      padding: 0 10px 0 16px; }
    .colhead { position: sticky; top: calc(var(--top, 0px) + 33px); z-index: 2;
      min-height: 24px; font-size: 11px;
      color: var(--muted); opacity: 0.8; border-bottom: 1px solid var(--line);
      background: color-mix(in srgb, var(--bg) 92%, transparent); backdrop-filter: blur(10px); }
    .colhead .tok, .colhead .dur, .colhead .at { font-size: 11px; font-family: inherit; }
    .colhead .tag { font-family: inherit; letter-spacing: 0; font-weight: 400; opacity: 1; }

    /* Ledger: turn groups, each a sticky header over its rows. */
    .turn-head { position: sticky; top: calc(var(--top, 0px) + 57px); z-index: 1; display: flex;
      gap: 10px; align-items: baseline; padding: 7px 10px 7px 16px; margin-top: 6px;
      border-top: 1px solid var(--line);
      background: color-mix(in srgb, var(--bg) 92%, transparent); backdrop-filter: blur(10px); }
    .turn-no { font-size: 12px; font-weight: 600; }
    .turn-facts { font-size: 11px; color: var(--muted);
      font-family: ui-monospace, "SF Mono", Menlo, monospace;
      font-variant-numeric: tabular-nums;
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .rec { scroll-margin-top: 108px; }
    /* Striping, not borders: at 26px a rule under every row is louder than the rows.
       Only in the unfiltered view — `nth-child` counts hidden rows too, so under a filter
       the stripes would land on an arbitrary half of what is left. */
    #f-all:checked ~ .ledger .rec:nth-child(even) > .row,
    #f-all:checked ~ .ledger .rec:nth-child(even) > .plain {
      background: color-mix(in srgb, var(--fg) 2.5%, transparent); }
    .rec.nested .row, .rec.nested .plain { padding-left: 30px; }
    .rec[data-err] > .row, .rec[data-err] > .plain {
      box-shadow: inset 2px 0 0 color-mix(in srgb, var(--k-err) 70%, transparent); }
    .row, .plain { position: relative; min-height: 26px; }
    .row { cursor: pointer; }
    /* Hover is a pointer affordance; on the phone a tap would leave it stuck on. */
    @media (hover: hover) and (pointer: fine) {
      .row:hover { background: color-mix(in srgb, var(--fg) 6%, transparent); }
    }
    .row:active { background: color-mix(in srgb, var(--fg) 9%, transparent); }
    .at { color: var(--muted); font-size: 11px; font-variant-numeric: tabular-nums;
      font-family: ui-monospace, "SF Mono", Menlo, monospace; }
    .at.dim { opacity: 0.4; }
    /* Colour goes to what is rare. Tools are most of a session, so an amber tag on every
       one of 360 rows is the loudest thing on the page and marks nothing; the turns you
       are actually looking for get the colour instead, and red still means one thing. */
    .tag { font-size: 11px; font-weight: 500; color: var(--muted); opacity: 0.75; }
    .rec[data-kind="user"] .tag { color: var(--k-user); opacity: 1; }
    .rec[data-kind="assistant"] .tag { color: var(--k-agent); opacity: 1; }
    .rec[data-err] .tag { color: var(--k-err-text); opacity: 1; }
    .what { display: flex; gap: 8px; align-items: baseline; min-width: 0; }
    .name { flex: 0 0 auto; font-weight: 550;
      font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 12px; }
    .rec[data-kind="thinking"] .name, .rec[data-kind="note"] .name { color: var(--muted); }
    .prev { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis;
      overflow-wrap: anywhere; white-space: nowrap; color: var(--muted); font-size: 12px; }
    /* Wrap: the log-viewer escape hatch for a line whose tail is the interesting part. */
    #f-wrap:checked ~ .ledger .what { display: block; }
    #f-wrap:checked ~ .ledger .name { margin-right: 8px; }
    #f-wrap:checked ~ .ledger .prev { white-space: normal; overflow: visible; }
    #f-wrap:checked ~ .ledger .row, #f-wrap:checked ~ .ledger .plain { align-items: start;
      padding-top: 5px; padding-bottom: 5px; }
    .tok, .dur { text-align: right; color: var(--muted); font-size: 11px;
      font-variant-numeric: tabular-nums;
      font-family: ui-monospace, "SF Mono", Menlo, monospace; }
    .dur { position: relative; }
    /* The bar needs a lane long enough to encode magnitude — inside the 52px the number
       occupies, every step from 100ms to 20s drew within a few pixels of each other. The
       track spans the widened column so the fill has somewhere to go. */
    .dur.timed::after { content: ""; position: absolute; left: 0; right: 0; bottom: 1px;
      height: 2px; border-radius: 1px; background: var(--line); }
    .dur-bar { position: absolute; right: 0; bottom: 1px; z-index: 1; height: 2px;
      border-radius: 1px; background: var(--fg); opacity: 0.4; }
    .dur-high .dur-bar { opacity: 0.75; }
    .dur-medium, .dur-high { color: var(--fg); }
    .dur-medium { font-weight: 400; }
    .dur-high { font-weight: 600; }
    .fail { flex: 0 0 auto; font-size: 11px; font-weight: 500;
      padding: 0 6px; border-radius: 5px; color: var(--k-err-text);
      background: color-mix(in srgb, var(--k-err) 12%, transparent); }
    /* A chevron that turns as its row opens — the only affordance the row needs, and the
       only motion on a page that exists to be scanned. */
    .row::before { content: ""; position: absolute; left: 5px; top: 10px;
      width: 4px; height: 4px;
      border-right: 1.4px solid var(--muted); border-bottom: 1.4px solid var(--muted);
      transform: rotate(-45deg); opacity: 0.5;
      transition: transform 0.16s cubic-bezier(0.23, 1, 0.32, 1); }
    .disc { position: absolute; opacity: 0; pointer-events: none; }
    /* The chevron follows the same XOR as the body, or it would point the wrong way on a
       targeted row and on every row under Expand all. */
    #f-open:not(:checked) ~ .ledger .rec:not(:target) > .disc:checked + .row::before,
    #f-open:not(:checked) ~ .ledger .rec:target > .disc:not(:checked) + .row::before,
    #f-open:checked ~ .ledger .rec > .disc:not(:checked) + .row::before {
      transform: rotate(45deg); opacity: 0.8; }
    .disc:focus-visible + .row { outline: 2px solid var(--accent); outline-offset: -2px; }
    @media (prefers-reduced-motion: reduce) { .row::before { transition: none; } }

    /* Narrow (the inspector and phone): metadata gets its own line, leaving the full row
       for the event. The column header goes with the wide grid it describes. */
    @media (max-width: 640px) {
      main { padding: 14px 14px 96px; }
      .facts { gap: 3px 12px; padding-bottom: 8px; }
      .histogram { margin: 10px 0 8px; }
      .cols { height: 40px; }
      .filters { gap: 2px; padding: 5px 0; }
      .filter { gap: 4px; padding: 3px 7px; }
      .colhead { display: none; }
      .turn-head { top: calc(var(--top, 0px) + 37px); gap: 8px;
        padding: 6px 8px 6px 16px; margin-top: 4px; }
      .rec { scroll-margin-top: 84px; }
      .row, .plain { grid-template-columns: 54px minmax(0, 1fr) auto;
        grid-template-areas: "at tag dur" "what what what";
        gap: 0 8px; align-items: baseline; padding: 5px 8px 6px 16px; }
      .row > .at, .plain > .at { grid-area: at; }
      .row > .tag, .plain > .tag { grid-area: tag; }
      .row > .what, .plain > .what { grid-area: what; padding-top: 1px; }
      .row > .dur, .plain > .dur { grid-area: dur; }
      .dur.timed::after, .dur-bar { display: none; }
      .tok { display: none; }
      .what { gap: 6px; }
    }

    /* Expanded body: the same content the old cards showed, one level in from the row. */
    .body { display: none; padding: 6px 12px 16px 32px; }
    /* A row is open when its own toggle says so — XOR whatever is forcing it open. Two
       things force: landing on a row from the histogram (`:target`), and Expand all. If
       those merely *added* an open rule they would win over the toggle underneath, and
       the row could be opened but never closed again. Inverting the toggle's meaning
       while a force is active keeps one click on the row always doing the opposite of
       what is on screen — including collapsing a single noisy row inside Expand all. */
    #f-open:not(:checked) ~ .ledger .rec:not(:target) > .disc:checked ~ .body,
    #f-open:not(:checked) ~ .ledger .rec:target > .disc:not(:checked) ~ .body,
    #f-open:checked ~ .ledger .rec > .disc:not(:checked) ~ .body { display: block; }
    .rec:target > .row { background: color-mix(in srgb, var(--accent) 12%, transparent); }
    .io { margin: 6px 0; border: 1px solid var(--line); border-radius: 8px; background: var(--soft);
      overflow: hidden; }
    .io.error { border-color: color-mix(in srgb, var(--k-err) 32%, var(--line)); }
    .io-label { font-size: 11px; color: var(--muted); padding: 8px 12px 0; }
    .io.error .io-label { color: var(--k-err-text); }
    .cut { font-size: 11px; color: var(--muted); padding: 0 12px 8px; }
    /* Arguments as a field list: the key is a label, the value is content. A short value
       sits on the key's line; anything long or multi-line gets the full width beneath it,
       because that is where a command or a patch is actually read. */
    .args { padding: 4px 12px 10px; }
    .arg { display: flex; gap: 10px; align-items: baseline; padding: 3px 0; min-width: 0; }
    .arg .key { flex: 0 0 92px; color: var(--muted); font-size: 11px; text-align: right; }
    .arg .val { flex: 1 1 auto; min-width: 0; font-family: ui-monospace, "SF Mono", Menlo, monospace;
      font-size: 12px; overflow-wrap: anywhere; word-break: break-word; }
    .arg.block { display: block; }
    .arg.block .key { display: block; text-align: left; margin-bottom: 2px; }
    .arg.block pre { padding: 0; }
    .args pre { background: none; }
    pre { margin: 0; padding: 8px 12px 12px; overflow-x: auto; white-space: pre-wrap;
      overflow-wrap: anywhere; word-wrap: break-word; font-family: ui-monospace, "SF Mono", Menlo, monospace;
      font-size: 12px; opacity: 0.92; }
    .think { white-space: pre-wrap; color: var(--muted); font-style: italic;
      border-left: 2px solid var(--line); padding-left: 12px; margin: 4px 0; }
    .image { color: var(--muted); font-size: 12px; margin: 8px 0; }
    .shot { display: block; max-width: 360px; width: 100%; height: auto; margin: 10px 0;
      border-radius: 10px; border: 1px solid var(--line); }
    .text.md .shot { max-width: 100%; }

    @media (max-width: 640px) {
      .body { padding: 6px 4px 16px 16px; }
      .meta-key, .arg .key { flex-basis: 72px; }
    }

    /* Filters: each one hides the rows it excludes, and any turn with nothing left. */
    #f-msg:checked ~ .ledger .rec:not([data-kind="user"]):not([data-kind="assistant"]) { display: none; }
    #f-msg:checked ~ .ledger .group:not(:has(.rec[data-kind="user"], .rec[data-kind="assistant"])) { display: none; }
    #f-tool:checked ~ .ledger .rec:not([data-kind="tool"]) { display: none; }
    #f-tool:checked ~ .ledger .group:not(:has(.rec[data-kind="tool"])) { display: none; }
    #f-err:checked ~ .ledger .rec:not([data-err]) { display: none; }
    #f-err:checked ~ .ledger .group:not(:has(.rec[data-err])) { display: none; }

    /* Markdown inside an expanded message. */
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
    .text.md pre { background: var(--soft); border: 1px solid var(--line); border-radius: 8px;
      margin: 10px 0; padding: 12px; }
    .text.md pre code { background: none; border: none; padding: 0; }
    .text.md .alert { margin: 10px 0; padding: 2px 0 2px 12px; border-left: 3px solid var(--alert-color); }
    .text.md .alert-title { margin: 0 0 4px; color: var(--alert-color); font-size: 11px;
      font-weight: 700; letter-spacing: 0.04em; text-transform: uppercase; }
    .text.md .alert > *:last-child { margin-bottom: 0; }
    .text.md .math-display { margin: 10px 0; }
    .text.md .footnotes { margin-top: 14px; padding-top: 8px; border-top: 1px solid var(--line);
      font-size: 12.5px; color: var(--muted); }
    .text.md ul, .text.md ol { margin: 8px 0; padding-left: 22px; }
    .text.md li { margin: 3px 0; }
    .text.md li.task { list-style: none; }
    .text.md li.task .task-box { width: 1.05em; height: 1.05em; vertical-align: -0.16em;
      margin: 0 0.4em 0 -1.5em; color: var(--muted); }
    .text.md li.task .task-box.checked { color: var(--accent); }
    .text.md blockquote { margin: 10px 0; padding-left: 12px;
      border-left: 3px solid var(--line); color: var(--muted); }
    .text.md table { border-collapse: collapse; margin: 10px 0; font-size: 12.5px;
      display: block; overflow-x: auto; }
    .text.md th, .text.md td { border: 1px solid var(--line); padding: 4px 10px; text-align: left; }
    .text.md th { background: var(--soft); }
    .text.md hr { border: none; border-top: 1px solid var(--line); margin: 14px 0; }
    .text.md a { color: var(--accent); }
    """
}
