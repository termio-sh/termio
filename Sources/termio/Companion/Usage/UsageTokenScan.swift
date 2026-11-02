import Foundation

/// The token totals for one time window, broken out by kind so the dollar
/// estimate can weight each correctly (cache reads are ~10× cheaper than fresh
/// input). `total` is the literal throughput — every token the agent processed.
struct TokenWindowStats: Sendable, Hashable {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0
    /// Accumulated dollar estimate, priced per token as each line is scanned.
    /// Zero for agents whose provider pricing termio doesn't carry (Codex).
    var costUSD = 0.0

    var total: Int { input + output + cacheWrite + cacheRead }
    var isEmpty: Bool { total == 0 }

    mutating func add(_ other: TokenWindowStats) {
        input += other.input
        output += other.output
        cacheWrite += other.cacheWrite
        cacheRead += other.cacheRead
        costUSD += other.costUSD
    }

    /// Compact token count for the UI: `1.2M`, `980K`, `420`.
    var tokenSummary: String {
        let value = total
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fK", Double(value) / 1_000) }
        return "\(value)"
    }

    /// Dollar estimate as `$3.40`, or empty when this window carries no priced cost.
    var costSummary: String {
        costUSD > 0 ? String(format: "$%.2f", costUSD) : ""
    }
}

/// One agent's token usage across the three windows the user asked for. `hasCost`
/// is false for agents shown as token counts only (no priced model table).
struct AgentTokenUsage: Sendable, Hashable {
    var today = TokenWindowStats()
    var week = TokenWindowStats()
    var month = TokenWindowStats()
    /// Per-local-day totals feeding the activity chart, covering the scan window
    /// (the last ~month). Keys are `startOfDay` instants in the scan's calendar.
    var daily: [Date: TokenWindowStats] = [:]
    var hasCost = false

    /// True when there is nothing to show at all — no in-month totals and no
    /// historical days — so the agent's pane can fall back to its hint.
    var isEmpty: Bool { month.isEmpty && daily.values.allSatisfy(\.isEmpty) }
}

/// The local-calendar boundaries the scan buckets into. Today is since local
/// midnight; week and month follow the user's calendar (locale-aware first
/// weekday, real month length). Today ⊂ this week ⊂ this month always holds, so a
/// line is simply added to each window whose start it is at or after.
struct DateWindows: Sendable {
    let todayStart: Date
    let weekStart: Date
    let monthStart: Date
    /// Where the scan stops looking back: the older of the month start and the
    /// activity chart's 30-day horizon, so the month totals stay whole and the
    /// chart's oldest day is never half-scanned. Anything older is skipped.
    let scanStart: Date
    let calendar: Calendar

    init(now: Date = Date(), calendar: Calendar = .current) {
        self.calendar = calendar
        todayStart = calendar.startOfDay(for: now)
        weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? todayStart
        monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? todayStart
        let chartStart = calendar.date(byAdding: .day, value: -29, to: todayStart)
            ?? todayStart.addingTimeInterval(-29 * 86_400)
        scanStart = min(monthStart, chartStart)
    }
}

/// Accumulates one agent's scanned log lines into the time windows and per-day
/// buckets.
///
/// This owns the three pieces every scanner needs — the window arithmetic, the
/// local-day resolver, and the duplicate filter — so a provider's scanner is
/// only ever "recognise a line, hand over a delta".
struct TokenTally {
    private let windows: DateWindows
    private var usage: AgentTokenUsage
    private var dayStart = Date.distantFuture
    private var dayEnd = Date.distantPast
    // Hashes, not the id strings themselves — a month of heavy use is hundreds
    // of thousands of ids, and a Set of full strings would hold tens of MB.
    private var seen = Set<Int>()

    init(_ windows: DateWindows, hasCost: Bool = false) {
        self.windows = windows
        usage = AgentTokenUsage(hasCost: hasCost)
    }

    /// True once `id` has already been counted — the turns some CLIs re-emit on
    /// resume. A record with no id is always counted; there is nothing to match
    /// it against.
    mutating func isDuplicate(_ id: String?) -> Bool {
        guard let id, !id.isEmpty else { return false }
        return !seen.insert(id.hashValue).inserted
    }

    /// Adds one record's tokens to every window it falls in, plus its day bucket.
    /// The caller has already dropped anything older than `windows.scanStart`.
    mutating func add(_ delta: TokenWindowStats, at timestamp: Date) {
        if timestamp >= windows.monthStart { usage.month.add(delta) }
        if timestamp >= windows.weekStart { usage.week.add(delta) }
        if timestamp >= windows.todayStart { usage.today.add(delta) }
        usage.daily[day(for: timestamp), default: TokenWindowStats()].add(delta)
    }

    var result: AgentTokenUsage { usage }

    /// Resolves a timestamp to its local `startOfDay`, caching the current day's
    /// bounds — log lines arrive in near-chronological runs, so almost every call
    /// is a two-comparison hit instead of a calendar computation.
    private mutating func day(for timestamp: Date) -> Date {
        if timestamp >= dayStart, timestamp < dayEnd { return dayStart }
        dayStart = windows.calendar.startOfDay(for: timestamp)
        dayEnd = windows.calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)
        return dayStart
    }
}

/// The append-only JSONL session logs every agent CLI writes. The layouts differ
/// per agent; the reading of them does not.
enum UsageLog {
    /// Calls `record` with the JSON object on each line of `file` that contains
    /// `probe`.
    ///
    /// The probe matches raw UTF-8 bytes, never Swift `String`: a
    /// `Substring.contains` over 1.5 GB of logs does Unicode-grapheme work on
    /// every byte and is ~20× slower than byte scanning. That cheap probe gates
    /// the JSON parse, so only genuine record lines are ever decoded, and a torn
    /// trailing line simply fails to parse.
    static func records(in file: URL, probe: Data, _ record: ([String: Any]) -> Void) {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return }
        for line in data.split(separator: 0x0A) {
            guard line.range(of: probe) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            record(object)
        }
    }

    /// The same, over every log under `root` that `isLog` accepts.
    ///
    /// Files untouched since before `since` can't hold an in-window line (the
    /// logs are append-only), so they're skipped by modification date — the one
    /// cheap prefilter available.
    static func records(
        under root: URL, probe: Data, since: Date,
        isLog: (URL) -> Bool, _ record: ([String: Any]) -> Void
    ) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys) else { return }
        for case let url as URL in walker where isLog(url) {
            if let modified = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate,
               modified < since {
                continue
            }
            records(in: url, probe: probe, record)
        }
    }
}
