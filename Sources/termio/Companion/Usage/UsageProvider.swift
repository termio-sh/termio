import Foundation

/// One usage window for an agent's coding plan — a session, weekly, or monthly
/// quota lane with how full it is and when it next resets. Modelled on CodexBar's
/// per-provider limit tiles, but scoped to the agents termio actually launches.
struct UsageWindow: Identifiable, Hashable, Sendable {
    /// The quota period this window covers (e.g. "5h", "Weekly", "Monthly").
    let label: String
    /// How full the window is, 0–100. CodexBar's percent; the bar fills to this.
    let usedPercent: Int
    /// When the window rolls over and frees up again, when the source reports it.
    let resetsAt: Date?

    var id: String { label }

    /// A short "resets in" phrase for the reset time (e.g. "2h", "3d", "now"), or
    /// an empty string when the window has no known reset.
    var resetSummary: String {
        guard let resetsAt else { return "" }
        let seconds = resetsAt.timeIntervalSinceNow
        if seconds <= 0 { return "now" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded()))m" }
        if seconds < 86_400 { return "\(Int((seconds / 3600).rounded()))h" }
        return "\(Int((seconds / 86_400).rounded()))d"
    }

    /// Names a window from its length, so the providers that publish a duration
    /// rather than a name share one vocabulary: hours up to a couple of days,
    /// then "Weekly", then "Monthly". A 30-day free-plan window must not read
    /// "5h", and a 7-day window must not read "Monthly"; the thresholds sit far
    /// from both to absorb skew.
    static func label(forSeconds seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "Usage" }
        switch seconds {
        case ..<(2 * 86_400): return "\(Int((seconds / 3600).rounded()))h"
        case ..<(30 * 86_400): return "Weekly"
        default: return "Monthly"
        }
    }
}

/// A snapshot of one agent's coding-plan usage, or the reason none is shown.
/// `windows` empty with no error means "fetched, nothing to show"; an error is
/// kept only to drive a quiet hint, never an alarm — a missing reading must
/// never interrupt a session.
struct AgentUsage: Hashable, Sendable {
    var windows: [UsageWindow]
}

/// One plan-limit fetch's result: the reading (if any) plus whether the user
/// refused the Keychain prompt along the way, so the monitor can remember the
/// refusal instead of silently retrying it forever.
struct PlanLimitReading {
    var usage: AgentUsage?
    var keychainDeclined = false

    /// Nothing readable — every failure path lands here.
    static let none = PlanLimitReading()

    /// The lanes a provider managed to read, collapsing "fetched, nothing
    /// measurable" back to no reading at all.
    init(_ windows: [UsageWindow]) {
        usage = windows.isEmpty ? nil : AgentUsage(windows: windows)
    }

    init(usage: AgentUsage? = nil, keychainDeclined: Bool = false) {
        self.usage = usage
        self.keychainDeclined = keychainDeclined
    }
}

/// One agent's usage source: where its plan limits come from and how its own
/// session logs are totalled.
///
/// Everything provider-specific — the credential file and its refresh dance, the
/// endpoint, the log layout — lives behind this, so `UsageMonitor` only knows the
/// list and adding an agent is one new file plus one line in that list. The
/// extension below is what a provider gets for free: the HTTP shapes, the
/// credential-file plumbing, and the CLI-home lookup, all of which every
/// provider needs and none of which is worth restating four times.
protocol UsageProvider: Sendable {
    /// The agent this reads for, and its key in the monitor's published maps.
    var agent: AgentPreset { get }

    /// The plan's quota lanes, fetched from the provider's usage endpoint with
    /// the credential its CLI already left on disk. `allowKeychain` is false once
    /// the user has refused the macOS Keychain prompt, so a credential that lives
    /// there stays unread until they explicitly retry.
    func planLimits(allowKeychain: Bool) async -> PlanLimitReading

    /// Token totals scanned out of the agent's own local session logs.
    func tokenUsage(in windows: DateWindows) -> AgentTokenUsage
}

