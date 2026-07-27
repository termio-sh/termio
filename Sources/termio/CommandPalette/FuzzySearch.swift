import Foundation

/// A file inside a project, carried with its repo-relative path (the search key
/// and result subtitle) alongside the absolute URL the editor opens. Shared by
/// the Open Quickly palette and the file browser's search pane.
struct ProjectFile: Sendable {
    let relative: String
    let url: URL
}

/// The fuzzy matcher and project file lister behind Open Quickly (⌘⇧O), split
/// out of `CommandPalette` so future consumers share one notion of "matches".
/// (Content search is separate — see `ContentSearch`.)
enum FuzzySearch {
    /// otty-style subsequence match: every query character must appear in
    /// order. Scoring is transparent, not learned — word-boundary hits beat
    /// consecutive runs beat scattered ones, and long candidates pay a small
    /// length tax so `App.swift` outranks a deep path with the same letters.
    static func score(_ query: String, in candidate: String) -> Int? {
        let q = Array(query.lowercased())
        let c = Array(candidate)
        let lower = Array(candidate.lowercased())
        var qi = 0, score = 0, lastMatch = -2
        for i in 0..<lower.count where qi < q.count {
            guard lower[i] == q[qi] else { continue }
            if i == 0 || "/ ._-+".contains(lower[i - 1]) || (c[i].isUppercase && !c[i - 1].isUppercase) {
                score += 3
            } else if lastMatch == i - 1 {
                score += 2
            } else {
                score += 1
            }
            lastMatch = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        return score - candidate.count / 16
    }

    /// `git ls-files` (tracked + untracked-but-not-ignored, so ignore rules
    /// apply for free); a non-repo folder falls back to a filesystem walk
    /// that skips hidden entries. Both capped at `limit`. Blocking — call it
    /// off the main thread.
    nonisolated static func listFiles(under root: URL, limit: Int) -> [ProjectFile] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "ls-files", "--cached", "--others", "--exclude-standard"]
        process.environment = GitEnvironment.optionalLocksDisabled
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        if (try? process.run()) != nil {
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0, let out = String(data: data, encoding: .utf8) {
                let relatives = out.split(separator: "\n").prefix(limit)
                if !relatives.isEmpty {
                    return relatives.map {
                        ProjectFile(relative: String($0), url: root.appendingPathComponent(String($0)))
                    }
                }
            }
        }
        var out: [ProjectFile] = []
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        let prefixLength = root.path.count + 1
        while let url = enumerator?.nextObject() as? URL, out.count < limit {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            out.append(ProjectFile(relative: String(url.path.dropFirst(prefixLength)), url: url))
        }
        return out
    }
}
