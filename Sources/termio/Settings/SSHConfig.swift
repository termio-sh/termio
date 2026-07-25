import Foundation

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

    /// The connectable hosts from `~/.ssh/config` and any `Include`d files.
    /// Wildcard patterns (`Host *`, globs, negations) are skipped — they are
    /// defaults, not destinations.
    static func hosts() -> [SSHConfigHost] {
        var visited: Set<String> = []
        return hosts(in: configURL, visited: &visited, depth: 0)
    }

    private static func hosts(in url: URL, visited: inout Set<String>, depth: Int) -> [SSHConfigHost] {
        let path = url.standardizedFileURL.path
        // The depth cap breaks Include chains that self-reference through a glob
        // the visited set can't catch (e.g. re-listing a rewritten temp file).
        guard depth <= 3, !visited.contains(path),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        visited.insert(path)

        var hosts: [SSHConfigHost] = []
        var aliases: [String] = []
        var hostName = "", user = ""
        var identityFile: String?
        var port = 22
        var blockLine = 0

        func flush() {
            for alias in aliases
            where !alias.contains("*") && !alias.contains("?") && !alias.hasPrefix("!") {
                hosts.append(SSHConfigHost(
                    alias: alias, hostName: hostName.isEmpty ? alias : hostName,
                    user: user, port: port, identityFile: identityFile,
                    file: url, line: blockLine
                ))
            }
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // `Keyword value…` — the keyword match is case-insensitive per
            // ssh_config(5), and `=` is a valid keyword/value separator.
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
                .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                .filter { !$0.isEmpty }
            guard let keyword = parts.first?.lowercased() else { continue }
            let values = Array(parts.dropFirst())
            switch keyword {
            case "host":
                flush()
                aliases = values
                hostName = ""; user = ""; port = 22; identityFile = nil
                blockLine = index + 1
            case "hostname": hostName = values.first ?? ""
            case "user": user = values.first ?? ""
            case "port": port = values.first.flatMap(Int.init) ?? 22
            case "identityfile": if identityFile == nil { identityFile = values.first }
            case "include":
                for value in values {
                    for included in resolveInclude(value) {
                        hosts.append(contentsOf: Self.hosts(
                            in: included, visited: &visited, depth: depth + 1
                        ))
                    }
                }
            default: break
            }
        }
        flush()
        return hosts
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
        if !manager.fileExists(atPath: configURL.path) {
            manager.createFile(
                atPath: configURL.path, contents: Data(),
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
        var block = "Host \(alias)\n  HostName \(hostName)\n"
        if !user.isEmpty { block += "  User \(user)\n" }
        if let portNumber = Int(port), portNumber != 22 { block += "  Port \(portNumber)\n" }
        if !identityFile.isEmpty { block += "  IdentityFile \(identityFile)\n" }

        try ensureConfigExists()
        var text = try String(contentsOf: configURL, encoding: .utf8)
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        if !text.isEmpty { text += "\n" }
        try (text + block).write(to: configURL, atomically: true, encoding: .utf8)
        // The atomic write lands as a fresh temp file, so re-assert the 0600 ssh
        // expects rather than inheriting the process umask.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: configURL.path
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
            case let raw: algorithm = raw
            }
            return SSHPublicKey(
                url: url, algorithm: algorithm,
                comment: fields.count > 2 ? fields[2] : ""
            )
        }
    }
}
