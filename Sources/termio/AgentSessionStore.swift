import Foundation

/// Discovers the conversation id that an agent which can't be handed one up front
/// (Codex, OpenCode) created for a session, so a relaunch can resume that *exact*
/// session by id rather than just continuing whatever ran last in the directory.
///
/// Neither CLI accepts a session id at launch, so the id is learned afterward: termio
/// records when it launched the agent (`Session.launchedAt`) and then matches the
/// agent's own session record by (a) working directory and (b) the file's creation
/// time. Creation time is read from the *filesystem* — the same system clock as
/// `launchedAt`, and (unlike modification time) it doesn't move as the conversation
/// grows — so the record created right when we launched is the one we bind to.
///
/// The record locations and field paths come from the manifest's `resume.discover`
/// descriptor — pure mechanism (a root, a format, two key paths), interpreted
/// generically here with no agent identities. The layouts described are each agent's
/// *private* on-disk format, undocumented and free to change between agent versions,
/// so every read is best-effort: any miss returns `nil` and the session launches fresh.
enum AgentSessionStore {
    static func discover(agent: AgentPreset, directory: String, after launchedAt: Date?) -> String? {
        match(agent: agent, directory: directory, after: launchedAt)?.id
    }

    /// The on-disk conversation transcript for an agent that doesn't hand termio a
    /// transcript path through its hooks the way Claude Code does. A `jsonl` record is
    /// the agent's session log itself (Codex's rollout file), so the Info pane can
    /// render a trace from it; a `json` record is metadata only (OpenCode). Returns the
    /// file path, or `nil` when none matches (yet) or the record isn't a transcript.
    static func discoverTranscript(agent: AgentPreset, directory: String, after launchedAt: Date?) -> String? {
        guard agent.resumeSpec.discover?.format == .jsonl else { return nil }
        return match(agent: agent, directory: directory, after: launchedAt)?.url.path
    }

    /// The session record for this agent — its URL and the session id parsed from it.
    /// Both `discover` (id, for resume) and `discoverTranscript` (path, for the trace
    /// viewer) read from the same scan.
    private static func match(agent: AgentPreset, directory: String, after launchedAt: Date?)
        -> (url: URL, id: String)? {
        guard let launchedAt, let spec = agent.resumeSpec.discover else { return nil }
        let root = URL(fileURLWithPath: (spec.root as NSString).expandingTildeInPath)
        let target = canonical(directory)
        return bestMatch(in: root, ext: spec.format.fileExtension, after: launchedAt) { url in
            guard let object = record(at: url, format: spec.format),
                  let id = value(at: spec.id, in: object),
                  let cwd = value(at: spec.cwd, in: object),
                  canonical(cwd) == target
            else { return nil }
            return id
        }
    }

    /// A small negative tolerance: the agent writes its record just after we launch it,
    /// so its creation time should be ≥ `launchedAt`, but allow for clock granularity.
    private static let tolerance: TimeInterval = 2

    /// One session record as a JSON object: for `jsonl`, the log's first line (the
    /// header event); for `json`, the whole file.
    private static func record(at url: URL,
                               format: AgentDefinition.ResumeSpec.Discover.Format) -> [String: Any]? {
        switch format {
        case .jsonl:
            return firstLine(of: url).flatMap(json)
        case .json:
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    /// The string at a dot-separated key path (e.g. `payload.id`) in a JSON object.
    private static func value(at keyPath: String, in object: [String: Any]) -> String? {
        var current: Any = object
        for key in keyPath.split(separator: ".") {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[String(key)] else { return nil }
            current = next
        }
        return current as? String
    }

    /// Walks `root` for `ext` files created at/after `launchedAt`, runs `identify` (which
    /// confirms the working directory and returns the session id), and returns the URL and
    /// id of the *earliest-created* match — the session born when we launched this one.
    private static func bestMatch(in root: URL, ext: String, after launchedAt: Date,
                                  identify: (URL) -> String?) -> (url: URL, id: String)? {
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys) else { return nil }

        let threshold = launchedAt.addingTimeInterval(-tolerance)
        var best: (url: URL, id: String, created: Date)?
        for case let url as URL in enumerator {
            guard url.pathExtension == ext,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let created = values.creationDate, created >= threshold,
                  best == nil || created < best!.created,
                  let id = identify(url)
            else { continue }
            best = (url, id, created)
        }
        return best.map { ($0.url, $0.id) }
    }

    /// Resolves symlinks and standardizes a path so termio's recorded workspace and the
    /// agent's recorded cwd compare equal even when one side went through `/private`.
    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func json(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The first line of a (possibly large) JSONL file, read from a bounded prefix so a
    /// long transcript isn't slurped whole just to reach its `session_meta` header.
    private static func firstLine(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: 64 * 1024),
              let text = String(data: chunk, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", maxSplits: 1).first.map(String.init)
    }
}
