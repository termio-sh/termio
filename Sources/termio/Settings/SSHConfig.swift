import Foundation

/// The outcome of a non-interactive SSH reachability + auth probe (the Settings
/// "Test Connection" action). Deliberately coarse: enough to tell "it works"
/// from "the network's the problem" from "auth's the problem", each with a short
/// human line for the row and the raw detail in a tooltip.
enum SSHProbeResult: Equatable {
    case reachable
    case authFailed(String)
    case unreachable(String)
}

/// One connectable `Host` block parsed from the user's OpenSSH client config —
/// the same aliases `ssh <alias>` itself resolves. A block that lists several
/// aliases yields one entry per alias. `file`/`line` locate the block's `Host`
/// line so the settings pane can jump straight to it in the editor.
struct SSHConfigHost: Identifiable, Hashable {
    let alias: String
    /// The block's `HostName`, falling back to the alias when the block sets none
    /// (which is how ssh resolves it too).
    let hostName: String
    let user: String
    let port: Int
    /// The block's first `IdentityFile`, verbatim (`~` unexpanded), when set.
    let identityFile: String?
    let file: URL
    let line: Int

    var id: String { "\(file.path)#\(line)#\(alias)" }

    /// The row caption under the alias: `user@host`, with the port only when it
    /// isn't ssh's default.
    var destinationLabel: String {
        let base = user.isEmpty ? hostName : "\(user)@\(hostName)"
        return port == 22 ? base : "\(base):\(port)"
    }
}

/// A public key sitting in `~/.ssh`, listed so its text is one click from the
/// clipboard (for a server's `authorized_keys`). Private keys are never read.
struct SSHPublicKey: Identifiable, Hashable {
    let url: URL
    /// The key's algorithm, prettified from the line's leading token.
    let algorithm: String
    /// The trailing comment (usually `user@machine`), empty when absent.
    let comment: String

    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

/// Reads and appends to the user's `~/.ssh/config`. The config file is the
/// single source of truth for SSH hosts — termio keeps no host database of its
/// own, so anything another tool (or the user, in any editor) writes there shows
/// up here, and anything added here works in a bare `ssh` immediately.
enum SSHConfigFile {
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    /// The config with symlinks resolved — dotfile managers commonly symlink
    /// `~/.ssh/config`, and an atomic write aimed at the link path would replace
    /// the link with a plain file, orphaning the managed target. Every write
    /// (and the in-app editor) goes through this.
    static var writableConfigURL: URL { configURL.resolvingSymlinksInPath() }

    /// The connectable hosts from `~/.ssh/config` and any `Include`d files,
    /// resolved the way ssh itself resolves them: blocks are replayed in file
    /// order and the *first obtained* value per key wins, so `Host *` defaults
    /// and wildcard blocks contribute exactly what a real `ssh <alias>` would
    /// use. (Known simplifications: `Match` blocks are skipped, and an
    /// `Include` splices at the top level rather than into a block's context.)
    static func hosts() -> [SSHConfigHost] {
        var visited: Set<String> = []
        // Directives before any Host/Match line apply unconditionally, exactly
        // as if they sat under `Host *`.
        var context: Block? = Block(patterns: ["*"], file: configURL, line: 0)
        var blocks = blocks(in: configURL, visited: &visited, depth: 0, context: &context)
        if let context { blocks.append(context) }
        var results: [SSHConfigHost] = []
        var seen: Set<String> = []
        for block in blocks {
            for alias in block.patterns
            where !alias.contains("*") && !alias.contains("?") && !alias.hasPrefix("!")
                && !seen.contains(alias) {
                seen.insert(alias)
                var hostName: String?, user: String?, identityFile: String?
                var port: Int?
                for candidate in blocks where matches(alias, patterns: candidate.patterns) {
                    if hostName == nil { hostName = candidate.hostName }
                    if user == nil { user = candidate.user }
                    if port == nil { port = candidate.port }
                    if identityFile == nil { identityFile = candidate.identityFile }
                }
                // ssh expands %h in HostName to the name given on the command
                // line (the alias) — `Host *.cloud` + `HostName %h.internal`.
                let expandedHostName = (hostName ?? alias)
                    .replacingOccurrences(of: "%%", with: "\u{0}")
                    .replacingOccurrences(of: "%h", with: alias)
                    .replacingOccurrences(of: "\u{0}", with: "%")
                results.append(SSHConfigHost(
                    alias: alias, hostName: expandedHostName, user: user ?? "",
                    port: port ?? 22, identityFile: identityFile,
                    file: block.file, line: block.line
                ))
            }
        }
        return results
    }

    /// One `Host` block in file order: its patterns plus the values its own
    /// lines set, kept unresolved so `hosts()` can replay ssh's
    /// first-obtained-value rule across blocks.
    private struct Block {
        var patterns: [String]
        var hostName: String?
        var user: String?
        var port: Int?
        var identityFile: String?
        var file: URL
        var line: Int
    }