extension UsageProvider {
    // MARK: - CLI data

    /// The CLI's data root: its own `$…_HOME` override when set, else the named
    /// dot-directory under the user's home. Honouring the override matters —
    /// a user who moved the CLI's home expects termio to read what the CLI wrote.
    func cliHome(environment: String, directory: String) -> URL {
        ProcessInfo.processInfo.environment[environment].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(directory)
    }

    /// The JSON object at `file`, or `nil` when it is missing, unreadable, or not
    /// an object — all of which mean the same thing here: no credential.
    func jsonObject(at file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Atomically rewrites a credential file, keeping the CLI's 0600 permissions.
    /// Callers pass the file's whole root back, so fields termio doesn't read
    /// survive the rotation untouched.
    func write(_ root: [String: Any], to file: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: root) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Reads a count that a service encodes as a JSON string (`"limit": "100"`)
    /// or a number, depending on the field — both Kimi's `/usages` and Grok's
    /// billing payload mix the two.
    func number(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let string = value as? String { return Double(string) }
        return nil
    }

    // MARK: - Networking

    /// A JSON GET. `nil` for a malformed URL, which lands in the same "no
    /// reading" branch as any other failure.
    func request(_ url: String) -> URLRequest? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// The same, carrying the CLI's bearer and any headers the endpoint demands.
    func request(_ url: String, bearer: String, headers: [String: String] = [:]) -> URLRequest? {
        guard var request = request(url) else { return nil }
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        return request
    }

    /// Runs `request` and decodes the body as `T`, returning `nil` on any failure
    /// (network, non-2xx, decode) — every caller treats that as "no reading".
    func getJSON<T: Decodable>(_ request: URLRequest) async -> T? {
        guard let data = await body(request) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// The dictionary-shaped sibling of `getJSON`, for endpoints whose wire
    /// format drifts (Kimi's `/usages` has shipped several reset-time spellings).
    func getObject(_ request: URLRequest) async -> [String: Any]? {
        guard let data = await body(request) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The form POST both OAuth refresh flows use, returning the token response
    /// as a dictionary. Field values are percent-encoded here so no caller has to
    /// remember to.
    func postForm(_ url: String, fields: [String: String]) async -> [String: Any]? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.map { field, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            return "\(field)=\(encoded ?? value)"
        }.joined(separator: "&").utf8)
        guard let data = await body(request) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The response body of a 2xx answer, `nil` for anything else.
    private func body(_ request: URLRequest) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return data
    }
}

/// The timestamp shapes the usage endpoints and the session logs emit.
enum UsageTime {
    /// Parses the fractional-second ISO 8601 timestamps the usage endpoints emit
    /// (e.g. `2026-06-27T18:30:00.206589+00:00`), tolerating the missing-fraction
    /// form too. Used off the hot path (a handful of plan-limit reset times).
    static func iso8601(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    /// Renders an instant back in the fractional-second form the CLIs store, for
    /// the credential write-back.
    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// A fast path for the rigid UTC log timestamps (`2026-06-27T11:22:05.555Z`),
    /// called once per turn across ~150k lines. `ISO8601DateFormatter` is ~100×
    /// slower and allocates per call, so the scan extracts the fixed fields by
    /// byte position and builds the instant against a cached UTC calendar; only a
    /// shape that doesn't match falls back to the formatter.
    static func logTimestamp(_ string: String) -> Date? {
        let utf8 = string.utf8
        guard utf8.count >= 19 else { return iso8601(string) }
        let bytes = Array(utf8)
        func number(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            for index in start..<(start + length) {
                let digit = Int(bytes[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x54,  // '-','-','T'
              let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2)
        else { return iso8601(string) }
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = second
        return utcCalendar.date(from: components)
    }

    /// A Gregorian calendar pinned to UTC, reused across the whole scan so the
    /// fast timestamp parser doesn't reallocate one per line.
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()
}
