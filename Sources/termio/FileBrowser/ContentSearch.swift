import Foundation

/// One grep hit: a line of a file that contains the query.
struct ContentMatch: Sendable {
    /// Path relative to the searched root — the grouping key and header label.
    let relative: String
    let url: URL
    /// 1-based line number, as grep reports it.
    let line: Int
    /// The matched line's text (capped, untrimmed — the row trims for display).
    let text: String
}

/// Project-wide content search behind the inspector's Search pane. `git grep`
/// first — tracked + untracked-but-not-ignored, so ignore rules apply for free,
/// exactly the `listFiles` bargain — falling back to BSD `grep -r` outside a
/// repo. Fixed-string (no regex surprises), smart-case (case-sensitive only
/// when the query has an uppercase letter), binaries skipped, per-file and
/// total caps so a one-letter query in a monorepo can't flood the pane.
/// Cancellation-aware: cancelling the surrounding task terminates the grep.
enum ContentSearch {
    /// Hits per file — past this the file's header row says "in this file",
    /// and the user should sharpen the query.
    private static let perFileLimit = "20"
    /// Longest line text kept; minified bundles can put megabytes on one line.
    private static let lineCap = 500
    /// Byte ceiling on buffered tool output. `maxLines` bounds complete lines,
    /// but the reader only counts newlines — one minified bundle line could
    /// otherwise grow the buffer without limit before its newline ever arrives.
    private static let outputByteCap = 4 << 20

    nonisolated static func search(_ query: String, under root: URL, limit: Int) async -> [ContentMatch] {
        guard !query.isEmpty else { return [] }
        // Smart case, the fzf/ripgrep default: all-lowercase queries match
        // insensitively; an uppercase letter opts into exactness.
        let insensitive = query == query.lowercased()

        var gitArgs = ["-C", root.path, "grep", "-I", "--line-number",
                       "--fixed-strings", "--untracked", "--max-count=\(perFileLimit)"]
        if insensitive { gitArgs.append("--ignore-case") }
        gitArgs += ["-e", query, "--", "."]
        // Exit 0 = hits, 1 = clean no-hits; ≥2 = not a repo (or git error) → fall back.
        if let result = await run("/usr/bin/git", gitArgs, maxLines: limit), result.status <= 1 {
            return parse(result.output, root: root, strippingPrefix: nil, limit: limit)
        }
        // A cancelled git grep dies by signal, which looks like the ≥2 error
        // path — don't misread it as "not a repo" and launch the fallback scan.
        guard !Task.isCancelled else { return [] }

        var grepArgs = ["-r", "-n", "--fixed-strings", "--binary-files=without-match",
                        "-m", perFileLimit,
                        "--exclude-dir=.git", "--exclude-dir=node_modules",
                        "--exclude-dir=.build", "--exclude-dir=DerivedData"]
        if insensitive { grepArgs.append("-i") }
        grepArgs += ["-e", query, root.path]
        guard let result = await run("/usr/bin/grep", grepArgs, maxLines: limit), result.status <= 1 else { return [] }
        return parse(result.output, root: root, strippingPrefix: root.path + "/", limit: limit)
    }

    /// `path:line:text` per line — git grep emits repo-relative paths, BSD grep
    /// absolute ones (stripped back to relative via `strippingPrefix`). A path
    /// containing `:` would mis-split; accepted as vanishingly rare.
    private static func parse(_ output: String, root: URL, strippingPrefix: String?, limit: Int) -> [ContentMatch] {
        var out: [ContentMatch] = []
        // Walk lines by index instead of `split`: split materializes every line
        // of the output up front, paying for the whole array even though this
        // loop stops at `limit`.
        var cursor = output.startIndex
        while cursor < output.endIndex, out.count < limit {
            let lineEnd = output[cursor...].firstIndex(of: "\n") ?? output.endIndex
            let rawLine = output[cursor..<lineEnd]
            cursor = lineEnd == output.endIndex ? output.endIndex : output.index(after: lineEnd)
            guard let firstColon = rawLine.firstIndex(of: ":") else { continue }
            let afterPath = rawLine.index(after: firstColon)
            guard let secondColon = rawLine[afterPath...].firstIndex(of: ":"),
                  let lineNumber = Int(rawLine[afterPath..<secondColon]) else { continue }
            var path = String(rawLine[..<firstColon])
            if let strippingPrefix, path.hasPrefix(strippingPrefix) {
                path = String(path.dropFirst(strippingPrefix.count))
            }
            let text = String(rawLine[rawLine.index(after: secondColon)...].prefix(lineCap))
            out.append(ContentMatch(
                relative: path,
                url: root.appendingPathComponent(path),
                line: lineNumber,
                text: text
            ))
        }
        return out
    }

    /// Runs the tool, draining stdout incrementally. `--max-count` is per FILE,
    /// so a short query in a monorepo has no global bound — the caller only
    /// keeps `maxLines` lines, so once that many have arrived the tool is
    /// terminated instead of letting it flood the pipe. Cancelling the
    /// surrounding task also terminates it, which unblocks the read via EOF.
    private static func run(
        _ executable: String, _ arguments: [String], maxLines: Int
    ) async -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // See `GitEnvironment`: keep `git grep` from touching the index; the BSD
        // `grep` fallback ignores it.
        if executable.hasSuffix("/git") {
            process.environment = GitEnvironment.optionalLocksDisabled
        }
        let stdout = Pipe()
        process.standardOutput = stdout
        // Never attach a pipe that isn't drained: BSD grep can emit 64KB+ of
        // per-file "Permission denied" noise, filling the buffer and deadlocking
        // the child against our stdout read. Discard stderr at the kernel.
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        return await withTaskCancellationHandler {
            let handle = stdout.fileHandleForReading
            var data = Data()
            var newlines = 0
            var stoppedEarly = false
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }  // EOF: exited, or terminated by cancel
                for byte in chunk where byte == UInt8(ascii: "\n") { newlines += 1 }
                data.append(chunk)
                if newlines >= maxLines || data.count >= outputByteCap {
                    stoppedEarly = true
                    process.terminate()
                    break
                }
            }
            process.waitUntilExit()
            // Lossy on purpose: stopping at a cap can cut the final chunk
            // mid-codepoint, and a strict decode would trade every hit already
            // buffered for one dangling byte.
            let output = String(decoding: data, as: UTF8.self)
            // Self-terminated = success with a full budget of lines; the real
            // exit status is just the SIGTERM we sent.
            return (stoppedEarly ? 0 : process.terminationStatus, output)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