    /// ssh_config pattern-list matching for one alias: any negated (`!`)
    /// pattern match excludes the block; otherwise any positive match includes.
    private static func matches(_ alias: String, patterns: [String]) -> Bool {
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if wildcardMatches(String(pattern.dropFirst()), alias) { return false }
            } else if wildcardMatches(pattern, alias) {
                matched = true
            }
        }
        return matched
    }

    /// ssh's own pattern language: `*` and `?` only — deliberately not
    /// `fnmatch`, whose bracket classes would make `web[1-3]` match here while
    /// a real ssh treats the brackets literally.
    private static func wildcardMatches(_ pattern: String, _ candidate: String) -> Bool {
        let p = Array(pattern), c = Array(candidate)
        var pi = 0, ci = 0, star = -1, mark = 0
        while ci < c.count {
            if pi < p.count, p[pi] == "?" || p[pi] == c[ci] {
                pi += 1; ci += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ci; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ci = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// Parses one file into blocks, threading the *current block* through
    /// `context` the way ssh splices `Include`: an included file's leading
    /// directives continue the including block, and a block left open at the
    /// file's end resumes in the includer (the top level flushes the last one).
    private static func blocks(
        in url: URL, visited: inout Set<String>, depth: Int, context: inout Block?
    ) -> [Block] {
        let path = url.standardizedFileURL.path
        // `visited` is the active recursion *stack*, not a permanent memo: a
        // shared file legitimately included under several Host blocks parses
        // once per inclusion; only a file currently being parsed (a cycle) is
        // refused. The depth cap breaks chains the stack can't catch.
        guard depth <= 3, !visited.contains(path),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        visited.insert(path)
        defer { visited.remove(path) }

        var blocks: [Block] = []
        // While true, the parse sits inside a Match block: its directives (and
        // its Includes, which ssh gates on the Match condition) are skipped
        // until the next Host, since this parser doesn't evaluate conditions.
        var inMatch = false

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = tokens(of: line)
            guard let keyword = parts.first?.lowercased() else { continue }
            let values = Array(parts.dropFirst())
            switch keyword {
            case "host":
                if let block = context { blocks.append(block) }
                context = Block(patterns: values, file: url, line: index + 1)
                inMatch = false
            case "match":
                if let block = context { blocks.append(block) }
                context = nil
                inMatch = true
            case "include" where !inMatch:
                for value in values {
                    for included in resolveInclude(value) {
                        blocks.append(contentsOf: Self.blocks(
                            in: included, visited: &visited, depth: depth + 1,
                            context: &context
                        ))
                    }
                }
            case "hostname": if context?.hostName == nil { context?.hostName = values.first }
            case "user": if context?.user == nil { context?.user = values.first }
            case "port": if context?.port == nil { context?.port = values.first.flatMap(Int.init) }
            case "identityfile": if context?.identityFile == nil { context?.identityFile = values.first }
            default: break
            }
        }
        return blocks
    }

    /// Splits an ssh_config line into tokens: whitespace/`=` separated, with
    /// double-quoted segments kept whole (ssh's own quoting for values that
    /// contain spaces — so the app can read back the blocks it writes). A `#`
    /// starting a token ends the line: ssh has no trailing comments, but a
    /// stray note should degrade to being ignored, not to bogus hosts.
    private static func tokens(of line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in line {
            if character == "\"" { inQuotes.toggle(); continue }
            if !inQuotes, character == " " || character == "\t" || character == "=" {
                if !current.isEmpty { tokens.append(current); current = "" }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { tokens.append(current) }
        if let hash = tokens.firstIndex(where: { $0.hasPrefix("#") }) {
            tokens = Array(tokens[..<hash])
        }
        return tokens
    }

    /// Expands one `Include` operand to concrete files: `~` and relative paths
    /// resolve per ssh_config(5) (relative means under `~/.ssh`), and a glob in
    /// the last path component matches directory entries via `fnmatch`.
    private static func resolveInclude(_ pattern: String) -> [URL] {
        var expanded = (pattern as NSString).expandingTildeInPath
        if !expanded.hasPrefix("/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh").appendingPathComponent(expanded).path
        }
        let url = URL(fileURLWithPath: expanded)
        let lastComponent = url.lastPathComponent
        guard lastComponent.contains("*") || lastComponent.contains("?") else { return [url] }
        let directory = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { fnmatch(lastComponent, $0, 0) == 0 }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    /// Creates `~/.ssh` (0700) and an empty config (0600) when missing — the
    /// permissions ssh itself insists on — so the editor and Add Host always have
    /// a real file to work with.
    static func ensureConfigExists() throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let target = writableConfigURL
        if !manager.fileExists(atPath: target.path) {
            manager.createFile(
                atPath: target.path, contents: Data(),
                attributes: [.posixPermissions: 0o600]
            )
        }
    }

    /// Appends a plain `Host` block to `~/.ssh/config`. Optional fields are
    /// simply omitted, and the default port is not written — the block stays as
    /// clean as one written by hand.
    static func appendHost(
        alias: String, hostName: String, user: String, port: String, identityFile: String
    ) throws {
        // ssh_config quotes arguments that contain spaces (a picked key file
        // under "My Drive" must not split into two tokens). Values containing a
        // double quote are unrepresentable in ssh_config and rejected upstream
        // in the sheet.
        func quoted(_ value: String) -> String {
            value.contains(" ") ? "\"\(value)\"" : value
        }
        var block = "Host \(quoted(alias))\n  HostName \(quoted(hostName))\n"
        if !user.isEmpty { block += "  User \(quoted(user))\n" }
        if let portNumber = Int(port), portNumber != 22 { block += "  Port \(portNumber)\n" }
        if !identityFile.isEmpty { block += "  IdentityFile \(quoted(identityFile))\n" }

        try ensureConfigExists()
        let target = writableConfigURL
        var text = try String(contentsOf: target, encoding: .utf8)
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        if !text.isEmpty { text += "\n" }
        try (text + block).write(to: target, atomically: true, encoding: .utf8)
        // The atomic write lands as a fresh temp file, so re-assert the 0600 ssh
        // expects rather than inheriting the process umask.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: target.path
        )
    }

    /// The `*.pub` keys in `~/.ssh`, sorted by name. Unreadable or non-key files
    /// are skipped rather than surfaced — this list is a convenience, not an audit.
    static func publicKeys() -> [SSHPublicKey] {
        let directory = configURL.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".pub") }.sorted().compactMap { name in
            let url = directory.appendingPathComponent(name)
            guard let line = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { return nil }
            let fields = line.split(separator: " ", maxSplits: 2).map(String.init)
            let algorithm: String
            switch fields.first ?? "" {
            case "ssh-ed25519": algorithm = "ED25519"
            case "ssh-rsa": algorithm = "RSA"
            case "ssh-dss": algorithm = "DSA"
            case let raw where raw.hasPrefix("sk-ssh-ed25519"): algorithm = "ED25519-SK"
            case let raw where raw.hasPrefix("sk-ecdsa"): algorithm = "ECDSA-SK"
            case let raw where raw.hasPrefix("ecdsa"): algorithm = "ECDSA"
            // Anything else isn't a public key line — including a `.pub`-named
            // symlink at a private key, which must never reach the clipboard.
            default: return nil
            }
            return SSHPublicKey(
                url: url, algorithm: algorithm,
                comment: fields.count > 2 ? fields[2] : ""
            )
        }
    }

    /// Probes an alias non-interactively: connect, authenticate, run `true`,
    /// exit — it never opens a shell or a prompt. `BatchMode=yes` blocks any
    /// password/passphrase ask (so it can't hang waiting on stdin),
    /// `ConnectTimeout` bounds the network wait, and running `true` makes a clean
    /// exit mean "authenticated and the remote executed a command". Runs off the
    /// main thread; the exact ssh resolution matches a real `ssh <alias>`.
    static func testConnection(alias: String) async -> SSHProbeResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = [
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=6",
                    // A never-seen host would otherwise fail the probe on the
                    // host-key prompt BatchMode suppresses; accept-new records it
                    // exactly as a first real connect would.
                    "-o", "StrictHostKeyChecking=accept-new",
                    alias, "true",
                ]
                let errorPipe = Pipe()
                process.standardError = errorPipe
                process.standardOutput = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .unreachable("ssh unavailable"))
                    return
                }
                // Drain before wait: a full stderr pipe would deadlock a process
                // we're blocking on. EOF arrives when ssh exits and closes it.
                let stderr = String(
                    data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
                ) ?? ""
                process.waitUntilExit()
                continuation.resume(
                    returning: process.terminationStatus == 0 ? .reachable : classify(stderr)
                )
            }
        }
    }

    /// Buckets ssh's stderr into the probe outcomes, keeping the clearest line as
    /// the detail. Auth failures (including BatchMode's "we won't ask for a
    /// password") are told apart from the host being unreachable.
    private static func classify(_ stderr: String) -> SSHProbeResult {
        let lower = stderr.lowercased()
        let lastLine = stderr
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? "Connection failed"
        if lower.contains("permission denied")
            || lower.contains("too many authentication failures")
            || lower.contains("no supported authentication methods") {
            return .authFailed(lastLine)
        }
        if lower.contains("could not resolve") || lower.contains("name or service not known") {
            return .unreachable("Host not found")
        }
        if lower.contains("connection refused") { return .unreachable("Connection refused") }
        if lower.contains("no route to host") { return .unreachable("No route to host") }
        if lower.contains("timed out") { return .unreachable("Timed out") }
        return .unreachable(lastLine)
    }
}
